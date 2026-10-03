use std::ffi::CString;
use std::fs::File;
use std::io::{Read, Seek};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use rustix::fs::{MemfdFlags, SealFlags, fcntl_add_seals, fcntl_get_seals, memfd_create};
use rustix::io::{FdFlags, fcntl_setfd};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::game::ChildIdentity;
use crate::{daemon, incident, inventory};

const ENABLE: &str = "WFCOMPANION_DEV_RELOAD";
const HANDOFF: &str = "WFCOMPANION_RELOAD_FD";
const SCHEMA: u32 = 1;
pub(crate) const READY: &str = "wfcompanion-reload/1\n";
const MAX_BYTES: u64 = 40 * 1024 * 1024;
const SEALS: SealFlags = SealFlags::SEAL
    .union(SealFlags::WRITE)
    .union(SealFlags::GROW)
    .union(SealFlags::SHRINK);

#[derive(Clone, Default, Serialize, Deserialize)]
pub(super) struct State {
    pub inventory: Option<inventory::Checkpoint>,
    pub publications: daemon::Replay,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Handoff {
    schema: u32,
    owner: u32,
    pub(super) installed: PathBuf,
    pub(super) child: Option<ChildIdentity>,
    pub(super) state: State,
}

impl Handoff {
    pub(super) fn new(installed: PathBuf, child: Option<ChildIdentity>, state: State) -> Self {
        Self {
            schema: SCHEMA,
            owner: std::process::id(),
            installed,
            child,
            state,
        }
    }

    fn validate(&self, owner: u32) -> Result<(), String> {
        if self.schema != SCHEMA || self.owner != owner || !self.installed.is_absolute() {
            return Err("incompatible development reload handoff".into());
        }
        self.state.publications.validate()?;
        if let Some(child) = &self.child {
            child.validate(owner)?;
        }
        Ok(())
    }

    fn file(&self) -> Result<File, String> {
        let fd = memfd_create(
            "wfcompanion-reload",
            MemfdFlags::CLOEXEC | MemfdFlags::ALLOW_SEALING,
        )
        .map_err(|error| error.to_string())?;
        let mut file = File::from(fd);
        serde_json::to_writer(&mut file, self).map_err(|error| error.to_string())?;
        if file.metadata().map_err(|error| error.to_string())?.len() > MAX_BYTES {
            return Err("development reload handoff is too large".into());
        }
        file.rewind().map_err(|error| error.to_string())?;
        fcntl_add_seals(&file, SEALS).map_err(|error| error.to_string())?;
        Ok(file)
    }
}

pub(super) fn enabled() -> Result<bool, String> {
    enabled_for_build(cfg!(debug_assertions), std::env::var(ENABLE))
}

fn enabled_for_build(
    debug: bool,
    value: Result<String, std::env::VarError>,
) -> Result<bool, String> {
    match value.as_deref() {
        Err(std::env::VarError::NotPresent) => Ok(debug),
        Ok("0") => Ok(false),
        Ok("1") if debug => Ok(true),
        Ok("1") => Err(format!("{ENABLE} requires a development build")),
        _ => Err(format!("{ENABLE} must be 0 or 1")),
    }
}

fn decode(reader: impl Read, owner: u32) -> Result<Handoff, String> {
    let mut bytes = Vec::new();
    reader
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| error.to_string())?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err("development reload handoff is too large".into());
    }
    let handoff: Handoff = serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    handoff.validate(owner)?;
    Ok(handoff)
}

pub(crate) fn resume() -> Result<Option<Handoff>, String> {
    let Some(raw) = std::env::var_os(HANDOFF) else {
        return Ok(None);
    };
    if !enabled()? {
        return Err("development reload handoff without reload enabled".into());
    }
    let fd: i32 = raw
        .to_str()
        .and_then(|value| value.parse().ok())
        .filter(|fd| *fd > 2)
        .ok_or("invalid reload descriptor")?;
    let file = File::open(format!("/proc/self/fd/{fd}")).map_err(|error| error.to_string())?;
    if !fcntl_get_seals(&file)
        .map_err(|error| error.to_string())?
        .contains(SEALS)
    {
        return Err("reload descriptor is not a sealed handoff".into());
    }
    // Startup is single-threaded; opening the proc descriptor validated ownership.
    drop(unsafe { File::from_raw_fd(fd) });
    // Do not propagate a consumed descriptor to helpers or a newly started daemon.
    unsafe {
        std::env::remove_var(HANDOFF);
    }
    decode(file, std::process::id()).map(Some)
}

