use std::fs;
use std::path::PathBuf;

pub(crate) const APP_ID: &str = "io.github.zeewanderer.wfcompanion";

const DESKTOP_ENTRY: &str = "\
[Desktop Entry]
Type=Application
Name=wfcompanion
Comment=Warframe overlay companion
Exec=wfcompanion
Terminal=false
NoDisplay=true
Categories=Game;Utility;
";

pub(crate) fn ensure_identity() -> Result<PathBuf, String> {
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .ok_or_else(|| "HOME and XDG_DATA_HOME are unset".to_owned())?;
    let path = data_home
        .join("applications")
        .join(format!("{APP_ID}.desktop"));
    if fs::read_to_string(&path).is_ok_and(|current| current == DESKTOP_ENTRY) {
        return Ok(path);
    }
    let parent = path
        .parent()
        .ok_or_else(|| format!("invalid desktop entry path: {}", path.display()))?;
    fs::create_dir_all(parent).map_err(|error| format!("create {}: {error}", parent.display()))?;
    let temporary = path.with_extension(format!("desktop.{}.tmp", std::process::id()));
    fs::write(&temporary, DESKTOP_ENTRY)
        .map_err(|error| format!("write {}: {error}", temporary.display()))?;
    fs::rename(&temporary, &path)
        .map_err(|error| format!("install {}: {error}", path.display()))?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_identity_matches_portal_app_id() {
        assert!(DESKTOP_ENTRY.contains("NoDisplay=true"));
        assert!(APP_ID.contains('.'));
        assert_eq!(
            format!("{APP_ID}.desktop"),
            "io.github.zeewanderer.wfcompanion.desktop"
        );
    }
}
