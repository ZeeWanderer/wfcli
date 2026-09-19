use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Write;

use serde::Serialize;
use serde_json::{Map, Value, json};

use super::adapter::{self, GameAdapter};
use super::memory::{ProcessMemory, identify_process};
use super::metadata;

const MAX_STACKS: usize = 32_768;
const MAX_JOBS: usize = 512;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Snapshot {
    pub sync: String,
    pub fields: Map<String, Value>,
}

pub struct Reader {
    memory: ProcessMemory,
    base: u64,
    adapter: GameAdapter,
    names: HashMap<u64, String>,
}

impl Reader {
    pub fn open(pid: u32) -> Result<Self, String> {
        let identity = identify_process(pid)?;
        let adapter = *adapter::require(&identity)?;
        let memory = ProcessMemory::open(pid)?;
        let base = memory
            .image_base()
            .ok_or("Warframe executable mapping not found")?;
        Ok(Self {
            memory,
            base,
            adapter,
            names: HashMap::new(),
        })
    }

    pub fn read(&mut self) -> Result<Snapshot, String> {
        if self.names.len() > MAX_STACKS * 2 + MAX_JOBS {
            self.names.clear();
        }
        let profile = self.profile()?;
        let layout = self.adapter.inventory;
        let sync = read::<12>(&self.memory, profile + layout.sync_offset)?;
        if sync == [0; 12] {
            return Err("native inventory is not synchronized".into());
        }
        let misc = Vector::read(&self.memory, profile + layout.misc_offset, 16, MAX_STACKS)?;
        let recipes = Vector::read(
            &self.memory,
            profile + layout.recipes_offset,
            16,
            MAX_STACKS,
        )?;
        let pending = Vector::read(
            &self.memory,
            profile + layout.pending_offset,
            0x58,
            MAX_JOBS,
        )?;
        let mut fields = Map::new();
        let mut used = HashSet::new();
        fields.insert("MiscItems".into(), self.stacks(&misc, &mut used)?);
        fields.insert("Recipes".into(), self.stacks(&recipes, &mut used)?);
        fields.insert("PendingRecipes".into(), self.jobs(&pending, &mut used)?);
        // Recheck bytes, not just vector pointers: stack counts change in place.
        for vector in [&misc, &recipes, &pending] {
            vector.verify(&self.memory)?;
        }
        if self.profile()? != profile
            || read::<12>(&self.memory, profile + layout.sync_offset)? != sync
        {
            return Err("native inventory changed during read".into());
        }
        self.names.retain(|address, _| used.contains(address));
        Ok(Snapshot {
            sync: object_id(&sync),
            fields,
        })
    }

    fn profile(&self) -> Result<u64, String> {
        let holder = metadata::global_object(
            &self.memory,
            self.base,
            self.adapter.metadata,
            self.adapter.inventory.profile_hash,
        )?;
        let profile = u64::from_le_bytes(read(&self.memory, holder)?);
        if profile == 0 {
            return Err("native player profile is unavailable".into());
        }
        Ok(profile)
    }

    fn name(&mut self, descriptor: u64, used: &mut HashSet<u64>) -> Result<String, String> {
        if descriptor == 0 {
            return Err("null inventory item type".into());
        }
        used.insert(descriptor);
        if let Some(name) = self.names.get(&descriptor) {
            return Ok(name.clone());
        }
        let name =
            metadata::resource_name(&self.memory, self.base, self.adapter.metadata, descriptor)?;
        if !name.starts_with("/Lotus/") || name.len() > 2048 {
            return Err("invalid inventory item type".into());
        }
        self.names.insert(descriptor, name.clone());
        Ok(name)
    }

