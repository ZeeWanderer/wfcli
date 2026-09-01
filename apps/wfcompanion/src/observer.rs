use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::json;
use wfcompanion::game_observer::{self, DebugOutputEvent, GameState};

use crate::daemon::{Outbound, OutboundSender};
use crate::debug_output::{Bridge as DebugBridge, Event as DebugEvent, Runtime as DebugRuntime};
use crate::game_metadata::{Bridge as MetadataBridge, Event as MetadataEvent};
use crate::incident;
use crate::inventory::{Bridge as InventoryBridge, Event as InventoryEvent};
use crate::relic::Trigger as RelicTrigger;

const SCAN_INTERVAL: Duration = Duration::from_secs(2);
const DEBUG_RESTART_DELAY: Duration = Duration::from_secs(10);
const EVENT_INTERVAL: Duration = Duration::from_millis(200);
const UI_CONSOLE_OPEN_GUARD: Duration = Duration::from_secs(1);

#[derive(Default)]
struct CollectorStatus {
    debug_lines: u64,
    inventory_updates: u64,
    account_updates: u64,
    metadata_updates: u64,
    debug_output_active: bool,
    inventory_active: bool,
    metadata_active: bool,
}

pub(crate) fn spawn(
    outbound: OutboundSender,
    relic: mpsc::Sender<RelicTrigger>,
    stopping: Arc<AtomicBool>,
) {
    thread::spawn(move || {
        let (debug_tx, debug_rx) = mpsc::channel();
        let (inventory_tx, inventory_rx) = mpsc::channel();
        let (metadata_tx, metadata_rx) = mpsc::channel();
        let mut previous: Option<GameState> = None;
        let mut bridge: Option<DebugBridge> = None;
        let mut inventory_bridge: Option<InventoryBridge> = None;
        let mut metadata_bridge: Option<MetadataBridge> = None;
        let mut bridge_error: Option<String> = None;
        let mut inventory_error: Option<String> = None;
        let mut status = CollectorStatus::default();
        let mut next_scan = Instant::now();
        let mut next_bridge_attempt = Instant::now();
        let mut next_inventory_attempt = Instant::now();
        let mut last_ui_console_open: Option<Instant> = None;

        while !stopping.load(Ordering::Relaxed) {
            if Instant::now() >= next_scan {
                let current = game_observer::find_warframe();
                if previous.as_ref() != Some(&current) {
                    if previous.as_ref().is_some_and(GameState::is_running) && !current.is_running()
                    {
                        let _ = relic.send(RelicTrigger::GameStopped);
                    }
                    let data = serde_json::to_value(&current).unwrap_or_else(|_| json!({}));
                    let _ = outbound.send(Outbound::Publish {
                        dataset: "player",
                        source: "game",
                        data,
                    });
                    previous = Some(current);
                }

                let runtime = previous
                    .as_ref()
                    .and_then(GameState::attach)
                    .and_then(|attach| {
                        DebugRuntime::discover(
                            attach.pid(),
                            attach.process_dir(),
                            attach.environment(),
                            attach.compat_data(),
                        )
                    });
                let bridge_is_current = match (&mut bridge, runtime.as_ref()) {
                    (Some(open), Some(runtime)) => {
                        open.game_pid() == runtime.game_pid() && open.is_running()
                    }
                    (None, None) => true,
                    _ => false,
                };
                if !bridge_is_current && bridge.take().is_some() {
                    status.debug_output_active = false;
                    publish_collector(&outbound, &status);
                }
                if bridge.is_none()
                    && let Some(runtime) = runtime.as_ref()
                    && Instant::now() >= next_bridge_attempt
                {
                    match DebugBridge::start(runtime, debug_tx.clone()) {
                        Ok(open) => {
                            incident::info(
                                "observer.debug_output_started",
                                format!("game_pid={}", runtime.game_pid()),
                            );
                            bridge = Some(open);
                            bridge_error = None;
                            status.debug_output_active = true;
                            publish_collector(&outbound, &status);
                        }
                        Err(error) => {
                            if bridge_error.as_deref() != Some(&error) {
                                incident::warn("observer.debug_output_failed", &error);
                                eprintln!("wfcompanion: {error}");
                            }
                            bridge_error = Some(error);
                            next_bridge_attempt = Instant::now() + DEBUG_RESTART_DELAY;
                        }
                    }
                }

                let inventory_is_current = match (&mut inventory_bridge, runtime.as_ref()) {
                    (Some(open), Some(runtime)) => {
                        open.game_pid() == runtime.game_pid() && open.is_running()
                    }
                    (None, None) => true,
                    _ => false,
                };
                if !inventory_is_current && inventory_bridge.take().is_some() {
                    status.inventory_active = false;
                    publish_collector(&outbound, &status);
                }
                if inventory_bridge.is_none()
                    && let Some(runtime) = runtime.as_ref()
                    && Instant::now() >= next_inventory_attempt
                {
                    match InventoryBridge::start(runtime, inventory_tx.clone()) {
                        Ok(open) => {
                            incident::info(
                                "observer.inventory_started",
                                format!("game_pid={}", runtime.game_pid()),
                            );
                            inventory_bridge = Some(open);
                            inventory_error = None;
                            status.inventory_active = true;
                            publish_collector(&outbound, &status);
                        }
                        Err(error) => {
                            if inventory_error.as_deref() != Some(&error) {
                                incident::warn("observer.inventory_failed", &error);
                                eprintln!("wfcompanion: {error}");
                            }
                            inventory_error = Some(error);
                            next_inventory_attempt = Instant::now() + DEBUG_RESTART_DELAY;
                        }
                    }
                }

                let metadata_is_current = match (&metadata_bridge, runtime.as_ref()) {
                    (Some(open), Some(runtime)) => {
                        open.game_pid() == runtime.game_pid() && open.is_running()
                    }
                    (None, None) => true,
                    _ => false,
                };
                if !metadata_is_current && metadata_bridge.take().is_some() {
                    status.metadata_active = false;
                    publish_collector(&outbound, &status);
                }
                if metadata_bridge.is_none()
                    && let Some(runtime) = runtime.as_ref()
                {
                    match MetadataBridge::start(
                        runtime.game_pid(),
                        outbound.clone(),
                        metadata_tx.clone(),
                    ) {
                        Ok(open) => {
                            incident::info(
                                "observer.game_metadata_started",
                                format!("game_pid={}", runtime.game_pid()),
                            );
                            metadata_bridge = Some(open);
                            status.metadata_active = true;
                            publish_collector(&outbound, &status);
                        }
                        Err(error) => {
                            incident::warn("observer.game_metadata_failed", &error);
                            eprintln!("wfcompanion: {error}");
                        }
                    }
                }
                next_scan = Instant::now() + SCAN_INTERVAL;
            }

            while let Ok(event) = inventory_rx.try_recv() {
                handle_inventory_event(event, &mut inventory_bridge, &outbound, &mut status);
            }
            while let Ok(event) = metadata_rx.try_recv() {
                handle_metadata_event(event, &metadata_bridge, &outbound, &mut status);
            }

            let wait = EVENT_INTERVAL.min(next_scan.saturating_duration_since(Instant::now()));
            if let Ok(event) = debug_rx.recv_timeout(wait) {
                handle_debug_event(
                    event,
                    &mut bridge,
                    &relic,
                    &outbound,
                    &mut status,
                    &mut next_bridge_attempt,
                    &mut last_ui_console_open,
                );
            }
        }
    });
}

