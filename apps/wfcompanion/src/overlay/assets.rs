use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;

use serde_json::{Value, json};

use crate::painter::{RasterImage, load_scene_icon};
use crate::relic::Scene;

const DECODED_BUDGET: usize = 64 * 1024 * 1024;
const IMAGE_BUDGET: usize = 16 * 1024 * 1024;

#[derive(Clone, Default)]
pub(super) struct SceneAssets {
    pub(super) images: BTreeMap<String, Arc<RasterImage>>,
    pub(super) issues: Vec<Value>,
}

impl SceneAssets {
    pub(super) fn prepare(&mut self, scene: &Scene, current: impl Fn() -> bool) {
        self.prepare_with_budget(scene, DECODED_BUDGET, current);
    }

    fn prepare_with_budget(&mut self, scene: &Scene, budget: usize, current: impl Fn() -> bool) {
        let mut previous = std::mem::take(&mut self.images);
        self.issues.clear();
        let Scene::Rewards(rewards) = scene else {
            return;
        };
        let requested = rewards
            .items
            .iter()
            .flat_map(|reward| {
                reward
                    .asset
                    .iter()
                    .chain(reward.parts.iter().filter_map(|part| part.asset.as_ref()))
            })
            .map(|asset| (&asset.digest, asset))
            .collect::<BTreeMap<_, _>>();
        previous.retain(|digest, _| requested.contains_key(digest));
        let mut used = 0;
        for (digest, asset) in requested {
            if !current() {
                return;
            }
            if digest == crate::assets::FORMA_ASSET.image.key {
                continue;
            }
            let remaining = budget.saturating_sub(used);
            let image = if let Some(image) = previous.remove(digest) {
                if image.byte_len() <= remaining {
                    Ok(image)
                } else {
                    Err("image exceeds decoded asset budget".to_owned())
                }
            } else {
                load_scene_icon(&asset.path, remaining.min(IMAGE_BUDGET))
                    .map(Arc::new)
                    .map_err(|error| error.to_string())
            };
            match image {
                Ok(image) => {
                    used += image.byte_len();
                    self.images.insert(digest.clone(), image);
                }
                Err(error) => self.issues.push(json!({
                    "kind": "asset_decode", "identity": asset.id,
                    "reason": error, "fallback": asset.image_name, "class": "companion"
                })),
            }
        }
    }
}

struct Request {
    revision: u64,
    scene: Scene,
}

pub(super) struct Loader {
    revision: Arc<AtomicU64>,
    sender: Option<mpsc::SyncSender<Request>>,
    receiver: Option<mpsc::Receiver<(u64, SceneAssets)>>,
    worker: Option<thread::JoinHandle<()>>,
    pending: Option<Request>,
}

impl Loader {
    pub(super) fn spawn() -> Self {
        let (sender, requests) = mpsc::sync_channel::<Request>(1);
        let (results, receiver) = mpsc::sync_channel(1);
        let revision = Arc::new(AtomicU64::new(0));
        let current_revision = revision.clone();
        let worker = thread::spawn(move || {
            let mut assets = SceneAssets::default();
            while let Ok(request) = requests.recv() {
                let current = || current_revision.load(Ordering::Acquire) == request.revision;
                if !current() {
                    continue;
                }
                assets.prepare(&request.scene, current);
                if current() && results.send((request.revision, assets.clone())).is_err() {
                    break;
                }
            }
        });
        Self {
            revision,
            sender: Some(sender),
            receiver: Some(receiver),
            worker: Some(worker),
            pending: None,
        }
    }

    pub(super) fn request(&mut self, scene: Scene) {
        let revision = self.revision.fetch_add(1, Ordering::AcqRel) + 1;
        self.pending = Some(Request { revision, scene });
        self.flush();
    }

    pub(super) fn poll(&mut self) -> Option<SceneAssets> {
        self.flush();
        let mut ready = None;
        while let Ok((revision, assets)) = self.receiver.as_ref().unwrap().try_recv() {
            if revision == self.revision.load(Ordering::Acquire) {
                ready = Some(assets);
            }
        }
        ready
    }

