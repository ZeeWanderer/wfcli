use std::collections::{BTreeSet, HashSet};
use std::time::Instant;

use super::DisplayScanMetrics;
use super::text;
use crate::game_observer::memory::ProcessMemory;

const FLASH_ROOT_OFFSET: usize = 0x88;
const ROOT_OWNER_OFFSET: usize = 0xa0;
const ROOT_OBJECT_VECTOR_OFFSET: usize = 0x28;
const CHILD_VECTOR_OFFSET: usize = 0x130;
const TEXT_OBJECT_NAME_OFFSET: usize = 0xc8;
const TEXT_OBJECT_INNER_OFFSET: usize = 0xe0;
const TEXT_OBJECT_BYTES: usize = TEXT_OBJECT_INNER_OFFSET + 0xb8;

const ROOT_VTABLE_RVA: u64 = 0x0222_44b8;
const ROOT_SECONDARY_VTABLE_RVA: u64 = 0x0222_4580;
const CONTAINER_VTABLE_RVA: u64 = 0x0222_5588;
const CONTAINER_SECONDARY_VTABLE_RVA: u64 = 0x0222_5878;
const TEXT_VTABLE_RVA: u64 = 0x0222_77d8;
const TEXT_SECONDARY_VTABLE_RVA: u64 = 0x0222_7ac0;

const MAX_REGISTERED_OBJECTS: usize = 65_536;
const MAX_CHILDREN_PER_CONTAINER: usize = 16_384;
const MAX_CHILD_OBJECTS: usize = 262_144;

struct Vector {
    address: u64,
    objects: usize,
    bytes: usize,
}

pub(super) fn scan_labels(
    memory: &ProcessMemory,
    image: u64,
    flash_object: u64,
    labels: &[&[u8]],
) -> Result<(BTreeSet<usize>, DisplayScanMetrics), String> {
    let mut matches = BTreeSet::new();
    let max_label = labels.iter().map(|label| label.len()).max().unwrap_or(0);
    let metrics = scan_text_objects(memory, image, flash_object, |_, pointer| {
        let Some(value) = read_prefix(memory, pointer, max_label.saturating_add(1)) else {
            return 0;
        };
        for (index, label) in labels.iter().enumerate() {
            if value.starts_with(label) {
                matches.insert(index);
            }
        }
        value.len()
    })?;

    Ok((matches, metrics))
}

pub(super) fn scan_named_text(
    memory: &ProcessMemory,
    image: u64,
    flash_object: u64,
    instance_name: &[u8],
    max_text_bytes: usize,
) -> Result<(Vec<String>, DisplayScanMetrics), String> {
    if instance_name.is_empty() || instance_name.contains(&0) || max_text_bytes == 0 {
        return Err("invalid named-text request".to_owned());
    }

    let mut values = Vec::new();
    let metrics = scan_text_objects(memory, image, flash_object, |object, pointer| {
        if !has_instance_name(object, instance_name) {
            return 0;
        }
        let Some(value) = read_prefix(memory, pointer, max_text_bytes) else {
            return 0;
        };
        let read = value.len();
        let Some(end) = value.iter().position(|byte| *byte == 0) else {
            return read;
        };
        if let Ok(value) = std::str::from_utf8(&value[..end]) {
            values.push(value.to_owned());
        }
        read
    })?;

    Ok((values, metrics))
}

