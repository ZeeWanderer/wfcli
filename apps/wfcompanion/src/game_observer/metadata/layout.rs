use std::path::Path;

use pelite::pattern;
use pelite::pe64::{Pe, PeFile};
use serde::Serialize;
use sha2::{Digest, Sha256};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub(super) struct MetadataLayout {
    pub(super) global_registry_rva: u64,
    pub(super) string_blocks_rva: u64,
    pub(super) store_manifest_descriptor_rva: u64,
    pub(super) variant_manifest_descriptor_rva: u64,
    pub(super) weapon_descriptor_rva: u64,
    pub(super) game_time_rva: u64,
    pub(super) game_rules_hash: u32,
}

const GLOBAL_REGISTRY: &str = r#"
    48 8d 15 ${ "Setting gGameRules" 0a 00 }
    48 8b c8 e8 ????
    e8 ${ [0-96] 48 8d 05 ${'} 48 83 c4 28 c3 }
    [0-12] 41 b8 u4 48 8b c8 e8 ????
"#;
const STRING_BLOCKS: &str = "
    44 8b 01 48 8b da 48 8b 05 ${'}
    41 0f b7 c8 48 03 c9 49 c1 e8 10 48 8b 0c c8 49 03 c8 48 89 0a
";
const ELIGIBILITY: &str = "
    48 8b 81 e0 00 00 00 f2 0f 10 0d ${'}
    48 85 c0 74 0e 0f 57 c0 f2 48 0f 2a c0 66 0f 2f c1 77 1a
    48 8b 81 e8 00 00 00 48 85 c0 74 11
    0f 57 c0 f2 48 0f 2a c0 66 0f 2f c1 73 03 32 c0 c3
    0f b6 81 5c 01 00 00 c0 e8 05 24 01 c3
";

pub(super) fn read(path: &Path) -> Result<(String, MetadataLayout), String> {
    let bytes = std::fs::read(path)
        .map_err(|error| format!("could not read Warframe executable: {error}"))?;
    let hash = format!("{:x}", Sha256::digest(&bytes));
    let layout = discover(&bytes)
        .map_err(|reason| format!("unsupported Warframe executable {hash} ({reason})"))?;
    Ok((hash, layout))
}

fn discover(bytes: &[u8]) -> Result<MetadataLayout, String> {
    let image = PeFile::from_bytes(bytes).map_err(|error| format!("invalid PE: {error}"))?;
    let registry = signature::<3>(image, "game registry", GLOBAL_REGISTRY)?;
    let strings = signature::<2>(image, "string blocks", STRING_BLOCKS)?;
    let eligibility = signature::<2>(image, "StoreItem eligibility", ELIGIBILITY)?;
    let layout = MetadataLayout {
        global_registry_rva: registry[1].into(),
        game_rules_hash: registry[2],
        string_blocks_rva: strings[1].into(),
        game_time_rva: eligibility[1].into(),
        store_manifest_descriptor_rva: descriptor(image, "StoreManifest", "/Lotus/Types/Game/")?,
        variant_manifest_descriptor_rva: descriptor(
            image,
            "VariantManifest",
            "/Lotus/Types/Game/Store/",
        )?,
        weapon_descriptor_rva: descriptor(image, "LotusWeapon", "/Lotus/Types/Game/")?,
    };
    for (rva, size) in [
        (layout.global_registry_rva, 0x148),
        (layout.string_blocks_rva, 8),
        (layout.game_time_rva, 8),
        (layout.store_manifest_descriptor_rva, 0x30),
        (layout.variant_manifest_descriptor_rva, 0x30),
        (layout.weapon_descriptor_rva, 0x30),
    ] {
        let valid = image.section_headers().iter().any(|section| {
            section.Characteristics & 0xa000_0000 == 0x8000_0000
                && rva >= u64::from(section.VirtualAddress)
                && rva + size <= u64::from(section.VirtualAddress) + u64::from(section.VirtualSize)
        });
        if !valid {
            return Err(format!(
                "metadata binding 0x{rva:x} is outside writable image data"
            ));
        }
    }
    Ok(layout)
}

fn descriptor(image: PeFile<'_>, name: &str, parent: &str) -> Result<u64, String> {
    let pattern = format!(
        r#"
        48 8d 15 ${{ "{name}" 00 }}
        48 8d 4c 24 50 e8 ???? 48 8d 15 ${{ "{parent}" 00 }}
        48 8d 4c 24 58 8b 18 e8 ????
        [0-40] 44 8b c3 8b 10 48 8d 0d ${{'}} c6 44 24 20 00 e8 ????
    "#
    );
    Ok(signature::<2>(image, name, &pattern)?[1].into())
}

fn signature<const N: usize>(
    image: PeFile<'_>,
    label: &str,
    source: &str,
) -> Result<[u32; N], String> {
    let pattern = pattern::parse(source).map_err(|error| format!("{label} pattern: {error}"))?;
    let scanner = image.scanner();
    let mut matches = scanner.matches_code(&pattern);
    let mut first = [0; N];
    if !matches.next(&mut first) {
        return Err(format!("{label} signature not found"));
    }
    let mut next = [0; N];
    while matches.next(&mut next) {
        if next[1..] != first[1..] {
            return Err(format!("ambiguous {label} signature"));
        }
    }
    Ok(first)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put32(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    fn emit(bytes: &mut [u8], offset: usize, hex: &str) {
        for (index, byte) in hex.split_whitespace().enumerate() {
            bytes[offset + index] = u8::from_str_radix(byte, 16).unwrap();
        }
    }

    fn relative(bytes: &mut [u8], offset: usize, target: usize) {
        put32(bytes, offset, (target as i32 - offset as i32 - 4) as u32);
    }

    fn fixture(shift: usize, hash: u32) -> Vec<u8> {
        // Minimal PE with independent code, read-only strings and writable bindings.
        let mut bytes = vec![0; 0x4000];
        emit(&mut bytes, 0, "4d 5a");
        put32(&mut bytes, 0x3c, 0x80);
        emit(&mut bytes, 0x80, "50 45 00 00 64 86 03 00");
        emit(&mut bytes, 0x94, "f0 00 00 00 0b 02");
        put32(&mut bytes, 0x9c, 0x1000);
        put32(&mut bytes, 0xac, 0x1000);
        put32(&mut bytes, 0xd0, 0x4000);
        put32(&mut bytes, 0xd4, 0x1000);
        for (index, flags) in [0x6000_0020, 0x4000_0040, 0xc000_0040]
            .into_iter()
            .enumerate()
        {
            let header = 0x188 + index * 40;
            let address = (index as u32 + 1) * 0x1000;
            for (offset, value) in [
                (8, 0x1000),
                (12, address),
                (16, 0x1000),
                (20, address),
                (36, flags),
            ] {
                put32(&mut bytes, header + offset, value);
            }
        }
        for (address, text) in [
            (0x2000, "Setting gGameRules\n"),
            (0x2020, "StoreManifest"),
            (0x2040, "VariantManifest"),
            (0x2060, "LotusWeapon"),
            (0x2080, "/Lotus/Types/Game/"),
            (0x20a0, "/Lotus/Types/Game/Store/"),
        ] {
            bytes[address..address + text.len()].copy_from_slice(text.as_bytes());
        }
        let code = 0x1000 + shift;
        emit(
            &mut bytes,
            code,
            "48 8d 15 00 00 00 00 48 8b c8 e8 00 00 00 00 e8 00 00 00 00
              48 8d 55 00 41 b8 00 00 00 00 48 8b c8 e8 00 00 00 00",
        );
        relative(&mut bytes, code + 3, 0x2000);
        relative(&mut bytes, code + 16, code + 0x100);
        put32(&mut bytes, code + 26, hash);
        emit(
            &mut bytes,
            code + 0x100,
            "48 83 ec 28 48 8d 05 00 00 00 00 48 83 c4 28 c3",
        );
        relative(&mut bytes, code + 0x107, 0x3000 + shift);
        emit(
            &mut bytes,
            code + 0x200,
            "44 8b 01 48 8b da 48 8b 05 00 00 00 00 41 0f b7 c8 48 03 c9
              49 c1 e8 10 48 8b 0c c8 49 03 c8 48 89 0a",
        );
        relative(&mut bytes, code + 0x209, 0x3200 + shift);
        emit(
            &mut bytes,
            code + 0x300,
            "48 8b 81 e0 00 00 00 f2 0f 10 0d 00 00 00 00
              48 85 c0 74 0e 0f 57 c0 f2 48 0f 2a c0 66 0f 2f c1 77 1a
              48 8b 81 e8 00 00 00 48 85 c0 74 11
              0f 57 c0 f2 48 0f 2a c0 66 0f 2f c1 73 03 32 c0 c3
              0f b6 81 5c 01 00 00 c0 e8 05 24 01 c3",
        );
        relative(&mut bytes, code + 0x30b, 0x3210 + shift);
        for (index, name, parent) in [
            (0, 0x2020, 0x2080),
            (1, 0x2040, 0x20a0),
            (2, 0x2060, 0x2080),
        ] {
            let start = code + 0x400 + index * 0x100;
            emit(
                &mut bytes,
                start,
                "48 8d 15 00 00 00 00 48 8d 4c 24 50 e8 00 00 00 00
                  48 8d 15 00 00 00 00 48 8d 4c 24 58 8b 18 e8 00 00 00 00
                  44 8b c3 8b 10 48 8d 0d 00 00 00 00 c6 44 24 20 00 e8 00 00 00 00",
            );
            relative(&mut bytes, start + 3, name);
            relative(&mut bytes, start + 20, parent);
            relative(&mut bytes, start + 44, 0x3300 + shift + index * 0x100);
        }
        bytes
    }

    #[test]
    fn discovers_relocated_bindings_and_changed_atom_hashes() {
        for (shift, hash) in [(0, 0x27816687), (0x80, 0xd7e3ec85)] {
            assert_eq!(
                discover(&fixture(shift, hash)).unwrap(),
                MetadataLayout {
                    global_registry_rva: 0x3000 + shift as u64,
                    string_blocks_rva: 0x3200 + shift as u64,
                    store_manifest_descriptor_rva: 0x3300 + shift as u64,
                    variant_manifest_descriptor_rva: 0x3400 + shift as u64,
                    weapon_descriptor_rva: 0x3500 + shift as u64,
                    game_time_rva: 0x3210 + shift as u64,
                    game_rules_hash: hash,
                }
            );
        }
    }

    #[test]
    fn accepts_repeated_bindings_but_rejects_conflicting_ones() {
        let mut bytes = fixture(0, 1);
        bytes.copy_within(0x1200..0x1222, 0x1800);
        relative(&mut bytes, 0x1809, 0x3200);
        assert!(discover(&bytes).is_ok());
        relative(&mut bytes, 0x1809, 0x3210);
        assert_eq!(
            discover(&bytes).unwrap_err(),
            "ambiguous string blocks signature"
        );
    }

    #[test]
    fn refuses_missing_anchors_changed_layout_and_non_data_bindings() {
        let original = fixture(0, 1);
        let mut bytes = original.clone();
        bytes[0x2000] = b'X';
        assert_eq!(
            discover(&bytes).unwrap_err(),
            "game registry signature not found"
        );
        bytes = original.clone();
        bytes[0x1303] = 0xf0;
        assert_eq!(
            discover(&bytes).unwrap_err(),
            "StoreItem eligibility signature not found"
        );
        bytes = original;
        relative(&mut bytes, 0x1209, 0x1000);
        assert!(
            discover(&bytes)
                .unwrap_err()
                .contains("outside writable image data")
        );
        assert!(
            discover(b"not an executable")
                .unwrap_err()
                .starts_with("invalid PE:")
        );
    }
}
