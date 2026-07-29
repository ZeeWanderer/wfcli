use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::json;

use crate::daemon::Outbound;
use crate::debug_output::{Bridge as DebugBridge, Event as DebugEvent, Runtime as DebugRuntime};
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
    debug_output_active: bool,
    inventory_active: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum GamePhase {
    #[default]
    Stopped,
    Launcher,
    Game,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub(crate) struct GameState {
    running: bool,
    launcher_running: bool,
    phase: GamePhase,
    #[serde(skip_serializing_if = "Option::is_none")]
    pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    compat_data: Option<PathBuf>,
    #[serde(skip)]
    runtime: Option<DebugRuntime>,
}

pub(crate) fn spawn(
    outbound: mpsc::Sender<Outbound>,
    relic: mpsc::Sender<RelicTrigger>,
    stopping: Arc<AtomicBool>,
) {
    thread::spawn(move || {
        let (debug_tx, debug_rx) = mpsc::channel();
        let (inventory_tx, inventory_rx) = mpsc::channel();
        let mut previous: Option<GameState> = None;
        let mut bridge: Option<DebugBridge> = None;
        let mut inventory_bridge: Option<InventoryBridge> = None;
        let mut bridge_error: Option<String> = None;
        let mut inventory_error: Option<String> = None;
        let mut last_inventory_sync: Option<String> = None;
        let mut status = CollectorStatus::default();
        let mut next_scan = Instant::now();
        let mut next_bridge_attempt = Instant::now();
        let mut next_inventory_attempt = Instant::now();
        let mut last_ui_console_open: Option<Instant> = None;

        while !stopping.load(Ordering::Relaxed) {
            if Instant::now() >= next_scan {
                let current = find_warframe();
                if previous.as_ref() != Some(&current) {
                    let data = serde_json::to_value(&current).unwrap_or_else(|_| json!({}));
                    let _ = outbound.send(Outbound::Publish {
                        source: "game",
                        data,
                    });
                    previous = Some(current);
                }

                let runtime = previous.as_ref().and_then(|state| state.runtime.as_ref());
                let bridge_is_current = match (&mut bridge, runtime) {
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
                    && let Some(runtime) = runtime
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

                let inventory_is_current = match (&mut inventory_bridge, runtime) {
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
                    && let Some(runtime) = runtime
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
                next_scan = Instant::now() + SCAN_INTERVAL;
            }

            while let Ok(event) = inventory_rx.try_recv() {
                handle_inventory_event(
                    event,
                    &mut inventory_bridge,
                    &outbound,
                    &mut last_inventory_sync,
                    &mut status,
                );
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

fn handle_debug_event(
    event: DebugEvent,
    bridge: &mut Option<DebugBridge>,
    relic: &mpsc::Sender<RelicTrigger>,
    outbound: &mpsc::Sender<Outbound>,
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
            match relic_debug_event(&message) {
                Some(RelicDebugEvent::Rewards) => {
                    incident::info(
                        "observer.relic_debug_output",
                        format!("event=rewards game_pid={game_pid} windows_pid={sender_pid}"),
                    );
                    publish_collector(outbound, status);
                }
                Some(RelicDebugEvent::Suggestions) => {
                    incident::info(
                        "observer.relic_debug_output",
                        format!("event=suggestions game_pid={game_pid} windows_pid={sender_pid}"),
                    );
                }
                _ => {}
            }
            handle_relic_debug_line(&message, relic, last_ui_console_open);
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
    outbound: &mpsc::Sender<Outbound>,
    last_sync: &mut Option<String>,
    status: &mut CollectorStatus,
) {
    match event {
        InventoryEvent::Inventory {
            game_pid,
            collector,
            process_pid,
            sync_key,
            data,
        } if bridge
            .as_ref()
            .is_some_and(|open| open.game_pid() == game_pid) =>
        {
            if last_sync.as_ref() == Some(&sync_key) {
                return;
            }
            *last_sync = Some(sync_key);
            status.inventory_updates += 1;
            incident::info(
                "observer.inventory_received",
                format!("game_pid={game_pid} collector={collector} process_pid={process_pid}"),
            );
            let _ = outbound.send(Outbound::Publish {
                source: "inventory",
                data,
            });
            publish_collector(outbound, status);
        }
        _ => {}
    }
}

fn publish_collector(outbound: &mpsc::Sender<Outbound>, status: &CollectorStatus) {
    let _ = outbound.send(Outbound::Publish {
        source: "collector",
        data: json!({
            "debug_output_lines_observed": status.debug_lines,
            "inventory_updates_observed": status.inventory_updates,
            "debug_output_active": status.debug_output_active,
            "inventory_active": status.inventory_active,
            "last_observed_at": unix_time_millis(),
        }),
    });
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RelicDebugEvent {
    Rewards,
    Suggestions,
    CloseSuggestions,
    UiConsoleOpen,
}

fn relic_debug_event(line: &str) -> Option<RelicDebugEvent> {
    if line.contains("Got rewards") {
        Some(RelicDebugEvent::Rewards)
    } else if line.contains("ThemedProjectionManager.lua: LoadingCompleteEnd") {
        Some(RelicDebugEvent::Suggestions)
    } else if line.contains("InitMapping for all devices with bindings") {
        Some(RelicDebugEvent::CloseSuggestions)
    } else if line.contains("UIConsoleTrigger::Open()") {
        Some(RelicDebugEvent::UiConsoleOpen)
    } else {
        None
    }
}

fn handle_relic_debug_line(
    line: &str,
    relic: &mpsc::Sender<RelicTrigger>,
    last_ui_console_open: &mut Option<Instant>,
) {
    match relic_debug_event(line) {
        Some(RelicDebugEvent::Rewards) => {
            let _ = relic.send(RelicTrigger::Rewards);
        }
        Some(RelicDebugEvent::Suggestions) => {
            let blocked = last_ui_console_open.is_some_and(|seen| {
                Instant::now().saturating_duration_since(seen) < UI_CONSOLE_OPEN_GUARD
            });
            if !blocked {
                let _ = relic.send(RelicTrigger::Suggestions);
            }
        }
        Some(RelicDebugEvent::CloseSuggestions) => {
            let _ = relic.send(RelicTrigger::CloseSuggestions);
        }
        Some(RelicDebugEvent::UiConsoleOpen) => {
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

pub(crate) fn find_warframe() -> GameState {
    let Ok(entries) = fs::read_dir("/proc") else {
        return GameState::default();
    };
    let mut game = None;
    let mut launcher = None;

    for entry in entries.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|name| name.parse::<u32>().ok())
        else {
            continue;
        };
        let process_dir = entry.path();
        let Ok(cmdline) = fs::read(process_dir.join("cmdline")) else {
            continue;
        };
        if is_warframe_cmdline(&cmdline) {
            game.get_or_insert_with(|| process_state(pid, &process_dir, GamePhase::Game));
        } else if is_launcher_cmdline(&cmdline) {
            launcher.get_or_insert_with(|| process_state(pid, &process_dir, GamePhase::Launcher));
        }
    }

    match (game, launcher) {
        (Some(mut game), Some(launcher)) => {
            game.launcher_running = true;
            if game.compat_data.is_none() {
                game.compat_data = launcher.compat_data;
            }
            game
        }
        (Some(game), None) => game,
        (None, Some(launcher)) => launcher,
        (None, None) => GameState::default(),
    }
}

fn process_state(pid: u32, process_dir: &Path, phase: GamePhase) -> GameState {
    let environment = read_environment(&process_dir.join("environ"));
    let compat_data = environment
        .get("STEAM_COMPAT_DATA_PATH")
        .or_else(|| environment.get("WINEPREFIX"))
        .map(PathBuf::from)
        .map(normalize_compat_data);
    let runtime = (phase == GamePhase::Game)
        .then(|| {
            compat_data.as_deref().and_then(|compat_data| {
                DebugRuntime::discover(pid, process_dir, &environment, compat_data)
            })
        })
        .flatten();
    GameState {
        running: phase == GamePhase::Game,
        launcher_running: phase == GamePhase::Launcher,
        phase,
        pid: Some(pid),
        compat_data,
        runtime,
    }
}

fn is_warframe_cmdline(cmdline: &[u8]) -> bool {
    matches!(
        executable_name(cmdline).as_deref(),
        Some("warframe.x64.exe" | "warframe.x64")
    )
}

fn is_launcher_cmdline(cmdline: &[u8]) -> bool {
    executable_path(cmdline).is_some_and(|path| path.contains("warframe"))
        && executable_name(cmdline).as_deref() == Some("launcher.exe")
        && !String::from_utf8_lossy(cmdline)
            .to_ascii_lowercase()
            .contains("--type=")
}

fn executable_name(cmdline: &[u8]) -> Option<String> {
    executable_path(cmdline)?
        .rsplit(['/', '\\'])
        .next()
        .map(str::to_owned)
}

fn executable_path(cmdline: &[u8]) -> Option<String> {
    let executable = cmdline.split(|byte| *byte == 0).next()?;
    Some(String::from_utf8_lossy(executable).to_ascii_lowercase())
}

fn read_environment(path: &Path) -> BTreeMap<String, String> {
    let mut bytes = Vec::new();
    if File::open(path)
        .and_then(|mut file| file.read_to_end(&mut bytes))
        .is_err()
    {
        return BTreeMap::new();
    }
    parse_environment(&bytes)
}

fn parse_environment(bytes: &[u8]) -> BTreeMap<String, String> {
    bytes
        .split(|byte| *byte == 0)
        .filter_map(|entry| {
            let entry = String::from_utf8_lossy(entry);
            entry
                .split_once('=')
                .map(|(key, value)| (key.to_owned(), value.to_owned()))
        })
        .collect()
}

fn normalize_compat_data(path: PathBuf) -> PathBuf {
    if path.file_name().is_some_and(|name| name == "pfx") {
        path.parent().unwrap_or(&path).to_owned()
    } else {
        path
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_proton_warframe_command() {
        assert!(is_warframe_cmdline(
            b"Z:\\games\\Warframe\\Warframe.x64.exe\0-x64\0"
        ));
        assert!(!is_warframe_cmdline(b"wine64-preloader\0explorer.exe\0"));
    }

    #[test]
    fn recognizes_warframe_launcher_only() {
        assert!(is_launcher_cmdline(
            b"S:\\common\\Warframe\\Tools\\Launcher.exe\0-cluster:public\0"
        ));
        assert!(!is_launcher_cmdline(b"other-game\\Launcher.exe\0"));
        assert!(!is_launcher_cmdline(
            b"/steam/reaper\0--\0S:\\common\\Warframe\\Tools\\Launcher.exe\0"
        ));
        assert!(!is_launcher_cmdline(
            b"S:\\common\\Warframe\\Tools\\Launcher.exe\0--type=renderer\0"
        ));
    }

    #[test]
    fn parses_nul_separated_environment() {
        let env = parse_environment(b"A=one\0STEAM_COMPAT_DATA_PATH=/tmp/compat\0");
        assert_eq!(env.get("A").map(String::as_str), Some("one"));
        assert_eq!(
            env.get("STEAM_COMPAT_DATA_PATH").map(String::as_str),
            Some("/tmp/compat")
        );
    }

    #[test]
    fn detects_relic_overlay_debug_markers() {
        assert_eq!(
            relic_debug_event("123.4 Script [Info]: Got rewards, waiting for choice"),
            Some(RelicDebugEvent::Rewards)
        );
        assert_eq!(
            relic_debug_event("ThemedProjectionManager.lua: LoadingCompleteEnd"),
            Some(RelicDebugEvent::Suggestions)
        );
        assert_eq!(
            relic_debug_event("InitMapping for all devices with bindings"),
            Some(RelicDebugEvent::CloseSuggestions)
        );
        assert_eq!(relic_debug_event("Mission rewards"), None);
    }

    #[test]
    fn ui_console_open_suppresses_immediate_suggestion_trigger() {
        let (sender, receiver) = mpsc::channel();
        let mut last = None;
        handle_relic_debug_line("UIConsoleTrigger::Open()", &sender, &mut last);
        handle_relic_debug_line(
            "ThemedProjectionManager.lua: LoadingCompleteEnd",
            &sender,
            &mut last,
        );
        assert!(receiver.try_recv().is_err());
    }
}
