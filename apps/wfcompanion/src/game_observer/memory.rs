use std::fmt::Write as _;
use std::fs::{self, File};
use std::io::{self, Read};
use std::os::unix::fs::FileExt;
use std::path::PathBuf;
use std::time::UNIX_EPOCH;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug)]
pub(crate) struct Region {
    pub(crate) start: u64,
    pub(crate) end: u64,
    pub(crate) permissions: String,
    pub(crate) path: String,
}

#[derive(Clone, Debug)]
pub(crate) struct ScanRange {
    pub(crate) start: u64,
    pub(crate) end: u64,
    pub(crate) permissions: String,
    pub(crate) path: String,
}

#[derive(Debug)]
pub(crate) struct ProcessMemory {
    pid: u32,
    backing: MemoryBacking,
    maps: String,
    regions: Vec<Region>,
}

#[derive(Debug)]
enum MemoryBacking {
    Live(File),
    Capture(CaptureMemory),
}

#[derive(Clone, Debug)]
pub(crate) struct CaptureBlock {
    pub(crate) address: u64,
    pub(crate) length: usize,
    pub(crate) file_offset: usize,
}

#[derive(Debug)]
struct CaptureMemory {
    bytes: Vec<u8>,
    blocks: Vec<CaptureBlock>,
}

impl ProcessMemory {
    pub(crate) fn open(pid: u32) -> Result<Self, String> {
        let maps = fs::read_to_string(format!("/proc/{pid}/maps"))
            .map_err(|error| format!("could not read Warframe maps: {error}"))?;
        let file = File::open(format!("/proc/{pid}/mem"))
            .map_err(|error| format!("could not open Warframe memory: {error}"))?;
        Ok(Self {
            pid,
            backing: MemoryBacking::Live(file),
            maps: maps.clone(),
            regions: parse_regions(&maps),
        })
    }

    pub(crate) fn from_capture(
        pid: u32,
        maps: String,
        blocks: Vec<CaptureBlock>,
        bytes: Vec<u8>,
    ) -> Result<Self, String> {
        let backing = CaptureMemory::new(blocks, bytes)?;
        Ok(Self {
            pid,
            regions: parse_regions(&maps),
            maps,
            backing: MemoryBacking::Capture(backing),
        })
    }

    pub(crate) fn pid(&self) -> u32 {
        self.pid
    }

    pub(crate) fn regions(&self) -> &[Region] {
        &self.regions
    }

    pub(crate) fn maps(&self) -> &str {
        &self.maps
    }

    pub(crate) fn scan_ranges(&self) -> Vec<ScanRange> {
        self.selected_ranges(Region::supports_research_scan)
    }

    pub(crate) fn selected_ranges(&self, accepts: impl Fn(&Region) -> bool) -> Vec<ScanRange> {
        match &self.backing {
            MemoryBacking::Live(_) => self
                .regions
                .iter()
                .filter(|region| accepts(region))
                .map(|region| ScanRange {
                    start: region.start,
                    end: region.end,
                    permissions: region.permissions.clone(),
                    path: region.path.clone(),
                })
                .collect(),
            MemoryBacking::Capture(capture) => {
                let mut ranges = Vec::<ScanRange>::new();
                for block in &capture.blocks {
                    let block_end = block.address + block.length as u64;
                    let first = self
                        .regions
                        .partition_point(|region| region.end <= block.address);
                    for region in self.regions[first..]
                        .iter()
                        .take_while(|region| region.start < block_end)
                        .filter(|region| accepts(region))
                    {
                        let start = block.address.max(region.start);
                        let end = block_end.min(region.end);
                        if let Some(previous) = ranges.last_mut()
                            && previous.end == start
                            && previous.permissions == region.permissions
                            && previous.path == region.path
                        {
                            previous.end = end;
                        } else {
                            ranges.push(ScanRange {
                                start,
                                end,
                                permissions: region.permissions.clone(),
                                path: region.path.clone(),
                            });
                        }
                    }
                }
                ranges
            }
        }
    }

    pub(crate) fn image_base(&self) -> Option<u64> {
        self.regions
            .iter()
            .find(|region| {
                region
                    .path
                    .to_ascii_lowercase()
                    .ends_with("/warframe.x64.exe")
            })
            .map(|region| region.start)
    }

    pub(crate) fn read_at(&self, buffer: &mut [u8], offset: u64) -> io::Result<usize> {
        match &self.backing {
            MemoryBacking::Live(file) => file.read_at(buffer, offset),
            MemoryBacking::Capture(capture) => capture.read_at(buffer, offset),
        }
    }

    pub(crate) fn read_exact_at(&self, buffer: &mut [u8], offset: u64) -> io::Result<()> {
        match &self.backing {
            MemoryBacking::Live(file) => file.read_exact_at(buffer, offset),
            MemoryBacking::Capture(capture) => capture.read_exact_at(buffer, offset),
        }
    }

