use std::collections::HashSet;
use std::collections::hash_map::DefaultHasher;
use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::{self, BufRead, BufReader};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::{Map, Value};

use crate::debug_output::Runtime;

const MAX_PAYLOAD_SIZE: usize = 0x4e2000;
const SCAN_CHUNK_SIZE: usize = 1024 * 1024;
const SCAN_INTERVAL: Duration = Duration::from_millis(25);
const HTTP_QUEUE_PATTERN: &[u8] = &[
    0x48, 0x00, 0x00, 0x48, 0x8b, 0x0d, 0x00, 0x00, 0x00, 0x00, 0x48, 0x85, 0x00, 0x74, 0x00, 0x48,
    0x8b, 0xd3, 0xe8,
];
const HTTP_QUEUE_MASK: &[u8] = &[
    0xff, 0x00, 0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0xff, 0x00, 0xff,
    0xff, 0xff, 0xff,
];
const INVENTORY_MARKER: &[u8] = b"LastInventorySync";
const SCHEMA_VERSION: u32 = 1;

const EQUIPMENT_COLLECTIONS: &[&str] = &[
    "Suits",
    "LongGuns",
    "Pistols",
    "Melee",
    "Ships",
    "Scoops",
    "Sentinels",
    "KubrowPets",
    "SpaceSuits",
    "SpaceMelee",
    "SpaceGuns",
    "OperatorAmps",
    "Hoverboards",
    "MoaPets",
    "DataKnives",
    "CrewShips",
    "CrewShipSalvagedWeapons",
    "CrewShipWeapons",
    "MechSuits",
    "Robotics",
];

const STACK_COLLECTIONS: &[&str] = &[
    "RawUpgrades",
    "FlavourItems",
    "MiscItems",
    "Recipes",
    "Upgrades",
    "Consumables",
    "LevelKeys",
    "FusionTreasures",
    "SpecialItems",
    "CrewShipAmmo",
];

