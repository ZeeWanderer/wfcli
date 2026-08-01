use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;

const RECORD_HEADER_SIZE: usize = 8;
const MAX_MESSAGE_SIZE: usize = 4092;
const RUNTIME_ENVIRONMENT: &[&str] = &[
    "LD_LIBRARY_PATH",
    "PATH",
    "WINEDLLPATH",
    "WINEESYNC",
    "WINEFSYNC",
    "WINELOADER",
    "WINENTSYNC",
    "WINESERVER",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Runtime {
    game_pid: u32,
    prefix: PathBuf,
    wine: PathBuf,
    environment: BTreeMap<String, String>,
}

impl Runtime {
    pub(crate) fn discover(
        game_pid: u32,
        process_dir: &Path,
        environment: &BTreeMap<String, String>,
        compat_data: &Path,
    ) -> Option<Self> {
        let prefix = if compat_data.file_name().is_some_and(|name| name == "pfx") {
            compat_data.to_owned()
        } else {
            compat_data.join("pfx")
        };
        let wine = wine_candidates(process_dir, environment)
            .into_iter()
            .find(|path| path.is_file())?;
        Some(Self {
            game_pid,
            prefix,
            wine,
            environment: environment.clone(),
        })
    }

    pub(crate) fn game_pid(&self) -> u32 {
        self.game_pid
    }

    pub(crate) fn prefix(&self) -> &Path {
        &self.prefix
    }

    pub(crate) fn helper_command(&self, helper: &Path) -> Command {
        let mut command = Command::new(&self.wine);
        command
            .arg(helper)
            .env("WINEPREFIX", &self.prefix)
            .env("WINEDEBUG", "-all")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        for key in RUNTIME_ENVIRONMENT {
            if let Some(value) = self.environment.get(*key) {
                command.env(key, value);
            }
        }
        command
    }
}

#[derive(Debug)]
pub(crate) enum Event {
    Record {
        game_pid: u32,
        sender_pid: u32,
        message: String,
    },
    Stopped {
        game_pid: u32,
        reason: String,
    },
}

pub(crate) struct Bridge {
    game_pid: u32,
    child: Child,
}

impl Bridge {
    pub(crate) fn start(runtime: &Runtime, events: mpsc::Sender<Event>) -> Result<Self, String> {
        let helper = helper_path().ok_or_else(|| {
            "wfcompanion DBWIN helper not found; rebuild companion with make companion".to_owned()
        })?;
        let mut command = runtime.helper_command(&helper);
        let mut child = command
            .spawn()
            .map_err(|error| format!("could not start Proton DBWIN helper: {error}"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "DBWIN helper stdout was not piped".to_owned())?;
        let game_pid = runtime.game_pid;
        thread::spawn(move || {
            let mut input = io::BufReader::new(stdout);
            loop {
                match read_record(&mut input) {
                    Ok(Some((sender_pid, message))) => {
                        if events
                            .send(Event::Record {
                                game_pid,
                                sender_pid,
                                message,
                            })
                            .is_err()
                        {
                            return;
                        }
                    }
                    Ok(None) => {
                        let _ = events.send(Event::Stopped {
                            game_pid,
                            reason: "DBWIN helper closed its output".to_owned(),
                        });
                        return;
                    }
                    Err(error) => {
                        let _ = events.send(Event::Stopped {
                            game_pid,
                            reason: format!("DBWIN helper protocol failed: {error}"),
                        });
                        return;
                    }
                }
            }
        });
        Ok(Self { game_pid, child })
    }

    pub(crate) fn game_pid(&self) -> u32 {
        self.game_pid
    }

    pub(crate) fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn read_record(input: &mut impl Read) -> io::Result<Option<(u32, String)>> {
    let mut header = [0_u8; RECORD_HEADER_SIZE];
    match input.read_exact(&mut header) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let sender_pid = u32::from_le_bytes(header[0..4].try_into().unwrap());
    let length = u32::from_le_bytes(header[4..8].try_into().unwrap()) as usize;
    if length > MAX_MESSAGE_SIZE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("message length {length} exceeds {MAX_MESSAGE_SIZE}"),
        ));
    }
    let mut message = vec![0_u8; length];
    input.read_exact(&mut message)?;
    Ok(Some((
        sender_pid,
        String::from_utf8_lossy(&message).into_owned(),
    )))
}

