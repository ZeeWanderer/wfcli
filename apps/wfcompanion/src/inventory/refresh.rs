use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde_json::Value;
use wfcompanion::game_observer::inventory::{Reader, Snapshot};

pub(super) struct Refresh {
    pub receiver: mpsc::Receiver<(Instant, Result<Snapshot, String>)>,
    stopping: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Refresh {
    pub fn start(pid: u32, stopping: Arc<AtomicBool>) -> Self {
        let (sender, receiver) = mpsc::sync_channel(1);
        let stop = Arc::clone(&stopping);
        let worker = thread::spawn(move || {
            let mut reader = match Reader::open(pid) {
                Ok(reader) => reader,
                Err(error) => {
                    crate::incident::warn("inventory.native_refresh_unavailable", error);
                    return;
                }
            };
            while !stop.load(Ordering::Relaxed) {
                let started = Instant::now();
                if matches!(
                    sender.try_send((started, reader.read())),
                    Err(mpsc::TrySendError::Disconnected(_))
                ) {
                    break;
                }
                thread::park_timeout(Duration::from_secs(1));
            }
        });
        Self {
            receiver,
            stopping,
            worker: Some(worker),
        }
    }
}

impl Drop for Refresh {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            worker.thread().unpark();
            let _ = worker.join();
        }
    }
}

#[derive(Default)]
pub(super) struct InventoryState {
    pub data: Option<Value>,
    full_received: Option<Instant>,
}

impl InventoryState {
    pub fn replace(&mut self, data: Value, received: Instant) {
        self.data = Some(data);
        self.full_received = Some(received);
    }

    pub fn refresh(&mut self, snapshot: Snapshot, started: Instant) -> Vec<&'static str> {
        let Some(data) = self.data.as_mut() else {
            return Vec::new();
        };
        if self
            .full_received
            .is_some_and(|received| started < received)
            || super::value_key(&data["sync"]) != snapshot.sync
        {
            return Vec::new();
        }
        let mut changed = Vec::new();
        for (key, identity) in [
            ("MiscItems", "ItemType"),
            ("Recipes", "ItemType"),
            ("PendingRecipes", "ItemId"),
        ] {
            let Some(rows) = snapshot.fields.get(key).and_then(Value::as_array) else {
                continue;
            };
            let merged = merge_rows(&data["raw"][key], rows, identity);
            if data["raw"][key] != merged {
                data["raw"][key] = merged;
                changed.push(key);
            }
        }
        if !changed.is_empty() {
            data["collector"] = "native_inventory".into();
            data["collected_at"] = serde_json::json!(super::unix_time_millis());
        }
        changed
    }
}

fn merge_rows(previous: &Value, rows: &[Value], identity: &str) -> Value {
    let mut remaining: HashMap<_, _> = rows
        .iter()
        .map(|row| (super::value_key(&row[identity]), row))
        .collect();
    let mut result = Vec::with_capacity(rows.len());
    if let Some(previous) = previous.as_array() {
        for row in previous {
            if let Some(next) = remaining.remove(&super::value_key(&row[identity])) {
                let mut merged = row.as_object().cloned().unwrap_or_default();
                merged.extend(
                    next.as_object()
                        .into_iter()
                        .flatten()
                        .map(|(k, v)| (k.clone(), v.clone())),
                );
                result.push(Value::Object(merged));
            }
        }
    }
    for row in rows {
        if remaining
            .remove(&super::value_key(&row[identity]))
            .is_some()
        {
            result.push(row.clone());
        }
    }
    Value::Array(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn observation(count: u32) -> Value {
        json!({"sync":{"$oid":"abc"},"raw":{
            "MiscItems":[{"ItemType":"ingredient","ItemCount":count,"future":true}],
            "Recipes":[{"ItemType":"blueprint","ItemCount":1}],
            "PendingRecipes":[{"ItemId":{"$oid":"job"},"ItemType":"blueprint"}],
            "Suits":[{"ItemType":"frame","XP":123}],"unknown":42}})
    }

    fn snapshot(count: u32) -> Snapshot {
        Snapshot {
            sync: "abc".into(),
            fields: json!({
                "MiscItems":[{"ItemType":"ingredient","ItemCount":count}],
                "Recipes":[{"ItemType":"blueprint","ItemCount":1}],"PendingRecipes":[]
            })
            .as_object()
            .unwrap()
            .clone(),
        }
    }

    #[test]
    fn identical_claims_and_missed_deltas_use_absolute_counts() {
        let now = Instant::now();
        let mut state = InventoryState::default();
        state.replace(observation(12), now);
        assert_eq!(
            state.refresh(snapshot(17), now),
            ["MiscItems", "PendingRecipes"]
        );
        assert!(state.refresh(snapshot(17), now).is_empty());
        assert_eq!(state.refresh(snapshot(22), now), ["MiscItems"]);
        assert_eq!(state.refresh(snapshot(32), now), ["MiscItems"]);
        let data = state.data.unwrap();
        assert_eq!(data["raw"]["MiscItems"][0]["ItemCount"], 32);
        assert_eq!(data["raw"]["MiscItems"][0]["future"], true);
        assert_eq!(data["raw"]["Suits"][0]["XP"], 123);
        assert_eq!(data["raw"]["unknown"], 42);
        assert_eq!(data["raw"]["PendingRecipes"], json!([]));
    }

    #[test]
    fn requires_current_full_snapshot_and_matching_sync() {
        let now = Instant::now();
        let mut state = InventoryState::default();
        assert!(state.refresh(snapshot(17), now).is_empty());
        state.replace(observation(12), now + Duration::from_millis(1));
        assert!(state.refresh(snapshot(17), now).is_empty());
        let mut other = snapshot(17);
        other.sync = "another-login".into();
        assert!(
            state
                .refresh(other, now + Duration::from_secs(1))
                .is_empty()
        );
        assert_eq!(
            state.data.as_ref().unwrap()["raw"]["MiscItems"][0]["ItemCount"],
            12
        );
    }

    #[test]
    fn full_resync_replaces_previous_native_state() {
        let now = Instant::now();
        let mut state = InventoryState::default();
        state.replace(observation(12), now);
        state.refresh(snapshot(17), now);
        state.replace(observation(22), now + Duration::from_secs(2));
        assert!(
            state
                .refresh(snapshot(17), now + Duration::from_secs(1))
                .is_empty()
        );
        assert_eq!(
            state.refresh(snapshot(22), now + Duration::from_secs(3)),
            ["PendingRecipes"]
        );
        assert_eq!(
            state.data.as_ref().unwrap()["raw"]["MiscItems"][0]["ItemCount"],
            22
        );
    }

    #[test]
    fn removal_new_rows_and_reordering_do_not_rewrite_unrelated_rows() {
        let previous = json!([{"ItemType":"b","ItemCount":1},{"ItemType":"a","ItemCount":2}]);
        let rows = json!([{"ItemType":"a","ItemCount":2},{"ItemType":"b","ItemCount":1}]);
        assert_eq!(
            merge_rows(&previous, rows.as_array().unwrap(), "ItemType"),
            previous
        );
        let next = json!([{"ItemType":"a","ItemCount":1},{"ItemType":"c","ItemCount":4}]);
        assert_eq!(
            merge_rows(&previous, next.as_array().unwrap(), "ItemType"),
            next
        );
    }
}
