use std::collections::{BTreeMap, VecDeque};
use std::io;
use std::path::PathBuf;
use std::process::{Command as ProcessCommand, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc as std_mpsc};
use std::thread;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;
use tokio::io::{
    AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, Lines,
};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tokio::time::{self, MissedTickBehavior};

use crate::{UiEvent, incident};

include!(concat!(env!("OUT_DIR"), "/local_protocol.rs"));
const CLIENT_VERSION: &str = env!("WFCLI_VERSION");
const RECONNECT_INTERVAL: Duration = Duration::from_secs(2);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(2);
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const RELIC_SUGGESTION_LIMIT: u64 = 32;
const STOP_CHECK_INTERVAL: Duration = Duration::from_secs(1);

pub(crate) type OutboundSender = mpsc::UnboundedSender<Outbound>;
type OutboundReceiver = mpsc::UnboundedReceiver<Outbound>;
type ReplySender = std_mpsc::Sender<Result<Value, String>>;

#[derive(Debug)]
pub(crate) struct RequestReply {
    sender: ReplySender,
    deadline: Instant,
}

impl RequestReply {
    fn new(sender: ReplySender) -> Self {
        Self {
            sender,
            deadline: Instant::now() + REQUEST_TIMEOUT,
        }
    }

    fn expired(&self) -> bool {
        Instant::now() >= self.deadline
    }

    fn send(&self, result: Result<Value, String>) {
        let _ = self.sender.send(result);
    }
}

#[derive(Debug, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum ClientMessage<'a> {
    Hello {
        id: u64,
        envelope: u32,
        interfaces: &'a BTreeMap<&'static str, u32>,
        features: &'a [&'static str],
        client: &'a str,
        version: &'a str,
        pid: u32,
        mode: &'a str,
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
    DiagnosticsReport {
        id: u64,
        issues: &'a [Value],
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
        reply: RequestReply,
    },
    AssetResolve {
        assets: Vec<Value>,
        reply: RequestReply,
    },
    RelicContext {
        items: Vec<String>,
        reply: RequestReply,
    },
    RelicRecommendations {
        era: String,
        fetch_prices: bool,
        limit: u64,
        reply: RequestReply,
    },
    DiagnosticsReport {
        issues: Vec<Value>,
    },
}

pub(crate) fn report_diagnostics(outbound: &OutboundSender, issues: Vec<Value>) {
    let _ = outbound.send(Outbound::DiagnosticsReport { issues });
}

pub(crate) fn market_resolve(
    outbound: &OutboundSender,
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
    outbound: &OutboundSender,
    assets: Vec<Value>,
) -> Result<Value, String> {
    request(outbound, |reply| Outbound::AssetResolve {
        assets: assets.clone(),
        reply,
    })
}

pub(crate) fn relic_context(
    outbound: &OutboundSender,
    items: Vec<String>,
) -> Result<Value, String> {
    request(outbound, |reply| Outbound::RelicContext {
        items: items.clone(),
        reply,
    })
}

pub(crate) fn relic_recommendations(
    outbound: &OutboundSender,
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
    outbound: &OutboundSender,
    build: impl Fn(RequestReply) -> Outbound,
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
    outbound: &OutboundSender,
    build: &impl Fn(RequestReply) -> Outbound,
) -> Result<Value, String> {
    let (reply_tx, reply_rx) = std_mpsc::channel();
    outbound
        .send(build(RequestReply::new(reply_tx)))
        .map_err(|_| "daemon connection worker stopped".to_owned())?;
    match reply_rx.recv_timeout(REQUEST_TIMEOUT) {
        Ok(result) => result,
        Err(std_mpsc::RecvTimeoutError::Timeout) => Err("daemon request timed out".to_owned()),
        Err(std_mpsc::RecvTimeoutError::Disconnected) => {
            Err("daemon connection worker stopped".to_owned())
        }
    }
}

pub(crate) fn spawn(
    ui: std_mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
    mode: &'static str,
) -> OutboundSender {
    let (outbound_tx, outbound_rx) = mpsc::unbounded_channel();
    thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build();
        match runtime {
            Ok(runtime) => runtime.block_on(connection_loop(outbound_rx, ui, stopping, mode)),
            Err(error) => incident::error("daemon.runtime_failed", error.to_string()),
        }
    });
    outbound_tx
}

