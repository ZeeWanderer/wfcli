use std::collections::{HashMap, HashSet, VecDeque};
use std::time::Instant;

use serde::Serialize;

use crate::game_observer::memory::{ProcessMemory, Region};

const BLOCK_SIZE: usize = 512;
const MAX_TRACE_DEPTH: u8 = 16;
const MAX_TRACE_BLOCKS: usize = 262_144;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct PointerHop {
    pub block_address: u64,
    pub pointer_address: u64,
    pub target_address: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct PointerPath {
    pub root: u64,
    pub target_start: u64,
    pub target_end: u64,
    pub hops: Vec<PointerHop>,
    pub blocks: usize,
    pub truncated: bool,
    pub total_ms: u128,
}

pub(super) fn trace(
    memory: &ProcessMemory,
    root: u64,
    target_start: u64,
    target_end: u64,
) -> Result<PointerPath, String> {
    if target_start >= target_end {
        return Err("pointer target range must not be empty".to_owned());
    }

    let started = Instant::now();
    let regions = GraphRegions::new(memory.regions());
    let root_block = root;
    let mut queue = VecDeque::from([(root_block, 0_u8)]);
    let mut discovered = HashSet::from([root_block]);
    let mut parents = HashMap::<u64, PointerHop>::new();
    let mut blocks = 0;

    while let Some((address, depth)) = queue.pop_front() {
        if blocks >= MAX_TRACE_BLOCKS {
            break;
        }
        let Some(region) = regions.find(address) else {
            continue;
        };
        let wanted = usize::try_from((region.end - address).min(BLOCK_SIZE as u64)).unwrap();
        let mut bytes = vec![0_u8; wanted];
        let Ok(read) = memory.read_at(&mut bytes, address) else {
            continue;
        };
        if read == 0 {
            continue;
        }
        bytes.truncate(read);
        blocks += 1;

        for (pointer_address, target_address) in pointer_edges(address, &bytes, &regions) {
            let hop = PointerHop {
                block_address: address,
                pointer_address,
                target_address,
            };
            if (target_start..target_end).contains(&target_address) {
                let mut hops = vec![hop];
                let mut child = address;
                while child != root_block {
                    let parent = parents
                        .get(&child)
                        .expect("every discovered non-root block has a parent")
                        .clone();
                    child = parent.block_address;
                    hops.push(parent);
                }
                hops.reverse();
                return Ok(PointerPath {
                    root,
                    target_start,
                    target_end,
                    hops,
                    blocks,
                    truncated: false,
                    total_ms: started.elapsed().as_millis(),
                });
            }
            if depth >= MAX_TRACE_DEPTH {
                continue;
            }
            let child = target_address;
            if discovered.insert(child) {
                parents.insert(child, hop);
                queue.push_back((child, depth + 1));
            }
        }
    }

    Ok(PointerPath {
        root,
        target_start,
        target_end,
        hops: Vec::new(),
        blocks,
        truncated: !queue.is_empty(),
        total_ms: started.elapsed().as_millis(),
    })
}

struct GraphRegions<'a> {
    regions: Vec<&'a Region>,
}

impl<'a> GraphRegions<'a> {
    fn new(regions: &'a [Region]) -> Self {
        Self {
            regions: regions
                .iter()
                .filter(|region| region.supports_ui_graph())
                .collect(),
        }
    }

    fn find(&self, address: u64) -> Option<&'a Region> {
        let index = self.regions.partition_point(|region| region.end <= address);
        self.regions
            .get(index)
            .copied()
            .filter(|region| region.contains(address))
    }
}

#[cfg(test)]
fn pointer_targets(bytes: &[u8], regions: &GraphRegions<'_>) -> Vec<u64> {
    pointer_edges(0, bytes, regions)
        .into_iter()
        .map(|(_, pointer)| pointer)
        .collect()
}

fn pointer_edges(address: u64, bytes: &[u8], regions: &GraphRegions<'_>) -> Vec<(u64, u64)> {
    let mut seen = HashSet::new();
    let mut pointers = Vec::new();
    for (index, chunk) in bytes.chunks_exact(8).enumerate() {
        let pointer = u64::from_le_bytes(chunk.try_into().unwrap());
        if pointer & 7 != 0 || !seen.insert(pointer) {
            continue;
        }
        if regions.find(pointer).is_some() {
            pointers.push((address + (index * 8) as u64, pointer));
        }
    }
    pointers
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
        let regions = GraphRegions::new(&regions);
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&0x1800_u64.to_le_bytes());
        bytes.extend_from_slice(&0x1801_u64.to_le_bytes());
        bytes.extend_from_slice(&0x3000_u64.to_le_bytes());
        assert_eq!(pointer_targets(&bytes, &regions), vec![0x1800]);
    }
}
