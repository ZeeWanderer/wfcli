use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::{Movie, ScanMetrics, Snapshot, TextScan, relic, scan_snapshot, text};
use crate::game_observer::adapter::{self, AdapterSupport};
use crate::game_observer::memory::{CaptureBlock, ProcessMemory, Region};
use crate::game_observer::{ProcessIdentity, identify_process};

const BLOCK_SIZE: usize = 512;
const MAX_DEPTH: u8 = 6;
const MAX_BLOCKS: usize = 65_536;
const MAX_BLOCKS_PER_ROOT: usize = 1024;
const MAX_CHILDREN: usize = 48;
const FLASH_RECORD_OFFSET: u64 = 0xc0;
const MEMORY_FILE: &str = "scaleform-memory.bin";
const MAX_CAPTURE_BYTES: usize = MAX_BLOCKS * BLOCK_SIZE;

#[derive(Clone, Debug, Serialize)]
pub struct EvidenceSummary {
    pub report: PathBuf,
    pub memory: PathBuf,
    pub maps: PathBuf,
    pub movies: usize,
    pub blocks: usize,
    pub bytes: usize,
    pub truncated: bool,
    pub duration_ms: u128,
}

#[derive(Debug, Serialize)]
pub struct EvidenceReplay {
    pub report: PathBuf,
    pub schema: u8,
    pub captured_at_unix_ms: u128,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identity: Option<ProcessIdentity>,
    pub adapter: AdapterSupport,
    pub snapshot: Snapshot,
    pub recorded_snapshot: Snapshot,
    pub memory: ReplayMemorySummary,
    pub selection: ReplayProbe<super::RelicSelection>,
    pub rewards: ReplayProbe<super::RelicRewardText>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ReplayMemorySummary {
    pub blocks: usize,
    pub bytes: usize,
    pub truncated: bool,
}

pub(crate) struct LoadedEvidence {
    pub(crate) report: PathBuf,
    pub(crate) schema: u8,
    pub(crate) captured_at_unix_ms: u128,
    pub(crate) identity: Option<ProcessIdentity>,
    pub(crate) snapshot: Snapshot,
    pub(crate) memory_summary: ReplayMemorySummary,
    pub(crate) memory: ProcessMemory,
}

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ReplayProbe<T> {
    Available { value: T },
    Unavailable { reason: String },
}

#[derive(Debug, Serialize)]
struct Report {
    schema: u8,
    captured_at_unix_ms: u128,
    duration_ms: u128,
    identity: ProcessIdentity,
    snapshot: Snapshot,
    scan: ScanMetrics,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<TextScan>,
    memory: MemoryManifest,
}

#[derive(Debug, Deserialize, Serialize)]
struct MemoryManifest {
    file: String,
    block_size: usize,
    max_depth: u8,
    max_blocks: usize,
    max_blocks_per_root: usize,
    max_children_per_block: usize,
    bytes: usize,
    truncated: bool,
    roots: Vec<MovieRoot>,
    blocks: Vec<MemoryBlock>,
}

#[derive(Debug, Deserialize, Serialize)]
struct MovieRoot {
    path: String,
    record_address: u64,
    path_address: u64,
}

#[derive(Debug, Deserialize, Serialize)]
struct MemoryBlock {
    address: u64,
    length: usize,
    file_offset: usize,
    depth: u8,
    permissions: String,
    region: String,
}

#[derive(Debug, Deserialize)]
struct StoredReport {
    schema: u8,
    captured_at_unix_ms: u128,
    #[serde(default)]
    identity: Option<ProcessIdentity>,
    snapshot: Snapshot,
    memory: MemoryManifest,
}

pub(super) fn capture(
    pid: u32,
    directory: &Path,
    terms: &[String],
) -> Result<EvidenceSummary, String> {
    let started = Instant::now();
    fs::create_dir_all(directory).map_err(|error| {
        format!(
            "could not create UI evidence directory {}: {error}",
            directory.display()
        )
    })?;
    let memory = ProcessMemory::open(pid)?;
    let identity = identify_process(pid)?;
    let maps_path = directory.join("maps.txt");
    fs::write(&maps_path, memory.maps())
        .map_err(|error| format!("could not write {}: {error}", maps_path.display()))?;
    let text = (!terms.is_empty())
        .then(|| text::scan(&memory, terms))
        .transpose()?;
    let scan = scan_snapshot(&memory)?;
    let (mut manifest, bytes) = capture_graph(&memory, &scan.snapshot.movies, text.as_ref());
    let memory_path = directory.join("scaleform-memory.bin");
    fs::write(&memory_path, &bytes)
        .map_err(|error| format!("could not write {}: {error}", memory_path.display()))?;
    manifest.bytes = bytes.len();
    let duration_ms = started.elapsed().as_millis();
    let report_path = directory.join("ui.json");
    let report = Report {
        schema: 3,
        captured_at_unix_ms: unix_time_millis(),
        duration_ms,
        identity,
        snapshot: scan.snapshot,
        scan: scan.metrics,
        text,
        memory: manifest,
    };
    let encoded = serde_json::to_vec_pretty(&report)
        .map_err(|error| format!("could not encode UI evidence: {error}"))?;
    fs::write(&report_path, encoded)
        .map_err(|error| format!("could not write {}: {error}", report_path.display()))?;

    Ok(EvidenceSummary {
        report: report_path,
        memory: memory_path,
        maps: maps_path,
        movies: report.snapshot.movies.len(),
        blocks: report.memory.blocks.len(),
        bytes: report.memory.bytes,
        truncated: report.memory.truncated,
        duration_ms,
    })
}

pub(crate) fn load_evidence(path: &Path) -> Result<LoadedEvidence, String> {
    let report_path = if path.is_dir() {
        path.join("ui.json")
    } else {
        path.to_owned()
    };
    let directory = report_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let report_bytes = fs::read(&report_path)
        .map_err(|error| format!("could not read {}: {error}", report_path.display()))?;
    let report: StoredReport = serde_json::from_slice(&report_bytes)
        .map_err(|error| format!("could not parse {}: {error}", report_path.display()))?;
    if !(2..=3).contains(&report.schema) {
        return Err(format!("unsupported UI evidence schema {}", report.schema));
    }
    if report.memory.file != MEMORY_FILE {
        return Err(format!(
            "unsupported UI evidence memory file: {}",
            report.memory.file
        ));
    }
    if report.memory.blocks.len() > MAX_BLOCKS || report.memory.bytes > MAX_CAPTURE_BYTES {
        return Err("UI evidence exceeds capture limits".to_owned());
    }
    let maps_path = directory.join("maps.txt");
    let maps = fs::read_to_string(&maps_path)
        .map_err(|error| format!("could not read {}: {error}", maps_path.display()))?;
    let memory_path = directory.join(&report.memory.file);
    let bytes = fs::read(&memory_path)
        .map_err(|error| format!("could not read {}: {error}", memory_path.display()))?;
    if bytes.len() != report.memory.bytes {
        return Err(format!(
            "capture memory size mismatch: manifest={} file={}",
            report.memory.bytes,
            bytes.len()
        ));
    }
    let blocks = report
        .memory
        .blocks
        .iter()
        .map(|block| CaptureBlock {
            address: block.address,
            length: block.length,
            file_offset: block.file_offset,
        })
        .collect();
    let memory = ProcessMemory::from_capture(report.snapshot.pid, maps, blocks, bytes)?;
    Ok(LoadedEvidence {
        report: report_path,
        schema: report.schema,
        captured_at_unix_ms: report.captured_at_unix_ms,
        identity: report.identity,
        snapshot: report.snapshot,
        memory_summary: ReplayMemorySummary {
            blocks: report.memory.blocks.len(),
            bytes: report.memory.bytes,
            truncated: report.memory.truncated,
        },
        memory,
    })
}

pub fn replay_evidence(path: &Path) -> Result<EvidenceReplay, String> {
    let evidence = load_evidence(path)?;
    let snapshot = super::scan_memory(&evidence.memory)?.snapshot;
    let adapter = adapter::support(evidence.identity.as_ref());
    let layout = evidence
        .identity
        .as_ref()
        .and_then(|identity| adapter::resolve(&identity.executable.sha256))
        .map(|adapter| adapter.scaleform);
    let (selection, rewards) = match layout {
        Some(layout) => (
            replay_probe(relic::selection_from_snapshot(
                &evidence.memory,
                layout,
                &snapshot,
            )),
            replay_probe(relic::rewards_from_snapshot(
                &evidence.memory,
                layout,
                &snapshot,
            )),
        ),
        None => {
            let reason = adapter::unsupported_reason(evidence.identity.as_ref())
                .unwrap_or_else(|| "capture adapter unavailable".to_owned());
            (
                ReplayProbe::Unavailable {
                    reason: reason.clone(),
                },
                ReplayProbe::Unavailable { reason },
            )
        }
    };
    Ok(EvidenceReplay {
        report: evidence.report,
        schema: evidence.schema,
        captured_at_unix_ms: evidence.captured_at_unix_ms,
        identity: evidence.identity,
        adapter,
        snapshot,
        recorded_snapshot: evidence.snapshot,
        memory: evidence.memory_summary,
        selection,
        rewards,
    })
}

fn replay_probe<T>(result: Result<T, String>) -> ReplayProbe<T> {
    match result {
        Ok(value) => ReplayProbe::Available { value },
        Err(reason) => ReplayProbe::Unavailable { reason },
    }
}

fn capture_graph(
    memory: &ProcessMemory,
    movies: &[Movie],
    text: Option<&TextScan>,
) -> (MemoryManifest, Vec<u8>) {
    let roots = movies
        .iter()
        .map(|movie| MovieRoot {
            path: movie.path.clone(),
            record_address: movie.record_address,
            path_address: movie.path_address,
        })
        .collect::<Vec<_>>();
    let mut root_addresses = movies
        .iter()
        .map(|movie| movie.record_address)
        .collect::<Vec<_>>();
    root_addresses.extend(
        movies
            .iter()
            .filter_map(|movie| movie.record_address.checked_sub(FLASH_RECORD_OFFSET)),
    );
    if let Some(text) = text {
        for found in text.terms.iter().flat_map(|term| &term.matches) {
            root_addresses.push(found.address);
            root_addresses.extend(
                found
                    .references
                    .iter()
                    .filter_map(|reference| reference.display_object_candidate),
            );
        }
    }
    let mut bytes = Vec::new();
    let mut blocks = Vec::new();
    let mut captured = HashMap::<u64, Vec<u8>>::new();
    let mut truncated = false;
    'roots: for root in root_addresses {
        let mut stack = vec![(block_address(root), 0_u8)];
        let mut visited = BTreeSet::new();
        while let Some((address, depth)) = stack.pop() {
            if !visited.insert(address) {
                continue;
            }
            if visited.len() > MAX_BLOCKS_PER_ROOT {
                truncated = true;
                continue 'roots;
            }
            let block = if let Some(block) = captured.get(&address) {
                block.clone()
            } else {
                if blocks.len() >= MAX_BLOCKS {
                    truncated = true;
                    break 'roots;
                }
                let Some(region) = graph_region(memory, address) else {
                    continue;
                };
                let wanted =
                    usize::try_from((region.end - address).min(BLOCK_SIZE as u64)).unwrap();
                let mut block = vec![0_u8; wanted];
                let Ok(read) = memory.read_at(&mut block, address) else {
                    continue;
                };
                if read == 0 {
                    continue;
                }
                block.truncate(read);
                let file_offset = bytes.len();
                bytes.extend_from_slice(&block);
                blocks.push(MemoryBlock {
                    address,
                    length: read,
                    file_offset,
                    depth,
                    permissions: region.permissions.clone(),
                    region: region.path.clone(),
                });
                captured.insert(address, block.clone());
                block
            };
            if depth >= MAX_DEPTH {
                continue;
            }
            let pointers = pointer_targets(&block, memory.regions());
            if pointers.len() > MAX_CHILDREN {
                truncated = true;
            }
            for pointer in pointers.into_iter().take(MAX_CHILDREN).rev() {
                stack.push((block_address(pointer), depth + 1));
            }
        }
    }

