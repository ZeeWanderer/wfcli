use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use crate::UiEvent;
use crate::assets;
use crate::capture;
use crate::daemon::OutboundSender;
use crate::incident;
use image::DynamicImage;

mod capture_analysis;
mod enrichment;
mod model;

#[cfg(test)]
use model::Suggestion;
pub(crate) use model::{
    Account, Asset, AssetRefresh, Reward, Rewards, Scene, SetPart, Suggestions, Trigger,
};

use capture_analysis::{capture_trigger, detect_player_count, read_candidate, suggestion_era};
#[cfg(test)]
use capture_analysis::{clean_label, parse_suggestion_era, reward_regions};
#[cfg(test)]
use enrichment::{
    AssetSpec, ContextReply, MarketMatch, accepted_match, candidate_score, embedded_asset, is_forma,
};
use enrichment::{contextual_rewards, resolve_assets, resolve_reward_candidates, reward_context};

const REWARD_CAPTURE_DELAY: Duration = Duration::from_millis(650);
const REWARD_TRIGGER_DEDUPLICATION: Duration = Duration::from_secs(30);
const RETRY_DELAY: Duration = Duration::from_millis(1500);
const SUGGESTION_CAPTURE_DELAY: Duration = Duration::from_millis(750);
const SUGGESTION_RETRY_DELAY: Duration = Duration::from_millis(1000);
const SUGGESTION_TRIGGER_DEDUPLICATION: Duration = Duration::from_secs(2);
const SUGGESTION_REWARD_FALLBACK: Duration = Duration::from_secs(23);
const SUGGESTION_CLOSE_GUARD: Duration = Duration::from_millis(500);
const POST_REWARD_SUGGESTION_CLOSE_GUARD: Duration = Duration::from_millis(3500);
const REWARD_SCENE_LIFETIME: Duration = Duration::from_secs(15);
const ERROR_SCENE_LIFETIME: Duration = Duration::from_secs(8);
const REWARD_IDENTIFICATION_FAILED: &str = "could not identify relic reward names";
const TESSERACT_ARGUMENTS: &[&str] = &[
    "stdout",
    "--oem",
    "1",
    "--psm",
    "6",
    "-l",
    "eng",
    "-c",
    "preserve_interword_spaces=1",
];

pub(crate) fn suggestion_fixture() -> Result<Scene, String> {
    serde_json::from_str(include_str!("../fixtures/relic-suggestions.json"))
        .map(Scene::Suggestions)
        .map_err(|error| format!("invalid relic suggestion fixture: {error}"))
}

pub(crate) fn reward_preview_scene(path: &Path, daemon: &OutboundSender) -> Result<Scene, String> {
    let image =
        image::open(path).map_err(|error| format!("could not read {}: {error}", path.display()))?;
    let rewards = scan_rewards(&image, daemon)?;
    let Some(context) = reward_context(daemon, &rewards)? else {
        return Ok(Scene::Rewards(Rewards {
            items: rewards,
            account: Account::default(),
        }));
    };
    let assets = resolve_assets(daemon, &context);
    Ok(Scene::Rewards(contextual_rewards(
        rewards, &context, &assets,
    )))
}

pub(crate) fn suggestion_preview_scene(
    era: String,
    daemon: &OutboundSender,
) -> Result<Scene, String> {
    crate::daemon::relic_recommendations(daemon, era, true)
        .and_then(|response| parse_suggestions(&response))
        .map(Scene::Suggestions)
}

pub(crate) fn diagnose(path: &Path) -> Result<serde_json::Value, String> {
    let image =
        image::open(path).map_err(|error| format!("could not read {}: {error}", path.display()))?;
    diagnose_image(
        &image,
        serde_json::Value::String(path.display().to_string()),
    )
}