async fn connection_loop(
    mut outbound: OutboundReceiver,
    ui: std_mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
    mode: &'static str,
) {
    let path = daemon_socket_path();
    let mut start_attempted = false;
    let mut latest = BTreeMap::new();
    let mut queued = VecDeque::new();
    loop {
        if stopping.load(Ordering::Relaxed) {
            return;
        }
        drain_outbound(&mut outbound, &mut latest, &mut queued);
        let connection = time::timeout(CONNECT_TIMEOUT, UnixStream::connect(&path))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "daemon connect timed out"))
            .and_then(|result| result);
        match connection {
            Ok(stream) => {
                start_attempted = false;
                if let Err(error) = connection_session(
                    stream,
                    &mut outbound,
                    &mut latest,
                    &mut queued,
                    &ui,
                    &stopping,
                    mode,
                )
                .await
                {
                    let daemon_outdated = error.kind() == io::ErrorKind::Unsupported;
                    incident::warn("daemon.disconnected", error.to_string());
                    let _ = ui.send(UiEvent::Disconnected(error.to_string()));
                    if daemon_outdated {
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
        if stopping.load(Ordering::Relaxed)
            || !wait_for_reconnect(&mut outbound, &mut latest, &mut queued, &stopping).await
        {
            return;
        }
    }
}

async fn wait_for_reconnect(
    outbound: &mut OutboundReceiver,
    latest: &mut BTreeMap<&'static str, Value>,
    queued: &mut VecDeque<Outbound>,
    stopping: &AtomicBool,
) -> bool {
    let delay = time::sleep(RECONNECT_INTERVAL);
    tokio::pin!(delay);
    let mut stop_check = time::interval(STOP_CHECK_INTERVAL);
    stop_check.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = &mut delay => return true,
            message = outbound.recv() => match message {
                Some(message) => retain_outbound(message, latest, queued),
                None => return false,
            },
            _ = stop_check.tick() => {
                if stopping.load(Ordering::Relaxed) {
                    return false;
                }
            }
        }
    }
}

async fn connection_session(
    mut stream: UnixStream,
    outbound: &mut OutboundReceiver,
    latest: &mut BTreeMap<&'static str, Value>,
    queued: &mut VecDeque<Outbound>,
    ui: &std_mpsc::Sender<UiEvent>,
    stopping: &AtomicBool,
    mode: &'static str,
) -> io::Result<()> {
    let (reader, mut writer) = stream.split();
    let mut reader = BufReader::new(reader).lines();
    let interfaces = companion_interfaces();
    let features = ["companion.command", "diagnostics.report"];
    let hello = time::timeout(HANDSHAKE_TIMEOUT, async {
        send_message(
            &mut writer,
            &ClientMessage::Hello {
                id: 1,
                envelope: ENVELOPE_VERSION,
                interfaces: &interfaces,
                features: &features,
                client: "wfcompanion",
                version: CLIENT_VERSION,
                pid: std::process::id(),
                mode,
            },
        )
        .await?;
        read_message(&mut reader).await
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "daemon handshake timed out"))??;
    let negotiated = validate_hello(&hello)?;
    incident::info(
        "daemon.connected",
        format!("local_envelope={ENVELOPE_VERSION} mode={mode}"),
    );
    let _ = ui.send(UiEvent::Connected(hello));

    send_message(
        &mut writer,
        &ClientMessage::Subscribe {
            id: 2,
            dataset: "player",
        },
    )
    .await?;
    send_message(
        &mut writer,
        &ClientMessage::Get {
            id: 3,
            dataset: "daemon",
        },
    )
    .await?;

    let mut next_id = 10;
    for (&source, data) in latest.iter() {
        send_publish(&mut writer, next_id, source, data).await?;
        next_id += 1;
    }

    let mut pending = BTreeMap::new();
    while let Some(message) = queued.pop_front() {
        if let Err(error) = send_outbound(
            &mut writer,
            next_id,
            message,
            latest,
            &mut pending,
            negotiated.diagnostics_report,
        )
        .await
        {
            fail_pending(&mut pending, "daemon connection closed");
            return Err(error);
        }
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
        diagnostics_report: negotiated.diagnostics_report,
    })
    .await;
    fail_pending(&mut pending, "daemon connection closed");
    result
}

struct ActiveSession<'a, R, W> {
    writer: &'a mut W,
    reader: &'a mut Lines<BufReader<R>>,
    outbound: &'a mut OutboundReceiver,
    latest: &'a mut BTreeMap<&'static str, Value>,
    ui: &'a std_mpsc::Sender<UiEvent>,
    stopping: &'a AtomicBool,
    next_id: u64,
    pending: &'a mut BTreeMap<u64, RequestReply>,
    diagnostics_report: bool,
}

