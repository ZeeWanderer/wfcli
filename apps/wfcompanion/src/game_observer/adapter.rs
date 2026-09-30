use serde::Serialize;

use super::ProcessIdentity;

#[derive(Clone, Copy, Debug)]
pub(crate) struct GameAdapter {
    pub(crate) id: &'static str,
    pub(crate) sha256: &'static str,
    pub(crate) global_registry_rva: u64,
    pub(crate) string_blocks_rva: u64,
    pub(crate) inventory: InventoryLayout,
    pub(crate) scaleform: ScaleformLayout,
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
    global_registry_rva: 0x2734d20,
    string_blocks_rva: 0x28a39a0,
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
};

pub fn list() -> serde_json::Value {
    serde_json::json!([{
        "id": CURRENT.id, "executable_sha256": CURRENT.sha256,
        "domains": ["scaleform", "inventory"],
    }])
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
                capabilities: &["native_inventory_v1", "scaleform_ui_v1"],
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
