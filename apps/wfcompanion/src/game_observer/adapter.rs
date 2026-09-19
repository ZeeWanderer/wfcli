use serde::Serialize;

use super::ProcessIdentity;

const STORE_MANIFEST_OFFSETS: [u64; 3] = [0x4e0, 0xbd0, 0xf78];

#[derive(Clone, Copy, Debug)]
pub(crate) struct GameAdapter {
    pub(crate) id: &'static str,
    pub(crate) sha256: &'static str,
    pub(crate) metadata: MetadataLayout,
    pub(crate) inventory: InventoryLayout,
    pub(crate) scaleform: ScaleformLayout,
    pub(crate) luau: LuauLayout,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct LuauLayout {
    pub(crate) bytecode_version: u8,
    pub(crate) type_version: u8,
    pub(crate) boolean_bytes: usize,
    pub(crate) opcodes: &'static [LuauOpcode],
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct LuauOpcode {
    pub(crate) raw: u8,
    pub(crate) canonical: u8,
    pub(crate) name: &'static str,
    pub(crate) has_aux: bool,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct MetadataLayout {
    pub(crate) global_registry_rva: u64,
    pub(crate) string_blocks_rva: u64,
    pub(crate) variant_manifest_descriptor_rva: u64,
    pub(crate) weapon_descriptor_rva: u64,
    pub(crate) game_time_rva: u64,
    pub(crate) game_rules_hash: u32,
    pub(crate) store_manifest_offsets: &'static [u64],
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct InventoryLayout {
    pub(crate) profile_hash: u32,
    pub(crate) sync_offset: u64,
    pub(crate) misc_offset: u64,
    pub(crate) recipes_offset: u64,
    pub(crate) pending_offset: u64,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct ScaleformLayout {
    pub(crate) registry_vector_rva: u64,
    pub(crate) flash_instance_type_rva: u64,
    pub(crate) flash_instance_vtable_rva: u64,
    pub(crate) root_vtable_rva: u64,
    pub(crate) root_secondary_vtable_rva: u64,
    pub(crate) container_vtable_rva: u64,
    pub(crate) container_secondary_vtable_rva: u64,
    pub(crate) text_vtable_rva: u64,
    pub(crate) text_secondary_vtable_rva: u64,
}

const CURRENT: GameAdapter = GameAdapter {
    id: "d01b5cb5cff5",
    sha256: "d01b5cb5cff51afc5ffb7d3af051674aafa84000bee764780ff71d9d073cad93",
    metadata: MetadataLayout {
        global_registry_rva: 0x2734d20,
        string_blocks_rva: 0x28a39a0,
        variant_manifest_descriptor_rva: 0x29f3d50,
        weapon_descriptor_rva: 0x297c620,
        game_time_rva: 0x28e13e8,
        game_rules_hash: 0x27816687,
        store_manifest_offsets: &STORE_MANIFEST_OFFSETS,
    },
    inventory: InventoryLayout {
        profile_hash: 0xf05f9824,
        sync_offset: 0xfdc0,
        misc_offset: 0xd6a0,
        recipes_offset: 0xd6b0,
        pending_offset: 0x11ac8,
    },
    scaleform: ScaleformLayout {
        registry_vector_rva: 0x028a_5410,
        flash_instance_type_rva: 0x0294_e130,
        flash_instance_vtable_rva: 0x0222_00f8,
        root_vtable_rva: 0x0222_44b8,
        root_secondary_vtable_rva: 0x0222_4580,
        container_vtable_rva: 0x0222_5588,
        container_secondary_vtable_rva: 0x0222_5878,
        text_vtable_rva: 0x0222_77d8,
        text_secondary_vtable_rva: 0x0222_7ac0,
    },
    luau: LuauLayout {
        bytecode_version: 9,
        type_version: 3,
        boolean_bytes: 4,
        opcodes: &CURRENT_LUAU_OPCODES,
    },
};

pub fn list() -> serde_json::Value {
    serde_json::json!([{
        "id": CURRENT.id, "executable_sha256": CURRENT.sha256,
        "luau": { "bytecode_version": CURRENT.luau.bytecode_version, "type_version": CURRENT.luau.type_version, "atom_bytes": CURRENT.luau.boolean_bytes },
        "domains": ["scaleform", "metadata", "luau"],
    }])
}

// Raw opcode byte to canonical open-source Luau opcode. Measured from this
// executable's VM dispatch table; AUX words are never rewritten.
const CURRENT_LUAU_OPCODES: [LuauOpcode; 67] = [
    luau(0x01, 13, "GETTABLE", false),
    luau(0x02, 8, "SETGLOBAL", true),
    luau(0x04, 3, "LOADB", false),
    luau(0x07, 34, "SUB", false),
    luau(0x09, 41, "MULK", false),
    luau(0x0a, 57, "FORNLOOP", false),
    luau(0x0b, 76, "FORGPREP", false),
    luau(0x0c, 75, "FASTCALL2K", true),
    luau(0x0d, 2, "LOADNIL", false),
    luau(0x0e, 51, "MINUS", false),
    luau(0x10, 68, "FASTCALL", false),
    luau(0x11, 65, "PREPVARARGS", false),
    luau(0x12, 4, "LOADN", false),
    luau(0x13, 9, "GETUPVAL", false),
    luau(0x14, 6, "MOVE", false),
    luau(0x15, 16, "SETTABLEKS", true),
    luau(0x16, 19, "NEWCLOSURE", false),
    luau(0x17, 7, "GETGLOBAL", true),
    luau(0x18, 26, "JUMPIFNOT", false),
    luau(0x19, 73, "FASTCALL1", false),
    luau(0x1a, 36, "DIV", false),
    luau(0x1b, 59, "FORGPREP_INEXT", false),
    luau(0x1c, 32, "JUMPIFNOTLT", true),
    luau(0x1e, 58, "FORGLOOP", true),
    luau(0x20, 79, "JUMPXEQKN", true),
    luau(0x21, 29, "JUMPIFLT", true),
    luau(0x22, 35, "MUL", false),
    luau(0x23, 28, "JUMPIFLE", true),
    luau(0x25, 24, "JUMPBACK", false),
    luau(0x26, 74, "FASTCALL2", true),
    luau(0x27, 30, "JUMPIFNOTEQ", true),
    luau(0x28, 49, "CONCAT", false),
    luau(0x29, 22, "RETURN", false),
    luau(0x2a, 14, "SETTABLE", false),
    luau(0x2b, 46, "OR", false),
    luau(0x2c, 53, "NEWTABLE", true),
    luau(0x2d, 20, "NAMECALL", true),
    luau(0x2e, 18, "SETTABLEN", false),
    luau(0x30, 61, "FORGPREP_NEXT", false),
    luau(0x32, 42, "DIVK", false),
    luau(0x33, 31, "JUMPIFNOTLE", true),
    luau(0x34, 78, "JUMPXEQKB", true),
    luau(0x35, 70, "CAPTURE", false),
    luau(0x37, 27, "JUMPIFEQ", true),
    luau(0x38, 39, "ADDK", false),
    luau(0x39, 11, "CLOSEUPVALS", false),
    luau(0x3a, 77, "JUMPXEQKNIL", true),
    luau(0x3c, 43, "MODK", false),
    luau(0x3d, 15, "GETTABLEKS", true),
    luau(0x3e, 40, "SUBK", false),
    luau(0x3f, 55, "SETLIST", true),
    luau(0x40, 23, "JUMP", false),
    luau(0x41, 80, "JUMPXEQKS", true),
    luau(0x42, 64, "DUPCLOSURE", false),
    luau(0x44, 17, "GETTABLEN", false),
    luau(0x46, 12, "GETIMPORT", true),
    luau(0x47, 56, "FORNPREP", false),
    luau(0x49, 33, "ADD", false),
    luau(0x4b, 25, "JUMPIF", false),
    luau(0x4c, 63, "GETVARARGS", false),
    luau(0x4d, 52, "LENGTH", false),
    luau(0x4e, 5, "LOADK", false),
    luau(0x4f, 54, "DUPTABLE", false),
    luau(0x50, 50, "NOT", false),
    luau(0x51, 48, "ORK", false),
    luau(0x53, 10, "SETUPVAL", false),
    luau(0x54, 21, "CALL", false),
];

const fn luau(raw: u8, canonical: u8, name: &'static str, has_aux: bool) -> LuauOpcode {
    LuauOpcode {
        raw,
        canonical,
        name,
        has_aux,
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum AdapterSupport {
    Supported {
        id: &'static str,
        capabilities: &'static [&'static str],
    },
    Unsupported {
        reason: String,
    },
}

pub(crate) fn resolve(sha256: &str) -> Option<&'static GameAdapter> {
    (sha256 == CURRENT.sha256).then_some(&CURRENT)
}

pub(crate) fn resolve_key(key: &str) -> Option<&'static GameAdapter> {
    (key == CURRENT.id || key == CURRENT.sha256).then_some(&CURRENT)
}

pub(crate) fn require(identity: &ProcessIdentity) -> Result<&'static GameAdapter, String> {
    resolve(&identity.executable.sha256).ok_or_else(|| {
        format!(
            "unsupported Warframe executable {}",
            identity.executable.sha256
        )
    })
}

pub fn support(identity: Option<&ProcessIdentity>) -> AdapterSupport {
    match identity {
        Some(identity) => match resolve(&identity.executable.sha256) {
            Some(adapter) => AdapterSupport::Supported {
                id: adapter.id,
                capabilities: &["game_metadata_v2", "scaleform_ui_v1", "warframe_luau_v1"],
            },
            None => AdapterSupport::Unsupported {
                reason: format!(
                    "unsupported Warframe executable {}",
                    identity.executable.sha256
                ),
            },
        },
        None => AdapterSupport::Unsupported {
            reason: "capture has no executable identity".to_owned(),
        },
    }
}

pub(crate) fn unsupported_reason(identity: Option<&ProcessIdentity>) -> Option<String> {
    match support(identity) {
        AdapterSupport::Supported { .. } => None,
        AdapterSupport::Unsupported { reason } => Some(reason),
    }
}

#[cfg(test)]
pub(crate) fn test_scaleform() -> ScaleformLayout {
    CURRENT.scaleform
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::game_observer::ExecutableIdentity;
    use std::path::PathBuf;

    #[test]
    fn resolves_only_exact_executable_identity() {
        let identity = ProcessIdentity {
            pid: 1,
            executable: ExecutableIdentity {
                path: PathBuf::from("Warframe.x64.exe"),
                size: 1,
                modified_unix_ms: None,
                sha256: CURRENT.sha256.to_owned(),
            },
        };
        assert_eq!(require(&identity).unwrap().id, CURRENT.id);

        let mut unknown = identity;
        unknown.executable.sha256 = "unknown".to_owned();
        assert!(require(&unknown).is_err());
    }
}