fn handle_metadata_event(
    event: MetadataEvent,
    bridge: &Option<MetadataBridge>,
    outbound: &OutboundSender,
    status: &mut CollectorStatus,
) {
    match event {
        MetadataEvent::Captured {
            game_pid,
            data,
            cached,
        } if bridge
            .as_ref()
            .is_some_and(|open| open.game_pid() == game_pid) =>
        {
            status.metadata_updates += 1;
            incident::info(
                "observer.game_metadata_received",
                format!(
                    "game_pid={game_pid} source={}",
                    if cached { "cache" } else { "memory" }
                ),
            );
            let _ = outbound.send(Outbound::Publish {
                dataset: "game_metadata",
                source: "warframe",
                data,
            });
            publish_collector(outbound, status);
        }
        MetadataEvent::Unavailable { game_pid, reason }
            if bridge
                .as_ref()
                .is_some_and(|open| open.game_pid() == game_pid) =>
        {
            incident::warn("observer.game_metadata_unavailable", &reason);
            if let Some(data) = unsupported_game_metadata(&reason) {
                status.metadata_updates += 1;
                let _ = outbound.send(Outbound::Publish {
                    dataset: "game_metadata",
                    source: "warframe",
                    data,
                });
                publish_collector(outbound, status);
            }
        }
        _ => {}
    }
}