pub(crate) fn check() -> Result<(), String> {
    if !cfg!(debug_assertions) {
        return Err("replacement is not a development build".into());
    }
    let owner = rustix::process::getppid()
        .ok_or("reload parent disappeared")?
        .as_raw_nonzero()
        .get() as u32;
    decode(std::io::stdin().lock(), owner).map(|_| ())
}

#[derive(Clone, Default)]
pub(crate) struct Gate(Arc<GateState>);

#[derive(Default)]
struct GateState {
    requested: AtomicBool,
    approved: AtomicBool,
    interactive: AtomicBool,
}

impl Gate {
    pub(crate) fn request(&self) {
        self.0.requested.store(true, Ordering::Release);
    }

    pub(crate) fn pending(&self) -> bool {
        cfg!(debug_assertions) && self.0.requested.load(Ordering::Acquire)
    }

    pub(crate) fn interaction(&self, active: bool) {
        self.0.interactive.store(active, Ordering::Release);
    }

    pub(crate) fn quiesce_if_idle(&self, idle: bool, stopping: &AtomicBool) -> bool {
        if idle
            && self.pending()
            && !self.0.interactive.load(Ordering::Acquire)
            && !stopping.load(Ordering::Acquire)
        {
            self.0.approved.store(true, Ordering::Release);
            stopping.store(true, Ordering::Release);
            return true;
        }
        false
    }

    pub(super) fn approved(&self) -> bool {
        self.0.approved.load(Ordering::Acquire)
    }
}

pub(super) struct Watch {
    worker: Option<JoinHandle<Result<Option<Candidate>, String>>>,
    cancel: Arc<AtomicBool>,
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct Stamp {
    device: u64,
    inode: u64,
    length: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}

impl Watch {
    pub(super) fn start(
        installed: PathBuf,
        gate: Gate,
        stopping: Arc<AtomicBool>,
        rejected: Option<Stamp>,
    ) -> Result<Self, String> {
        let cancel = Arc::new(AtomicBool::new(false));
        if !enabled()? {
            return Ok(Self {
                worker: None,
                cancel,
            });
        }
        let cancelled = cancel.clone();
        let worker = thread::Builder::new()
            .name("wfcompanion-reload".into())
            .spawn(move || {
                let mut running =
                    File::open("/proc/self/exe").map_err(|error| error.to_string())?;
                let own_hash = digest(&mut running)?;
                let running_stamp = stamp(&running)?;
                let mut previous = running_stamp;
                incident::info("reload.watching", installed.display().to_string());
                while !stopping.load(Ordering::Acquire) && !cancelled.load(Ordering::Acquire) {
                    if let Ok(mut file) = File::open(&installed) {
                        let current = stamp(&file)?;
                        if current != previous {
                            let hash = digest(&mut file)?;
                            previous = current;
                            let candidate = Candidate {
                                file,
                                hash,
                                stamp: current,
                            };
                            if let Some(reason) = candidate.change_reason(running_stamp, own_hash)
                                && Some(current) != rejected
                            {
                                incident::info(
                                    "reload.pending",
                                    format!("{reason}; waiting for idle services"),
                                );
                                gate.request();
                                return Ok(Some(candidate));
                            }
                        }
                    }
                    for _ in 0..10 {
                        if stopping.load(Ordering::Acquire) || cancelled.load(Ordering::Acquire) {
                            break;
                        }
                        thread::sleep(Duration::from_millis(100));
                    }
                }
                Ok(None)
            })
            .map_err(|error| format!("reload watcher: {error}"))?;
        Ok(Self {
            worker: Some(worker),
            cancel,
        })
    }

    pub(super) fn finish(&mut self) -> Result<Option<Candidate>, String> {
        self.cancel.store(true, Ordering::Release);
        match self.worker.take() {
            Some(worker) => worker.join().map_err(|_| "reload watcher panicked")?,
            None => Ok(None),
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        if let Err(error) = self.finish() {
            incident::warn("reload.watch_failed", error);
        }
    }
}

pub(super) struct Candidate {
    file: File,
    hash: [u8; 32],
    pub stamp: Stamp,
}

impl Candidate {
    fn change_reason(&self, running: Stamp, own_hash: [u8; 32]) -> Option<&'static str> {
        if self.hash != own_hash {
            Some("code changed")
        } else if (self.stamp.device, self.stamp.inode) != (running.device, running.inode) {
            Some("installed identity changed")
        } else {
            None
        }
    }