fn helper_path() -> Option<PathBuf> {
    helper_candidates(
        std::env::var_os("WFCOMPANION_DEBUG_BRIDGE"),
        std::env::current_exe().ok().as_deref(),
        option_env!("WFCOMPANION_BUILD_DEBUG_BRIDGE"),
    )
    .into_iter()
    .find(|path| path.is_file())
}

fn helper_candidates(
    configured: Option<OsString>,
    current_exe: Option<&Path>,
    build_path: Option<&str>,
) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(configured) = configured.filter(|path| !path.is_empty()) {
        candidates.push(PathBuf::from(configured));
    }
    if let Some(bin_dir) = current_exe.and_then(Path::parent) {
        candidates.push(bin_dir.join("../libexec/wfcompanion-debug-output.exe"));
    }
    if let Some(build_path) = build_path.filter(|path| !path.is_empty()) {
        candidates.push(PathBuf::from(build_path));
    }
    candidates
}

fn wine_candidates(process_dir: &Path, environment: &BTreeMap<String, String>) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(loader) = environment.get("WINELOADER") {
        push_unique(&mut candidates, PathBuf::from(loader));
    }
    if let Some(tool_paths) = environment.get("STEAM_COMPAT_TOOL_PATHS") {
        for tool in tool_paths.split(':').filter(|path| !path.is_empty()) {
            push_unique(
                &mut candidates,
                PathBuf::from(tool).join("files/bin/wine64"),
            );
        }
    }
    if let Ok(executable) = fs::read_link(process_dir.join("exe")) {
        if executable
            .file_name()
            .is_some_and(|name| name == "wine64-preloader")
        {
            push_unique(&mut candidates, executable.with_file_name("wine64"));
        }
        push_unique(&mut candidates, executable);
    }
    if let Ok(maps) = fs::read_to_string(process_dir.join("maps")) {
        for path in maps
            .lines()
            .filter_map(|line| line.split_whitespace().last())
        {
            if path.ends_with("/files/bin/wine64") {
                push_unique(&mut candidates, PathBuf::from(path));
            }
        }
    }
    candidates
}

fn push_unique(paths: &mut Vec<PathBuf>, path: PathBuf) {
    if !path.as_os_str().is_empty() && !paths.contains(&path) {
        paths.push(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn decodes_bridge_record() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&42_u32.to_le_bytes());
        bytes.extend_from_slice(&11_u32.to_le_bytes());
        bytes.extend_from_slice(b"Got rewards");
        assert_eq!(
            read_record(&mut Cursor::new(bytes)).unwrap(),
            Some((42, "Got rewards".to_owned()))
        );
    }

    #[test]
    fn rejects_oversized_bridge_record() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&42_u32.to_le_bytes());
        bytes.extend_from_slice(&5000_u32.to_le_bytes());
        assert_eq!(
            read_record(&mut Cursor::new(bytes)).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn finds_proton_wine_from_tool_path() {
        let environment = BTreeMap::from([(
            "STEAM_COMPAT_TOOL_PATHS".to_owned(),
            "/steam/Proton 10.0:/steam/runtime".to_owned(),
        )]);
        assert_eq!(
            wine_candidates(Path::new("/missing"), &environment)[0],
            PathBuf::from("/steam/Proton 10.0/files/bin/wine64")
        );
    }

    #[test]
    fn packaged_helper_precedes_build_fallback() {
        assert_eq!(
            helper_candidates(
                None,
                Some(Path::new("/package/bin/wfcompanion")),
                Some("/repo/prod/libexec/helper.exe"),
            ),
            vec![
                PathBuf::from("/package/bin/../libexec/wfcompanion-debug-output.exe"),
                PathBuf::from("/repo/prod/libexec/helper.exe"),
            ]
        );
    }
}