    fn stacks(&mut self, vector: &Vector, used: &mut HashSet<u64>) -> Result<Value, String> {
        let mut stacks = BTreeMap::new();
        for (index, row) in vector.bytes.chunks_exact(16).enumerate() {
            let count = quantity(row, vector.data + index as u64 * 16)?;
            if count == 0 {
                continue;
            }
            let name = self.name(u64_at(row, 0), used)?;
            if stacks.insert(name, count).is_some() {
                return Err("duplicate native inventory stack".into());
            }
        }
        Ok(stacks
            .into_iter()
            .map(|(name, count)| json!({"ItemType":name,"ItemCount":count}))
            .collect())
    }

    fn jobs(&mut self, vector: &Vector, used: &mut HashSet<u64>) -> Result<Value, String> {
        let mut jobs = BTreeMap::new();
        for row in vector.bytes.chunks_exact(0x58) {
            if row[..12] == [0; 12] {
                return Err("invalid native foundry job identity".into());
            }
            let id = object_id(&row[..12]);
            let name = self.name(u64_at(row, 0x10), used)?;
            let seconds = engine_string(&self.memory, &row[0x18..0x28])?;
            let date = seconds
                .parse::<u64>()
                .ok()
                .and_then(|n| n.checked_mul(1000))
                .ok_or("invalid native foundry completion time")?;
            let mut job = json!({"ItemId":{"$oid":id},"ItemType":name,
                "CompletionDate":{"$date":{"$numberLong":date.to_string()}}});
            for (key, offset) in [
                ("TargetItemId", 0x28),
                ("TargetFingerprint", 0x38),
                ("IngredientId", 0x48),
            ] {
                let text = engine_string(&self.memory, &row[offset..offset + 16])?;
                if !text.is_empty() {
                    job[key] = text.into();
                }
            }
            if jobs.insert(id, job).is_some() {
                return Err("duplicate native foundry job".into());
            }
        }
        Ok(jobs.into_values().collect())
    }
}

struct Vector {
    address: u64,
    header: [u8; 16],
    data: u64,
    bytes: Vec<u8>,
}

impl Vector {
    fn read(
        memory: &ProcessMemory,
        address: u64,
        stride: usize,
        limit: usize,
    ) -> Result<Self, String> {
        let header = read(memory, address)?;
        let data = u64_at(&header, 0);
        let length = u32_at(&header, 8) as usize;
        let capacity = u32_at(&header, 12) as usize;
        if !length.is_multiple_of(stride)
            || length > limit * stride
            || length > capacity
            || (length != 0 && data == 0)
            || data.checked_add(length as u64).is_none()
        {
            return Err("invalid native inventory vector".into());
        }
        let mut bytes = vec![0; length];
        memory
            .read_exact_at(&mut bytes, data)
            .map_err(|e| format!("native inventory vector: {e}"))?;
        Ok(Self {
            address,
            header,
            data,
            bytes,
        })
    }

    fn verify(&self, memory: &ProcessMemory) -> Result<(), String> {
        let mut bytes = vec![0; self.bytes.len()];
        memory
            .read_exact_at(&mut bytes, self.data)
            .map_err(|e| format!("native inventory reread: {e}"))?;
        if bytes != self.bytes || read::<16>(memory, self.address)? != self.header {
            return Err("native inventory changed during read".into());
        }
        Ok(())
    }
}

fn quantity(row: &[u8], address: u64) -> Result<u32, String> {
    let encoded = u32_at(row, 12);
    if u32_at(row, 8) != encoded ^ 0xad84b2ea {
        return Err("native inventory quantity check failed".into());
    }
    let count = encoded.rotate_left(19) ^ ((address + 12) >> 3) as u32 ^ 0xc55198a3;
    if count > i32::MAX as u32 {
        return Err("negative native inventory quantity".into());
    }
    Ok(count)
}

