use std::path::PathBuf;

use serde::Deserialize;

use crate::assets;

#[derive(Debug)]
pub(crate) enum Trigger {
    Rewards,
    Suggestions,
    CloseSuggestions,
    DismissSuggestions,
    Screenshot(PathBuf),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum Scene {
    Reading,
    Rewards(Rewards),
    Suggestions(Suggestions),
    Error(String),
}

impl Scene {
    pub(crate) fn apply_asset_refresh(&mut self, refresh: &AssetRefresh) -> Option<bool> {
        let Self::Rewards(rewards) = self else {
            return None;
        };
        let mut matched = false;
        let mut changed = false;
        for asset in rewards.items.iter_mut().flat_map(|reward| {
            reward.asset.iter_mut().chain(
                reward
                    .parts
                    .iter_mut()
                    .filter_map(|part| part.asset.as_mut()),
            )
        }) {
            if asset.source != refresh.source || asset.image_name != refresh.image_name {
                continue;
            }
            matched = true;
            if asset.path != refresh.path || asset.digest != refresh.digest {
                asset.path.clone_from(&refresh.path);
                asset.digest.clone_from(&refresh.digest);
                changed = true;
            }
        }
        matched.then_some(changed)
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Rewards {
    pub(crate) items: Vec<Reward>,
    pub(crate) account: Account,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct Account {
    pub(crate) platinum: Option<u64>,
    pub(crate) ducats: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Reward {
    pub(crate) name: String,
    pub(crate) slug: Option<String>,
    pub(crate) game_ref: Option<String>,
    pub(crate) ducats: Option<u64>,
    pub(crate) lowest_sell: Option<u64>,
    pub(crate) highest_buy: Option<u64>,
    pub(crate) count_owned: u64,
    pub(crate) total_to_own: u64,
    pub(crate) crafted: Option<bool>,
    pub(crate) set_complete: Option<bool>,
    pub(crate) vaulted: bool,
    pub(crate) set_price: Option<u64>,
    pub(crate) asset: Option<Asset>,
    pub(crate) parts: Vec<SetPart>,
}

impl Reward {
    pub(super) fn unresolved(name: String, slug: Option<String>, ducats: Option<u64>) -> Self {
        Self {
            name,
            slug,
            game_ref: None,
            ducats,
            lowest_sell: None,
            highest_buy: None,
            count_owned: 0,
            total_to_own: 1,
            crafted: None,
            set_complete: None,
            vaulted: false,
            set_price: None,
            asset: None,
            parts: Vec::new(),
        }
    }

    pub(super) fn forma() -> Self {
        Self {
            name: "Forma Blueprint".to_owned(),
            slug: None,
            game_ref: Some("/Lotus/Types/Recipes/Components/FormaBlueprint".to_owned()),
            ducats: Some(0),
            lowest_sell: Some(2),
            highest_buy: None,
            count_owned: 0,
            total_to_own: 1,
            crafted: Some(true),
            set_complete: None,
            vaulted: false,
            set_price: None,
            asset: Some(Asset {
                id: "embedded:forma".to_owned(),
                source: "embedded".to_owned(),
                image_name: "forma.png".to_owned(),
                path: String::new(),
                digest: assets::FORMA_ASSET.image.key.to_owned(),
            }),
            parts: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SetPart {
    pub(crate) name: String,
    pub(crate) owned: u64,
    pub(crate) required: u64,
    pub(crate) current: bool,
    pub(crate) asset: Option<Asset>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Asset {
    pub(crate) id: String,
    pub(crate) source: String,
    pub(crate) image_name: String,
    pub(crate) path: String,
    pub(crate) digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub(crate) struct AssetRefresh {
    pub(crate) source: String,
    pub(crate) image_name: String,
    pub(crate) path: String,
    pub(crate) digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub(crate) struct Suggestions {
    pub(crate) trace_count: u64,
    pub(crate) items: Vec<Suggestion>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub(crate) struct Suggestion {
    pub(crate) name: String,
    pub(crate) amount_owned: u64,
    pub(crate) vaulted: bool,
    pub(crate) favorite: bool,
    pub(crate) expected_platinum: Option<u64>,
    pub(crate) expected_ducats: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asset(id: &str, name: &str, digest: &str) -> Asset {
        Asset {
            id: id.to_owned(),
            source: "market".to_owned(),
            image_name: name.to_owned(),
            path: format!("/old/{name}"),
            digest: digest.to_owned(),
        }
    }

    #[test]
    fn refreshes_all_scene_assets_with_same_identity() {
        let mut scene = Scene::Rewards(Rewards {
            items: vec![Reward {
                asset: Some(asset("item", "shared.webp", "old")),
                parts: vec![SetPart {
                    name: "Part".to_owned(),
                    owned: 0,
                    required: 1,
                    current: true,
                    asset: Some(asset("part", "shared.webp", "old")),
                }],
                ..Reward::unresolved("Part".to_owned(), None, None)
            }],
            account: Account::default(),
        });
        let refresh = AssetRefresh {
            source: "market".to_owned(),
            image_name: "shared.webp".to_owned(),
            path: "/new/shared.webp".to_owned(),
            digest: "new".to_owned(),
        };

        assert_eq!(scene.apply_asset_refresh(&refresh), Some(true));
        let Scene::Rewards(rewards) = scene else {
            unreachable!();
        };
        assert_eq!(rewards.items[0].asset.as_ref().unwrap().digest, "new");
        assert_eq!(
            rewards.items[0].parts[0].asset.as_ref().unwrap().digest,
            "new"
        );
    }

    #[test]
    fn ignores_refresh_for_another_asset() {
        let mut scene = Scene::Rewards(Rewards {
            items: vec![Reward {
                asset: Some(asset("item", "item.webp", "old")),
                ..Reward::unresolved("Part".to_owned(), None, None)
            }],
            account: Account::default(),
        });
        let refresh = AssetRefresh {
            source: "market".to_owned(),
            image_name: "other.webp".to_owned(),
            path: "/new/other.webp".to_owned(),
            digest: "new".to_owned(),
        };

        assert_eq!(scene.apply_asset_refresh(&refresh), None);
    }
}