pub(crate) fn diagnose_image(
    image: &DynamicImage,
    source: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let detected_layouts = [Geometry::Normal, Geometry::Legacy]
        .into_iter()
        .map(|geometry| {
            serde_json::json!({
                "geometry": geometry_name(geometry),
                "players": detect_player_count(image, geometry),
            })
        })
        .collect::<Vec<_>>();
    let mut candidates = Vec::new();
    for geometry in [Geometry::Normal, Geometry::Legacy] {
        for count in (1..=4).rev() {
            let candidate = read_candidate(image, geometry, count)?;
            candidates.push(serde_json::json!({
                "geometry": geometry_name(geometry),
                "players": count,
                "labels": candidate.labels,
            }));
        }
    }
    Ok(serde_json::json!({
        "image": {
            "source": source,
            "width": image.width(),
            "height": image.height(),
        },
        "detected_layouts": detected_layouts,
        "candidates": candidates,
    }))
}

fn geometry_name(geometry: Geometry) -> &'static str {
    match geometry {
        Geometry::Normal => "normal",
        Geometry::Legacy => "legacy",
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Geometry {
    Normal,
    Legacy,
}

#[derive(Clone, Debug)]
struct Candidate {
    geometry: Geometry,
    count: usize,
    labels: Vec<String>,
}

pub(crate) fn spawn(
    triggers: mpsc::Receiver<Trigger>,
    daemon: OutboundSender,
    ui: mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
) {
    thread::spawn(move || {
        let mut last_reward_trigger: Option<Instant> = None;
        let mut last_suggestion_trigger: Option<Instant> = None;
        let mut last_suggestion_era: Option<String> = None;
        let mut last_suggestion_opened: Option<Instant> = None;
        let mut suggestion_after_reward = false;
        let mut suggestion_dismissed = false;
        let suggestion_generation = Arc::new(AtomicU64::new(0));
        while !stopping.load(Ordering::Relaxed) {
            let trigger = match triggers.recv_timeout(Duration::from_millis(200)) {
                Ok(trigger) => trigger,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            };
            let trigger_name = match &trigger {
                Trigger::Rewards => "rewards",
                Trigger::Suggestions => "suggestions",
                Trigger::CloseSuggestions => "close_suggestions",
                Trigger::DismissSuggestions => "dismiss_suggestions",
                Trigger::Screenshot(_) => "screenshot",
            };
            match trigger {
                Trigger::Suggestions => {
                    if suggestion_dismissed {
                        incident::info("relic.suggestion_dismissed", "current_context");
                        continue;
                    }
                    if reject_recent_trigger(
                        &mut last_suggestion_trigger,
                        SUGGESTION_TRIGGER_DEDUPLICATION,
                    ) {
                        incident::info("relic.suggestion_duplicate", "debug_output");
                        continue;
                    }
                    let reward_recent = last_reward_trigger.is_some_and(|seen| {
                        Instant::now().saturating_duration_since(seen) < SUGGESTION_REWARD_FALLBACK
                    });
                    let _ = ui.send(UiEvent::RelicSuggestionStart);
                    let opened = Instant::now();
                    let generation = suggestion_generation.fetch_add(1, Ordering::AcqRel) + 1;
                    match show_suggestions(
                        &daemon,
                        &ui,
                        reward_recent
                            .then_some(last_suggestion_era.as_deref())
                            .flatten(),
                    ) {
                        Ok(era) => {
                            last_suggestion_era = Some(era.clone());
                            last_suggestion_opened = Some(opened);
                            suggestion_after_reward = reward_recent;
                            spawn_suggestion_prices(
                                daemon.clone(),
                                ui.clone(),
                                stopping.clone(),
                                suggestion_generation.clone(),
                                generation,
                                era,
                            );
                        }
                        Err(error) => {
                            incident::warn("relic.suggestion_failed", &error);
                        }
                    }
                    continue;
                }
                Trigger::CloseSuggestions => {
                    suggestion_dismissed = false;
                    if let Some(opened) = last_suggestion_opened {
                        let elapsed = opened.elapsed();
                        if ignore_suggestion_close(suggestion_after_reward, elapsed) {
                            incident::info(
                                "relic.suggestion_close_ignored",
                                format!(
                                    "source=debug_output elapsed_ms={} after_reward={suggestion_after_reward}",
                                    elapsed.as_millis()
                                ),
                            );
                            continue;
                        }
                        incident::info(
                            "relic.suggestion_close",
                            format!(
                                "source=debug_output elapsed_ms={} after_reward={suggestion_after_reward}",
                                elapsed.as_millis()
                            ),
                        );
                    }
                    last_suggestion_opened = None;
                    suggestion_after_reward = false;
                    suggestion_generation.fetch_add(1, Ordering::AcqRel);
                    let _ = ui.send(UiEvent::RelicDismiss);
                    continue;
                }
                Trigger::DismissSuggestions => {
                    suggestion_dismissed = true;
                    last_suggestion_opened = None;
                    suggestion_after_reward = false;
                    suggestion_generation.fetch_add(1, Ordering::AcqRel);
                    incident::info("relic.suggestion_dismiss", "current_context");
                    continue;
                }
                Trigger::Rewards => {
                    suggestion_dismissed = false;
                }
                Trigger::Screenshot(_) => {}
            }
            suggestion_generation.fetch_add(1, Ordering::AcqRel);
            let live_capture = matches!(&trigger, Trigger::Rewards);
            if live_capture && reject_duplicate_reward_trigger(&mut last_reward_trigger) {
                incident::info("relic.trigger_duplicate", &trigger_name);
                continue;
            }
            incident::info("relic.trigger", &trigger_name);
            if live_capture {
                thread::sleep(REWARD_CAPTURE_DELAY);
            }
            let image = match capture_trigger(&trigger) {
                Ok(image) => image,
                Err(first_error) if live_capture => {
                    incident::warn("relic.capture_retry", &first_error);
                    thread::sleep(RETRY_DELAY);
                    match capture_trigger(&trigger) {
                        Ok(image) => image,
                        Err(error) => {
                            incident::error("relic.capture_failed", &error);
                            eprintln!("wfcompanion: relic capture failed: {error}");
                            send_scene(&ui, Scene::Error(error), None);
                            last_reward_trigger = None;
                            continue;
                        }
                    }
                }
                Err(error) => {
                    incident::error("relic.capture_failed", &error);
                    eprintln!("wfcompanion: relic capture failed: {error}");
                    send_scene(&ui, Scene::Error(error), None);
                    last_reward_trigger = None;
                    continue;
                }
            };
            let scene_deadline = live_capture.then(|| Instant::now() + REWARD_SCENE_LIFETIME);
            if live_capture {
                send_scene(&ui, Scene::Reading, scene_deadline);
            }
            incident::info(
                "relic.capture_ready",
                format!("{}x{} source={trigger_name}", image.width(), image.height()),
            );
            let started = Instant::now();
            let scanned = match scan_rewards(&image, &daemon) {
                Err(first_error) if live_capture => {
                    incident::warn("relic.ocr_retry", &first_error);
                    thread::sleep(RETRY_DELAY);
                    capture_trigger(&trigger).and_then(|retry| {
                        incident::info(
                            "relic.capture_ready",
                            format!("{}x{} source=retry", retry.width(), retry.height()),
                        );
                        scan_rewards(&retry, &daemon)
                    })
                }
                result => result,
            };
            match scanned {
                Ok(candidates) => {
                    let names = candidates
                        .iter()
                        .map(|reward| reward.name.as_str())
                        .collect::<Vec<_>>()
                        .join(" | ");
                    incident::info(
                        "relic.names_ready",
                        format!(
                            "elapsed_ms={} rewards={names}",
                            started.elapsed().as_millis()
                        ),
                    );
                    send_scene(
                        &ui,
                        Scene::Rewards(Rewards {
                            items: candidates.clone(),
                            account: Account::default(),
                        }),
                        scene_deadline,
                    );
                    match reward_context(&daemon, &candidates) {
                        Ok(Some(context)) => {
                            let contextual = contextual_rewards(
                                candidates.clone(),
                                &context,
                                &std::collections::BTreeMap::new(),
                            );
                            incident::info(
                                "relic.context_ready",
                                format!("elapsed_ms={}", started.elapsed().as_millis()),
                            );
                            send_scene(&ui, Scene::Rewards(contextual.clone()), scene_deadline);

                            let assets = resolve_assets(&daemon, &context);
                            let complete = contextual_rewards(candidates, &context, &assets);
                            if complete != contextual {
                                incident::info(
                                    "relic.assets_ready",
                                    format!(
                                        "elapsed_ms={} assets={}",
                                        started.elapsed().as_millis(),
                                        assets.len()
                                    ),
                                );
                                send_scene(&ui, Scene::Rewards(complete), scene_deadline);
                            }
                            eprintln!(
                                "wfcompanion: relic reward scene ready in {} ms",
                                started.elapsed().as_millis()
                            );
                        }
                        Ok(None) => incident::info(
                            "relic.context_ready",
                            format!(
                                "elapsed_ms={} market=not_required",
                                started.elapsed().as_millis()
                            ),
                        ),
                        Err(error) => {
                            incident::error("relic.context_failed", &error);
                            eprintln!("wfcompanion: relic context lookup failed: {error}");
                        }
                    }
                }
                Err(error) => {
                    incident::error("relic.ocr_failed", &error);
                    eprintln!("wfcompanion: relic OCR failed: {error}");
                    send_scene(&ui, Scene::Error(error), scene_deadline);
                    if live_capture {
                        last_reward_trigger = None;
                    }
                }
            }
        }
    });
}

fn send_scene(ui: &mpsc::Sender<UiEvent>, scene: Scene, deadline: Option<Instant>) {
    let deadline = deadline.or_else(|| {
        let lifetime = match &scene {
            Scene::Error(_) => Some(ERROR_SCENE_LIFETIME),
            Scene::Reading | Scene::Rewards(_) => Some(REWARD_SCENE_LIFETIME),
            Scene::Suggestions(_) => None,
        };
        lifetime.map(|lifetime| Instant::now() + lifetime)
    });
    let _ = ui.send(UiEvent::RelicScene { scene, deadline });
}

fn reject_duplicate_reward_trigger(last: &mut Option<Instant>) -> bool {
    reject_recent_trigger(last, REWARD_TRIGGER_DEDUPLICATION)
}

fn reject_recent_trigger(last: &mut Option<Instant>, duration: Duration) -> bool {
    let now = Instant::now();
    if last.is_some_and(|seen| now.saturating_duration_since(seen) < duration) {
        true
    } else {
        *last = Some(now);
        false
    }
}

fn ignore_suggestion_close(after_reward: bool, elapsed: Duration) -> bool {
    elapsed < SUGGESTION_CLOSE_GUARD
        || (after_reward && elapsed < POST_REWARD_SUGGESTION_CLOSE_GUARD)
}

fn show_suggestions(
    daemon: &OutboundSender,
    ui: &mpsc::Sender<UiEvent>,
    fallback_era: Option<&str>,
) -> Result<String, String> {
    let started = Instant::now();
    thread::sleep(SUGGESTION_CAPTURE_DELAY);
    let (mut era, mut capture_ms, mut ocr_ms) = timed_suggestion_era();
    let mut retried = false;
    if let Err(first_error) = &era {
        incident::warn("relic.suggestion_ocr_retry", &first_error);
        thread::sleep(SUGGESTION_RETRY_DELAY);
        retried = true;
        let (retry, retry_capture_ms, retry_ocr_ms) = timed_suggestion_era();
        era = retry;
        capture_ms += retry_capture_ms;
        ocr_ms += retry_ocr_ms;
    }
    let era = match era {
        Ok(era) => era,
        Err(error) => fallback_era.map(str::to_owned).ok_or(error)?,
    };
    let daemon_started = Instant::now();
    let response = crate::daemon::relic_recommendations(daemon, era.clone(), false)?;
    let daemon_ms = daemon_started.elapsed().as_millis();
    let suggestions = parse_suggestions(&response)?;
    let priced = priced_suggestion_count(&suggestions);
    let total_ms = started.elapsed().as_millis();
    incident::info(
        "relic.suggestion_ready",
        format!(
            "era={era} relics={} priced={priced} total_ms={total_ms} capture_ms={capture_ms} ocr_ms={ocr_ms} daemon_ms={daemon_ms} retried={retried}",
            suggestions.items.len(),
        ),
    );
    send_scene(ui, Scene::Suggestions(suggestions), None);
    Ok(era)
}

fn timed_suggestion_era() -> (Result<String, String>, u128, u128) {
    let capture_started = Instant::now();
    let image = capture::relic_window();
    let capture_ms = capture_started.elapsed().as_millis();
    let image = match image {
        Ok(image) => image,
        Err(error) => return (Err(error), capture_ms, 0),
    };
    let ocr_started = Instant::now();
    let era = suggestion_era(&image);
    (era, capture_ms, ocr_started.elapsed().as_millis())
}

fn spawn_suggestion_prices(
    daemon: OutboundSender,
    ui: mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
    current_generation: Arc<AtomicU64>,
    generation: u64,
    era: String,
) {
    thread::spawn(move || {
        let result = crate::daemon::relic_recommendations(&daemon, era.clone(), true)
            .and_then(|response| parse_suggestions(&response));
        if stopping.load(Ordering::Relaxed)
            || current_generation.load(Ordering::Acquire) != generation
        {
            return;
        }
        match result {
            Ok(suggestions) => {
                let priced = priced_suggestion_count(&suggestions);
                incident::info(
                    "relic.suggestion_prices_ready",
                    format!(
                        "era={era} relics={} priced={priced}",
                        suggestions.items.len()
                    ),
                );
                send_scene(&ui, Scene::Suggestions(suggestions), None);
            }
            Err(error) => incident::warn("relic.suggestion_prices_failed", error),
        }
    });
}

fn parse_suggestions(response: &serde_json::Value) -> Result<Suggestions, String> {
    serde_json::from_value(
        response
            .get("data")
            .cloned()
            .ok_or_else(|| "daemon returned no relic recommendations".to_owned())?,
    )
    .map_err(|error| format!("daemon returned malformed relic recommendations: {error}"))
}

fn priced_suggestion_count(suggestions: &Suggestions) -> usize {
    suggestions
        .items
        .iter()
        .filter(|item| item.expected_platinum.is_some())
        .count()
}

fn scan_rewards(image: &DynamicImage, daemon: &OutboundSender) -> Result<Vec<Reward>, String> {
    let mut detected = Vec::new();
    for geometry in [Geometry::Normal, Geometry::Legacy] {
        if let Some(count) = detect_player_count(image, geometry) {
            detected.push(read_candidate(image, geometry, count)?);
        }
    }
    if !detected.is_empty() {
        match resolve_reward_candidates(daemon, detected) {
            Ok(detected_result) if detected_result.complete => {
                incident::info(
                    "relic.layout",
                    format!(
                        "geometry={} players={} path=border",
                        geometry_name(detected_result.geometry),
                        detected_result.count
                    ),
                );
                eprintln!(
                    "wfcompanion: relic OCR selected {:?} {}-player border path",
                    detected_result.geometry, detected_result.count
                );
                return Ok(detected_result.rewards);
            }
            Ok(_) => {}
            Err(error) if error == REWARD_IDENTIFICATION_FAILED => {}
            Err(error) => return Err(error),
        }
    }

    let fast = read_candidate(image, Geometry::Normal, 4)?;
    let fast_result = resolve_reward_candidates(daemon, vec![fast.clone()])?;
    if fast_result.complete {
        incident::info("relic.layout", "geometry=normal players=4 path=fast");
        eprintln!("wfcompanion: relic OCR selected Normal 4-player fast path");
        return Ok(fast_result.rewards);
    }

    let mut normal = vec![fast];
    for count in (1..=3).rev() {
        normal.push(read_candidate(image, Geometry::Normal, count)?);
    }
    let normal_result = resolve_reward_candidates(daemon, normal)?;
    if normal_result.complete {
        incident::info(
            "relic.layout",
            format!(
                "geometry={} players={}",
                geometry_name(normal_result.geometry),
                normal_result.count
            ),
        );
        eprintln!(
            "wfcompanion: relic OCR selected {:?} {}-player layout",
            normal_result.geometry, normal_result.count
        );
        return Ok(normal_result.rewards);
    }

    let mut legacy = Vec::with_capacity(4);
    for count in (1..=4).rev() {
        legacy.push(read_candidate(image, Geometry::Legacy, count)?);
    }
    let legacy_result = resolve_reward_candidates(daemon, legacy)?;
    let selected = if legacy_result.score > normal_result.score {
        legacy_result
    } else {
        normal_result
    };
    eprintln!(
        "wfcompanion: relic OCR selected {:?} {}-player layout",
        selected.geometry, selected.count
    );
    incident::info(
        "relic.layout",
        format!(
            "geometry={} players={}",
            geometry_name(selected.geometry),
            selected.count
        ),
    );
    Ok(selected.rewards)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suppresses_delayed_fallback_trigger_for_same_reward() {
        let mut last = Some(Instant::now() - Duration::from_secs(12));
        assert!(reject_duplicate_reward_trigger(&mut last));
        last = Some(Instant::now() - Duration::from_secs(31));
        assert!(!reject_duplicate_reward_trigger(&mut last));
    }

    #[test]
    fn suggestion_close_guards_match_aleca() {
        assert!(ignore_suggestion_close(false, Duration::from_millis(499)));
        assert!(!ignore_suggestion_close(false, Duration::from_millis(500)));
        assert!(ignore_suggestion_close(true, Duration::from_millis(3499)));
        assert!(!ignore_suggestion_close(true, Duration::from_millis(3500)));
    }

    #[test]
    fn suggestion_scene_has_no_deadline() {
        let (sender, receiver) = mpsc::channel();
        send_scene(
            &sender,
            Scene::Suggestions(Suggestions {
                trace_count: 0,
                items: Vec::new(),
            }),
            None,
        );
        let UiEvent::RelicScene { deadline, .. } = receiver.recv().unwrap() else {
            panic!("expected relic scene");
        };
        assert_eq!(deadline, None);
    }

    #[test]
    fn context_and_assets_can_be_applied_in_separate_stages() {
        let context: ContextReply = serde_json::from_value(serde_json::json!({
            "items": [{
                "slug": "test_part",
                "name": "Test Prime Part",
                "ducats": 45,
                "lowest_sell": 12,
                "count_owned": 2,
                "total_to_own": 1,
                "asset": {"id": "item", "source": "market", "image_name": "item.png"},
                "parts": [{
                    "slug": "test_part",
                    "name": "Test Prime Part",
                    "owned": 2,
                    "required": 1,
                    "asset": {"id": "part", "source": "market", "image_name": "part.png"}
                }]
            }],
            "account": {"platinum": 100, "ducats": 200}
        }))
        .unwrap();
        let base = vec![Reward::unresolved(
            "OCR name".to_owned(),
            Some("test_part".to_owned()),
            None,
        )];

        let contextual =
            contextual_rewards(base.clone(), &context, &std::collections::BTreeMap::new());
        assert_eq!(contextual.items[0].lowest_sell, Some(12));
        assert!(contextual.items[0].asset.is_none());
        assert!(contextual.items[0].parts[0].asset.is_none());

        let assets = [
            (
                "item".to_owned(),
                Asset {
                    id: "item".to_owned(),
                    source: "market".to_owned(),
                    image_name: "item.png".to_owned(),
                    path: "/tmp/item.png".to_owned(),
                    digest: "item-digest".to_owned(),
                },
            ),
            (
                "part".to_owned(),
                Asset {
                    id: "part".to_owned(),
                    source: "market".to_owned(),
                    image_name: "part.png".to_owned(),
                    path: "/tmp/part.png".to_owned(),
                    digest: "part-digest".to_owned(),
                },
            ),
        ]
        .into_iter()
        .collect();
        let complete = contextual_rewards(base, &context, &assets);
        assert_eq!(complete.items[0].asset.as_ref().unwrap().id, "item");
        assert_eq!(
            complete.items[0].parts[0].asset.as_ref().unwrap().id,
            "part"
        );
    }

    #[test]
    fn parses_relic_era_from_noisy_ocr() {
        assert_eq!(
            parse_suggestion_era("SELECT A RELIC\nA X I ERA"),
            Some("axi".to_owned())
        );
        assert_eq!(
            parse_suggestion_era("SELECT A RELIC\nALL ERA"),
            Some("all".to_owned())
        );
        assert_eq!(parse_suggestion_era("REQUIEM ERA"), None);
        assert_eq!(parse_suggestion_era("Void Fissure"), None);
    }

    #[test]
    fn detects_eras_from_1440p_selection_fixtures() {
        for (filename, expected) in [
            ("relic_selection_lith_2560x1440.jpg", "lith"),
            ("relic_selection_meso_2560x1440.jpg", "meso"),
            ("relic_selection_neo_2560x1440.jpg", "neo"),
            ("relic_selection_axi_2560x1440.jpg", "axi"),
            ("relic_selection_all_2560x1440.jpg", "all"),
        ] {
            let path = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests")
                .join("fixtures")
                .join(filename);
            let image = image::open(&path)
                .unwrap_or_else(|error| panic!("could not open {}: {error}", path.display()));
            assert_eq!(
                suggestion_era(&image).as_deref(),
                Ok(expected),
                "fixture {filename}"
            );
        }
    }

    #[test]
    fn forma_uses_overlay_value_without_market_listing() {
        let forma = Reward::forma();
        assert_eq!(forma.lowest_sell, Some(2));
        assert_eq!(forma.ducats, Some(0));
        assert_eq!(forma.crafted, Some(true));
        assert_eq!(forma.slug, None);
        assert_eq!(forma.asset.unwrap().digest, "forma.png");
    }

    #[test]
    fn counts_only_priced_relic_suggestions() {
        let suggestions = Suggestions {
            trace_count: 0,
            items: vec![
                Suggestion {
                    name: "Lith A1".to_owned(),
                    amount_owned: 1,
                    vaulted: false,
                    favorite: false,
                    expected_platinum: Some(12),
                    expected_ducats: 20,
                },
                Suggestion {
                    name: "Lith B1".to_owned(),
                    amount_owned: 1,
                    vaulted: false,
                    favorite: false,
                    expected_platinum: None,
                    expected_ducats: 15,
                },
            ],
        };

        assert_eq!(priced_suggestion_count(&suggestions), 1);
    }

    #[test]
    fn only_synthetic_assets_bypass_daemon_cache() {
        let forma = embedded_asset(&AssetSpec {
            id: "embedded:forma".to_owned(),
            source: "embedded".to_owned(),
            image_name: "forma.png".to_owned(),
        })
        .unwrap();
        assert!(forma.path.is_empty());
        assert_eq!(forma.digest, assets::FORMA_ASSET.image.key);

        let market_part = AssetSpec {
            id: "market:part".to_owned(),
            source: "market".to_owned(),
            image_name: "sub_icons/weapon/prime_barrel_128x128.png".to_owned(),
        };
        assert!(embedded_asset(&market_part).is_none());
    }

    #[test]
    fn normal_four_player_regions_are_centered() {
        let regions = reward_regions(1920, 1080, Geometry::Normal, 4);
        assert_eq!(regions.len(), 4);
        assert_eq!(regions[0].1, 410);
        assert_eq!(regions[0].3, 51);
        let left = regions[0].0;
        let right = regions[3].0 + regions[3].2;
        assert!((i64::from(left) - i64::from(1920 - right)).abs() <= 1);
    }

    #[test]
    fn geometry_stays_inside_narrow_screen() {
        for region in reward_regions(1280, 1024, Geometry::Normal, 4) {
            assert!(region.0 + region.2 <= 1280);
            assert!(region.1 + region.3 <= 1024);
        }
    }

    #[test]
    fn applies_alecaframe_2560_by_1600_geometry_correction() {
        let regions = reward_regions(2560, 1600, Geometry::Normal, 4);
        assert_eq!(regions.len(), 4);
        assert_eq!(regions[0].1, 632);
        assert_eq!(regions[0].2, 310);
        assert_eq!(regions[0].3, 60);
    }

    #[test]
    fn cleans_multiline_ocr_output() {
        assert_eq!(
            clean_label("  [Saryn Prime\nChassis]  \n"),
            "Saryn Prime Chassis"
        );
    }

    #[test]
    fn removes_short_artifact_line_above_reward() {
        assert_eq!(
            clean_label("KA\nDual Zoren Prime Handle\n"),
            "Dual Zoren Prime Handle"
        );
    }

    #[test]
    fn removes_known_ocr_artifacts_without_losing_valid_short_names() {
        assert_eq!(clean_label("1 F | Bo Prime Handle!"), "Bo Prime Handle");
        assert_eq!(clean_label("Fanq Prime Blade"), "Fang Prime Blade");
        assert_eq!(
            clean_label("Cobra & Crane Prime Blade"),
            "Cobra & Crane Prime Blade"
        );
    }

    #[test]
    fn accepts_close_unambiguous_market_match() {
        let resolution = serde_json::json!({
            "matches": [
                {"name": "Saryn Prime Chassis Blueprint", "slug": "saryn_prime_chassis_blueprint", "ducats": 100, "distance": 1, "confidence": 0.9667},
                {"name": "Saryn Prime Systems Blueprint", "slug": "saryn_prime_systems_blueprint", "distance": 8, "confidence": 0.7333}
            ]
        });
        let matched = accepted_match(&resolution).unwrap();
        assert_eq!(matched.slug, "saryn_prime_chassis_blueprint");
        assert_eq!(matched.ducats, Some(100));
    }

    #[test]
    fn rejects_ambiguous_market_match() {
        let resolution = serde_json::json!({
            "matches": [
                {"name": "Thing A", "slug": "thing_a", "distance": 3, "confidence": 0.75},
                {"name": "Thing B", "slug": "thing_b", "distance": 3, "confidence": 0.74}
            ]
        });
        assert!(accepted_match(&resolution).is_none());
    }

    #[test]
    fn layout_score_rewards_multiple_recognized_cards() {
        let one = Candidate {
            geometry: Geometry::Normal,
            count: 1,
            labels: vec!["Saryn Prime Chassis".to_owned()],
        };
        let four = Candidate {
            geometry: Geometry::Normal,
            count: 4,
            labels: vec![
                "a".to_owned(),
                "b".to_owned(),
                "c".to_owned(),
                String::new(),
            ],
        };
        let matched = |name: &str| {
            Some(MarketMatch {
                name: name.to_owned(),
                slug: name.to_owned(),
                ducats: None,
                distance: 1,
                confidence: 0.9,
            })
        };
        assert!(
            candidate_score(&four, &[matched("a"), matched("b"), matched("c"), None])
                > candidate_score(&one, &[matched("saryn")])
        );
    }

    #[test]
    fn recognizes_non_tradable_forma() {
        assert!(is_forma("Forma Blueprint"));
        assert!(is_forma("F0rma Blueprnt"));
        assert!(!is_forma("Saryn Prime Blueprint"));
    }

    #[test]
    fn tesseract_uses_lstm_only_engine() {
        assert!(
            TESSERACT_ARGUMENTS
                .windows(2)
                .any(|pair| pair == ["--oem", "1"])
        );
    }

    #[test]
    fn reward_fixtures_detect_player_count_at_native_resolution() {
        for (name, expected) in [
            ("relic_rewards_1p_2560x1440.jpg", 1),
            ("relic_rewards_2p_2560x1440.jpg", 2),
            ("relic_rewards_3p_2560x1440.jpg", 3),
            ("relic_rewards_4p_2560x1440.jpg", 4),
        ] {
            let path = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures")
                .join(name);
            let image = image::open(path).unwrap();
            assert_eq!((image.width(), image.height()), (2560, 1440));
            assert_eq!(
                detect_player_count(&image, Geometry::Normal),
                Some(expected)
            );
            assert_eq!(
                reward_regions(2560, 1440, Geometry::Normal, expected).len(),
                expected
            );
        }
    }
}
