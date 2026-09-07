use std::collections::{BTreeMap, HashMap, HashSet};

use memchr::memmem;
use serde::Serialize;

use super::ProcessIdentity;
use super::adapter::{self, MetadataLayout};
use super::memory::{ExecutableIdentity, ProcessMemory, Region, identify_process};

const STORE_ENTRY_SIZE: u64 = 16;
const VARIANT_ENTRY_SIZE: u64 = 0x68;
const MAX_STORE_ENTRIES: usize = 100_000;
const MAX_VARIANT_ENTRIES: usize = 50_000;
const SCAN_CHUNK_SIZE: usize = 8 * 1024 * 1024;
const PLAYER_POWER_SUIT: &str = "/Lotus/Types/Game/PowerSuits/PlayerPowerSuit";

#[derive(Debug, Serialize)]
pub struct GameMetadata {
    schema: u32,
    executable: ExecutableIdentity,
    archimedea: ArchimedeaMetadata,
}

#[derive(Debug, Serialize)]
struct ArchimedeaMetadata {
    catalog: Catalog,
    owned_suit_items: Vec<String>,
    owned_weapon_items: Vec<String>,
    suit_aliases: Vec<Alias>,
    weapon_aliases: Vec<Alias>,
}

#[derive(Debug, Default, Serialize)]
struct Catalog {
    suits: Vec<String>,
    primaries: Vec<String>,
    secondaries: Vec<String>,
    melees: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
struct Alias {
    source: String,
    canonical: String,
}

#[derive(Clone, Debug)]
struct StoreEntry {
    category: u8,
    path: String,
    descriptor: u64,
    icon: u32,
    excluded: bool,
    eligible: bool,
}

#[derive(Clone, Debug)]
struct DescriptorNode {
    address: u64,
    name: String,
    parent: u64,
}

pub fn capture(pid: u32) -> Result<GameMetadata, String> {
    let identity = identify_process(pid)?;
    capture_for_identity(pid, identity)
}

pub fn capture_for_identity(pid: u32, identity: ProcessIdentity) -> Result<GameMetadata, String> {
    if identity.pid != pid {
        return Err("Warframe process identity PID mismatch".to_owned());
    }
    let layout = adapter::require(&identity)?.metadata;
    let memory = ProcessMemory::open(pid)?;
    let base = memory
        .image_base()
        .ok_or_else(|| "Warframe executable mapping not found".to_owned())?;
    let store = read_store_entries(&memory, base, layout)?;
    let variants = read_variant_manifest(&memory, base, layout)?;
    let archimedea = build_archimedea(&memory, base, layout, &store, &variants)?;
    Ok(GameMetadata {
        schema: 2,
        executable: identity.executable,
        archimedea,
    })
}

fn build_archimedea(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
    store: &[StoreEntry],
    variants: &HashMap<u64, u64>,
) -> Result<ArchimedeaMetadata, String> {
    let mut catalog = Catalog::default();
    let mut owned_suit_items = Vec::new();
    let mut owned_weapon_items = Vec::new();
    let mut weapon_aliases = Vec::new();
    for entry in store {
        if entry.category == 3 {
            owned_suit_items.push(entry.path.clone());
            if !entry.excluded {
                catalog.suits.push(entry.path.clone());
            }
            continue;
        }
        if is_owned_weapon(entry)
            && let Some(canonical) =
                normalized_weapon(memory, base, layout, entry.descriptor, variants)?
        {
            owned_weapon_items.push(entry.path.clone());
            if canonical != entry.path {
                weapon_aliases.push(Alias {
                    source: entry.path.clone(),
                    canonical,
                });
            }
        }
        if entry.icon == 0 || !entry.eligible || entry.excluded || !is_catalog_weapon(&entry.path) {
            continue;
        }
        match entry.category {
            0 => catalog.secondaries.push(entry.path.clone()),
            1 => catalog.primaries.push(entry.path.clone()),
            5 => catalog.melees.push(entry.path.clone()),
            _ => {}
        }
    }
    Ok(ArchimedeaMetadata {
        catalog,
        owned_suit_items,
        owned_weapon_items,
        suit_aliases: suit_aliases(memory, base, layout, store)?,
        weapon_aliases,
    })
}

fn is_owned_weapon(entry: &StoreEntry) -> bool {
    let modular = entry.path.contains("Modular");
    entry.icon != 0
        && (!entry.excluded || modular)
        && (is_owned_base_weapon(&entry.path) || modular)
}

fn is_owned_base_weapon(path: &str) -> bool {
    ![
        "MK1",
        "StartingRifle",
        "Wraith",
        "Vandal",
        "Prisma",
        "Syndicate",
        "Modular",
        "Gear",
    ]
    .iter()
    .any(|token| path.contains(token))
}

fn is_catalog_weapon(path: &str) -> bool {
    is_owned_base_weapon(path) && !path.contains("Prime") && !path.contains("Bayonet/TnBayonet")
}

fn read_store_entries(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
) -> Result<Vec<StoreEntry>, String> {
    let game_time = read_f64(memory, base + layout.game_time_rva)?;
    if !game_time.is_finite() {
        return Err("invalid Warframe game time".to_owned());
    }
    let holder = global_object(memory, base, layout, layout.game_rules_hash)?;
    let game_rules = non_null(read_u64(memory, holder)?, "gGameRules")?;
    let mut candidates = BTreeMap::new();
    for &offset in layout.store_manifest_offsets {
        let mut candidate = read_u64(memory, game_rules + offset)?;
        for _depth in 0..=2 {
            if candidate == 0 {
                break;
            }
            if let Some(shape) =
                manifest_shape(memory, candidate, STORE_ENTRY_SIZE, MAX_STORE_ENTRIES)
            {
                candidates.insert(candidate, shape);
            }
            candidate = match read_u64(memory, candidate) {
                Ok(next) => next,
                Err(_) => break,
            };
        }
    }
    let candidates = candidates.into_iter().collect::<Vec<_>>();
    if candidates.len() != 1 {
        return Err("expected one StoreManifest candidate".to_owned());
    }
    let (_manifest, (entries, count)) = candidates[0];
    let mut result = Vec::new();
    for index in 0..count {
        let holder = read_u64(memory, entries + index as u64 * STORE_ENTRY_SIZE)?;
        if holder == 0 {
            continue;
        }
        let item = read_u64(memory, holder)?;
        if item == 0 {
            continue;
        }
        let category = read_u8(memory, item + 0x155)?;
        if !matches!(category, 0 | 1 | 3 | 5) {
            continue;
        }
        let resource = non_null(read_u64(memory, item + 0x28)?, "StoreItem resource")?;
        let flags = read_u32(memory, item + 0x15c)?;
        result.push(StoreEntry {
            category,
            path: resource_name(memory, base, layout, resource)?,
            descriptor: resource,
            icon: read_u32(memory, item + 0xfc)?,
            excluded: flags & 0x100 != 0,
            eligible: store_item_eligible(
                read_i64(memory, item + 0xe0)?,
                read_i64(memory, item + 0xe8)?,
                flags,
                game_time,
            ),
        });
    }
    Ok(result)
}

fn suit_aliases(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
    entries: &[StoreEntry],
) -> Result<Vec<Alias>, String> {
    let mut groups = Vec::new();
    for entry in entries.iter().filter(|entry| entry.category == 3) {
        let mut descriptor = entry.descriptor;
        let mut seen = HashSet::new();
        while descriptor != 0 && seen.insert(descriptor) {
            let parent = read_u64(memory, descriptor + 0x18)?;
            if parent == 0 {
                break;
            }
            if resource_name(memory, base, layout, parent)? == PLAYER_POWER_SUIT {
                groups.push((entry.path.clone(), descriptor));
                break;
            }
            descriptor = parent;
        }
    }
    Ok(suit_aliases_from_groups(&groups))
}

fn suit_aliases_from_groups(groups: &[(String, u64)]) -> Vec<Alias> {
    let mut canonical = HashMap::new();
    let mut result = Vec::new();
    for (path, group) in groups {
        let target = canonical.entry(*group).or_insert_with(|| path.clone());
        if target != path {
            result.push(Alias {
                source: path.clone(),
                canonical: target.clone(),
            });
        }
    }
    result
}

fn read_variant_manifest(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
) -> Result<HashMap<u64, u64>, String> {
    let descriptor = base + layout.variant_manifest_descriptor_rva;
    let mut candidates = Vec::new();
    for manifest in instances_with_descriptor(memory, descriptor)? {
        if let Some((vector, count)) =
            manifest_shape(memory, manifest, VARIANT_ENTRY_SIZE, MAX_VARIANT_ENTRIES)
        {
            let score = variant_score(memory, base, layout, vector, count).unwrap_or(0);
            if score >= 24 {
                candidates.push((score, manifest, vector, count));
            }
        }
    }
    candidates.sort_unstable_by(|left, right| right.cmp(left));
    let Some(&(score, _resource, vector, count)) = candidates.first() else {
        return Err("VariantManifest is not loaded".to_owned());
    };
    if candidates
        .get(1)
        .is_some_and(|candidate| candidate.0 == score)
    {
        return Err("ambiguous VariantManifest candidates".to_owned());
    }
    let mut variants = HashMap::new();
    for index in 0..count {
        let entry = vector + index as u64 * VARIANT_ENTRY_SIZE;
        if read_u32(memory, entry + 0x10)? == 0 {
            continue;
        }
        let holder = read_u64(memory, entry + 0x08)?;
        if holder == 0 {
            continue;
        }
        let target = read_u64(memory, holder)?;
        if target == 0 {
            continue;
        }
        variants.insert(read_u64(memory, entry)?, target);
    }
    Ok(variants)
}

fn normalized_weapon(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
    descriptor: u64,
    variants: &HashMap<u64, u64>,
) -> Result<Option<String>, String> {
    let chain = descriptor_chain(memory, base, layout, descriptor)?;
    let Some(target) =
        variant_target_from_chain(&chain, base + layout.weapon_descriptor_rva, variants)
    else {
        return Ok(None);
    };
    resource_name(memory, base, layout, target).map(Some)
}

fn descriptor_chain(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
    descriptor: u64,
) -> Result<Vec<DescriptorNode>, String> {
    let mut chain = Vec::new();
    let mut current = descriptor;
    let mut seen = HashSet::new();
    while current != 0 && seen.insert(current) {
        let parent = read_u64(memory, current + 0x18)?;
        chain.push(DescriptorNode {
            address: current,
            name: resource_name(memory, base, layout, current)?,
            parent,
        });
        if parent == 0 || parent == current {
            break;
        }
        current = parent;
    }
    Ok(chain)
}

fn variant_target_from_chain(
    chain: &[DescriptorNode],
    weapon_descriptor: u64,
    variants: &HashMap<u64, u64>,
) -> Option<u64> {
    let weapon_index = chain
        .iter()
        .position(|node| node.address == weapon_descriptor);
    for (index, node) in chain.iter().enumerate() {
        if let Some(target) = variants.get(&node.address) {
            return Some(*target);
        }
        if node.name.contains("Base")
            || node.parent == 0
            || node.parent == node.address
            || weapon_index.is_none_or(|weapon_index| index > weapon_index)
        {
            return None;
        }
    }
    None
}

fn store_item_eligible(start: i64, end: i64, flags: u32, game_time: f64) -> bool {
    (start == 0 || start as f64 <= game_time)
        && (end == 0 || end as f64 >= game_time)
        && flags & 0x20 != 0
}

fn variant_score(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
    vector: u64,
    count: usize,
) -> Result<usize, String> {
    let mut previous = 0;
    let mut decoded = 0;
    let mut mapped = 0;
    for index in 0..count.min(32) {
        let entry = vector + index as u64 * VARIANT_ENTRY_SIZE;
        let key = read_u64(memory, entry)?;
        if key == 0 || key < previous {
            return Ok(0);
        }
        previous = key;
        if resource_name(memory, base, layout, key)?.starts_with("/Lotus/") {
            decoded += 1;
        }
        if read_u32(memory, entry + 0x10)? != 0 {
            let holder = non_null(read_u64(memory, entry + 0x08)?, "variant holder")?;
            let target = non_null(read_u64(memory, holder)?, "variant target")?;
            if resource_name(memory, base, layout, target)?.starts_with("/Lotus/") {
                mapped += 1;
            }
        }
    }
    Ok(decoded + mapped * 2)
}

fn instances_with_descriptor(memory: &ProcessMemory, descriptor: u64) -> Result<Vec<u64>, String> {
    let needle = descriptor.to_le_bytes();
    let mut instances = Vec::new();
    for region in memory
        .regions()
        .iter()
        .filter(|region| private_writable(region))
    {
        let mut cursor = region.start;
        let mut tail = Vec::new();
        while cursor < region.end {
            let size = (region.end - cursor).min(SCAN_CHUNK_SIZE as u64) as usize;
            let mut chunk = vec![0; size];
            if memory.read_exact_at(&mut chunk, cursor).is_err() {
                break;
            }
            let mut data = Vec::with_capacity(tail.len() + chunk.len());
            data.extend_from_slice(&tail);
            data.extend_from_slice(&chunk);
            let start = cursor.saturating_sub(tail.len() as u64);
            for offset in memmem::find_iter(&data, &needle) {
                let address = start + offset as u64;
                if let Some(instance) = address.checked_sub(8)
                    && read_u64(memory, instance + 8).ok() == Some(descriptor)
                {
                    instances.push(instance);
                }
            }
            tail.clear();
            tail.extend_from_slice(&chunk[chunk.len().saturating_sub(7)..]);
            cursor += size as u64;
        }
    }
    instances.sort_unstable();
    instances.dedup();
    Ok(instances)
}

fn global_object(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
    key: u32,
) -> Result<u64, String> {
    let registry = base + layout.global_registry_rva;
    let entries = read_u64(memory, registry + 0x138)?;
    let byte_length = read_u32(memory, registry + 0x140)? as u64;
    if byte_length > 0x10000 || !byte_length.is_multiple_of(16) {
        return Err("invalid Warframe global registry".to_owned());
    }
    for offset in (0..byte_length).step_by(16) {
        if read_u32(memory, entries + offset)? == key {
            return non_null(read_u64(memory, entries + offset + 8)?, "Warframe global");
        }
    }
    Err(format!("Warframe global 0x{key:08x} not found"))
}

fn manifest_shape(
    memory: &ProcessMemory,
    manifest: u64,
    entry_size: u64,
    maximum: usize,
) -> Option<(u64, usize)> {
    let entries = read_u64(memory, manifest + 0x38).ok()?;
    let byte_length = read_u32(memory, manifest + 0x40).ok()? as u64;
    if entries == 0 || byte_length == 0 || !byte_length.is_multiple_of(entry_size) {
        return None;
    }
    let count = (byte_length / entry_size) as usize;
    (count <= maximum && readable_range(memory, entries, byte_length)).then_some((entries, count))
}

fn resource_name(
    memory: &ProcessMemory,
    base: u64,
    layout: MetadataLayout,
    resource: u64,
) -> Result<String, String> {
    let blocks = read_u64(memory, base + layout.string_blocks_rva)?;
    let first_pointer = read_u64(memory, resource + 0x10)?;
    let first = if first_pointer == 0 {
        0
    } else {
        read_u32(memory, first_pointer)?
    };
    let second = read_u32(memory, resource + 0x2c)?;
    Ok(token_part(memory, blocks, first)? + &token_part(memory, blocks, second)?)
}

fn token_part(memory: &ProcessMemory, blocks: u64, token: u32) -> Result<String, String> {
    let block = read_u64(memory, blocks + u64::from(token & 0xffff) * 16)?;
    read_c_string(memory, block + u64::from(token >> 16), 1024)
}

fn read_c_string(memory: &ProcessMemory, address: u64, limit: usize) -> Result<String, String> {
    let mut bytes = Vec::new();
    while bytes.len() < limit {
        let size = (limit - bytes.len()).min(64);
        let mut chunk = vec![0; size];
        memory
            .read_exact_at(&mut chunk, address + bytes.len() as u64)
            .map_err(|error| format!("could not read Warframe string: {error}"))?;
        if let Some(end) = chunk.iter().position(|byte| *byte == 0) {
            bytes.extend_from_slice(&chunk[..end]);
            return String::from_utf8(bytes)
                .map_err(|error| format!("invalid Warframe resource name: {error}"));
        }
        bytes.extend_from_slice(&chunk);
    }
    Err("unterminated Warframe resource name".to_owned())
}

fn containing(regions: &[Region], address: u64, size: u64) -> Option<&Region> {
    let end = address.checked_add(size)?;
    regions
        .iter()
        .find(|region| region.start <= address && end <= region.end)
}

fn readable_range(memory: &ProcessMemory, address: u64, size: u64) -> bool {
    containing(memory.regions(), address, size)
        .is_some_and(|region| region.permissions.starts_with('r'))
}

fn private_writable(region: &Region) -> bool {
    region.permissions.starts_with("rw")
        && region.permissions.ends_with('p')
        && (region.path.is_empty() || region.path.starts_with('['))
}

fn non_null(value: u64, name: &str) -> Result<u64, String> {
    (value != 0)
        .then_some(value)
        .ok_or_else(|| format!("null {name} pointer"))
}

fn read_u8(memory: &ProcessMemory, address: u64) -> Result<u8, String> {
    let mut bytes = [0; 1];
    memory
        .read_exact_at(&mut bytes, address)
        .map_err(|error| format!("could not read Warframe memory at 0x{address:x}: {error}"))?;
    Ok(bytes[0])
}

fn read_u32(memory: &ProcessMemory, address: u64) -> Result<u32, String> {
    let mut bytes = [0; 4];
    memory
        .read_exact_at(&mut bytes, address)
        .map_err(|error| format!("could not read Warframe memory at 0x{address:x}: {error}"))?;
    Ok(u32::from_le_bytes(bytes))
}

fn read_i64(memory: &ProcessMemory, address: u64) -> Result<i64, String> {
    let mut bytes = [0; 8];
    memory
        .read_exact_at(&mut bytes, address)
        .map_err(|error| format!("could not read Warframe memory at 0x{address:x}: {error}"))?;
    Ok(i64::from_le_bytes(bytes))
}

fn read_f64(memory: &ProcessMemory, address: u64) -> Result<f64, String> {
    let mut bytes = [0; 8];
    memory
        .read_exact_at(&mut bytes, address)
        .map_err(|error| format!("could not read Warframe memory at 0x{address:x}: {error}"))?;
    Ok(f64::from_le_bytes(bytes))
}

fn read_u64(memory: &ProcessMemory, address: u64) -> Result<u64, String> {
    let mut bytes = [0; 8];
    memory
        .read_exact_at(&mut bytes, address)
        .map_err(|error| format!("could not read Warframe memory at 0x{address:x}: {error}"))?;
    Ok(u64::from_le_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_and_owned_filters_match_archimedea_scripts() {
        assert!(is_catalog_weapon("/Lotus/Weapons/Tenno/Rifle/HeavyRifle"));
        assert!(!is_catalog_weapon("/Lotus/Weapons/Tenno/Rifle/BratonPrime"));
        assert!(!is_catalog_weapon(
            "/Lotus/Weapons/Syndicates/SteelMeridian/SMHek"
        ));
        assert!(!is_catalog_weapon("/Lotus/Weapons/Tenno/Bayonet/TnBayonet"));
        assert!(is_owned_base_weapon(
            "/Lotus/Weapons/Tenno/Rifle/BratonPrime"
        ));
        assert!(is_owned_base_weapon(
            "/Lotus/Weapons/Tenno/Bayonet/TnBayonet"
        ));
    }

    #[test]
    fn owned_weapon_filter_uses_local_rules_and_keeps_modular_weapons() {
        let entry = |path: &str, excluded, eligible| StoreEntry {
            category: 1,
            path: path.to_owned(),
            descriptor: 0,
            icon: 1,
            excluded,
            eligible,
        };
        assert!(is_owned_weapon(&entry(
            "/Lotus/Weapons/Tenno/Rifle/HeavyRifle",
            false,
            true
        )));
        assert!(is_owned_weapon(&entry(
            "/Lotus/Weapons/Tenno/Rifle/BratonPrime",
            false,
            true
        )));
        assert!(!is_owned_weapon(&entry(
            "/Lotus/Weapons/Tenno/Rifle/BratonWraith",
            false,
            true
        )));
        assert!(is_owned_weapon(&entry(
            "/Lotus/Weapons/SolarisUnited/ModularPrimary",
            true,
            true
        )));
        assert!(is_owned_weapon(&entry(
            "/Lotus/Weapons/Tenno/Rifle/HeavyRifle",
            false,
            false
        )));
    }

    #[test]
    fn eligibility_uses_native_flag_and_time_window() {
        assert!(store_item_eligible(0, 0, 0x20, 100.0));
        assert!(store_item_eligible(100, 100, 0x20, 100.0));
        assert!(!store_item_eligible(101, 0, 0x20, 100.0));
        assert!(!store_item_eligible(0, 99, 0x20, 100.0));
        assert!(!store_item_eligible(0, 0, 0x20000, 100.0));
    }

    #[test]
    fn variant_lookup_walks_parents_but_stops_at_base_or_weapon_boundary() {
        let chain = vec![
            node(1, "Variant", 2),
            node(2, "Family", 3),
            node(3, "Weapon", 4),
            node(4, "Resource", 0),
        ];
        assert_eq!(
            variant_target_from_chain(&chain, 3, &HashMap::from([(2, 9)])),
            Some(9)
        );
        assert_eq!(
            variant_target_from_chain(&chain, 3, &HashMap::from([(4, 9)])),
            Some(9)
        );
        let base = vec![node(1, "VariantBase", 2), node(2, "Weapon", 0)];
        assert_eq!(
            variant_target_from_chain(&base, 2, &HashMap::from([(2, 9)])),
            None
        );
    }

    #[test]
    fn suit_aliases_use_first_store_item_in_each_base_suit_group() {
        let groups = vec![
            ("/Lotus/Powersuits/Cowgirl/Cowgirl".to_owned(), 0x200),
            ("/Lotus/Powersuits/Cowgirl/MesaPrime".to_owned(), 0x200),
            ("/Lotus/Powersuits/Mag/Mag".to_owned(), 0x300),
        ];
        assert_eq!(
            suit_aliases_from_groups(&groups),
            vec![Alias {
                source: "/Lotus/Powersuits/Cowgirl/MesaPrime".to_owned(),
                canonical: "/Lotus/Powersuits/Cowgirl/Cowgirl".to_owned(),
            }]
        );
    }

    fn node(address: u64, name: &str, parent: u64) -> DescriptorNode {
        DescriptorNode {
            address,
            name: name.to_owned(),
            parent,
        }
    }
}