#[derive(Debug)]
pub(crate) enum Event {
    Inventory {
        game_pid: u32,
        collector: &'static str,
        process_pid: u32,
        sync_key: String,
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
    index: InventoryIndex,
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

#[derive(Debug, Default, Serialize)]
struct InventoryIndex {
    equipment: Vec<IndexedItem>,
    stacks: Vec<IndexedItem>,
    mastery: Vec<MasteryRecord>,
    pending_recipes: Vec<PendingRecipe>,
    missions: Vec<Value>,
    player_skills: Value,
}

#[derive(Debug, Serialize)]
struct IndexedItem {
    collection: String,
    item_type: String,
    instance_id: Option<String>,
    count: i64,
    xp: Option<i64>,
    item_name: Option<String>,
}

#[derive(Debug, Serialize)]
struct MasteryRecord {
    item_type: String,
    xp: i64,
}

#[derive(Debug, Serialize)]
struct PendingRecipe {
    item_type: String,
    instance_id: Option<String>,
    completion_date: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ExecutableRegion {
    start: u64,
    end: u64,
}

fn start_native(
    game_pid: u32,
    prefix: PathBuf,
    events: mpsc::Sender<Event>,
) -> Result<(Arc<AtomicBool>, JoinHandle<()>), String> {
    let mem = File::open(format!("/proc/{game_pid}/mem"))
        .map_err(|error| format!("could not open Warframe memory: {error}"))?;
    let queue_global = resolve_http_queue(&mem, game_pid)?;
    let stopping = Arc::new(AtomicBool::new(false));
    let worker_stopping = Arc::clone(&stopping);
    let worker = thread::spawn(move || {
        scan_native(game_pid, mem, queue_global, prefix, worker_stopping, events)
    });
    Ok((stopping, worker))
}

fn scan_native(
    game_pid: u32,
    mem: File,
    queue_global: u64,
    prefix: PathBuf,
    stopping: Arc<AtomicBool>,
    events: mpsc::Sender<Event>,
) {
    let mut last_sync: Option<String> = None;
    let mut player_name = player_name_from_log(&prefix);
    let mut seen_payloads = HashSet::new();
    crate::incident::info(
        "inventory.native_queue_ready",
        format!("game_pid={game_pid} global=0x{queue_global:x}"),
    );
    while !stopping.load(Ordering::Relaxed) {
        if let Ok(payloads) = retained_responses(&mem, queue_global) {
            for payload in payloads {
                if !payload
                    .windows(INVENTORY_MARKER.len())
                    .any(|window| window == INVENTORY_MARKER)
                {
                    continue;
                }
                let mut hasher = DefaultHasher::new();
                payload.hash(&mut hasher);
                if !seen_payloads.insert(hasher.finish()) {
                    continue;
                }
                if player_name.is_none() {
                    player_name = player_name_from_log(&prefix);
                }
                if let Ok((sync_key, data)) = parse_observation(
                    &payload,
                    "native_http_buffer",
                    game_pid,
                    player_name.as_deref(),
                ) && last_sync.as_ref() != Some(&sync_key)
                {
                    last_sync = Some(sync_key.clone());
                    if events
                        .send(Event::Inventory {
                            game_pid,
                            collector: "native_http_buffer",
                            process_pid: game_pid,
                            sync_key,
                            data,
                        })
                        .is_err()
                    {
                        return;
                    }
                }
            }
        }
        wait_for_scan(&stopping);
    }
}

fn resolve_http_queue(mem: &File, game_pid: u32) -> Result<u64, String> {
    let region = executable_region(game_pid)?;
    let mut offset = region.start;
    let mut tail = Vec::new();
    let mut chunk = vec![0_u8; SCAN_CHUNK_SIZE];
    while offset < region.end {
        let wanted = usize::try_from((region.end - offset).min(SCAN_CHUNK_SIZE as u64)).unwrap();
        let read = mem
            .read_at(&mut chunk[..wanted], offset)
            .map_err(|error| format!("could not scan Warframe executable: {error}"))?;
        if read == 0 {
            break;
        }
        let mut searchable = Vec::with_capacity(tail.len() + read);
        searchable.extend_from_slice(&tail);
        searchable.extend_from_slice(&chunk[..read]);
        if let Some(index) = find_masked(&searchable, HTTP_QUEUE_PATTERN, HTTP_QUEUE_MASK) {
            let anchor = offset.saturating_sub(tail.len() as u64) + index as u64;
            let displacement = i32::from_le_bytes(
                searchable[index + 6..index + 10]
                    .try_into()
                    .expect("pattern includes displacement"),
            );
            return Ok((anchor + 10).wrapping_add_signed(i64::from(displacement)));
        }
        let overlap = HTTP_QUEUE_PATTERN.len() - 1;
        tail.clear();
        tail.extend_from_slice(&chunk[read.saturating_sub(overlap)..read]);
        offset += read as u64;
    }
    Err("Warframe HTTP queue signature not found".to_owned())
}

fn retained_responses(mem: &File, queue_global: u64) -> io::Result<Vec<Vec<u8>>> {
    let manager = read_u64(mem, queue_global)?;
    if manager == 0 {
        return Ok(Vec::new());
    }
    let table = read_u64(mem, manager + 0x98)?;
    let capacity = read_u64(mem, manager + 0xa0)?;
    if table == 0 || capacity == 0 || !capacity.is_power_of_two() || capacity > 65_536 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid Warframe HTTP queue",
        ));
    }

    let mut payloads = Vec::new();
    let mut seen_items = HashSet::new();
    for bucket_index in 0..capacity {
        let bucket = read_u64(mem, table + bucket_index * 8)?;
        if bucket == 0 {
            continue;
        }
        for slot in 0..2 {
            let item = read_u64(mem, bucket + slot * 8)?;
            if item == 0 || !seen_items.insert(item) {
                continue;
            }
            if let Ok(payload) = read_game_string(mem, item + 0x50) {
                payloads.push(payload);
            }
        }
    }
    Ok(payloads)
}