fn scan_text_objects(
    memory: &ProcessMemory,
    image: u64,
    flash_object: u64,
    mut visit: impl FnMut(&[u8], u64) -> usize,
) -> Result<DisplayScanMetrics, String> {
    let started = Instant::now();
    let root_address = flash_object
        .checked_add(FLASH_ROOT_OFFSET as u64)
        .ok_or_else(|| "invalid Flash instance".to_owned())?;
    let root = read_u64(memory, root_address, "movie root")?;
    let root_header = read(memory, root, ROOT_OWNER_OFFSET + 8, "movie root")?;
    require_vtables(
        &root_header,
        image + ROOT_VTABLE_RVA,
        image + ROOT_SECONDARY_VTABLE_RVA,
        "movie root",
    )?;
    if u64_at(&root_header, ROOT_OWNER_OFFSET) != Some(flash_object) {
        return Err("movie root owner mismatch".to_owned());
    }

    let root_vector = vector_at(
        memory,
        &root_header,
        ROOT_OBJECT_VECTOR_OFFSET,
        MAX_REGISTERED_OBJECTS,
        "movie display registry",
    )?;
    let registered = read(
        memory,
        root_vector.address,
        root_vector.bytes,
        "movie display registry",
    )?;
    let mut bytes_read = root_header.len() + registered.len() + 8;
    let mut containers = 0;
    let mut child_count = 0_usize;
    let mut children = HashSet::new();
    let mut text_objects = 0;

    for object in pointers(&registered) {
        if object == 0 || !memory.supports_ui_range(object, CHILD_VECTOR_OFFSET + 16) {
            continue;
        }
        let header = read(
            memory,
            object,
            CHILD_VECTOR_OFFSET + 16,
            "display container",
        )?;
        bytes_read += header.len();
        if !has_vtables(
            &header,
            image + CONTAINER_VTABLE_RVA,
            image + CONTAINER_SECONDARY_VTABLE_RVA,
        ) {
            continue;
        }
        containers += 1;
        let Some(vector) = optional_vector_at(
            memory,
            &header,
            CHILD_VECTOR_OFFSET,
            MAX_CHILDREN_PER_CONTAINER,
        ) else {
            continue;
        };
        child_count = child_count
            .checked_add(vector.objects)
            .filter(|count| *count <= MAX_CHILD_OBJECTS)
            .ok_or_else(|| "movie child-object limit exceeded".to_owned())?;
        let child_bytes = read(memory, vector.address, vector.bytes, "display children")?;
        bytes_read += child_bytes.len();
        for child in pointers(&child_bytes) {
            if child == 0 || !children.insert(child) || !memory.supports_ui_range(child, 0x18) {
                continue;
            }
            let header = read(memory, child, 0x18, "display child")?;
            bytes_read += header.len();
            if !has_vtables(
                &header,
                image + TEXT_VTABLE_RVA,
                image + TEXT_SECONDARY_VTABLE_RVA,
            ) || !memory.supports_ui_range(child, TEXT_OBJECT_BYTES)
            {
                continue;
            }
            let object = read(memory, child, TEXT_OBJECT_BYTES, "text display object")?;
            bytes_read += object.len();
            let Some(pointer) = text::display_text_pointer(&object[TEXT_OBJECT_INNER_OFFSET..])
            else {
                continue;
            };
            text_objects += 1;
            bytes_read += visit(&object, pointer);
        }
    }

    Ok(DisplayScanMetrics {
        registered_objects: root_vector.objects,
        containers,
        child_objects: children.len(),
        text_objects,
        bytes_read,
        total_ms: started.elapsed().as_millis(),
    })
}

fn has_instance_name(object: &[u8], expected: &[u8]) -> bool {
    let Some(name) = object.get(TEXT_OBJECT_NAME_OFFSET..TEXT_OBJECT_INNER_OFFSET) else {
        return false;
    };
    name.get(..expected.len()) == Some(expected) && name.get(expected.len()) == Some(&0)
}

fn read_prefix(memory: &ProcessMemory, address: u64, limit: usize) -> Option<Vec<u8>> {
    let length = memory
        .regions()
        .iter()
        .find(|region| region.supports_ui_graph() && region.contains(address))
        .and_then(|region| usize::try_from(region.end.saturating_sub(address)).ok())?
        .min(limit);
    if length == 0 {
        return None;
    }
    let mut bytes = vec![0_u8; length];
    let read = memory.read_at(&mut bytes, address).ok()?;
    bytes.truncate(read);
    Some(bytes)
}

fn vector_at(
    memory: &ProcessMemory,
    owner: &[u8],
    offset: usize,
    max_objects: usize,
    name: &str,
) -> Result<Vector, String> {
    optional_vector_at(memory, owner, offset, max_objects).ok_or_else(|| format!("invalid {name}"))
}

