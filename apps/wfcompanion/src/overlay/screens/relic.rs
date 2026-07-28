use std::collections::BTreeMap;
use std::fs;
use std::time::Duration;

use fontdue::Font;

use crate::incident;
use crate::painter::{Painter, RasterImage, load_icon};
use crate::ui::ScreenOutput;

mod fixture;
mod reward;
mod suggestion;

const MAX_DECODED_ASSETS: usize = 128;

struct SuggestionIcons {
    trace: RasterImage,
    vaulted: RasterImage,
    close: RasterImage,
}

impl SuggestionIcons {
    fn load() -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            trace: load_icon(include_bytes!("../../../assets/trace.png"))?,
            vaulted: load_icon(include_bytes!("../../../assets/vaulted.png"))?,
            close: load_icon(include_bytes!("../../../assets/close.png"))?,
        })
    }
}

pub(super) struct Assets {
    platinum_icon: RasterImage,
    ducat_icon: RasterImage,
    icons: SuggestionIcons,
    asset_images: BTreeMap<String, RasterImage>,
}

impl Assets {
    pub(super) fn load() -> Result<Self, Box<dyn std::error::Error>> {
        Ok(Self {
            platinum_icon: load_icon(include_bytes!("../../../assets/platinum.png"))?,
            ducat_icon: load_icon(include_bytes!("../../../assets/ducats.png"))?,
            icons: SuggestionIcons::load()?,
            asset_images: embedded_part_images()?,
        })
    }

    pub(super) fn cache_scene(&mut self, scene: &crate::relic::Scene) {
        let crate::relic::Scene::Rewards(rewards) = scene else {
            return;
        };
        for asset in rewards.items.iter().flat_map(|reward| {
            reward
                .asset
                .iter()
                .chain(reward.parts.iter().filter_map(|part| part.asset.as_ref()))
        }) {
            if self.asset_images.contains_key(&asset.digest) {
                continue;
            }
            let image = fs::read(&asset.path)
                .map_err(|error| format!("{}: {error}", asset.path))
                .and_then(|bytes| load_icon(&bytes).map_err(|error| error.to_string()));
            match image {
                Ok(image) => {
                    if self.asset_images.len() >= MAX_DECODED_ASSETS
                        && let Some(oldest) = self.asset_images.keys().next().cloned()
                    {
                        self.asset_images.remove(&oldest);
                    }
                    self.asset_images.insert(asset.digest.clone(), image);
                }
                Err(error) => incident::warn(
                    "overlay.asset_decode_failed",
                    format!("id={} error={error}", asset.id),
                ),
            }
        }
    }

    fn resources<'a>(&'a self, font: &'a Font) -> Resources<'a> {
        Resources {
            font,
            platinum_icon: &self.platinum_icon,
            ducat_icon: &self.ducat_icon,
            icons: &self.icons,
            asset_images: &self.asset_images,
        }
    }
}

struct Resources<'a> {
    font: &'a Font,
    platinum_icon: &'a RasterImage,
    ducat_icon: &'a RasterImage,
    icons: &'a SuggestionIcons,
    asset_images: &'a BTreeMap<String, RasterImage>,
}

#[derive(Clone, Copy)]
pub(super) struct View {
    pub(super) scale: u32,
    pub(super) suggestion_offset: usize,
    pub(super) interaction_active: bool,
    pub(super) close_hovered: bool,
}

pub(super) fn draw_static_relic_scene(
    painter: &mut Painter<'_>,
    font: &Font,
    assets: &Assets,
    scene: &crate::relic::Scene,
    view: View,
) -> ScreenOutput {
    let resources = assets.resources(font);
    match scene {
        crate::relic::Scene::Suggestions(suggestions) => {
            suggestion::draw(painter, &resources, suggestions, view)
        }
        _ => ScreenOutput {
            animation_bounds: reward::draw(painter, &resources, scene, view),
            hit_regions: Vec::new(),
        },
    }
}

fn embedded_part_images() -> Result<BTreeMap<String, RasterImage>, Box<dyn std::error::Error>> {
    let mut images = BTreeMap::new();
    for asset in crate::assets::EMBEDDED_PART_ASSETS {
        if !images.contains_key(asset.image.key) {
            images.insert(asset.image.key.to_owned(), load_icon(asset.image.bytes)?);
        }
    }
    Ok(images)
}

pub(super) fn draw_loading_pulse(
    painter: &mut Painter<'_>,
    bounds: crate::ui::Rect,
    scale: u32,
    elapsed: Duration,
) {
    reward::draw_loading_pulse(painter, bounds, scale, elapsed);
}

pub(super) fn mock_relic_scene() -> crate::relic::Scene {
    fixture::scene()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mock_scene_has_four_reward_cards() {
        let crate::relic::Scene::Rewards(rewards) = fixture::scene() else {
            panic!("mock scene must contain rewards");
        };
        assert_eq!(rewards.items.len(), 4);
        assert_eq!(rewards.items[1].ducats, Some(100));
    }

    #[test]
    fn suggestion_fixture_has_four_ranked_relics() {
        let crate::relic::Scene::Suggestions(suggestions) =
            crate::relic::suggestion_fixture().unwrap()
        else {
            panic!("fixture must contain suggestions");
        };
        assert_eq!(suggestions.items.len(), 4);
        assert!(
            suggestions.items[0].expected_platinum.unwrap()
                >= suggestions.items[1].expected_platinum.unwrap()
        );
    }

    #[test]
    fn embedded_part_registry_matches_resolver() {
        let images = embedded_part_images().unwrap();
        assert_eq!(images.len(), 23);
        assert!(images.len() < crate::assets::EMBEDDED_PART_ASSETS.len());
        assert!(
            crate::assets::EMBEDDED_PART_ASSETS
                .iter()
                .all(|asset| images.contains_key(asset.image.key))
        );
        for name in [
            "Blueprint",
            "Barrel",
            "Receiver",
            "Chassis",
            "Neuroptics",
            "Systems",
        ] {
            let asset = fixture::part_asset(name).unwrap();
            assert!(images.contains_key(&asset.digest));
        }
    }
}
