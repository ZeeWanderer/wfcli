use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;

use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::oneshot;

use super::Worker;

pub(super) struct Signals {
    cancel: Option<oneshot::Sender<()>>,
    _worker: Worker,
    requested: Arc<AtomicBool>,
}

impl Signals {
    pub(super) fn start(stopping: Arc<AtomicBool>) -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| format!("signal runtime: {error}"))?;
        let (mut terminate, mut interrupt) = {
            let _entered = runtime.enter();
            (
                signal(SignalKind::terminate()).map_err(|error| format!("SIGTERM: {error}"))?,
                signal(SignalKind::interrupt()).map_err(|error| format!("SIGINT: {error}"))?,
            )
        };
        let (cancel, cancelled) = oneshot::channel();
        let requested = Arc::new(AtomicBool::new(false));
        let received = requested.clone();
        let worker = thread::Builder::new()
            .name("wfcompanion-signals".to_owned())
            .spawn(move || {
                runtime.block_on(async {
                    let name = tokio::select! {
                        _ = cancelled => return,
                        _ = terminate.recv() => "SIGTERM",
                        _ = interrupt.recv() => "SIGINT",
                    };
                    received.store(true, Ordering::Release);
                    stopping.store(true, Ordering::Release);
                    crate::incident::info("process.stop_requested", name);
                });
            })
            .map_err(|error| format!("could not start signal worker: {error}"))?;
        Ok(Self {
            cancel: Some(cancel),
            _worker: Worker::new("signals", worker),
            requested,
        })
    }

    pub(super) fn requested(&self) -> bool {
        self.requested.load(Ordering::Acquire)
    }
}

impl Drop for Signals {
    fn drop(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            let _ = cancel.send(());
        }
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;
    use std::time::{Duration, Instant};

    use super::*;

    #[test]
    fn unix_signals_request_shutdown() {
        const CHILD: &str = "WFCOMPANION_TEST_SIGNAL";
        if let Ok(name) = std::env::var(CHILD) {
            let stopping = Arc::new(AtomicBool::new(false));
            let signals = Signals::start(stopping.clone()).unwrap();
            assert!(
                Command::new("kill")
                    .args([&format!("-{name}"), &std::process::id().to_string()])
                    .status()
                    .unwrap()
                    .success()
            );
            let deadline = Instant::now() + Duration::from_secs(5);
            while !stopping.load(Ordering::Acquire) && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(5));
            }
            assert!(stopping.load(Ordering::Acquire));
            drop(signals);
            return;
        }
        for name in ["TERM", "INT"] {
            let result = Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "runtime::signals::tests::unix_signals_request_shutdown",
                    "--nocapture",
                ])
                .env(CHILD, name)
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "{name}: {}",
                String::from_utf8_lossy(&result.stderr)
            );
        }
    }
}