fn executable_region(game_pid: u32) -> Result<ExecutableRegion, String> {
    let maps = fs::read_to_string(format!("/proc/{game_pid}/maps"))
        .map_err(|error| format!("could not read Warframe memory map: {error}"))?;
    let mut image_start = None;
    for line in maps.lines() {
        let mut fields = line.split_whitespace();
        let range = fields.next().unwrap_or_default();
        let permissions = fields.next().unwrap_or_default();
        let path = fields.nth(3).unwrap_or_default();
        let Some((start, end)) = parse_range(range) else {
            continue;
        };
        if path.ends_with("/Warframe.x64.exe") {
            image_start = Some(start);
        }
        if permissions.contains('x')
            && image_start.is_some_and(|image| start >= image && start - image < 0x4000_0000)
        {
            return Ok(ExecutableRegion { start, end });
        }
    }
    Err("Warframe executable mapping not found".to_owned())
}

fn parse_range(range: &str) -> Option<(u64, u64)> {
    let (start, end) = range.split_once('-')?;
    Some((
        u64::from_str_radix(start, 16).ok()?,
        u64::from_str_radix(end, 16).ok()?,
    ))
}

fn read_game_string(mem: &File, address: u64) -> io::Result<Vec<u8>> {
    let mut descriptor = [0_u8; 16];
    read_exact_at(mem, address, &mut descriptor)?;
    let tag = descriptor[15];
    let (data, length) = if tag == 0xff {
        (
            u64::from_le_bytes(descriptor[..8].try_into().unwrap()),
            (u32::from_le_bytes(descriptor[8..12].try_into().unwrap()) & 0x0fff_ffff) as usize,
        )
    } else {
        (address, 15_usize.saturating_sub(tag as usize))
    };
    if length == 0 || length > MAX_PAYLOAD_SIZE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid Warframe string length",
        ));
    }
    let mut bytes = vec![0_u8; length];
    read_exact_at(mem, data, &mut bytes)?;
    Ok(bytes)
}

fn read_exact_at(mem: &File, address: u64, buffer: &mut [u8]) -> io::Result<()> {
    let mut read = 0;
    while read < buffer.len() {
        let count = mem.read_at(&mut buffer[read..], address + read as u64)?;
        if count == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "short process-memory read",
            ));
        }
        read += count;
    }
    Ok(())
}

fn read_u64(mem: &File, address: u64) -> io::Result<u64> {
    let mut bytes = [0_u8; 8];
    read_exact_at(mem, address, &mut bytes)?;
    Ok(u64::from_le_bytes(bytes))
}

fn find_masked(haystack: &[u8], pattern: &[u8], mask: &[u8]) -> Option<usize> {
    haystack.windows(pattern.len()).position(|window| {
        window
            .iter()
            .zip(pattern)
            .zip(mask)
            .all(|((&byte, &expected), &significant)| byte & significant == expected & significant)
    })
}

fn wait_for_scan(stopping: &AtomicBool) {
    for _ in 0..20 {
        if stopping.load(Ordering::Relaxed) {
            return;
        }
        thread::sleep(SCAN_INTERVAL / 20);
    }
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
) -> Result<(String, Value), String> {
    let value: Value = serde_json::from_slice(payload)
        .map_err(|error| format!("inventory payload is not valid JSON: {error}"))?;
    let raw = unwrap_inventory(value)?;
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
        index: build_index(object),
        raw,
    };
    let data = serde_json::to_value(observation)
        .map_err(|error| format!("could not encode inventory observation: {error}"))?;
    Ok((sync_key, data))
}

fn unwrap_inventory(value: Value) -> Result<Value, String> {
    let Some(encoded) = value
        .as_object()
        .and_then(|object| object.get("InventoryJSON"))
        .and_then(Value::as_str)
    else {
        return Ok(value);
    };
    serde_json::from_str(encoded)
        .map_err(|error| format!("InventoryJSON is not valid JSON: {error}"))
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

fn build_index(object: &Map<String, Value>) -> InventoryIndex {
    InventoryIndex {
        equipment: index_items(object, EQUIPMENT_COLLECTIONS, 1),
        stacks: index_items(object, STACK_COLLECTIONS, 0),
        mastery: object
            .get("XPInfo")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|item| {
                Some(MasteryRecord {
                    item_type: field_text(item, "ItemType")?,
                    xp: field_integer(item, "XP").unwrap_or(0),
                })
            })
            .collect(),
        pending_recipes: object
            .get("PendingRecipes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|item| {
                Some(PendingRecipe {
                    item_type: field_text(item, "ItemType")?,
                    instance_id: item
                        .get("ItemId")
                        .map(value_key)
                        .filter(|id| !id.is_empty()),
                    completion_date: item.get("CompletionDate").cloned().unwrap_or(Value::Null),
                })
            })
            .collect(),
        missions: object
            .get("Missions")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        player_skills: object.get("PlayerSkills").cloned().unwrap_or(Value::Null),
    }
}