fn optional_vector_at(
    memory: &ProcessMemory,
    owner: &[u8],
    offset: usize,
    max_objects: usize,
) -> Option<Vector> {
    let address = u64_at(owner, offset)?;
    let used = u32_at(owner, offset + 8)? as usize;
    let capacity = u32_at(owner, offset + 12)? as usize;
    if used == 0 {
        return None;
    }
    if address == 0
        || !used.is_multiple_of(8)
        || !capacity.is_multiple_of(8)
        || capacity < used
        || capacity / 8 > max_objects
        || used / 8 > max_objects
        || !memory.supports_ui_range(address, used)
    {
        return None;
    }
    Some(Vector {
        address,
        objects: used / 8,
        bytes: used,
    })
}

fn require_vtables(bytes: &[u8], primary: u64, secondary: u64, name: &str) -> Result<(), String> {
    has_vtables(bytes, primary, secondary)
        .then_some(())
        .ok_or_else(|| format!("invalid {name} type"))
}

fn has_vtables(bytes: &[u8], primary: u64, secondary: u64) -> bool {
    u64_at(bytes, 0) == Some(primary) && u64_at(bytes, 0x10) == Some(secondary)
}

fn read_u64(memory: &ProcessMemory, address: u64, name: &str) -> Result<u64, String> {
    let bytes = read(memory, address, 8, name)?;
    Ok(u64::from_le_bytes(bytes.try_into().unwrap()))
}

fn read(
    memory: &ProcessMemory,
    address: u64,
    length: usize,
    name: &str,
) -> Result<Vec<u8>, String> {
    if !memory.supports_ui_range(address, length) {
        return Err(format!("invalid {name} range"));
    }
    let mut bytes = vec![0_u8; length];
    memory
        .read_exact_at(&mut bytes, address)
        .map_err(|error| format!("could not read {name}: {error}"))?;
    Ok(bytes)
}

fn pointers(bytes: &[u8]) -> impl Iterator<Item = u64> + '_ {
    bytes
        .chunks_exact(8)
        .map(|bytes| u64::from_le_bytes(bytes.try_into().unwrap()))
}

fn u32_at(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        bytes.get(offset..offset + 4)?.try_into().ok()?,
    ))
}

