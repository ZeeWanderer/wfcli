use std::collections::{BTreeMap, VecDeque};
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command as ProcessCommand, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

use crate::{UiEvent, incident};

const PROTOCOL_VERSION: u32 = 9;
const CLIENT_VERSION: &str = env!("WFCLI_VERSION");
const RECONNECT_INTERVAL: Duration = Duration::from_secs(2);
const SOCKET_READ_TIMEOUT: Duration = Duration::from_millis(200);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(2);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const RELIC_SUGGESTION_LIMIT: u64 = 32;

#[derive(Debug, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum ClientMessage<'a> {
    Hello {
        id: u64,
        protocol: u32,
        client: &'a str,
        version: &'a str,
        pid: u32,
        mode: &'a str,
        capabilities: &'a [&'a str],
    },
    Get {
        id: u64,
        dataset: &'a str,
    },
    Subscribe {
        id: u64,
        dataset: &'a str,
    },
    Publish {
        id: u64,
        dataset: &'a str,
        source: &'a str,
        data: &'a Value,
    },
    MarketResolve {
        id: u64,
        labels: &'a [String],
        limit: u64,
    },
    AssetResolve {
        id: u64,
        assets: &'a [Value],
    },
    RelicContext {
        id: u64,
        items: &'a [String],
    },
    RelicRecommendations {
        id: u64,
        era: &'a str,
        fetch_prices: bool,
        limit: u64,
    },
}

#[derive(Debug)]
pub(crate) enum Outbound {
    Publish {
        source: &'static str,
        data: Value,
    },
    MarketResolve {
        labels: Vec<String>,
        limit: u64,
        reply: mpsc::Sender<Result<Value, String>>,
    },
    AssetResolve {
        assets: Vec<Value>,
        reply: mpsc::Sender<Result<Value, String>>,
    },
    RelicContext {
        items: Vec<String>,
        reply: mpsc::Sender<Result<Value, String>>,
    },
    RelicRecommendations {
        era: String,
        fetch_prices: bool,
        limit: u64,
        reply: mpsc::Sender<Result<Value, String>>,
    },
}

pub(crate) fn market_resolve(
    outbound: &mpsc::Sender<Outbound>,
    labels: Vec<String>,
    limit: u64,
) -> Result<Value, String> {
    request(outbound, |reply| Outbound::MarketResolve {
        labels: labels.clone(),
        limit,
        reply,
    })
}

pub(crate) fn asset_resolve(
    outbound: &mpsc::Sender<Outbound>,
    assets: Vec<Value>,
) -> Result<Value, String> {
    request(outbound, |reply| Outbound::AssetResolve {
        assets: assets.clone(),
        reply,
    })
}

pub(crate) fn relic_context(
    outbound: &mpsc::Sender<Outbound>,
    items: Vec<String>,
) -> Result<Value, String> {
    request(outbound, |reply| Outbound::RelicContext {
        items: items.clone(),
        reply,
    })
}

pub(crate) fn relic_recommendations(
    outbound: &mpsc::Sender<Outbound>,
    era: String,
    fetch_prices: bool,
) -> Result<Value, String> {
    request(outbound, |reply| Outbound::RelicRecommendations {
        era: era.clone(),
        fetch_prices,
        limit: RELIC_SUGGESTION_LIMIT,
        reply,
    })
}

fn request(
    outbound: &mpsc::Sender<Outbound>,
    build: impl Fn(mpsc::Sender<Result<Value, String>>) -> Outbound,
) -> Result<Value, String> {
    match request_once(outbound, &build) {
        Err(error) if error == "daemon connection closed" => {
            incident::warn("daemon.request_retry", &error);
            request_once(outbound, &build)
        }
        result => result,
    }
}

fn request_once(
    outbound: &mpsc::Sender<Outbound>,
    build: &impl Fn(mpsc::Sender<Result<Value, String>>) -> Outbound,
) -> Result<Value, String> {
    let (reply_tx, reply_rx) = mpsc::channel();
    outbound
        .send(build(reply_tx))
        .map_err(|_| "daemon connection worker stopped".to_owned())?;
    reply_rx
        .recv_timeout(REQUEST_TIMEOUT)
        .map_err(|_| "daemon request timed out".to_owned())?
}

pub(crate) fn spawn(
    ui: mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
    mode: &'static str,
) -> mpsc::Sender<Outbound> {
    let (outbound_tx, outbound_rx) = mpsc::channel();
    thread::spawn(move || connection_loop(outbound_rx, ui, stopping, mode));
    outbound_tx
}

