use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use super::{Movie, ScanMetrics, Snapshot, TextScan, scan_snapshot, text};
use crate::game_observer::memory::{ProcessMemory, Region};

const BLOCK_SIZE: usize = 512;
const MAX_DEPTH: u8 = 4;
const MAX_BLOCKS: usize = 65_536;
const MAX_BLOCKS_PER_ROOT: usize = 1024;
const MAX_CHILDREN: usize = 48;

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
struct Report {
    schema: u8,
    captured_at_unix_ms: u128,
    duration_ms: u128,
    snapshot: Snapshot,
    scan: ScanMetrics,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<TextScan>,
    memory: MemoryManifest,
}

#[derive(Debug, Serialize)]
struct MemoryManifest {
    file: &'static str,
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

#[derive(Debug, Serialize)]
struct MovieRoot {
    path: String,
    record_address: u64,
    path_address: u64,
}

#[derive(Debug, Serialize)]
struct MemoryBlock {
    address: u64,
    length: usize,
    file_offset: usize,
    depth: u8,
    permissions: String,
    region: String,
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
        schema: 2,
        captured_at_unix_ms: unix_time_millis(),
        duration_ms,
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
            file: "scaleform-memory.bin",
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
}