fn index_items(
    object: &Map<String, Value>,
    collections: &[&str],
    default_count: i64,
) -> Vec<IndexedItem> {
    let mut indexed = Vec::new();
    for collection in collections {
        let Some(items) = object.get(*collection).and_then(Value::as_array) else {
            continue;
        };
        for item in items {
            let Some(item_type) = field_text(item, "ItemType") else {
                continue;
            };
            indexed.push(IndexedItem {
                collection: (*collection).to_owned(),
                item_type,
                instance_id: item
                    .get("ItemId")
                    .map(value_key)
                    .filter(|id| !id.is_empty()),
                count: field_integer(item, "ItemCount").unwrap_or(default_count),
                xp: field_integer(item, "XP"),
                item_name: field_text(item, "ItemName"),
            });
        }
    }
    indexed
}

fn integer(object: &Map<String, Value>, key: &str) -> Option<i64> {
    object.get(key).and_then(Value::as_i64)
}

fn text(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn field_integer(value: &Value, key: &str) -> Option<i64> {
    value.get(key).and_then(Value::as_i64)
}

fn field_text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
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
    fn parses_and_indexes_inventory_without_dropping_raw_fields() {
        let (sync, value) = parse_observation(
            SAMPLE.as_bytes(),
            "native_http_queue",
            42,
            Some("TestTenno"),
        )
        .unwrap();
        assert_eq!(sync, "abcdef");
        assert_eq!(value["schema"], 1);
        assert_eq!(value["collector"], "native_http_queue");
        assert_eq!(value["process_pid"], 42);
        assert_eq!(value["profile"]["player_name"], "TestTenno");
        assert_eq!(value["profile"]["player_level"], 18);
        assert_eq!(value["index"]["equipment"][0]["count"], 1);
        assert_eq!(value["index"]["stacks"][0]["count"], 3);
        assert_eq!(value["index"]["mastery"][0]["xp"], 450000);
        assert_eq!(value["raw"]["UnknownFutureField"]["kept"], true);
    }

    #[test]
    fn unwraps_inventory_json_envelope() {
        let wrapped = serde_json::json!({"InventoryJSON": SAMPLE}).to_string();
        let (sync, value) =
            parse_observation(wrapped.as_bytes(), "native_http_queue", 7, None).unwrap();
        assert_eq!(sync, "abcdef");
        assert_eq!(value["process_pid"], 7);
    }

    #[test]
    fn rejects_payload_without_sync_marker() {
        assert!(
            parse_observation(br#"{"MiscItems":[]}"#, "native_http_queue", 1, None)
                .unwrap_err()
                .contains("LastInventorySync")
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

    #[test]
    fn finds_masked_http_queue_signature() {
        let mut bytes = vec![0x90; 32];
        bytes[5..5 + HTTP_QUEUE_PATTERN.len()].copy_from_slice(HTTP_QUEUE_PATTERN);
        bytes[6] = 0xaa;
        bytes[7] = 0xbb;
        bytes[17] = 0x7f;
        assert_eq!(
            find_masked(&bytes, HTTP_QUEUE_PATTERN, HTTP_QUEUE_MASK),
            Some(5)
        );
    }

    #[test]
    fn parses_proc_map_range() {
        assert_eq!(
            parse_range("140001000-142027000"),
            Some((0x140001000, 0x142027000))
        );
        assert_eq!(parse_range("broken"), None);
    }
}