fn connection_loop(
    outbound: mpsc::Receiver<Outbound>,
    ui: mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
    mode: &'static str,
) {
    let path = daemon_socket_path();
    let mut start_attempted = false;
    let mut latest = BTreeMap::new();
    let mut queued = VecDeque::new();
    while !stopping.load(Ordering::Relaxed) {
        drain_outbound(&outbound, &mut latest, &mut queued);
        match UnixStream::connect(&path) {
            Ok(stream) => {
                start_attempted = false;
                if let Err(error) = connection_session(
                    stream,
                    &outbound,
                    &mut latest,
                    &mut queued,
                    &ui,
                    &stopping,
                    mode,
                ) {
                    let incompatible = error.kind() == io::ErrorKind::InvalidData;
                    incident::warn("daemon.disconnected", error.to_string());
                    let _ = ui.send(UiEvent::Disconnected(error.to_string()));
                    if incompatible {
                        ensure_daemon();
                    }
                }
            }
            Err(error) => {
                incident::warn(
                    "daemon.connect_failed",
                    format!("{}: {error}", path.display()),
                );
                let _ = ui.send(UiEvent::Disconnected(format!(
                    "{}: {error}",
                    path.display()
                )));
                if !start_attempted {
                    start_attempted = true;
                    ensure_daemon();
                }
            }
        }
        thread::sleep(RECONNECT_INTERVAL);
    }
}

fn connection_session(
    stream: UnixStream,
    outbound: &mpsc::Receiver<Outbound>,
    latest: &mut BTreeMap<&'static str, Value>,
    queued: &mut VecDeque<Outbound>,
    ui: &mpsc::Sender<UiEvent>,
    stopping: &AtomicBool,
    mode: &'static str,
) -> io::Result<()> {
    stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT))?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    send_message(
        &mut writer,
        &ClientMessage::Hello {
            id: 1,
            protocol: PROTOCOL_VERSION,
            client: "wfcompanion",
            version: CLIENT_VERSION,
            pid: std::process::id(),
            mode,
            capabilities: &[
                "player.publish",
                "dataset.subscribe",
                "market.resolve",
                "market.quote",
                "relic.context",
                "asset.resolve",
                "overlay",
            ],
        },
    )?;
    let hello = read_message(&mut reader)?;
    validate_hello(&hello)?;
    incident::info(
        "daemon.connected",
        format!("local_protocol={PROTOCOL_VERSION} mode={mode}"),
    );
    let _ = ui.send(UiEvent::Connected(hello));

    reader
        .get_ref()
        .set_read_timeout(Some(SOCKET_READ_TIMEOUT))?;
    send_message(
        &mut writer,
        &ClientMessage::Subscribe {
            id: 2,
            dataset: "player",
        },
    )?;
    send_message(
        &mut writer,
        &ClientMessage::Get {
            id: 3,
            dataset: "daemon",
        },
    )?;

    let mut next_id = 10;
    for (&source, data) in latest.iter() {
        send_publish(&mut writer, next_id, source, data)?;
        next_id += 1;
    }

    let mut pending = BTreeMap::new();
    while let Some(message) = queued.pop_front() {
        send_outbound(&mut writer, next_id, message, latest, &mut pending)?;
        next_id += 1;
    }

    let result = active_session(ActiveSession {
        writer: &mut writer,
        reader: &mut reader,
        outbound,
        latest,
        ui,
        stopping,
        next_id,
        pending: &mut pending,
    });
    fail_pending(&mut pending, "daemon connection closed");
    result
}

struct ActiveSession<'a> {
    writer: &'a mut UnixStream,
    reader: &'a mut BufReader<UnixStream>,
    outbound: &'a mpsc::Receiver<Outbound>,
    latest: &'a mut BTreeMap<&'static str, Value>,
    ui: &'a mpsc::Sender<UiEvent>,
    stopping: &'a AtomicBool,
    next_id: u64,
    pending: &'a mut BTreeMap<u64, mpsc::Sender<Result<Value, String>>>,
}