    pub(crate) fn supports_ui_range(&self, address: u64, length: usize) -> bool {
        let Some(end) = address.checked_add(length as u64) else {
            return false;
        };
        let mapped = self
            .regions
            .iter()
            .any(|region| region.supports_ui_graph() && region.contains_range(address, end));
        mapped
            && match &self.backing {
                MemoryBacking::Live(_) => true,
                MemoryBacking::Capture(capture) => capture.contains_range(address, length),
            }
    }

    pub(crate) fn supports_read_range(&self, address: u64, length: usize) -> bool {
        let Some(end) = address.checked_add(length as u64) else {
            return false;
        };
        let mapped = self.regions.iter().any(|region| {
            region.permissions.starts_with('r') && region.contains_range(address, end)
        });
        mapped
            && match &self.backing {
                MemoryBacking::Live(_) => true,
                MemoryBacking::Capture(capture) => capture.contains_range(address, length),
            }
    }

    #[cfg(test)]
    pub(crate) fn from_test_bytes(bytes: &[u8], regions: Vec<Region>) -> Self {
        use std::sync::atomic::{AtomicU64, Ordering};

        static NEXT_FILE: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "wfcompanion-memory-{}-{}",
            std::process::id(),
            NEXT_FILE.fetch_add(1, Ordering::Relaxed)
        ));
        let mut output = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .expect("create test memory");
        std::io::Write::write_all(&mut output, bytes).expect("write test memory");
        drop(output);
        let file = File::open(&path).expect("open test memory");
        fs::remove_file(path).expect("unlink test memory");
        Self {
            pid: 0,
            backing: MemoryBacking::Live(file),
            maps: String::new(),
            regions,
        }
    }
}

impl CaptureMemory {
    fn new(mut blocks: Vec<CaptureBlock>, bytes: Vec<u8>) -> Result<Self, String> {
        blocks.sort_by_key(|block| block.address);
        let mut previous_end = None;
        for block in &blocks {
            if block.length == 0 {
                return Err("capture contains an empty memory block".to_owned());
            }
            let virtual_end = block
                .address
                .checked_add(block.length as u64)
                .ok_or_else(|| "capture memory block overflows address space".to_owned())?;
            block
                .file_offset
                .checked_add(block.length)
                .filter(|end| *end <= bytes.len())
                .ok_or_else(|| "capture memory block exceeds data file".to_owned())?;
            if previous_end.is_some_and(|end| block.address < end) {
                return Err("capture contains overlapping memory blocks".to_owned());
            }
            previous_end = Some(virtual_end);
        }
        Ok(Self { bytes, blocks })
    }

    fn read_at(&self, buffer: &mut [u8], offset: u64) -> io::Result<usize> {
        let mut address = offset;
        let mut written = 0;
        while written < buffer.len() {
            let index = self
                .blocks
                .partition_point(|block| block.address <= address);
            let Some(block) = index
                .checked_sub(1)
                .and_then(|index| self.blocks.get(index))
            else {
                break;
            };
            let block_end = block.address + block.length as u64;
            if address >= block_end {
                break;
            }
            let within = usize::try_from(address - block.address).unwrap();
            let length = (block.length - within).min(buffer.len() - written);
            let source = block.file_offset + within;
            buffer[written..written + length].copy_from_slice(&self.bytes[source..source + length]);
            written += length;
            address += length as u64;
        }
        Ok(written)
    }

    fn read_exact_at(&self, buffer: &mut [u8], offset: u64) -> io::Result<()> {
        let read = self.read_at(buffer, offset)?;
        if read == buffer.len() {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "range is absent from capture",
            ))
        }
    }

    fn contains_range(&self, start: u64, length: usize) -> bool {
        if length == 0 {
            return true;
        }
        let Some(end) = start.checked_add(length as u64) else {
            return false;
        };
        let index = self.blocks.partition_point(|block| block.address <= start);
        let Some(mut index) = index.checked_sub(1) else {
            return false;
        };
        let mut covered = start;
        while covered < end {
            let Some(block) = self.blocks.get(index) else {
                return false;
            };
            if block.address > covered || block.address + block.length as u64 <= covered {
                return false;
            }
            covered = block.address + block.length as u64;
            index += 1;
        }
        true
    }
}

impl Region {
    pub(crate) fn contains(&self, address: u64) -> bool {
        (self.start..self.end).contains(&address)
    }

    pub(crate) fn supports_ui_graph(&self) -> bool {
        self.permissions.starts_with("rw")
            && self.permissions.ends_with('p')
            && (self.path.is_empty() || self.path.starts_with('['))
    }

