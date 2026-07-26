use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_LOG_BYTES: u64 = 1024 * 1024;
const DUPLICATE_WINDOW: Duration = Duration::from_secs(60);

struct State {
    recent: BTreeMap<String, SystemTime>,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

pub(crate) fn info(event: &str, message: impl AsRef<str>) {
    write("info", event, message.as_ref());
}

pub(crate) fn warn(event: &str, message: impl AsRef<str>) {
    write("warn", event, message.as_ref());
}

pub(crate) fn error(event: &str, message: impl AsRef<str>) {
    write("error", event, message.as_ref());
}

pub(crate) fn log_path() -> PathBuf {
    if let Some(path) = std::env::var_os("WFCOMPANION_LOG") {
        return PathBuf::from(path);
    }
    let state = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .unwrap_or_else(|| PathBuf::from("."));
    state.join("wfcli/wfcompanion.log")
}

pub(crate) fn print_recent(limit: usize) -> Result<(), String> {
    let path = log_path();
    println!("{}", path.display());
    if !path.exists() {
        return Ok(());
    }
    let mut contents = String::new();
    fs::File::open(&path)
        .and_then(|mut file| file.read_to_string(&mut contents))
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    for line in tail_lines(&contents, limit) {
        println!("{line}");
    }
    Ok(())
}

fn write(level: &str, event: &str, message: &str) {
    let now = SystemTime::now();
    let key = format!("{level}\0{event}\0{message}");
    let state = STATE.get_or_init(|| {
        Mutex::new(State {
            recent: BTreeMap::new(),
        })
    });
    let Ok(mut state) = state.lock() else {
        return;
    };
    state.recent.retain(|_, timestamp| {
        now.duration_since(*timestamp).unwrap_or_default() < DUPLICATE_WINDOW
    });
    if state.recent.contains_key(&key) {
        return;
    }
    state.recent.insert(key, now);

    let path = log_path();
    if let Some(parent) = path.parent()
        && fs::create_dir_all(parent).is_err()
    {
        return;
    }
    rotate_if_needed(&path);
    let timestamp_ms = now
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let line = serde_json::json!({
        "timestamp_ms": timestamp_ms,
        "pid": std::process::id(),
        "level": level,
        "event": event,
        "message": message,
    });
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{line}");
    }
}

fn rotate_if_needed(path: &Path) {
    let Ok(metadata) = fs::metadata(path) else {
        return;
    };
    if metadata.len() < MAX_LOG_BYTES {
        return;
    }
    let rotated = path.with_extension("log.1");
    let _ = fs::remove_file(&rotated);
    let _ = fs::rename(path, rotated);
}

fn tail_lines(contents: &str, limit: usize) -> Vec<&str> {
    let lines: Vec<_> = contents.lines().collect();
    let start = lines.len().saturating_sub(limit);
    lines[start..].to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tail_is_bounded() {
        assert_eq!(tail_lines("one\ntwo\nthree\n", 2), vec!["two", "three"]);
        assert_eq!(tail_lines("one\n", 2), vec!["one"]);
    }

    #[test]
    fn rotation_path_keeps_log_suffix() {
        assert_eq!(
            Path::new("/tmp/wfcompanion.log").with_extension("log.1"),
            Path::new("/tmp/wfcompanion.log.1")
        );
    }
}
