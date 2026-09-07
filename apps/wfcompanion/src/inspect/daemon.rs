use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{Value, json};

use crate::local_protocol;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(2);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_FRAME_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Debug, Serialize)]
pub struct HandshakeReport {
    pub socket: PathBuf,
    pub round_trip_ms: u128,
    pub required_interfaces: Value,
    pub response: Value,
}

#[derive(Debug, Serialize)]
pub struct DatasetReport {
    pub handshake: HandshakeReport,
    pub request_ms: u128,
    pub response: Value,
}

#[derive(Debug, Serialize)]
pub struct SubscriptionReport {
    pub handshake: HandshakeReport,
    pub initial: Value,
    pub duration_ms: u128,
    pub events: Vec<SubscriptionEvent>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SubscriptionEvent {
    pub observed_after_ms: u128,
    pub message: Value,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SubscriptionItem {
    Initial {
        message: Value,
    },
    Update {
        observed_after_ms: u128,
        message: Value,
    },
}

#[derive(Debug, Serialize)]
pub struct SubscriptionSummary {
    pub handshake: HandshakeReport,
    pub duration_ms: u128,
    pub events: usize,
}

pub fn handshake() -> Result<HandshakeReport, String> {
    let mut connection = Connection::connect()?;
    connection.handshake()
}

pub fn dataset(name: &str) -> Result<DatasetReport, String> {
    let mut connection = Connection::connect()?;
    let handshake = connection.handshake()?;
    require_compatible(&handshake.response)?;
    let started = Instant::now();
    connection.send(&json!({"op": "get", "id": 2, "dataset": name}))?;
    let response = connection.receive(REQUEST_TIMEOUT)?;
    Ok(DatasetReport {
        handshake,
        request_ms: started.elapsed().as_millis(),
        response,
    })
}

pub fn subscribe(
    name: &str,
    duration: Duration,
    limit: usize,
) -> Result<SubscriptionReport, String> {
    let mut initial = None;
    let mut events = Vec::new();
    let summary = subscribe_stream(name, duration, limit, |item| {
        match item {
            SubscriptionItem::Initial { message } => initial = Some(message.clone()),
            SubscriptionItem::Update {
                observed_after_ms,
                message,
            } => events.push(SubscriptionEvent {
                observed_after_ms: *observed_after_ms,
                message: message.clone(),
            }),
        }
        Ok(())
    })?;
    Ok(SubscriptionReport {
        handshake: summary.handshake,
        initial: initial.ok_or_else(|| "subscription returned no initial response".to_owned())?,
        duration_ms: summary.duration_ms,
        events,
    })
}

pub fn subscribe_stream(
    name: &str,
    duration: Duration,
    limit: usize,
    mut emit: impl FnMut(&SubscriptionItem) -> Result<(), String>,
) -> Result<SubscriptionSummary, String> {
    validate_bounds(duration, limit)?;
    let mut connection = Connection::connect()?;
    let handshake = connection.handshake()?;
    require_compatible(&handshake.response)?;
    connection.send(&json!({
        "op": "subscribe",
        "id": 2,
        "dataset": name,
        "include_data": false,
    }))?;
    let initial = connection.receive(REQUEST_TIMEOUT)?;
    require_ok(&initial, "subscription")?;
    emit(&SubscriptionItem::Initial { message: initial })?;

    let started = Instant::now();
    let deadline = started + duration;
    let mut events = 0;
    while Instant::now() < deadline && events < limit {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match connection.receive(remaining) {
            Ok(message) => {
                let item = SubscriptionItem::Update {
                    observed_after_ms: started.elapsed().as_millis(),
                    message,
                };
                emit(&item)?;
                events += 1;
            }
            Err(error) if error == "daemon read timed out" => break,
            Err(error) => return Err(error),
        }
    }
    let _ = connection.send(&json!({
        "op": "unsubscribe",
        "id": 3,
        "subscription": 2,
    }));
    Ok(SubscriptionSummary {
        handshake,
        duration_ms: started.elapsed().as_millis(),
        events,
    })
}

struct Connection {
    socket: PathBuf,
    writer: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Connection {
    fn connect() -> Result<Self, String> {
        let socket = local_protocol::socket_path();
        let writer = UnixStream::connect(&socket)
            .map_err(|error| format!("could not connect to {}: {error}", socket.display()))?;
        writer
            .set_write_timeout(Some(REQUEST_TIMEOUT))
            .map_err(|error| format!("could not configure daemon socket: {error}"))?;
        let reader = writer
            .try_clone()
            .map(BufReader::new)
            .map_err(|error| format!("could not clone daemon socket: {error}"))?;
        Ok(Self {
            socket,
            writer,
            reader,
        })
    }

    fn handshake(&mut self) -> Result<HandshakeReport, String> {
        let request = hello_request();
        let required_interfaces = request["interfaces"].clone();
        let started = Instant::now();
        self.send(&request)?;
        let response = self.receive(HANDSHAKE_TIMEOUT)?;
        Ok(HandshakeReport {
            socket: self.socket.clone(),
            round_trip_ms: started.elapsed().as_millis(),
            required_interfaces,
            response,
        })
    }

    fn send(&mut self, message: &Value) -> Result<(), String> {
        serde_json::to_writer(&mut self.writer, message)
            .map_err(|error| format!("could not encode daemon request: {error}"))?;
        self.writer
            .write_all(b"\n")
            .map_err(|error| format!("could not write daemon request: {error}"))
    }

    fn receive(&mut self, timeout: Duration) -> Result<Value, String> {
        self.reader
            .get_ref()
            .set_read_timeout(Some(timeout))
            .map_err(|error| format!("could not configure daemon socket: {error}"))?;
        let mut frame = Vec::new();
        let read = self
            .reader
            .by_ref()
            .take(MAX_FRAME_BYTES + 1)
            .read_until(b'\n', &mut frame)
            .map_err(|error| {
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) {
                    "daemon read timed out".to_owned()
                } else {
                    format!("could not read daemon response: {error}")
                }
            })?;
        if read == 0 {
            return Err("daemon closed the connection".to_owned());
        }
        if read as u64 > MAX_FRAME_BYTES || !frame.ends_with(b"\n") {
            return Err("daemon response exceeds 128 MiB frame limit".to_owned());
        }
        frame.pop();
        if frame.ends_with(b"\r") {
            frame.pop();
        }
        serde_json::from_slice(&frame).map_err(|error| format!("daemon sent invalid JSON: {error}"))
    }
}

fn hello_request() -> Value {
    json!({
        "op": "hello",
        "id": 1,
        "envelope": local_protocol::ENVELOPE_VERSION,
        "interfaces": local_protocol::interfaces(),
        "features": [],
        "client": "wfinspect",
        "version": env!("WFCLI_VERSION"),
        "pid": std::process::id(),
        "mode": "diagnostic",
    })
}

fn require_compatible(response: &Value) -> Result<(), String> {
    require_ok(response, "handshake")?;
    if response.get("compatible").and_then(Value::as_bool) == Some(true) {
        Ok(())
    } else {
        Err(format!("daemon contract mismatch: {response}"))
    }
}

fn require_ok(response: &Value, operation: &str) -> Result<(), String> {
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        Ok(())
    } else {
        Err(format!("daemon {operation} failed: {response}"))
    }
}

fn validate_bounds(duration: Duration, limit: usize) -> Result<(), String> {
    if duration.is_zero() || duration > Duration::from_secs(300) {
        return Err("duration must be between 1 ms and 300 seconds".to_owned());
    }
    if limit == 0 || limit > 1000 {
        return Err("event limit must be between 1 and 1000".to_owned());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hello_requires_complete_local_contract() {
        let hello = hello_request();
        assert_eq!(hello["envelope"], local_protocol::ENVELOPE_VERSION);
        assert_eq!(hello["interfaces"]["worldstate"], 1);
        assert_eq!(hello["interfaces"]["builds"], 1);
        assert_eq!(hello["client"], "wfinspect");
    }

    #[test]
    fn subscription_is_bounded() {
        assert!(validate_bounds(Duration::ZERO, 1).is_err());
        assert!(validate_bounds(Duration::from_secs(301), 1).is_err());
        assert!(validate_bounds(Duration::from_secs(1), 0).is_err());
        assert!(validate_bounds(Duration::from_secs(1), 1001).is_err());
    }
}