    pub(crate) fn supports_research_scan(&self) -> bool {
        let private_writable = self.permissions.starts_with("rw")
            && self.permissions.ends_with('p')
            && (self.path.is_empty() || self.path.starts_with('['));
        let game_image = self.permissions.starts_with('r')
            && self
                .path
                .to_ascii_lowercase()
                .ends_with("/warframe.x64.exe");
        private_writable || game_image
    }

    fn contains_range(&self, start: u64, end: u64) -> bool {
        self.start <= start && start <= end && end <= self.end
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ExecutableIdentity {
    pub path: PathBuf,
    pub size: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified_unix_ms: Option<u128>,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ProcessIdentity {
    pub pid: u32,
    pub executable: ExecutableIdentity,
}

pub fn identify_process(pid: u32) -> Result<ProcessIdentity, String> {
    let maps = fs::read_to_string(format!("/proc/{pid}/maps"))
        .map_err(|error| format!("could not read Warframe maps: {error}"))?;
    let path = game_executable_path(&maps)
        .ok_or_else(|| "Warframe executable is absent from process maps".to_owned())?;
    let metadata = fs::metadata(&path)
        .map_err(|error| format!("could not stat {}: {error}", path.display()))?;
    let modified_unix_ms = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis());
    let sha256 = hash_file(&path)?;
    Ok(ProcessIdentity {
        pid,
        executable: ExecutableIdentity {
            path,
            size: metadata.len(),
            modified_unix_ms,
            sha256,
        },
    })
}

fn hash_file(path: &PathBuf) -> Result<String, String> {
    let mut file = File::open(path)
        .map_err(|error| format!("could not open {} for hashing: {error}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| format!("could not hash {}: {error}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let mut encoded = String::with_capacity(64);
    for byte in hasher.finalize() {
        let _ = write!(encoded, "{byte:02x}");
    }
    Ok(encoded)
}

fn game_executable_path(maps: &str) -> Option<PathBuf> {
    parse_regions(maps)
        .into_iter()
        .find(|region| {
            region
                .path
                .to_ascii_lowercase()
                .ends_with("/warframe.x64.exe")
        })
        .map(|region| PathBuf::from(region.path))
}

fn parse_regions(maps: &str) -> Vec<Region> {
    maps.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let range = fields.next()?;
            let permissions = fields.next()?.to_owned();
            let _offset = fields.next()?;
            let _device = fields.next()?;
            let _inode = fields.next()?;
            let path = decode_maps_path(&fields.collect::<Vec<_>>().join(" "));
            let (start, end) = range.split_once('-')?;
            Some(Region {
                start: u64::from_str_radix(start, 16).ok()?,
                end: u64::from_str_radix(end, 16).ok()?,
                permissions,
                path,
            })
        })
        .collect()
}

fn decode_maps_path(path: &str) -> String {
    path.replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

#[cfg(test)]
fn scan_regions(regions: &[Region]) -> impl Iterator<Item = &Region> {
    regions
        .iter()
        .filter(|region| region.supports_research_scan())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_and_decodes_warframe_image_path() {
        let maps = "140000000-141000000 r-xp 0 00:00 1 /games/Steam\\040Library/Warframe.x64.exe\n";
        assert_eq!(
            game_executable_path(maps),
            Some(PathBuf::from("/games/Steam Library/Warframe.x64.exe"))
        );
    }

    #[test]
    fn limits_explicit_scans_to_game_and_private_memory() {
        let maps = concat!(
            "1000-2000 rw-p 0 00:00 0 \n",
            "2000-3000 r--p 0 00:00 1 /games/Warframe.x64.exe\n",
            "3000-4000 r--p 0 00:00 2 /usr/lib/libc.so\n",
        );
        assert_eq!(scan_regions(&parse_regions(maps)).count(), 2);
    }

    #[test]
    fn validates_complete_memory_ranges() {
        let region = Region {
            start: 0x1000,
            end: 0x2000,
            permissions: "rw-p".to_owned(),
            path: String::new(),
        };
        assert!(region.contains_range(0x1000, 0x2000));
        assert!(region.contains_range(0x1800, 0x1800));
        assert!(!region.contains_range(0x0fff, 0x1800));
        assert!(!region.contains_range(0x1800, 0x2001));
    }

    #[test]
    fn captured_memory_reads_across_adjacent_blocks() {
        let capture = CaptureMemory::new(
            vec![
                CaptureBlock {
                    address: 0x1000,
                    length: 4,
                    file_offset: 0,
                },
                CaptureBlock {
                    address: 0x1004,
                    length: 4,
                    file_offset: 4,
                },
            ],
            b"abcdefgh".to_vec(),
        )
        .unwrap();
        let mut bytes = [0_u8; 6];
        capture.read_exact_at(&mut bytes, 0x1001).unwrap();
        assert_eq!(&bytes, b"bcdefg");
        assert!(capture.contains_range(0x1001, 6));
        assert!(!capture.contains_range(0x0fff, 2));
    }
}