    (
        MemoryManifest {
            file: MEMORY_FILE.to_owned(),
            block_size: BLOCK_SIZE,
            max_depth: MAX_DEPTH,
            max_blocks: MAX_BLOCKS,
            max_blocks_per_root: MAX_BLOCKS_PER_ROOT,
            max_children_per_block: MAX_CHILDREN,
            bytes: 0,
            truncated,
            roots,
            blocks,
        },
        bytes,
    )
}

fn block_address(pointer: u64) -> u64 {
    pointer & !((BLOCK_SIZE as u64) - 1)
}

fn graph_region(memory: &ProcessMemory, address: u64) -> Option<&Region> {
    memory
        .regions()
        .iter()
        .find(|region| region.supports_ui_graph() && region.contains(address))
}

fn pointer_targets(bytes: &[u8], regions: &[Region]) -> Vec<u64> {
    let mut pointers = BTreeSet::new();
    for chunk in bytes.chunks_exact(8) {
        let pointer = u64::from_le_bytes(chunk.try_into().unwrap());
        if pointer & 7 != 0 {
            continue;
        }
        if regions
            .iter()
            .any(|region| region.supports_ui_graph() && region.contains(pointer))
        {
            pointers.insert(pointer);
        }
    }
    pointers.into_iter().collect()
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
    use std::sync::atomic::{AtomicU64, Ordering};

    #[test]
    fn follows_only_aligned_private_writable_pointers() {
        let regions = vec![Region {
            start: 0x1000,
            end: 0x2000,
            permissions: "rw-p".to_owned(),
            path: "[heap]".to_owned(),
        }];
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&0x1800_u64.to_le_bytes());
        bytes.extend_from_slice(&0x1801_u64.to_le_bytes());
        bytes.extend_from_slice(&0x3000_u64.to_le_bytes());
        assert_eq!(pointer_targets(&bytes, &regions), vec![0x1800]);
    }

    #[test]
    fn loads_legacy_capture_for_offline_inspection() {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "wfinspect-evidence-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&directory).unwrap();
        fs::write(
            directory.join("maps.txt"),
            "140000000-141000000 r-xp 0 00:00 1 /game/Warframe.x64.exe\n\
             200000000-200001000 rw-p 0 00:00 0 [heap]\n",
        )
        .unwrap();
        fs::write(directory.join("scaleform-memory.bin"), b"abcdefgh").unwrap();
        let report = serde_json::json!({
            "schema": 2,
            "captured_at_unix_ms": 123,
            "snapshot": {"pid": 42, "movies": []},
            "memory": {
                "file": "scaleform-memory.bin",
                "block_size": 512,
                "max_depth": 4,
                "max_blocks": 16,
                "max_blocks_per_root": 4,
                "max_children_per_block": 4,
                "bytes": 8,
                "truncated": false,
                "roots": [],
                "blocks": [{
                    "address": 0x200000000_u64,
                    "length": 8,
                    "file_offset": 0,
                    "depth": 0,
                    "permissions": "rw-p",
                    "region": "[heap]"
                }]
            }
        });
        fs::write(
            directory.join("ui.json"),
            serde_json::to_vec_pretty(&report).unwrap(),
        )
        .unwrap();

        let replay = replay_evidence(&directory).unwrap();
        assert_eq!(replay.schema, 2);
        assert_eq!(replay.memory.blocks, 1);
        assert!(matches!(replay.selection, ReplayProbe::Unavailable { .. }));
        assert!(matches!(replay.rewards, ReplayProbe::Unavailable { .. }));

        let mut invalid = report;
        invalid["memory"]["file"] = serde_json::json!("../outside.bin");
        fs::write(
            directory.join("ui.json"),
            serde_json::to_vec_pretty(&invalid).unwrap(),
        )
        .unwrap();
        assert!(replay_evidence(&directory).is_err());
        fs::remove_dir_all(directory).unwrap();
    }
}