fn unsupported_game_metadata(reason: &str) -> Option<serde_json::Value> {
    let sha256 = reason.strip_prefix("unsupported Warframe executable ")?;
    (sha256.len() == 64 && sha256.bytes().all(|byte| byte.is_ascii_hexdigit())).then(|| {
        json!({
            "schema": 2,
            "executable": {"sha256": sha256},
            "unavailable": {"reason": "unsupported_executable"},
        })
    })
}

fn handle_debug_event(
    event: DebugEvent,
    bridge: &mut Option<DebugBridge>,
    relic: &mpsc::Sender<RelicTrigger>,
    outbound: &OutboundSender,
    status: &mut CollectorStatus,
    next_bridge_attempt: &mut Instant,
    last_ui_console_open: &mut Option<Instant>,
) {
    match event {
        DebugEvent::Record {
            game_pid,
            sender_pid,
            message,
        } if bridge
            .as_ref()
            .is_some_and(|open| open.game_pid() == game_pid) =>
        {
            status.debug_lines += 1;
            let observation = game_observer::classify_debug_output(&message);
            match observation {
                Some(DebugOutputEvent::RelicRewards) => {
                    incident::info(
                        "observer.relic_debug_output",
                        format!("event=rewards game_pid={game_pid} windows_pid={sender_pid}"),
                    );
                    publish_collector(outbound, status);
                }
                Some(DebugOutputEvent::RelicSuggestions) => {
                    incident::info(
                        "observer.relic_debug_output",
                        format!("event=suggestions game_pid={game_pid} windows_pid={sender_pid}"),
                    );
                }
                _ => {}
            }
            handle_relic_observation(observation, game_pid, relic, last_ui_console_open);
        }
        DebugEvent::Stopped { game_pid, reason }
            if bridge
                .as_ref()
                .is_some_and(|open| open.game_pid() == game_pid) =>
        {
            incident::warn("observer.debug_output_stopped", &reason);
            bridge.take();
            *next_bridge_attempt = Instant::now() + DEBUG_RESTART_DELAY;
            status.debug_output_active = false;
            publish_collector(outbound, status);
        }
        _ => {}
    }
}