fn active_session(session: ActiveSession<'_>) -> io::Result<()> {
    let ActiveSession {
        writer,
        reader,
        outbound,
        latest,
        ui,
        stopping,
        mut next_id,
        pending,
    } = session;
    let mut line = String::new();
    while !stopping.load(Ordering::Relaxed) {
        while let Ok(message) = outbound.try_recv() {
            send_outbound(writer, next_id, message, latest, pending)?;
            next_id += 1;
        }

        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionReset,
                    "daemon closed",
                ));
            }
            Ok(_) => handle_server_message(line.trim_end(), ui, pending),
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock
                    || error.kind() == io::ErrorKind::TimedOut => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn drain_outbound(
    outbound: &mpsc::Receiver<Outbound>,
    latest: &mut BTreeMap<&'static str, Value>,
    queued: &mut VecDeque<Outbound>,
) {
    while let Ok(message) = outbound.try_recv() {
        match message {
            Outbound::Publish { source, data } => {
                latest.insert(source, data);
            }
            request => queued.push_back(request),
        }
    }
}

fn send_outbound(
    writer: &mut UnixStream,
    id: u64,
    message: Outbound,
    latest: &mut BTreeMap<&'static str, Value>,
    pending: &mut BTreeMap<u64, mpsc::Sender<Result<Value, String>>>,
) -> io::Result<()> {
    match message {
        Outbound::Publish { source, data } => {
            latest.insert(source, data);
            send_publish(writer, id, source, &latest[source])
        }
        Outbound::MarketResolve {
            labels,
            limit,
            reply,
        } => {
            pending.insert(id, reply);
            send_message(
                writer,
                &ClientMessage::MarketResolve {
                    id,
                    labels: &labels,
                    limit,
                },
            )
        }
        Outbound::AssetResolve { assets, reply } => {
            pending.insert(id, reply);
            send_message(
                writer,
                &ClientMessage::AssetResolve {
                    id,
                    assets: &assets,
                },
            )
        }
        Outbound::RelicContext { items, reply } => {
            pending.insert(id, reply);
            send_message(writer, &ClientMessage::RelicContext { id, items: &items })
        }
        Outbound::RelicRecommendations {
            era,
            fetch_prices,
            limit,
            reply,
        } => {
            pending.insert(id, reply);
            send_message(
                writer,
                &ClientMessage::RelicRecommendations {
                    id,
                    era: &era,
                    fetch_prices,
                    limit,
                },
            )
        }
    }
}

fn fail_pending(pending: &mut BTreeMap<u64, mpsc::Sender<Result<Value, String>>>, reason: &str) {
    for (_, reply) in std::mem::take(pending) {
        let _ = reply.send(Err(reason.to_owned()));
    }
}

fn validate_hello(message: &Value) -> io::Result<()> {
    let compatible = message.get("id").and_then(Value::as_u64) == Some(1)
        && message.get("ok").and_then(Value::as_bool) == Some(true)
        && message.get("compatible").and_then(Value::as_bool) == Some(true);
    if !compatible {
        let daemon_protocol = message
            .get("protocol")
            .and_then(Value::as_u64)
            .map_or_else(|| "unknown".to_owned(), |value| value.to_string());
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "local protocol mismatch: companion {PROTOCOL_VERSION}, daemon {daemon_protocol}"
            ),
        ));
    }

    const REQUIRED: &[&str] = &[
        "player.publish",
        "dataset.subscribe",
        "market.resolve",
        "market.quote",
        "relic.context",
        "asset.resolve",
    ];
    let capabilities = message
        .get("capabilities")
        .and_then(Value::as_array)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "daemon sent no capabilities"))?;
    let missing = REQUIRED.iter().find(|required| {
        !capabilities
            .iter()
            .any(|capability| capability.as_str() == Some(**required))
    });
    match missing {
        Some(capability) => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("daemon missing required capability: {capability}"),
        )),
        None => Ok(()),
    }
}

fn read_message(reader: &mut BufReader<UnixStream>) -> io::Result<Value> {
    let mut line = String::new();
    match reader.read_line(&mut line)? {
        0 => Err(io::Error::new(
            io::ErrorKind::ConnectionReset,
            "daemon closed during handshake",
        )),
        _ => serde_json::from_str(line.trim_end())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error)),
    }
}

fn send_publish(
    writer: &mut UnixStream,
    id: u64,
    source: &'static str,
    data: &Value,
) -> io::Result<()> {
    send_message(
        writer,
        &ClientMessage::Publish {
            id,
            dataset: "player",
            source,
            data,
        },
    )
}

