use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde_json::Value;
use wfcompanion::game_observer::{identify_process, metadata};

use crate::daemon::{self, OutboundSender};

const RETRY_INTERVAL: Duration = Duration::from_secs(30);
const STOP_CHECK_INTERVAL: Duration = Duration::from_millis(250);
const METADATA_SCHEMA: u64 = 2;

#[derive(Debug)]
pub(crate) enum Event {
    Captured {
        game_pid: u32,
        data: Value,
        cached: bool,
    },
    Unavailable {
        game_pid: u32,
        reason: String,
    },
}

pub(crate) struct Bridge {
    game_pid: u32,
    stopping: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Bridge {
    pub(crate) fn start(
        game_pid: u32,
        outbound: OutboundSender,
        events: mpsc::Sender<Event>,
    ) -> Result<Self, String> {
        let stopping = Arc::new(AtomicBool::new(false));
        let worker_stopping = Arc::clone(&stopping);
        let worker = thread::Builder::new()
            .name("wfcompanion-game-metadata".to_owned())
            .spawn(move || scan(game_pid, outbound, worker_stopping, events))
            .map_err(|error| format!("could not start game metadata collector: {error}"))?;
        Ok(Self {
            game_pid,
            stopping,
            worker: Some(worker),
        })
    }

    pub(crate) fn game_pid(&self) -> u32 {
        self.game_pid
    }

    pub(crate) fn is_running(&self) -> bool {
        self.worker
            .as_ref()
            .is_some_and(|worker| !worker.is_finished())
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

fn scan(
    game_pid: u32,
    outbound: OutboundSender,
    stopping: Arc<AtomicBool>,
    events: mpsc::Sender<Event>,
) {
    if let Ok(Some(data)) = cached_metadata(game_pid, &outbound) {
        let _ = events.send(Event::Captured {
            game_pid,
            data,
            cached: true,
        });
        wait(&stopping, Duration::MAX);
        return;
    }
    let mut previous_error = None;
    while !stopping.load(Ordering::Relaxed) {
        match metadata::capture(game_pid).and_then(|captured| {
            serde_json::to_value(captured)
                .map_err(|error| format!("could not serialize game metadata: {error}"))
        }) {
            Ok(data) => {
                let _ = events.send(Event::Captured {
                    game_pid,
                    data,
                    cached: false,
                });
                wait(&stopping, Duration::MAX);
                return;
            }
            Err(reason) => {
                if previous_error.as_deref() != Some(reason.as_str()) {
                    if events
                        .send(Event::Unavailable {
                            game_pid,
                            reason: reason.clone(),
                        })
                        .is_err()
                    {
                        return;
                    }
                    previous_error = Some(reason.clone());
                }
                if reason.starts_with("unsupported Warframe executable ") {
                    wait(&stopping, Duration::MAX);
                    return;
                }
                wait(&stopping, RETRY_INTERVAL);
            }
        }
    }
}

fn cached_metadata(game_pid: u32, outbound: &OutboundSender) -> Result<Option<Value>, String> {
    let identity = identify_process(game_pid)?;
    let response = daemon::dataset_get(outbound, "game_metadata")?;
    Ok(cached_payload(&response, &identity.executable.sha256))
}

fn cached_payload(response: &Value, executable_sha256: &str) -> Option<Value> {
    let Some(data) = response.pointer("/data/data").cloned() else {
        return None;
    };
    let hash = data.pointer("/executable/sha256").and_then(Value::as_str);
    let schema = data.get("schema").and_then(Value::as_u64);
    let usable = data.get("archimedea").is_some_and(Value::is_object);
    (schema == Some(METADATA_SCHEMA) && hash == Some(executable_sha256) && usable).then_some(data)
}

fn wait(stopping: &AtomicBool, duration: Duration) {
    let deadline = Instant::now().checked_add(duration);
    while !stopping.load(Ordering::Relaxed)
        && deadline.is_none_or(|deadline| Instant::now() < deadline)
    {
        thread::sleep(STOP_CHECK_INTERVAL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wait_returns_immediately_when_stopped() {
        let stopping = AtomicBool::new(true);
        let started = Instant::now();
        wait(&stopping, Duration::MAX);
        assert!(started.elapsed() < STOP_CHECK_INTERVAL);
    }

    #[test]
    fn cache_payload_requires_matching_executable_and_archimedea_data() {
        let response = serde_json::json!({
            "data": {
                "revision": 1,
                "data": {
                    "schema": 2,
                    "executable": {"sha256": "current"},
                    "archimedea": {}
                }
            }
        });
        assert!(cached_payload(&response, "current").is_some());
        assert!(cached_payload(&response, "stale").is_none());
        let obsolete = serde_json::json!({
            "data": {"data": {
                "schema": 1,
                "executable": {"sha256": "current"},
                "archimedea": {}
            }}
        });
        assert!(cached_payload(&obsolete, "current").is_none());
    }
}