fn engine_string(memory: &ProcessMemory, storage: &[u8]) -> Result<String, String> {
    let bytes = match storage[15] {
        tag @ 0..=15 => storage[..15 - tag as usize].to_vec(),
        255 => {
            let length = (u32_at(storage, 8) & 0x0fff_ffff) as usize;
            if length > 4096 {
                return Err("native inventory string exceeds limit".into());
            }
            let mut bytes = vec![0; length];
            memory
                .read_exact_at(&mut bytes, u64_at(storage, 0))
                .map_err(|e| format!("native inventory string: {e}"))?;
            bytes
        }
        _ => return Err("invalid native inventory string tag".into()),
    };
    String::from_utf8(bytes).map_err(|e| format!("native inventory string: {e}"))
}

fn object_id(bytes: &[u8]) -> String {
    let mut result = String::with_capacity(24);
    for byte in bytes {
        let _ = write!(result, "{byte:02x}");
    }
    result
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

fn u64_at(bytes: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
}

fn read<const N: usize>(memory: &ProcessMemory, address: u64) -> Result<[u8; N], String> {
    let mut bytes = [0; N];
    memory
        .read_exact_at(&mut bytes, address)
        .map_err(|e| format!("native inventory read: {e}"))?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::super::memory::Region;
    use super::*;

    fn encode_count(row: &mut [u8], address: u64, count: u32) {
        let encoded = (count ^ ((address + 12) >> 3) as u32 ^ 0xc55198a3).rotate_right(19);
        row[8..12].copy_from_slice(&(encoded ^ 0xad84b2ea).to_le_bytes());
        row[12..16].copy_from_slice(&encoded.to_le_bytes());
    }

    fn put64(bytes: &mut [u8], offset: usize, value: u64) {
        bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
    }

    fn put32(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    fn vector(bytes: &mut [u8], offset: usize, data: u64, length: u32) {
        put64(bytes, offset, data);
        put32(bytes, offset + 8, length);
        put32(bytes, offset + 12, length);
    }

    fn fixture() -> (GameAdapter, Vec<u8>) {
        let mut adapter = *adapter::resolve_key("d01b5cb5cff5").unwrap();
        adapter.metadata.global_registry_rva = 0x100;
        adapter.inventory.sync_offset = 0x140;
        adapter.inventory.misc_offset = 0x100;
        adapter.inventory.recipes_offset = 0x110;
        adapter.inventory.pending_offset = 0x120;
        let mut bytes = vec![0; 0x3000];
        vector(&mut bytes, 0x238, 0x400, 16);
        put32(&mut bytes, 0x400, adapter.inventory.profile_hash);
        put64(&mut bytes, 0x408, 0x500);
        put64(&mut bytes, 0x500, 0x1000);
        bytes[0x1140..0x114c].copy_from_slice(&[1; 12]);
        vector(&mut bytes, 0x1100, 0x2000, 32);
        vector(&mut bytes, 0x1110, 0x2100, 16);
        vector(&mut bytes, 0x1120, 0x2200, 0x58);
        for (address, descriptor, count) in [
            (0x2000, 0x9000, 22),
            (0x2010, 0x9100, 0),
            (0x2100, 0x9200, 1),
        ] {
            put64(&mut bytes, address, descriptor);
            encode_count(&mut bytes[address..address + 16], address as u64, count);
        }
        bytes[0x2200..0x220c].copy_from_slice(&[2; 12]);
        put64(&mut bytes, 0x2210, 0x9200);
        bytes[0x2218..0x2222].copy_from_slice(b"1789086000");
        bytes[0x2227] = 5;
        bytes[0x2237] = 15;
        bytes[0x2247] = 15;
        bytes[0x2257] = 15;
        (adapter, bytes)
    }

    fn reader(adapter: GameAdapter, bytes: &[u8]) -> Reader {
        Reader {
            memory: ProcessMemory::from_test_bytes(
                bytes,
                vec![Region {
                    start: 0,
                    end: bytes.len() as u64,
                    permissions: "rw-p".into(),
                    path: String::new(),
                }],
            ),
            base: 0,
            adapter,
            names: [
                (0x9000, "/Lotus/ingredient".into()),
                (0x9200, "/Lotus/blueprint".into()),
            ]
            .into(),
        }
    }

    #[test]
    fn reads_absolute_stacks_and_pending_jobs() {
        let (adapter, bytes) = fixture();
        let mut reader = reader(adapter, &bytes);
        let first = reader.read().unwrap();
        assert_eq!(first.sync, "010101010101010101010101");
        assert_eq!(
            first.fields["MiscItems"],
            json!([{"ItemType":"/Lotus/ingredient","ItemCount":22}])
        );
        assert_eq!(
            first.fields["PendingRecipes"],
            json!([{
                "ItemId":{"$oid":"020202020202020202020202"},"ItemType":"/Lotus/blueprint",
                "CompletionDate":{"$date":{"$numberLong":"1789086000000"}}
            }])
        );
        assert_eq!(reader.read().unwrap(), first);
    }

    #[test]
    fn quantities_are_address_dependent_and_integrity_checked() {
        let mut row = [0; 16];
        for address in [0x1000, 0x3de9ae00, 0x10000000e0] {
            encode_count(&mut row, address, 22);
            assert_eq!(quantity(&row, address).unwrap(), 22);
            assert_ne!(quantity(&row, address + 16).unwrap(), 22);
        }
        row[8] ^= 1;
        assert!(quantity(&row, 0x10000000e0).is_err());
        encode_count(&mut row, 0x1000, u32::MAX);
        assert!(quantity(&row, 0x1000).is_err());
    }

    #[test]
    fn invalid_vectors_strings_and_sync_fail_without_partial_snapshot() {
        let (adapter, bytes) = fixture();
        for (offset, value) in [
            (0x1108, 17),
            (0x1108, u32::MAX),
            (0x110c, 0),
            (0x1128, 0x58 * 513),
        ] {
            let mut corrupt = bytes.clone();
            put32(&mut corrupt, offset, value);
            assert!(reader(adapter, &corrupt).read().is_err());
        }
        let mut corrupt = bytes.clone();
        corrupt[0x1140..0x114c].fill(0);
        assert!(reader(adapter, &corrupt).read().is_err());
        let mut corrupt = bytes.clone();
        corrupt[0x2227] = 16;
        assert!(reader(adapter, &corrupt).read().is_err());
    }

    #[test]
    fn detects_same_address_mutation_and_vector_reallocation() {
        let (adapter, bytes) = fixture();
        let before = reader(adapter, &bytes);
        let vector = Vector::read(&before.memory, 0x1100, 16, MAX_STACKS).unwrap();
        let mut changed = bytes.clone();
        encode_count(&mut changed[0x2000..0x2010], 0x2000, 27);
        assert!(vector.verify(&reader(adapter, &changed).memory).is_err());
        let mut changed = bytes;
        put64(&mut changed, 0x1100, 0x2500);
        assert!(vector.verify(&reader(adapter, &changed).memory).is_err());
    }

    #[test]
    #[ignore = "manual read-only benchmark; requires WF_GAME_PID"]
    fn benchmark_live_inventory_refresh() {
        let pid = std::env::var("WF_GAME_PID").unwrap().parse().unwrap();
        let mut reader = Reader::open(pid).unwrap();
        let cold = std::time::Instant::now();
        let snapshot = reader.read().unwrap();
        let cold = cold.elapsed();
        let mut samples = Vec::new();
        for _ in 0..20 {
            let start = std::time::Instant::now();
            reader.read().unwrap();
            samples.push(start.elapsed().as_micros());
        }
        samples.sort_unstable();
        eprintln!(
            "native inventory: cold={}us warm_median={}us warm_max={}us resources={} recipes={}",
            cold.as_micros(),
            samples[10],
            samples[19],
            snapshot.fields["MiscItems"].as_array().unwrap().len(),
            snapshot.fields["Recipes"].as_array().unwrap().len()
        );
    }
}