fn send_message(writer: &mut UnixStream, message: &ClientMessage<'_>) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, message)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

fn handle_server_message(
    line: &str,
    ui: &mpsc::Sender<UiEvent>,
    pending: &mut BTreeMap<u64, mpsc::Sender<Result<Value, String>>>,
) {
    let Ok(message) = serde_json::from_str::<Value>(line) else {
        return;
    };
    if message.get("event").and_then(Value::as_str) == Some("command") {
        let data = message.get("data");
        let command = data
            .and_then(|data| data.get("command"))
            .and_then(Value::as_str);
        let visible = data
            .and_then(|data| data.get("visible"))
            .and_then(Value::as_bool);
        match (command, visible) {
            (Some("overlay"), Some(visible)) => {
                let _ = ui.send(UiEvent::OverlayVisible(visible));
            }
            (Some("hud"), Some(visible)) => {
                let _ = ui.send(UiEvent::HudVisible(visible));
            }
            _ => {}
        }
        return;
    }
    if message.get("event").and_then(Value::as_str) == Some("dataset") {
        send_snapshot(&message, ui);
        return;
    }
    if let Some(reply) = message
        .get("id")
        .and_then(Value::as_u64)
        .and_then(|id| pending.remove(&id))
    {
        let result = if message.get("ok").and_then(Value::as_bool) == Some(true) {
            Ok(message)
        } else {
            Err(message
                .get("error")
                .map(Value::to_string)
                .unwrap_or_else(|| "daemon request failed".to_owned()))
        };
        let _ = reply.send(result);
        return;
    }
    if matches!(message.get("id").and_then(Value::as_u64), Some(2 | 3)) {
        send_snapshot(&message, ui);
    }
}

fn send_snapshot(message: &Value, ui: &mpsc::Sender<UiEvent>) {
    let Some(dataset) = message.get("dataset").and_then(Value::as_str) else {
        return;
    };
    let Some(data) = message.get("data") else {
        return;
    };
    let _ = ui.send(UiEvent::Snapshot {
        dataset: dataset.to_owned(),
        data: data.clone(),
    });
}

fn ensure_daemon() {
    let command = wfcli_command();
    let mut extra = Vec::new();
    if let Some(root) = std::env::var_os("ERL_ROOTDIR") {
        extra.push(PathBuf::from(root).join("bin/escript"));
    }
    extra.extend([
        PathBuf::from("/home/linuxbrew/.linuxbrew/bin/escript"),
        PathBuf::from("/usr/local/bin/escript"),
        PathBuf::from("/usr/bin/escript"),
    ]);
    let escript = crate::external::resolve(
        "WFCOMPANION_ESCRIPT",
        "escript",
        option_env!("WFCOMPANION_BUILD_ESCRIPT"),
        &extra,
    );
    let invocation = format!(
        "{} {}",
        PathBuf::from(&escript).display(),
        command.display()
    );
    let mut process = ProcessCommand::new(&escript);
    process.arg(&command).args(["daemon", "ensure"]);
    sanitize_native_child(&mut process);
    match process
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
    {
        Ok(status) if status.success() => {
            incident::info("daemon.ensure", format!("command={invocation}"));
        }
        Ok(status) => incident::warn(
            "daemon.ensure_failed",
            format!("command={invocation} status={status}"),
        ),
        Err(error) => incident::error(
            "daemon.ensure_failed",
            format!("command={invocation} error={error}"),
        ),
    }
}

fn sanitize_native_child(process: &mut ProcessCommand) {
    for name in [
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "STEAM_RUNTIME",
        "STEAM_RUNTIME_LIBRARY_PATH",
    ] {
        process.env_remove(name);
    }
}

fn wfcli_command() -> PathBuf {
    if let Some(path) = std::env::var_os("WFCLI_COMMAND") {
        return PathBuf::from(path);
    }
    if let Ok(current) = std::env::current_dir() {
        let candidate = current.join("wfcli");
        if candidate.is_file() {
            return candidate;
        }
    }
    if let Ok(executable) = std::env::current_exe() {
        for ancestor in executable.ancestors() {
            let candidate = ancestor.join("wfcli");
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    PathBuf::from("wfcli")
}

pub(crate) fn daemon_socket_path() -> PathBuf {
    if let Some(path) = std::env::var_os("WFCLI_DAEMON_SOCKET") {
        return PathBuf::from(path);
    }
    if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime).join("wfcli/wfdaemon.sock");
    }
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
        .unwrap_or_else(|| PathBuf::from("."));
    cache.join("wfcli/wfdaemon.sock")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_latest_value_for_reconnect_replay() {
        let (sender, receiver) = mpsc::channel();
        sender
            .send(Outbound::Publish {
                source: "game",
                data: serde_json::json!({"running": false}),
            })
            .unwrap();
        sender
            .send(Outbound::Publish {
                source: "game",
                data: serde_json::json!({"running": true}),
            })
            .unwrap();

        let mut latest = BTreeMap::new();
        let mut queued = VecDeque::new();
        drain_outbound(&receiver, &mut latest, &mut queued);
        assert_eq!(latest["game"]["running"], true);
        assert!(queued.is_empty());
    }

    #[test]
    fn rejects_incompatible_handshake() {
        let result = validate_hello(&serde_json::json!({
            "id": 1,
            "ok": false,
            "compatible": false,
            "protocol": 2
        }));
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn rejects_handshake_missing_required_capability() {
        let result = validate_hello(&serde_json::json!({
            "id": 1,
            "ok": true,
            "compatible": true,
            "protocol": PROTOCOL_VERSION,
            "capabilities": ["player.publish"]
        }));
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("dataset.subscribe")
        );
    }

    #[test]
    fn accepts_handshake_with_required_capabilities() {
        validate_hello(&serde_json::json!({
            "id": 1,
            "ok": true,
            "compatible": true,
            "protocol": PROTOCOL_VERSION,
            "capabilities": [
                "player.publish",
                "dataset.subscribe",
                "market.resolve",
                "market.quote",
                "relic.context",
                "asset.resolve"
            ]
        }))
        .unwrap();
    }

    #[test]
    fn routes_correlated_request_reply() {
        let (ui, _events) = mpsc::channel();
        let (reply, result) = mpsc::channel();
        let mut pending = BTreeMap::from([(17, reply)]);
        handle_server_message(
            r#"{"id":17,"ok":true,"data":{"matches":[]}}"#,
            &ui,
            &mut pending,
        );
        assert_eq!(result.recv().unwrap().unwrap()["id"], 17);
        assert!(pending.is_empty());
    }

    #[test]
    fn routes_overlay_and_hud_visibility_independently() {
        let (ui, events) = mpsc::channel();
        let mut pending = BTreeMap::new();

        handle_server_message(
            r#"{"event":"command","data":{"command":"overlay","visible":false}}"#,
            &ui,
            &mut pending,
        );
        assert!(matches!(
            events.recv().unwrap(),
            UiEvent::OverlayVisible(false)
        ));

        handle_server_message(
            r#"{"event":"command","data":{"command":"hud","visible":true}}"#,
            &ui,
            &mut pending,
        );
        assert!(matches!(events.recv().unwrap(), UiEvent::HudVisible(true)));
    }

    #[test]
    fn retries_request_closed_by_daemon_restart() {
        let (sender, receiver) = mpsc::channel();
        let worker = thread::spawn(move || {
            let Outbound::RelicContext { reply, .. } = receiver.recv().unwrap() else {
                panic!("expected first relic context request");
            };
            reply
                .send(Err("daemon connection closed".to_owned()))
                .unwrap();

            let Outbound::RelicContext { reply, .. } = receiver.recv().unwrap() else {
                panic!("expected retried relic context request");
            };
            reply
                .send(Ok(serde_json::json!({"data": {"quotes": []}})))
                .unwrap();
        });

        let response = relic_context(&sender, vec!["forma-blueprint".to_owned()]).unwrap();
        assert_eq!(response["data"]["quotes"], serde_json::json!([]));
        worker.join().unwrap();
    }

    #[test]
    fn relic_recommendations_preserve_price_request() {
        let (sender, receiver) = mpsc::channel();
        let worker = thread::spawn(move || {
            let Outbound::RelicRecommendations {
                fetch_prices,
                limit,
                reply,
                ..
            } = receiver.recv().unwrap()
            else {
                panic!("expected relic recommendations request");
            };
            assert!(fetch_prices);
            assert_eq!(limit, 32);
            reply
                .send(Ok(serde_json::json!({"data": {"items": []}})))
                .unwrap();
        });

        relic_recommendations(&sender, "lith".to_owned(), true).unwrap();
        worker.join().unwrap();
    }

    #[test]
    fn native_daemon_child_clears_steam_loader_environment() {
        let mut process = ProcessCommand::new("true");
        sanitize_native_child(&mut process);
        let environment: BTreeMap<_, _> = process.get_envs().collect();

        for name in [
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "STEAM_RUNTIME",
            "STEAM_RUNTIME_LIBRARY_PATH",
        ] {
            assert_eq!(environment.get(std::ffi::OsStr::new(name)), Some(&None));
        }
    }
}