    pub(super) fn replace(
        &self,
        handoff: &Handoff,
        active: impl Fn() -> bool,
    ) -> Result<(), String> {
        let mut state = handoff.file()?;
        let path = format!("/proc/{}/fd/{}", std::process::id(), self.file.as_raw_fd());
        let mut probe = Command::new(&path);
        probe.arg("--reload-check").env_remove(HANDOFF);
        let result = super::process::output_with_stdin(
            probe,
            Stdio::from(state.try_clone().map_err(|error| error.to_string())?),
            Duration::from_secs(5),
            &active,
        )?;
        if !result.status.success() || result.stdout != READY.as_bytes() || !active() {
            return Err(
                "replacement rejected the reload handoff or validation was cancelled".into(),
            );
        }
        let mut installed = File::open(&handoff.installed).map_err(|error| error.to_string())?;
        if stamp(&installed)? != self.stamp || digest(&mut installed)? != self.hash {
            return Err("replacement changed during reload validation".into());
        }
        state.rewind().map_err(|error| error.to_string())?;
        self.exec(&state)
    }

    fn exec(&self, state: &File) -> Result<(), String> {
        let args: Vec<_> = std::env::args_os()
            .map(|arg| CString::new(arg.as_bytes()))
            .collect::<Result<_, _>>()
            .map_err(|error| error.to_string())?;
        let mut environment: Vec<_> = std::env::vars_os()
            .filter(|(key, _)| key != HANDOFF)
            .map(|(key, value)| {
                let mut entry = key.as_bytes().to_vec();
                entry.push(b'=');
                entry.extend_from_slice(value.as_bytes());
                CString::new(entry)
            })
            .collect::<Result<_, _>>()
            .map_err(|error| error.to_string())?;
        environment.push(CString::new(format!("{HANDOFF}={}", state.as_raw_fd())).unwrap());
        let pointers = |strings: &[CString]| {
            strings
                .iter()
                .map(|value| value.as_ptr())
                .chain(std::iter::once(std::ptr::null()))
                .collect::<Vec<_>>()
        };
        let args_ptrs = pointers(&args);
        let env_ptrs = pointers(&environment);
        fcntl_setfd(state, FdFlags::empty()).map_err(|error| error.to_string())?;
        // Keep the validated inode pinned and leave the old process unchanged on failure.
        // Both null-terminated pointer arrays borrow live CStrings throughout fexecve.
        unsafe {
            libc::fexecve(self.file.as_raw_fd(), args_ptrs.as_ptr(), env_ptrs.as_ptr());
        }
        let error = std::io::Error::last_os_error();
        let _ = fcntl_setfd(state, FdFlags::CLOEXEC);
        Err(format!("replacement exec: {error}"))
    }
}

fn stamp(file: &File) -> Result<Stamp, String> {
    let stat = file.metadata().map_err(|error| error.to_string())?;
    Ok(Stamp {
        device: stat.dev(),
        inode: stat.ino(),
        length: stat.len(),
        modified: (stat.mtime(), stat.mtime_nsec()),
        changed: (stat.ctime(), stat.ctime_nsec()),
    })
}

fn digest(file: &mut File) -> Result<[u8; 32], String> {
    file.rewind().map_err(|error| error.to_string())?;
    let mut hash = Sha256::new();
    let mut bytes = [0; 64 * 1024];
    loop {
        let count = file.read(&mut bytes).map_err(|error| error.to_string())?;
        if count == 0 {
            return Ok(hash.finalize().into());
        }
        hash.update(&bytes[..count]);
    }
}

#[cfg(test)]
mod tests {
    use super::super::game::Game;
    use super::*;
    use std::time::Instant;

    #[test]
    fn reload_defaults_to_development_builds_and_allows_opt_out() {
        for debug in [false, true] {
            assert_eq!(
                enabled_for_build(debug, Err(std::env::VarError::NotPresent)).unwrap(),
                debug
            );
            assert!(!enabled_for_build(debug, Ok("0".into())).unwrap());
            for invalid in ["", "true", "2"] {
                assert!(enabled_for_build(debug, Ok(invalid.into())).is_err());
            }
        }
        assert!(enabled_for_build(true, Ok("1".into())).unwrap());
        assert!(enabled_for_build(false, Ok("1".into())).is_err());
    }

    #[test]
    fn gate_requires_idle_noninteractive_live_runtime() {
        let gate = Gate::default();
        let stopping = AtomicBool::new(false);
        assert!(!gate.quiesce_if_idle(true, &stopping));
        gate.request();
        assert!(!gate.quiesce_if_idle(false, &stopping));
        gate.interaction(true);
        assert!(!gate.quiesce_if_idle(true, &stopping));
        gate.interaction(false);
        assert!(gate.quiesce_if_idle(true, &stopping));
        assert!(stopping.load(Ordering::Acquire));
        assert!(gate.approved());
        let exiting = Gate::default();
        exiting.request();
        assert!(!exiting.quiesce_if_idle(true, &stopping));
        assert!(!exiting.approved());
    }

