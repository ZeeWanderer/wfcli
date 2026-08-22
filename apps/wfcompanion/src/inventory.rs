use std::collections::HashSet;
use std::collections::hash_map::DefaultHasher;
use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::{Map, Value};

use crate::debug_output::Runtime;

mod gep;

const POINTER_POLL_INTERVAL: Duration = Duration::from_millis(7);
const INVENTORY_MARKER: &[u8] = b"LastInventorySync";
const SCHEMA_VERSION: u32 = 2;

#[derive(Debug)]
pub(crate) enum Event {
    Inventory {
        game_pid: u32,
        collector: &'static str,
        process_pid: u32,
        data: Value,
    },
}

pub(crate) struct Bridge {
    game_pid: u32,
    stopping: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl Bridge {
    pub(crate) fn start(runtime: &Runtime, events: mpsc::Sender<Event>) -> Result<Self, String> {
        let game_pid = runtime.game_pid();
        let (stopping, worker) = start_native(game_pid, runtime.prefix().to_owned(), events)?;
        Ok(Self {
            game_pid,
            stopping,
            worker: Some(worker),
        })
    }

    pub(crate) fn game_pid(&self) -> u32 {
        self.game_pid
    }

    pub(crate) fn is_running(&mut self) -> bool {
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

#[derive(Debug, Serialize)]
struct Observation {
    schema: u32,
    collector: &'static str,
    collected_at: u128,
    process_pid: u32,
    sync: Value,
    profile: Profile,
    raw: Value,
}

#[derive(Debug, Default, Serialize)]
struct Profile {
    player_name: Option<String>,
    player_level: Option<i64>,
    regular_credits: Option<i64>,
    premium_credits: Option<i64>,
    premium_credits_free: Option<i64>,
    fusion_points: Option<i64>,
    trades_remaining: Option<i64>,
    daily_focus: Option<i64>,
    focus_capacity: Option<i64>,
    last_region_played: Option<String>,
}

fn start_native(
    game_pid: u32,
    prefix: PathBuf,
    events: mpsc::Sender<Event>,
) -> Result<(Arc<AtomicBool>, JoinHandle<()>), String> {
    let mem = File::open(format!("/proc/{game_pid}/mem"))
        .map_err(|error| format!("could not open Warframe memory: {error}"))?;
    let sources = gep::Sources::discover(&mem, game_pid)?;
    let stopping = Arc::new(AtomicBool::new(false));
    let worker_stopping = Arc::clone(&stopping);
    let worker =
        thread::spawn(move || scan_native(game_pid, mem, sources, prefix, worker_stopping, events));
    Ok((stopping, worker))
}

fn scan_native(
    game_pid: u32,
    mem: File,
    sources: gep::Sources,
    prefix: PathBuf,
    stopping: Arc<AtomicBool>,
    events: mpsc::Sender<Event>,
) {
    let mut player_name = player_name_from_log(&prefix);
    let mut seen_payloads = HashSet::new();
    let mut poll_state = gep::PollState::default();
    let (queue, item_base, body, alternate) = sources.response_offsets();
    crate::incident::info(
        "inventory.native_gep_ready",
        format!(
            "game_pid={game_pid} global=0x{:x} queue=0x{queue:x} item=0x{item_base:x} body=0x{body:x} alternate=0x{alternate:x}",
            sources.manager_global()
        ),
    );
    while !stopping.load(Ordering::Relaxed) {
        for (source, payload) in sources.persistent_payloads(&mem, &mut poll_state) {
            if publish_payload(
                &payload,
                source,
                game_pid,
                &prefix,
                &mut player_name,
                &mut seen_payloads,
                &events,
            )
            .is_err()
            {
                return;
            }
        }
        thread::sleep(POINTER_POLL_INTERVAL);
    }
}

fn publish_payload(
    payload: &[u8],
    source: &'static str,
    game_pid: u32,
    prefix: &Path,
    player_name: &mut Option<String>,
    seen_payloads: &mut HashSet<u64>,
    events: &mpsc::Sender<Event>,
) -> Result<bool, ()> {
    let (data, snapshot) =
        match decode_new_payload(payload, game_pid, prefix, player_name, seen_payloads) {
            Ok(Some(parsed)) => parsed,
            Ok(None) => return Ok(false),
            Err(error) => {
                crate::incident::warn(
                    "inventory.native_payload_rejected",
                    format!("source={source} bytes={} error={error}", payload.len()),
                );
                return Ok(false);
            }
        };
    crate::incident::info(
        "inventory.native_payload_accepted",
        format!(
            "source={source} bytes={} snapshot={snapshot:016x}",
            payload.len()
        ),
    );
    events
        .send(Event::Inventory {
            game_pid,
            collector: "native_http_buffer",
            process_pid: game_pid,
            data,
        })
        .map_err(|_| ())?;
    Ok(true)
}

fn decode_new_payload(
    payload: &[u8],
    game_pid: u32,
    prefix: &Path,
    player_name: &mut Option<String>,
    seen_payloads: &mut HashSet<u64>,
) -> Result<Option<(Value, u64)>, String> {
    if !payload
        .windows(INVENTORY_MARKER.len())
        .any(|window| window == INVENTORY_MARKER)
    {
        return Ok(None);
    }
    let fingerprint = hash_bytes(payload);
    if seen_payloads.contains(&fingerprint) {
        return Ok(None);
    }
    if player_name.is_none() {
        *player_name = player_name_from_log(prefix);
    }
    let data = parse_observation(
        payload,
        "native_http_buffer",
        game_pid,
        player_name.as_deref(),
    )?;
    let snapshot = hash_bytes(
        &serde_json::to_vec(data.get("raw").unwrap_or(&data))
            .map_err(|error| format!("could not fingerprint inventory: {error}"))?,
    );
    seen_payloads.insert(fingerprint);
    Ok(Some((data, snapshot)))
}

fn hash_bytes(bytes: &[u8]) -> u64 {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

fn player_name_from_log(prefix: &Path) -> Option<String> {
    let users = prefix.join("drive_c/users");
    let steam_log = users.join("steamuser/AppData/Local/Warframe/EE.log");
    let log = if steam_log.is_file() {
        steam_log
    } else {
        fs::read_dir(users)
            .ok()?
            .flatten()
            .map(|entry| entry.path().join("AppData/Local/Warframe/EE.log"))
            .find(|path| path.is_file())?
    };
    BufReader::new(File::open(log).ok()?)
        .lines()
        .map_while(Result::ok)
        .find_map(|line| {
            let (_, login) = line.split_once("Logged in ")?;
            let name = login.split('(').next()?.trim();
            (!name.is_empty()).then(|| name.to_owned())
        })
}

fn parse_observation(
    payload: &[u8],
    collector: &'static str,
    process_pid: u32,
    player_name: Option<&str>,
) -> Result<Value, String> {
    let value: Value = serde_json::from_slice(payload)
        .map_err(|error| format!("inventory payload is not valid JSON: {error}"))?;
    let shape = root_shape(&value);
    let raw = extract_inventory(value).ok_or_else(|| {
        format!("inventory payload contains no complete inventory object; {shape}")
    })?;
    let object = raw
        .as_object()
        .ok_or_else(|| "inventory payload root is not an object".to_owned())?;
    let sync = object
        .get("LastInventorySync")
        .cloned()
        .ok_or_else(|| "inventory payload has no LastInventorySync".to_owned())?;
    let sync_key = value_key(&sync);
    if sync_key.is_empty() {
        return Err("inventory LastInventorySync is empty".to_owned());
    }
    let observation = Observation {
        schema: SCHEMA_VERSION,
        collector,
        collected_at: unix_time_millis(),
        process_pid,
        sync,
        profile: profile(object, player_name),
        raw,
    };
    let data = serde_json::to_value(observation)
        .map_err(|error| format!("could not encode inventory observation: {error}"))?;
    Ok(data)
}

fn extract_inventory(value: Value) -> Option<Value> {
    match value {
        Value::Object(mut object) => {
            if is_inventory_object(&object) {
                return Some(Value::Object(object));
            }
            if let Some(inventory) = object.remove("InventoryJSON")
                && let Some(found) = extract_inventory(inventory)
            {
                return Some(found);
            }
            object.into_values().find_map(extract_inventory)
        }
        Value::Array(values) => values.into_iter().find_map(extract_inventory),
        Value::String(encoded) if encoded.contains("LastInventorySync") => {
            serde_json::from_str(&encoded)
                .ok()
                .and_then(extract_inventory)
        }
        _ => None,
    }
}

fn is_inventory_object(object: &Map<String, Value>) -> bool {
    object.contains_key("LastInventorySync")
        && [
            "Suits",
            "LongGuns",
            "Pistols",
            "Melee",
            "SpaceSuits",
            "MiscItems",
            "XPInfo",
            "Recipes",
        ]
        .iter()
        .any(|key| object.contains_key(*key))
}

fn root_shape(value: &Value) -> String {
    match value {
        Value::Object(object) => {
            let mut keys: Vec<_> = object.keys().map(String::as_str).collect();
            keys.sort_unstable();
            keys.truncate(16);
            format!("root=object keys={}", keys.join(","))
        }
        Value::Array(values) => format!("root=array length={}", values.len()),
        Value::String(_) => "root=string".to_owned(),
        Value::Null => "root=null".to_owned(),
        Value::Bool(_) => "root=boolean".to_owned(),
        Value::Number(_) => "root=number".to_owned(),
    }
}

fn profile(object: &Map<String, Value>, player_name: Option<&str>) -> Profile {
    Profile {
        player_name: player_name.map(str::to_owned),
        player_level: integer(object, "PlayerLevel"),
        regular_credits: integer(object, "RegularCredits"),
        premium_credits: integer(object, "PremiumCredits"),
        premium_credits_free: integer(object, "PremiumCreditsFree"),
        fusion_points: integer(object, "FusionPoints"),
        trades_remaining: integer(object, "TradesRemaining"),
        daily_focus: integer(object, "DailyFocus"),
        focus_capacity: integer(object, "FocusCapacity"),
        last_region_played: text(object, "LastRegionPlayed"),
    }
}

fn integer(object: &Map<String, Value>, key: &str) -> Option<i64> {
    object.get(key).and_then(Value::as_i64)
}

fn text(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn value_key(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Object(object) => ["$oid", "oid", "$date", "$numberLong"]
            .iter()
            .find_map(|key| object.get(*key).map(value_key))
            .unwrap_or_else(|| serde_json::to_string(value).unwrap_or_default()),
        Value::Null => String::new(),
        _ => serde_json::to_string(value).unwrap_or_default(),
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

    const SAMPLE: &str = r#"{
        "LastInventorySync":{"$oid":"abcdef"},
        "PlayerLevel":18,
        "RegularCredits":12345,
        "Suits":[{"ItemType":"/Lotus/Powersuits/Excalibur","ItemId":{"$oid":"suit1"},"XP":9000}],
        "MiscItems":[{"ItemType":"/Lotus/Types/Items/MiscItems/ArgonCrystal","ItemCount":3}],
        "XPInfo":[{"ItemType":"/Lotus/Weapons/Tenno/Rifle/Braton","XP":450000}],
        "PendingRecipes":[{"ItemType":"/Lotus/Weapons/Tenno/Rifle/Braton","ItemId":{"$oid":"recipe1"}}],
        "UnknownFutureField":{"kept":true}
    }"#;

    #[test]
    fn parses_inventory_without_dropping_raw_fields() {
        let value = parse_observation(
            SAMPLE.as_bytes(),
            "native_http_queue",
            42,
            Some("TestTenno"),
        )
        .unwrap();
        assert_eq!(value["sync"]["$oid"], "abcdef");
        assert_eq!(value["schema"], 2);
        assert_eq!(value["collector"], "native_http_queue");
        assert_eq!(value["process_pid"], 42);
        assert_eq!(value["profile"]["player_name"], "TestTenno");
        assert_eq!(value["profile"]["player_level"], 18);
        assert!(value.get("index").is_none());
        assert_eq!(value["raw"]["Suits"][0]["XP"], 9000);
        assert_eq!(value["raw"]["MiscItems"][0]["ItemCount"], 3);
        assert_eq!(value["raw"]["XPInfo"][0]["XP"], 450000);
        assert_eq!(value["raw"]["UnknownFutureField"]["kept"], true);
    }

    #[test]
    fn unwraps_inventory_json_envelope() {
        let wrapped = serde_json::json!({"InventoryJSON": SAMPLE}).to_string();
        let value = parse_observation(wrapped.as_bytes(), "native_http_queue", 7, None).unwrap();
        assert_eq!(value["sync"]["$oid"], "abcdef");
        assert_eq!(value["process_pid"], 7);
    }

    #[test]
    fn extracts_nested_inventory_object() {
        let inventory: Value = serde_json::from_str(SAMPLE).unwrap();
        let wrapped = serde_json::json!({"response": {"data": inventory}}).to_string();
        let value = parse_observation(wrapped.as_bytes(), "native_http_buffer", 7, None).unwrap();
        assert_eq!(value["sync"]["$oid"], "abcdef");
        assert_eq!(value["raw"]["Suits"][0]["XP"], 9000);
    }

    #[test]
    fn extracts_nested_encoded_inventory() {
        let wrapped = serde_json::json!({"response": {"body": SAMPLE}}).to_string();
        let value = parse_observation(wrapped.as_bytes(), "native_http_buffer", 7, None).unwrap();
        assert_eq!(value["sync"]["$oid"], "abcdef");
        assert_eq!(value["raw"]["XPInfo"][0]["XP"], 450000);
    }

    #[test]
    fn rejects_marker_without_inventory_collections() {
        let error = parse_observation(
            br#"{"metadata":{"LastInventorySync":"not-an-inventory"}}"#,
            "native_http_buffer",
            7,
            None,
        )
        .unwrap_err();
        assert!(error.contains("no complete inventory object"));
    }

    #[test]
    fn deduplicates_payloads_not_inventory_sync_markers() {
        let changed = SAMPLE.replace("\"ItemCount\":3", "\"ItemCount\":4");
        let mut seen = HashSet::new();
        let mut player_name = None;
        let prefix = Path::new("/nonexistent");
        let (sender, receiver) = mpsc::channel();
        assert_eq!(
            publish_payload(
                SAMPLE.as_bytes(),
                "test",
                42,
                prefix,
                &mut player_name,
                &mut seen,
                &sender,
            ),
            Ok(true)
        );
        assert_eq!(
            publish_payload(
                SAMPLE.as_bytes(),
                "test",
                42,
                prefix,
                &mut player_name,
                &mut seen,
                &sender,
            ),
            Ok(false)
        );
        assert_eq!(
            publish_payload(
                changed.as_bytes(),
                "test",
                42,
                prefix,
                &mut player_name,
                &mut seen,
                &sender,
            ),
            Ok(true)
        );

        let Event::Inventory { data: first, .. } = receiver.recv().unwrap();
        let Event::Inventory { data: second, .. } = receiver.recv().unwrap();
        assert_eq!(first["raw"]["MiscItems"][0]["ItemCount"], 3);
        assert_eq!(second["raw"]["MiscItems"][0]["ItemCount"], 4);
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn fingerprints_inventory_independent_of_response_envelope() {
        let nested = serde_json::json!({"response": {"body": SAMPLE}}).to_string();
        let mut direct_seen = HashSet::new();
        let mut nested_seen = HashSet::new();
        let mut player_name = None;
        let prefix = Path::new("/nonexistent");
        let (_, direct_fingerprint) = decode_new_payload(
            SAMPLE.as_bytes(),
            42,
            prefix,
            &mut player_name,
            &mut direct_seen,
        )
        .unwrap()
        .unwrap();
        let (_, nested_fingerprint) = decode_new_payload(
            nested.as_bytes(),
            42,
            prefix,
            &mut player_name,
            &mut nested_seen,
        )
        .unwrap()
        .unwrap();
        assert_eq!(direct_fingerprint, nested_fingerprint);
    }

    #[test]
    fn rejects_payload_without_sync_marker() {
        assert!(
            parse_observation(br#"{"MiscItems":[]}"#, "native_http_queue", 1, None)
                .unwrap_err()
                .contains("no complete inventory object")
        );
    }

    #[test]
    fn reads_player_name_from_proton_log() {
        let prefix = std::env::temp_dir().join(format!(
            "wfcompanion-inventory-{}-{}",
            std::process::id(),
            unix_time_millis()
        ));
        let log = prefix.join("drive_c/users/steamuser/AppData/Local/Warframe/EE.log");
        fs::create_dir_all(log.parent().unwrap()).unwrap();
        fs::write(&log, "0.0 Sys [Info]: Logged in TestTenno (abcdef)\n").unwrap();
        assert_eq!(player_name_from_log(&prefix).as_deref(), Some("TestTenno"));
        fs::remove_dir_all(prefix).unwrap();
    }
}