async fn active_session<R, W>(session: ActiveSession<'_, R, W>) -> io::Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let ActiveSession {
        writer,
        reader,
        outbound,
        latest,
        ui,
        stopping,
        mut next_id,
        pending,
        diagnostics_report,
    } = session;
    let mut stop_check = time::interval(STOP_CHECK_INTERVAL);
    stop_check.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            message = outbound.recv() => match message {
                Some(message) => {
                    send_outbound(
                        writer,
                        next_id,
                        message,
                        latest,
                        pending,
                        diagnostics_report,
                    )
                    .await?;
                    next_id += 1;
                }
                None => return Ok(()),
            },
            line = reader.next_line() => match line? {
                Some(line) => handle_server_message(&line, ui, pending),
                None => {
                    return Err(io::Error::new(
                        io::ErrorKind::ConnectionReset,
                        "daemon closed",
                    ));
                }
            },
            _ = stop_check.tick() => {
                expire_pending(pending);
                if stopping.load(Ordering::Relaxed) {
                    return Ok(());
                }
            }
        }
    }
}

fn drain_outbound(
    outbound: &mut OutboundReceiver,
    latest: &mut BTreeMap<&'static str, Value>,
    queued: &mut VecDeque<Outbound>,
) {
    while let Ok(message) = outbound.try_recv() {
        retain_outbound(message, latest, queued);
    }
}

fn retain_outbound(
    message: Outbound,
    latest: &mut BTreeMap<&'static str, Value>,
    queued: &mut VecDeque<Outbound>,
) {
    match message {
        Outbound::Publish { source, data } => {
            latest.insert(source, data);
        }
        report @ Outbound::DiagnosticsReport { .. } => {
            queued.retain(|item| !matches!(item, Outbound::DiagnosticsReport { .. }));
            queued.push_back(report);
        }
        request => queued.push_back(request),
    }
}

async fn send_outbound<W>(
    writer: &mut W,
    id: u64,
    message: Outbound,
    latest: &mut BTreeMap<&'static str, Value>,
    pending: &mut BTreeMap<u64, RequestReply>,
    diagnostics_report: bool,
) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    match message {
        Outbound::Publish { source, data } => {
            latest.insert(source, data);
            send_publish(writer, id, source, &latest[source]).await
        }
        Outbound::MarketResolve {
            labels,
            limit,
            reply,
        } => {
            if !register_pending(pending, id, reply) {
                return Ok(());
            }
            send_message(
                writer,
                &ClientMessage::MarketResolve {
                    id,
                    labels: &labels,
                    limit,
                },
            )
            .await
        }
        Outbound::AssetResolve { assets, reply } => {
            if !register_pending(pending, id, reply) {
                return Ok(());
            }
            send_message(
                writer,
                &ClientMessage::AssetResolve {
                    id,
                    assets: &assets,
                },
            )
            .await
        }
        Outbound::RelicContext { items, reply } => {
            if !register_pending(pending, id, reply) {
                return Ok(());
            }
            send_message(writer, &ClientMessage::RelicContext { id, items: &items }).await
        }
        Outbound::RelicRecommendations {
            era,
            fetch_prices,
            limit,
            reply,
        } => {
            if !register_pending(pending, id, reply) {
                return Ok(());
            }
            send_message(
                writer,
                &ClientMessage::RelicRecommendations {
                    id,
                    era: &era,
                    fetch_prices,
                    limit,
                },
            )
            .await
        }
        Outbound::DiagnosticsReport { issues } => {
            if !diagnostics_report {
                return Ok(());
            }
            send_message(
                writer,
                &ClientMessage::DiagnosticsReport {
                    id,
                    issues: &issues,
                },
            )
            .await
        }
    }
}

fn register_pending(
    pending: &mut BTreeMap<u64, RequestReply>,
    id: u64,
    reply: RequestReply,
) -> bool {
    if reply.expired() {
        reply.send(Err("daemon request timed out".to_owned()));
        false
    } else {
        pending.insert(id, reply);
        true
    }
}

fn expire_pending(pending: &mut BTreeMap<u64, RequestReply>) {
    pending.retain(|_, reply| {
        if reply.expired() {
            reply.send(Err("daemon request timed out".to_owned()));
            false
        } else {
            true
        }
    });
}

