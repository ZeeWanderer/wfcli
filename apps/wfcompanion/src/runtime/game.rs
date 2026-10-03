use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::incident;
use rustix::process::{Pid, WaitOptions, waitpid};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(super) struct ChildIdentity {
    pid: u32,
    started: u64,
}

impl ChildIdentity {
    fn read(pid: u32, parent: u32) -> Result<Self, String> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .map_err(|error| format!("launched game identity: {error}"))?;
        let fields: Vec<_> = stat
            .rsplit_once(')')
            .ok_or("invalid launched game stat")?
            .1
            .split_whitespace()
            .collect();
        if fields.get(1).and_then(|field| field.parse::<u32>().ok()) != Some(parent) {
            return Err("launched game is no longer our child".into());
        }
        let started = fields
            .get(19)
            .and_then(|field| field.parse().ok())
            .ok_or("launched game start time is missing")?;
        Ok(Self { pid, started })
    }

    pub(super) fn validate(&self, parent: u32) -> Result<(), String> {
        let live = Self::read(self.pid, parent)?;
        if live.started != self.started {
            return Err("launched game PID has been reused".into());
        }
        Ok(())
    }

    fn exited(&self) -> Result<bool, String> {
        let pid = Pid::from_raw(self.pid as i32).ok_or("invalid launched game PID")?;
        waitpid(Some(pid), WaitOptions::NOHANG)
            .map(|result| result.is_some())
            .map_err(|error| format!("launched game wait: {error}"))
    }
}

pub(super) struct Game {
    stop: mpsc::Sender<()>,
    worker: Option<JoinHandle<Option<ChildIdentity>>>,
}

impl Game {
    pub(super) fn launch(command: &[String], shutdown: Arc<AtomicBool>) -> Result<Self, String> {
        let (executable, arguments) = command
            .split_first()
            .ok_or_else(|| "game command is empty".to_owned())?;
        let child = Command::new(executable)
            .args(arguments)
            .spawn()
            .map_err(|error| format!("failed to launch game: {error}"))?;
        let identity = ChildIdentity::read(child.id(), std::process::id())?;
        Self::resume(identity, shutdown)
    }

    pub(super) fn resume(child: ChildIdentity, shutdown: Arc<AtomicBool>) -> Result<Self, String> {
        child.validate(std::process::id())?;
        let (stop, stopping) = mpsc::channel();
        let worker = thread::Builder::new()
            .name("wfcompanion-game".to_owned())
            .spawn(move || {
                loop {
                    match child.exited() {
                        Ok(false) => {}
                        result => {
                            if let Err(error) = result {
                                incident::warn("game.wait_failed", error.to_string());
                            }
                            shutdown.store(true, Ordering::Release);
                            return None;
                        }
                    }
                    if stopping.recv_timeout(Duration::from_millis(200))
                        != Err(mpsc::RecvTimeoutError::Timeout)
                    {
                        break;
                    }
                }
                Some(child)
            })
            .map_err(|error| format!("could not monitor launched game: {error}"))?;
        Ok(Self {
            stop,
            worker: Some(worker),
        })
    }

    pub(super) fn stop_monitor(&mut self) -> Option<ChildIdentity> {
        let _ = self.stop.send(());
        self.worker.take().and_then(|worker| match worker.join() {
            Ok(child) => child,
            Err(_) => {
                incident::error("game.wait_failed", "game monitor panicked");
                None
            }
        })
    }
}

impl Drop for Game {
    fn drop(&mut self) {
        // Stopping companion must not terminate the user's game.
        let _ = self.stop_monitor();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stopping_monitor_preserves_live_child() {
        let shutdown = Arc::new(AtomicBool::new(false));
        let mut game = Game::launch(&["sleep".into(), "60".into()], shutdown.clone()).unwrap();
        let child = game.stop_monitor().unwrap();
        let running = !child.exited().unwrap();
        let pid = Pid::from_raw(child.pid as i32).unwrap();
        rustix::process::kill_process(pid, rustix::process::Signal::KILL).unwrap();
        waitpid(Some(pid), WaitOptions::empty()).unwrap();
        assert!(running);
        assert!(!shutdown.load(Ordering::Acquire));
    }

    #[test]
    fn child_exit_notifies_core_and_is_reaped() {
        let shutdown = Arc::new(AtomicBool::new(false));
        let mut game = Game::launch(&["true".into()], shutdown.clone()).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !shutdown.load(Ordering::Acquire) && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(shutdown.load(Ordering::Acquire));
        assert!(game.stop_monitor().is_none());
    }

    #[test]
    fn launch_failure_is_returned_to_caller() {
        assert!(
            Game::launch(
                &["/wfcompanion-test/no-such-command".into()],
                Arc::new(AtomicBool::new(false))
            )
            .is_err()
        );
    }

    #[test]
    fn monitor_can_resume_and_reap_the_same_child() {
        let stopping = Arc::new(AtomicBool::new(false));
        let mut first = Game::launch(&["sleep".into(), "60".into()], stopping.clone()).unwrap();
        let child = first.stop_monitor().unwrap();
        let encoded = serde_json::to_vec(&child).unwrap();
        let mut wrong = child.clone();
        wrong.started += 1;
        assert!(Game::resume(wrong, stopping.clone()).is_err());
        let mut second =
            Game::resume(serde_json::from_slice(&encoded).unwrap(), stopping.clone()).unwrap();
        let pid = Pid::from_raw(child.pid as i32).unwrap();
        rustix::process::kill_process(pid, rustix::process::Signal::KILL).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !stopping.load(Ordering::Acquire) && std::time::Instant::now() < deadline {
            thread::sleep(Duration::from_millis(5));
        }
        assert!(stopping.load(Ordering::Acquire));
        assert!(second.stop_monitor().is_none());
        assert_eq!(
            waitpid(Some(pid), WaitOptions::NOHANG).unwrap_err(),
            rustix::io::Errno::CHILD
        );
    }
}