fn handle_inventory_event(
    event: InventoryEvent,
    bridge: &mut Option<InventoryBridge>,
    outbound: &OutboundSender,
    status: &mut CollectorStatus,
) {
    match event {
        InventoryEvent::Inventory {
            game_pid,
            collector,
            process_pid,
            data,
        } if bridge
            .as_ref()
            .is_some_and(|open| open.game_pid() == game_pid) =>
        {
            status.inventory_updates += 1;
            incident::info(
                "observer.inventory_received",
                format!("game_pid={game_pid} collector={collector} process_pid={process_pid}"),
            );
            let _ = outbound.send(Outbound::Publish {
                dataset: "player",
                source: "inventory",
                data,
            });
            publish_collector(outbound, status);
        }
        InventoryEvent::Account { game_pid, seed }
            if bridge
                .as_ref()
                .is_some_and(|open| open.game_pid() == game_pid) =>
        {
            status.account_updates += 1;
            incident::info(
                "observer.account_seed_received",
                format!("game_pid={game_pid}"),
            );
            let _ = outbound.send(Outbound::Publish {
                dataset: "player",
                source: "account",
                data: json!({
                    "schema": 1,
                    "archimedea_seed": seed,
                    "collected_at": unix_time_millis(),
                }),
            });
            publish_collector(outbound, status);
        }
        _ => {}
    }
}

fn publish_collector(outbound: &OutboundSender, status: &CollectorStatus) {
    let _ = outbound.send(Outbound::Publish {
        dataset: "player",
        source: "collector",
        data: json!({
            "debug_output_lines_observed": status.debug_lines,
            "inventory_updates_observed": status.inventory_updates,
            "account_updates_observed": status.account_updates,
            "game_metadata_updates_observed": status.metadata_updates,
            "debug_output_active": status.debug_output_active,
            "inventory_active": status.inventory_active,
            "game_metadata_active": status.metadata_active,
            "last_observed_at": unix_time_millis(),
        }),
    });
}

fn handle_relic_observation(
    observation: Option<DebugOutputEvent>,
    game_pid: u32,
    relic: &mpsc::Sender<RelicTrigger>,
    last_ui_console_open: &mut Option<Instant>,
) {
    match observation {
        Some(DebugOutputEvent::RelicRewards) => {
            let _ = relic.send(RelicTrigger::Rewards {
                game_pid,
                observed_at: Instant::now(),
                observed_at_unix_ms: unix_time_millis(),
            });
        }
        Some(DebugOutputEvent::RelicSuggestions) => {
            let blocked = last_ui_console_open.is_some_and(|seen| {
                Instant::now().saturating_duration_since(seen) < UI_CONSOLE_OPEN_GUARD
            });
            if !blocked {
                let _ = relic.send(RelicTrigger::Suggestions {
                    game_pid,
                    observed_at: Instant::now(),
                });
            }
        }
        Some(DebugOutputEvent::CloseRelicSuggestions) => {
            let _ = relic.send(RelicTrigger::CloseSuggestions);
        }
        Some(DebugOutputEvent::UiConsoleOpen) => {
            *last_ui_console_open = Some(Instant::now());
        }
        None => {}
    }
}

fn unix_time_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ui_console_open_suppresses_immediate_suggestion_trigger() {
        let (sender, receiver) = mpsc::channel();
        let mut last = None;
        handle_relic_observation(
            Some(DebugOutputEvent::UiConsoleOpen),
            10,
            &sender,
            &mut last,
        );
        handle_relic_observation(
            Some(DebugOutputEvent::RelicSuggestions),
            10,
            &sender,
            &mut last,
        );
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn suggestion_trigger_carries_game_process_and_time() {
        let (sender, receiver) = mpsc::channel();
        let mut last = None;
        handle_relic_observation(
            Some(DebugOutputEvent::RelicSuggestions),
            42,
            &sender,
            &mut last,
        );
        assert!(matches!(
            receiver.recv().unwrap(),
            RelicTrigger::Suggestions { game_pid: 42, .. }
        ));
    }

    #[test]
    fn unsupported_executable_invalidates_cached_metadata() {
        let hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        let data =
            unsupported_game_metadata(&format!("unsupported Warframe executable {hash}")).unwrap();
        assert_eq!(data["schema"], 2);
        assert_eq!(data["executable"]["sha256"], hash);
        assert_eq!(data["unavailable"]["reason"], "unsupported_executable");
        assert!(unsupported_game_metadata("VariantManifest is not loaded").is_none());
    }
}