fn fail_pending(pending: &mut BTreeMap<u64, RequestReply>, reason: &str) {
    for (_, reply) in std::mem::take(pending) {
        reply.send(Err(reason.to_owned()));
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
struct NegotiatedFeatures {
    diagnostics_report: bool,
}

fn validate_hello(message: &Value) -> io::Result<NegotiatedFeatures> {
    let compatible = message.get("id").and_then(Value::as_u64) == Some(1)
        && message.get("ok").and_then(Value::as_bool) == Some(true)
        && message.get("compatible").and_then(Value::as_bool) == Some(true);
    if !compatible {
        let daemon_envelope = message
            .get("envelope")
            .and_then(Value::as_u64)
            .map_or_else(|| "unknown".to_owned(), |value| value.to_string());
        let mismatches = message
            .get("mismatches")
            .map_or_else(|| "unknown".to_owned(), Value::to_string);
        let kind = if daemon_contract_outdated(message) {
            io::ErrorKind::Unsupported
        } else {
            io::ErrorKind::InvalidData
        };
        return Err(io::Error::new(
            kind,
            format!(
                "daemon contract mismatch: companion envelope {ENVELOPE_VERSION}, daemon {daemon_envelope}; {mismatches}"
            ),
        ));
    }

    if message.get("envelope").and_then(Value::as_u64) != Some(u64::from(ENVELOPE_VERSION)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "daemon returned a different handshake envelope",
        ));
    }
    let offered = message
        .get("interfaces")
        .and_then(Value::as_object)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "daemon sent no interfaces"))?;
    for (name, version) in companion_interfaces() {
        if offered.get(name).and_then(Value::as_u64) != Some(u64::from(version)) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("daemon interface mismatch: {name} requires {version}"),
            ));
        }
    }
    let diagnostics_report = message
        .get("features")
        .and_then(Value::as_array)
        .is_some_and(|features| {
            features
                .iter()
                .any(|value| value.as_str() == Some("diagnostics.report"))
        })
        && offered.get("diagnostics").and_then(Value::as_u64)
            == Some(u64::from(INTERFACE_DIAGNOSTICS));
    Ok(NegotiatedFeatures { diagnostics_report })
}

fn companion_interfaces() -> BTreeMap<&'static str, u32> {
    BTreeMap::from([
        ("datasets", INTERFACE_DATASETS),
        ("player", INTERFACE_PLAYER),
        ("market", INTERFACE_MARKET),
        ("relics", INTERFACE_RELICS),
        ("assets", INTERFACE_ASSETS),
        ("diagnostics", INTERFACE_DIAGNOSTICS),
    ])
}

fn daemon_contract_outdated(message: &Value) -> bool {
    if message.get("envelope").is_none()
        && message.get("protocol").and_then(Value::as_u64).is_some()
    {
        return true;
    }
    let Some(envelope) = message.get("envelope").and_then(Value::as_u64) else {
        return false;
    };
    let Some(offered) = message.get("interfaces").and_then(Value::as_object) else {
        return false;
    };

    let mut mismatch = false;
    if envelope != u64::from(ENVELOPE_VERSION) {
        mismatch = true;
        if u64::from(ENVELOPE_VERSION) <= envelope {
            return false;
        }
    }
    for (name, required) in companion_interfaces() {
        let available = offered.get(name).and_then(Value::as_u64);
        if available == Some(u64::from(required)) {
            continue;
        }
        mismatch = true;
        if available.is_some_and(|version| u64::from(required) <= version) {
            return false;
        }
    }
    mismatch
}

async fn read_message<R>(reader: &mut Lines<R>) -> io::Result<Value>
where
    R: AsyncBufRead + Unpin,
{
    match reader.next_line().await? {
        None => Err(io::Error::new(
            io::ErrorKind::ConnectionReset,
            "daemon closed during handshake",
        )),
        Some(line) => serde_json::from_str(&line)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error)),
    }
}

async fn send_publish<W>(
    writer: &mut W,
    id: u64,
    source: &'static str,
    data: &Value,
) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    send_message(
        writer,
        &ClientMessage::Publish {
            id,
            dataset: "player",
            source,
            data,
        },
    )
    .await
}

async fn send_message<W>(writer: &mut W, message: &ClientMessage<'_>) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let mut frame = serde_json::to_vec(message)?;
    frame.push(b'\n');
    time::timeout(WRITE_TIMEOUT, writer.write_all(&frame))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "daemon write timed out"))?
}

