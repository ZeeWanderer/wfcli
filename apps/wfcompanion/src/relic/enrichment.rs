use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::{
    Account, Asset, Candidate, OutboundSender, REWARD_IDENTIFICATION_FAILED, Reward, Rewards,
    SetPart, assets,
};

#[derive(Clone, Debug)]
pub(super) struct MarketMatch {
    pub(super) name: String,
    pub(super) slug: String,
    pub(super) ducats: Option<u64>,
    pub(super) distance: u64,
    pub(super) confidence: f64,
}

pub(super) struct Resolution {
    pub(super) rewards: Vec<Reward>,
    pub(super) complete: bool,
    pub(super) score: f64,
    pub(super) geometry: super::Geometry,
    pub(super) count: usize,
}

#[derive(Debug, Deserialize)]
pub(super) struct ContextReply {
    #[serde(default)]
    items: Vec<ContextItem>,
    #[serde(default)]
    account: ContextAccount,
}

#[derive(Debug, Default, Deserialize)]
struct ContextAccount {
    platinum: Option<u64>,
    ducats: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct ContextItem {
    slug: String,
    name: String,
    game_ref: Option<String>,
    ducats: Option<u64>,
    lowest_sell: Option<u64>,
    highest_buy: Option<u64>,
    #[serde(default)]
    count_owned: u64,
    #[serde(default = "one")]
    total_to_own: u64,
    crafted: Option<bool>,
    set_complete: Option<bool>,
    #[serde(default)]
    vaulted: bool,
    set_price: Option<u64>,
    asset: Option<AssetSpec>,
    #[serde(default)]
    parts: Vec<ContextPart>,
}

#[derive(Debug, Deserialize)]
struct ContextPart {
    slug: String,
    name: String,
    #[serde(default)]
    owned: u64,
    #[serde(default = "one")]
    required: u64,
    #[serde(default)]
    set_root: bool,
    asset: Option<AssetSpec>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(super) struct AssetSpec {
    pub(super) id: String,
    pub(super) source: String,
    pub(super) image_name: String,
}

pub(super) fn resolve_reward_candidates(
    daemon: &OutboundSender,
    candidates: Vec<Candidate>,
) -> Result<Resolution, String> {
    let mut positions = Vec::new();
    let mut labels = Vec::new();
    let mut matches: Vec<Vec<Option<MarketMatch>>> = candidates
        .iter()
        .map(|candidate| vec![None; candidate.labels.len()])
        .collect();

    for (candidate_index, candidate) in candidates.iter().enumerate() {
        for (label_index, label) in candidate.labels.iter().enumerate() {
            if label.is_empty() || is_forma(label) {
                continue;
            }
            positions.push((candidate_index, label_index));
            labels.push(label.clone());
        }
    }

    if !labels.is_empty() {
        let response = crate::daemon::market_resolve(daemon, labels, 2)?;
        let resolutions = response
            .get("data")
            .and_then(|data| data.get("resolutions"))
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| "daemon returned malformed market resolution".to_owned())?;
        if resolutions.len() != positions.len() {
            return Err("daemon returned incomplete market resolution".to_owned());
        }
        for ((candidate_index, label_index), resolution) in positions.into_iter().zip(resolutions) {
            matches[candidate_index][label_index] = accepted_match(resolution);
        }
    }

    let (selected_index, selected_score) = candidates
        .iter()
        .enumerate()
        .map(|(index, candidate)| (index, candidate_score(candidate, &matches[index])))
        .max_by(|left, right| left.1.total_cmp(&right.1))
        .filter(|(_, score)| *score > 0.0)
        .ok_or_else(|| REWARD_IDENTIFICATION_FAILED.to_owned())?;
    let selected = &candidates[selected_index];
    let complete = selected
        .labels
        .iter()
        .zip(&matches[selected_index])
        .all(|(label, market_match)| is_forma(label) || market_match.is_some());

    let rewards = selected
        .labels
        .iter()
        .zip(&matches[selected_index])
        .map(|(label, market_match)| {
            if is_forma(label) {
                Reward::forma()
            } else if let Some(market_match) = market_match {
                Reward::unresolved(
                    market_match.name.clone(),
                    Some(market_match.slug.clone()),
                    market_match.ducats,
                )
            } else {
                Reward::unresolved(
                    if label.is_empty() {
                        "Unrecognized reward".to_owned()
                    } else {
                        label.clone()
                    },
                    None,
                    None,
                )
            }
        })
        .collect();