    #[test]
    fn sealed_handoff_is_private_bounded_and_schema_checked() {
        use std::io::Write;
        let handoff = Handoff::new(std::env::current_exe().unwrap(), None, State::default());
        let mut file = handoff.file().unwrap();
        assert_eq!(fcntl_get_seals(&file).unwrap(), SEALS);
        assert!(file.write_all(b"corrupt").is_err());
        let restored = decode(file, std::process::id()).unwrap();
        assert_eq!(restored.owner, handoff.owner);
        let mut data = serde_json::to_value(&handoff).unwrap();
        data["schema"] = 0.into();
        assert!(decode(serde_json::to_vec(&data).unwrap().as_slice(), handoff.owner).is_err());
        assert!(decode(handoff.file().unwrap(), handoff.owner + 1).is_err());
    }

    #[test]
    fn metadata_touch_is_ignored_but_replaced_install_identity_is_not() {
        let loaded = Stamp {
            device: 1,
            inode: 2,
            ..Stamp::default()
        };
        let mut candidate = Candidate {
            file: File::open("/dev/null").unwrap(),
            hash: [0; 32],
            stamp: loaded,
        };
        candidate.stamp.modified = (100, 0);
        assert!(candidate.change_reason(loaded, [0; 32]).is_none());
        candidate.stamp.inode = 3;
        assert_eq!(
            candidate.change_reason(loaded, [0; 32]),
            Some("installed identity changed")
        );
        candidate.stamp = loaded;
        candidate.hash = [1; 32];
        assert_eq!(
            candidate.change_reason(loaded, [0; 32]),
            Some("code changed")
        );
    }

    #[test]
    fn failed_exec_keeps_handoff_readable_and_does_not_leak_it_to_children() {
        let handoff = Handoff::new(std::env::current_exe().unwrap(), None, State::default());
        let state = handoff.file().unwrap();
        let candidate = Candidate {
            file: File::open("/dev/null").unwrap(),
            hash: [0; 32],
            stamp: Stamp::default(),
        };
        assert!(
            candidate
                .exec(&state)
                .unwrap_err()
                .contains("replacement exec")
        );
        assert!(
            rustix::io::fcntl_getfd(&state)
                .unwrap()
                .contains(FdFlags::CLOEXEC)
        );
        assert!(decode(state, handoff.owner).is_ok());
    }

    #[test]
    fn zero_exit_without_companion_readiness_is_not_a_valid_replacement() {
        let handoff = Handoff::new(std::env::current_exe().unwrap(), None, State::default());
        let mut file = File::open("/usr/bin/true").unwrap();
        let candidate = Candidate {
            stamp: stamp(&file).unwrap(),
            hash: digest(&mut file).unwrap(),
            file,
        };
        assert!(
            candidate
                .replace(&handoff, || true)
                .unwrap_err()
                .contains("rejected")
        );
    }

    #[test]
    fn exec_preserves_pid_and_child_parentage_and_resumes_reaping() {
        const CHILD: &str = "WFCOMPANION_TEST_REEXEC";
        if std::env::var_os(CHILD).is_some() {
            let stopping = Arc::new(AtomicBool::new(false));
            if let Some(saved) = resume().unwrap() {
                assert_eq!(saved.owner, std::process::id());
                let mut game = Game::resume(saved.child.unwrap(), stopping.clone()).unwrap();
                let deadline = Instant::now() + Duration::from_secs(5);
                while !stopping.load(Ordering::Acquire) && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(10));
                }
                assert!(stopping.load(Ordering::Acquire));
                assert!(game.stop_monitor().is_none());
                return;
            }
            let mut game = Game::launch(&["sleep".into(), "1".into()], stopping).unwrap();
            let handoff = Handoff::new(
                std::env::current_exe().unwrap(),
                game.stop_monitor(),
                State::default(),
            );
            assert!(handoff.child.is_some());
            let candidate = Candidate {
                file: File::open("/proc/self/exe").unwrap(),
                hash: [0; 32],
                stamp: Stamp::default(),
            };
            panic!(
                "exec failed: {}",
                candidate.exec(&handoff.file().unwrap()).unwrap_err()
            );
        }
        let mut command = Command::new(std::env::current_exe().unwrap());
        command.args(["--exact", "runtime::reload::tests::exec_preserves_pid_and_child_parentage_and_resumes_reaping"])
            .env(CHILD, "1").env_remove(ENABLE).env_remove(HANDOFF);
        let result =
            super::super::process::output(command, Duration::from_secs(10), || true).unwrap();
        assert!(
            result.status.success(),
            "{} {}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }
}
