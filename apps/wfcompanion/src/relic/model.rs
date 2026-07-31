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