    Ok(Resolution {
        rewards,
        complete,
        score: selected_score,
        geometry: selected.geometry,
        count: selected.count,
    })
}

pub(super) fn reward_context(
    daemon: &OutboundSender,
    rewards: &[Reward],
) -> Result<Option<ContextReply>, String> {
    let slugs = rewards
        .iter()
        .filter_map(|reward| reward.slug.clone())
        .collect::<Vec<_>>();
    if slugs.is_empty() {
        return Ok(None);
    }
    let response = crate::daemon::relic_context(daemon, slugs)?;
    let context = serde_json::from_value(
        response
            .get("data")
            .cloned()
            .ok_or_else(|| "daemon returned no relic context".to_owned())?,
    )
    .map_err(|error| format!("daemon returned malformed relic context: {error}"))?;
    Ok(Some(context))
}

pub(super) fn contextual_rewards(
    mut rewards: Vec<Reward>,
    context: &ContextReply,
    assets: &BTreeMap<String, Asset>,
) -> Rewards {
    for reward in &mut rewards {
        let Some(slug) = reward.slug.as_deref() else {
            continue;
        };
        let Some(item) = context.items.iter().find(|item| item.slug == slug) else {
            continue;
        };
        reward.name.clone_from(&item.name);
        reward.game_ref.clone_from(&item.game_ref);
        reward.ducats = item.ducats.or(reward.ducats);
        reward.lowest_sell = item.lowest_sell;
        reward.highest_buy = item.highest_buy;
        reward.count_owned = item.count_owned;
        reward.total_to_own = item.total_to_own.max(1);
        reward.crafted = item.crafted;
        reward.set_complete = item.set_complete;
        reward.vaulted = item.vaulted;
        reward.set_price = item.set_price;
        reward.asset = item
            .asset
            .as_ref()
            .and_then(|spec| assets.get(&spec.id).cloned());
        reward.parts = item
            .parts
            .iter()
            .filter(|part| !part.set_root)
            .map(|part| SetPart {
                name: part.name.clone(),
                owned: part.owned,
                required: part.required.max(1),
                current: part.slug == slug,
                asset: part
                    .asset
                    .as_ref()
                    .and_then(|spec| assets.get(&spec.id).cloned()),
            })
            .collect();
    }
    Rewards {
        items: rewards,
        account: Account {
            platinum: context.account.platinum,
            ducats: context.account.ducats,
        },
    }
}

pub(super) fn resolve_assets(
    daemon: &OutboundSender,
    context: &ContextReply,
) -> BTreeMap<String, Asset> {
    let specs = context
        .items
        .iter()
        .flat_map(|item| {
            item.asset
                .iter()
                .chain(item.parts.iter().filter_map(|part| part.asset.as_ref()))
        })
        .fold(BTreeMap::new(), |mut unique, spec| {
            unique
                .entry(spec.id.clone())
                .or_insert_with(|| spec.clone());
            unique
        });
    let mut resolved = BTreeMap::new();
    let request = specs
        .into_values()
        .filter_map(|spec| {
            if let Some(asset) = embedded_asset(&spec) {
                resolved.insert(spec.id, asset);
                None
            } else {
                serde_json::to_value(spec).ok()
            }
        })
        .collect::<Vec<_>>();
    if request.is_empty() {
        return resolved;
    }
    let Ok(response) = crate::daemon::asset_resolve(daemon, request) else {
        return resolved;
    };
    resolved.extend(
        response
            .get("data")
            .and_then(|data| data.get("assets"))
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|descriptor| {
                if descriptor.get("ok").and_then(serde_json::Value::as_bool) != Some(true) {
                    return None;
                }
                Some((
                    descriptor.get("id")?.as_str()?.to_owned(),
                    Asset {
                        id: descriptor.get("id")?.as_str()?.to_owned(),
                        source: descriptor.get("source")?.as_str()?.to_owned(),
                        image_name: descriptor.get("image_name")?.as_str()?.to_owned(),
                        path: descriptor.get("path")?.as_str()?.to_owned(),
                        digest: descriptor.get("digest")?.as_str()?.to_owned(),
                    },
                ))
            })
            .collect::<BTreeMap<_, _>>(),
    );
    resolved
}

pub(super) fn embedded_asset(spec: &AssetSpec) -> Option<Asset> {
    assets::embedded_asset(&spec.source, &spec.image_name).map(|embedded| Asset {
        id: spec.id.clone(),
        source: spec.source.clone(),
        image_name: spec.image_name.clone(),
        path: String::new(),
        digest: embedded.image.key.to_owned(),
    })
}

fn one() -> u64 {
    1
}

pub(super) fn accepted_match(resolution: &serde_json::Value) -> Option<MarketMatch> {
    let candidates = resolution.get("matches")?.as_array()?;
    let best = candidates.first()?;
    let distance = best.get("distance")?.as_u64()?;
    let confidence = best.get("confidence")?.as_f64()?;
    let second_confidence = candidates
        .get(1)
        .and_then(|candidate| candidate.get("confidence"))
        .and_then(serde_json::Value::as_f64)
        .unwrap_or(0.0);
    let unambiguous = distance == 0 || confidence - second_confidence >= 0.04;
    if (distance <= 2 || confidence >= 0.72) && unambiguous {
        Some(MarketMatch {
            name: best.get("name")?.as_str()?.to_owned(),
            slug: best.get("slug")?.as_str()?.to_owned(),
            ducats: best.get("ducats").and_then(serde_json::Value::as_u64),
            distance,
            confidence,
        })
    } else {
        None
    }
}

pub(super) fn candidate_score(candidate: &Candidate, matches: &[Option<MarketMatch>]) -> f64 {
    let mut recognized = 0usize;
    let mut confidence = 0.0;
    let mut distance_penalty = 0.0;
    for (label, market_match) in candidate.labels.iter().zip(matches) {
        if is_forma(label) {
            recognized += 1;
            confidence += 1.0;
        } else if let Some(market_match) = market_match {
            recognized += 1;
            confidence += market_match.confidence;
            distance_penalty += market_match.distance as f64 * 0.01;
        }
    }
    if recognized == 0 {
        return 0.0;
    }
    let complete_bonus = if recognized == candidate.count {
        0.5
    } else {
        0.0
    };
    recognized as f64 * 2.0 + confidence / recognized as f64 + complete_bonus - distance_penalty
}

pub(super) fn is_forma(label: &str) -> bool {
    let normalized = label
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect::<String>();
    normalized.contains("forma") || (normalized.contains("f0rma") && normalized.contains("blue"))
}