fn u64_at(bytes: &[u8], offset: usize) -> Option<u64> {
    Some(u64::from_le_bytes(
        bytes.get(offset..offset + 8)?.try_into().ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::game_observer::memory::Region;

    #[test]
    fn checks_expected_vtables() {
        let mut bytes = [0_u8; 0x18];
        bytes[..8].copy_from_slice(&0x1000_u64.to_le_bytes());
        bytes[0x10..].copy_from_slice(&0x2000_u64.to_le_bytes());
        assert!(has_vtables(&bytes, 0x1000, 0x2000));
        assert!(!has_vtables(&bytes, 0x1000, 0x3000));
    }

    #[test]
    fn matches_exact_inline_instance_name() {
        let mut object = [0_u8; TEXT_OBJECT_BYTES];
        object[TEXT_OBJECT_NAME_OFFSET..TEXT_OBJECT_NAME_OFFSET + 8].copy_from_slice(b"ItemName");
        assert!(has_instance_name(&object, b"ItemName"));
        assert!(!has_instance_name(&object, b"Item"));
        object[TEXT_OBJECT_NAME_OFFSET + 8] = b'X';
        assert!(!has_instance_name(&object, b"ItemName"));
    }

    #[test]
    fn walks_named_text_in_display_order() {
        let image = 0x1_4000_0000;
        let flash = 0x1000;
        let root = 0x2000;
        let registry = 0x3000;
        let containers = [0x4000, 0x4200];
        let child_vectors = [0x5000, 0x5100];
        let text_objects = [0x6000, 0x6200, 0x6400];
        let strings = [0x8000, 0x8100, 0x8200];
        let mut bytes = vec![0_u8; 0x10_000];

        write_u64(&mut bytes, flash + FLASH_ROOT_OFFSET, root);
        write_vtables(
            &mut bytes,
            root,
            image + ROOT_VTABLE_RVA,
            image + ROOT_SECONDARY_VTABLE_RVA,
        );
        write_u64(&mut bytes, root + ROOT_OBJECT_VECTOR_OFFSET, registry);
        write_u32(&mut bytes, root + ROOT_OBJECT_VECTOR_OFFSET + 8, 16);
        write_u32(&mut bytes, root + ROOT_OBJECT_VECTOR_OFFSET + 12, 16);
        write_u64(&mut bytes, root + ROOT_OWNER_OFFSET, flash);
        write_u64(&mut bytes, registry, containers[0]);
        write_u64(&mut bytes, registry + 8, containers[1]);

        for (container, children) in containers.into_iter().zip(child_vectors) {
            write_vtables(
                &mut bytes,
                container,
                image + CONTAINER_VTABLE_RVA,
                image + CONTAINER_SECONDARY_VTABLE_RVA,
            );
            write_u64(&mut bytes, container + CHILD_VECTOR_OFFSET, children);
            write_u32(&mut bytes, container + CHILD_VECTOR_OFFSET + 8, 16);
            write_u32(&mut bytes, container + CHILD_VECTOR_OFFSET + 12, 16);
        }
        write_u64(&mut bytes, child_vectors[0], text_objects[2]);
        write_u64(&mut bytes, child_vectors[0] + 8, text_objects[0]);
        write_u64(&mut bytes, child_vectors[1], text_objects[0]);
        write_u64(&mut bytes, child_vectors[1] + 8, text_objects[1]);

        write_text_object(
            &mut bytes,
            image,
            text_objects[0],
            b"ItemName",
            strings[0],
            b"First Reward\0",
        );
        write_text_object(
            &mut bytes,
            image,
            text_objects[1],
            b"ItemName",
            strings[1],
            b"Second Reward\0",
        );
        write_text_object(
            &mut bytes,
            image,
            text_objects[2],
            b"Label",
            strings[2],
            b"Not A Reward\0",
        );

        let memory = ProcessMemory::from_test_bytes(
            &bytes,
            vec![Region {
                start: flash as u64,
                end: bytes.len() as u64,
                permissions: "rw-p".to_owned(),
                path: String::new(),
            }],
        );
        let (values, metrics) =
            scan_named_text(&memory, image, flash as u64, b"ItemName", 160).unwrap();
        assert_eq!(values, ["First Reward", "Second Reward"]);
        assert_eq!(metrics.registered_objects, 2);
        assert_eq!(metrics.containers, 2);
        assert_eq!(metrics.child_objects, 3);
        assert_eq!(metrics.text_objects, 3);
    }

    fn write_text_object(
        bytes: &mut [u8],
        image: u64,
        object: usize,
        name: &[u8],
        text: usize,
        value: &[u8],
    ) {
        write_vtables(
            bytes,
            object,
            image + TEXT_VTABLE_RVA,
            image + TEXT_SECONDARY_VTABLE_RVA,
        );
        bytes[object + TEXT_OBJECT_NAME_OFFSET..object + TEXT_OBJECT_NAME_OFFSET + name.len()]
            .copy_from_slice(name);
        let inner = object + TEXT_OBJECT_INNER_OFFSET;
        write_u32(bytes, inner + 0x20, 1);
        write_u32(bytes, inner + 0x24, 1);
        write_u32(bytes, inner + 0x60, 1);
        write_u32(bytes, inner + 0x64, 1);
        write_u64(bytes, inner + 0xb0, text);
        bytes[text..text + value.len()].copy_from_slice(value);
    }

    fn write_vtables(bytes: &mut [u8], object: usize, primary: u64, secondary: u64) {
        write_u64(bytes, object, primary as usize);
        write_u64(bytes, object + 0x10, secondary as usize);
    }

    fn write_u32(bytes: &mut [u8], offset: usize, value: usize) {
        bytes[offset..offset + 4].copy_from_slice(&(value as u32).to_le_bytes());
    }

    fn write_u64(bytes: &mut [u8], offset: usize, value: usize) {
        bytes[offset..offset + 8].copy_from_slice(&(value as u64).to_le_bytes());
    }
}