    fn flush(&mut self) {
        if let Some(request) = self.pending.take()
            && let Err(mpsc::TrySendError::Full(request)) =
                self.sender.as_ref().unwrap().try_send(request)
        {
            self.pending = Some(request);
        }
    }
}

impl Drop for Loader {
    fn drop(&mut self) {
        self.revision.fetch_add(1, Ordering::AcqRel);
        self.sender.take();
        self.receiver.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scene_cache_has_a_byte_budget_and_reuses_images() {
        let scene = super::super::screens::mock_relic_scene();
        let mut assets = SceneAssets::default();
        assets.prepare(&scene, || true);
        assert!(!assets.images.is_empty());
        let previous = assets.images.clone();
        assets.prepare(&scene, || true);
        assert!(
            assets
                .images
                .iter()
                .all(|(id, image)| Arc::ptr_eq(image, &previous[id]))
        );
        assets.prepare_with_budget(&scene, 1024, || true);
        assert!(
            assets
                .images
                .values()
                .map(|image| image.byte_len())
                .sum::<usize>()
                <= 1024
        );
        assert!(!assets.issues.is_empty());
        assets = SceneAssets::default();
        assets.prepare_with_budget(&scene, 1, || true);
        assert!(assets.images.is_empty());
        assert!(!assets.issues.is_empty());
    }

    #[test]
    fn stale_load_result_is_not_installed() {
        let (sender, _) = mpsc::sync_channel(1);
        let (results, receiver) = mpsc::sync_channel(1);
        let mut loader = Loader {
            revision: Arc::new(AtomicU64::new(2)),
            sender: Some(sender),
            receiver: Some(receiver),
            worker: None,
            pending: None,
        };
        results.send((1, SceneAssets::default())).unwrap();
        assert!(loader.poll().is_none());
        results.send((2, SceneAssets::default())).unwrap();
        assert!(loader.poll().is_some());
    }

    #[test]
    fn pending_load_is_replaced_with_the_latest_scene() {
        let (sender, requests) = mpsc::sync_channel(1);
        let (_results, receiver) = mpsc::sync_channel(1);
        let mut loader = Loader {
            revision: Arc::new(AtomicU64::new(0)),
            sender: Some(sender),
            receiver: Some(receiver),
            worker: None,
            pending: None,
        };
        loader.request(Scene::Reading);
        loader.request(Scene::Error("obsolete".to_owned()));
        loader.request(Scene::Error("latest".to_owned()));
        assert_eq!(requests.recv().unwrap().revision, 1);
        loader.flush();
        let request = requests.recv().unwrap();
        assert_eq!(request.revision, 3);
        assert_eq!(request.scene, Scene::Error("latest".to_owned()));
        assert!(loader.pending.is_none());
    }

    #[test]
    #[ignore = "manual cached-asset decode benchmark"]
    fn benchmark_scene_assets() {
        let mut scene = super::super::screens::mock_relic_scene();
        if let Ok(directory) = std::env::var("WFCOMPANION_BENCH_ASSET_DIR") {
            let paths = std::fs::read_dir(directory)
                .unwrap()
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| {
                    matches!(
                        path.extension().and_then(|value| value.to_str()),
                        Some("png" | "webp")
                    )
                });
            let Scene::Rewards(rewards) = &mut scene else {
                unreachable!()
            };
            for (asset, path) in rewards
                .items
                .iter_mut()
                .flat_map(|reward| {
                    reward.asset.iter_mut().chain(
                        reward
                            .parts
                            .iter_mut()
                            .filter_map(|part| part.asset.as_mut()),
                    )
                })
                .zip(paths)
            {
                asset.path = path.to_string_lossy().into_owned();
                asset.digest = asset.path.clone();
            }
        }
        let mut assets = SceneAssets::default();
        for pass in ["decode", "reuse"] {
            let started = std::time::Instant::now();
            assets.prepare(&scene, || true);
            eprintln!(
                "scene_assets pass={pass} elapsed_us={} images={} bytes={} errors={}",
                started.elapsed().as_micros(),
                assets.images.len(),
                assets
                    .images
                    .values()
                    .map(|image| image.byte_len())
                    .sum::<usize>(),
                assets.issues.len()
            );
        }
    }
}
