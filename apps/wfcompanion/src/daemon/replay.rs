use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{PublicationKey, outbox};
use crate::runtime::inbox::value_bytes;

#[derive(Clone, Default, Serialize, Deserialize)]
pub(crate) struct Replay(Vec<(String, String, Value)>);

impl Replay {
    pub(super) fn from_latest(latest: BTreeMap<PublicationKey, Value>) -> Self {
        Self(
            latest
                .into_iter()
                .map(|((dataset, source), data)| (dataset.into(), source.into(), data))
                .collect(),
        )
    }

    pub(crate) fn validate(&self) -> Result<(), String> {
        self.latest().map(|_| ())
    }

    pub(super) fn latest(&self) -> Result<BTreeMap<PublicationKey, Value>, String> {
        if self.0.len() > outbox::MAX_MESSAGES
            || self
                .0
                .iter()
                .map(|(_, _, data)| value_bytes(data))
                .sum::<usize>()
                > outbox::MAX_BYTES
        {
            return Err("reload publication limit exceeded".into());
        }
        let mut latest = BTreeMap::new();
        for (dataset, source, data) in &self.0 {
            let key = outbox::snapshot_key(dataset, source)
                .ok_or("reload contains an unknown publication source")?;
            if latest.insert(key, data.clone()).is_some() {
                return Err("reload contains duplicate publication sources".into());
            }
        }
        Ok(latest)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn snapshot_replay_keeps_http_before_native_without_changing_observations() {
        let latest = BTreeMap::from([
            (
                ("player", "inventory_native"),
                json!({"observation":{"sequence":2,"baseline":1}}),
            ),
            (
                ("player", "inventory_http"),
                json!({"observation":{"sequence":1,"baseline":1}}),
            ),
        ]);
        let replay = Replay::from_latest(latest.clone());
        let saved = serde_json::to_vec(&replay).unwrap();
        let restored: Replay = serde_json::from_slice(&saved).unwrap();
        assert_eq!(restored.latest().unwrap(), latest);
        assert_eq!(
            restored.latest().unwrap().keys().next().unwrap().1,
            "inventory_http"
        );
    }

    #[test]
    fn invalid_replay_is_rejected_instead_of_leaking_dynamic_source_names() {
        assert!(
            Replay(vec![("other".into(), "source".into(), json!({}))])
                .validate()
                .is_err()
        );
        let snapshot = ("player".into(), "game".into(), json!({}));
        assert!(Replay(vec![snapshot.clone(), snapshot]).validate().is_err());
    }
}