fn handle_server_message(
    line: &str,
    ui: &std_mpsc::Sender<UiEvent>,
    pending: &mut BTreeMap<u64, RequestReply>,
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
    if message.get("event").and_then(Value::as_str) == Some("asset") {
        if let Some(data) = message.get("data")
            && let Ok(refresh) = serde_json::from_value::<crate::relic::AssetRefresh>(data.clone())
        {
            let _ = ui.send(UiEvent::AssetRefreshed(refresh));
        }
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
        reply.send(result);
        return;
    }
    if matches!(message.get("id").and_then(Value::as_u64), Some(2 | 3)) {
        send_snapshot(&message, ui);
    }
}

fn send_snapshot(message: &Value, ui: &std_mpsc::Sender<UiEvent>) {
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
    let invocation = format!("{} daemon ensure", command.display());
    let mut process = ProcessCommand::new(&command);
    process.args(["daemon", "ensure"]);
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
        let (sender, mut receiver) = mpsc::unbounded_channel();
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
        drain_outbound(&mut receiver, &mut latest, &mut queued);
        assert_eq!(latest["game"]["running"], true);
        assert!(queued.is_empty());
    }

    #[test]
    fn coalesces_disconnected_diagnostics_reports() {
        let mut latest = BTreeMap::new();
        let mut queued = VecDeque::new();
        retain_outbound(
            Outbound::DiagnosticsReport {
                issues: vec![serde_json::json!({"identity": "old"})],
            },
            &mut latest,
            &mut queued,
        );
        retain_outbound(
            Outbound::DiagnosticsReport {
                issues: vec![serde_json::json!({"identity": "new"})],
            },
            &mut latest,
            &mut queued,
        );

        assert_eq!(queued.len(), 1);
        let Some(Outbound::DiagnosticsReport { issues }) = queued.pop_front() else {
            panic!("expected diagnostics report");
        };
        assert_eq!(issues[0]["identity"], "new");
    }

    #[test]
    fn active_session_wakes_for_outbound_publish() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let (mut client, server) = UnixStream::pair().unwrap();
            let (reader, mut writer) = client.split();
            let mut reader = BufReader::new(reader).lines();
            let mut server = BufReader::new(server).lines();
            let (sender, mut outbound) = mpsc::unbounded_channel();
            let (ui, _events) = std_mpsc::channel();
            let stopping = AtomicBool::new(false);
            let mut latest = BTreeMap::new();
            let mut pending = BTreeMap::new();
            let session = active_session(ActiveSession {
                writer: &mut writer,
                reader: &mut reader,
                outbound: &mut outbound,
                latest: &mut latest,
                ui: &ui,
                stopping: &stopping,
                next_id: 10,
                pending: &mut pending,
                diagnostics_report: false,
            });
            tokio::pin!(session);

            let line = time::timeout(Duration::from_secs(1), async {
                time::sleep(Duration::from_millis(10)).await;
                sender
                    .send(Outbound::Publish {
                        source: "game",
                        data: serde_json::json!({"running": true}),
                    })
                    .unwrap();
                tokio::select! {
                    result = &mut session => panic!("session ended before publish: {result:?}"),
                    line = server.next_line() => line.unwrap().unwrap(),
                }
            })
            .await
            .unwrap();
            let message: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(message["op"], "publish");
            assert_eq!(message["source"], "game");
            assert_eq!(message["data"]["running"], true);

            drop(server);
            assert!(
                time::timeout(Duration::from_secs(1), &mut session)
                    .await
                    .unwrap()
                    .is_err()
            );
        });
    }

    #[test]
    fn expired_request_is_not_registered() {
        let (sender, result) = std_mpsc::channel();
        let reply = RequestReply {
            sender,
            deadline: Instant::now() - Duration::from_millis(1),
        };
        let mut pending = BTreeMap::new();

        assert!(!register_pending(&mut pending, 17, reply));
        assert_eq!(
            result.recv().unwrap(),
            Err("daemon request timed out".to_owned())
        );
        assert!(pending.is_empty());
    }

    #[test]
    fn rejects_incompatible_handshake() {
        let result = validate_hello(&serde_json::json!({
            "id": 1,
            "ok": false,
            "compatible": false,
            "envelope": 2,
            "mismatches": [{"kind": "envelope"}]
        }));
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn requests_update_only_for_older_daemon_contract() {
        let result = validate_hello(&serde_json::json!({
            "id": 1,
            "ok": false,
            "compatible": false,
            "envelope": ENVELOPE_VERSION,
            "interfaces": {
                "player": INTERFACE_PLAYER,
                "market": INTERFACE_MARKET,
                "relics": INTERFACE_RELICS,
                "assets": INTERFACE_ASSETS,
                "diagnostics": INTERFACE_DIAGNOSTICS
            }
        }));
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Unsupported);

        let result = validate_hello(&serde_json::json!({
            "id": 1,
            "ok": false,
            "compatible": false,
            "envelope": ENVELOPE_VERSION,
            "interfaces": {
                "datasets": INTERFACE_DATASETS + 1,
                "player": INTERFACE_PLAYER,
                "market": INTERFACE_MARKET,
                "relics": INTERFACE_RELICS,
                "assets": INTERFACE_ASSETS,
                "diagnostics": INTERFACE_DIAGNOSTICS
            }
        }));
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::InvalidData);

        let result = validate_hello(&serde_json::json!({
            "id": 1,
            "ok": false,
            "compatible": false,
            "protocol": 13
        }));
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Unsupported);
    }

    #[test]
    fn rejects_handshake_missing_required_interface() {
        let result = validate_hello(&serde_json::json!({
            "id": 1,
            "ok": true,
            "compatible": true,
            "envelope": ENVELOPE_VERSION,
            "interfaces": {
                "datasets": INTERFACE_DATASETS,
                "player": INTERFACE_PLAYER
            }
        }));
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("interface mismatch")
        );
    }

    #[test]
    fn accepts_handshake_with_required_interfaces() {
        let negotiated = validate_hello(&serde_json::json!({
            "id": 1,
            "ok": true,
            "compatible": true,
            "envelope": ENVELOPE_VERSION,
            "interfaces": {
                "datasets": INTERFACE_DATASETS,
                "player": INTERFACE_PLAYER,
                "market": INTERFACE_MARKET,
                "relics": INTERFACE_RELICS,
                "assets": INTERFACE_ASSETS,
                "diagnostics": INTERFACE_DIAGNOSTICS
            },
            "features": ["companion.command", "diagnostics.report"]
        }))
        .unwrap();
        assert!(negotiated.diagnostics_report);
    }

    #[test]
    fn routes_correlated_request_reply() {
        let (ui, _events) = std_mpsc::channel();
        let (reply, result) = std_mpsc::channel();
        let mut pending = BTreeMap::from([(17, RequestReply::new(reply))]);
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
        let (ui, events) = std_mpsc::channel();
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
    fn routes_asset_refresh_event() {
        let (ui, events) = std_mpsc::channel();
        let mut pending = BTreeMap::new();

        handle_server_message(
            r#"{"event":"asset","data":{"source":"market","image_name":"item.webp","path":"/cache/item.webp","digest":"new"}}"#,
            &ui,
            &mut pending,
        );

        let UiEvent::AssetRefreshed(refresh) = events.recv().unwrap() else {
            panic!("expected asset refresh");
        };
        assert_eq!(refresh.source, "market");
        assert_eq!(refresh.image_name, "item.webp");
        assert_eq!(refresh.digest, "new");
    }

    #[test]
    fn retries_request_closed_by_daemon_restart() {
        let (sender, mut receiver) = mpsc::unbounded_channel();
        let worker = thread::spawn(move || {
            let Outbound::RelicContext { reply, .. } = receiver.blocking_recv().unwrap() else {
                panic!("expected first relic context request");
            };
            reply.send(Err("daemon connection closed".to_owned()));

            let Outbound::RelicContext { reply, .. } = receiver.blocking_recv().unwrap() else {
                panic!("expected retried relic context request");
            };
            reply.send(Ok(serde_json::json!({"data": {"quotes": []}})));
        });

        let response = relic_context(&sender, vec!["forma-blueprint".to_owned()]).unwrap();
        assert_eq!(response["data"]["quotes"], serde_json::json!([]));
        worker.join().unwrap();
    }

    #[test]
    fn relic_recommendations_preserve_price_request() {
        let (sender, mut receiver) = mpsc::unbounded_channel();
        let worker = thread::spawn(move || {
            let Outbound::RelicRecommendations {
                fetch_prices,
                limit,
                reply,
                ..
            } = receiver.blocking_recv().unwrap()
            else {
                panic!("expected relic recommendations request");
            };
            assert!(fetch_prices);
            assert_eq!(limit, 32);
            reply.send(Ok(serde_json::json!({"data": {"items": []}})));
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
