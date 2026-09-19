use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use super::*;

const MAX_WORKERS: usize = 2;

#[derive(Clone, Debug)]
pub(crate) struct Context {
    pub(crate) generation: u64,
    pub(crate) deadline: Option<Instant>,
    cancelled: Arc<AtomicBool>,
    stopping: Arc<AtomicBool>,
}

impl Context {
    #[cfg(test)]
    pub(crate) fn for_test(deadline: Option<Instant>) -> Self {
        Lifecycle::default().start(deadline, &Arc::new(AtomicBool::new(false)))
    }

    pub(crate) fn is_current(&self) -> bool {
        !self.cancelled.load(Ordering::Acquire)
            && !self.stopping.load(Ordering::Relaxed)
            && self
                .deadline
                .is_none_or(|deadline| Instant::now() < deadline)
    }

    pub(crate) fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }

    pub(super) fn check(&self) -> Result<(), String> {
        self.is_current()
            .then_some(())
            .ok_or_else(|| "relic context cancelled".to_owned())
    }
}

#[derive(Default)]
struct Lifecycle {
    generation: u64,
    current: Option<Context>,
    last_reward: Option<Instant>,
    last_suggestion: Option<Instant>,
    last_era: Option<String>,
    opened: Option<Instant>,
    after_reward: bool,
    dismissed: bool,
    suggesting: bool,
}

impl Lifecycle {
    fn start(&mut self, deadline: Option<Instant>, stopping: &Arc<AtomicBool>) -> Context {
        self.cancel();
        self.generation += 1;
        let context = Context {
            generation: self.generation,
            deadline,
            cancelled: Arc::new(AtomicBool::new(false)),
            stopping: stopping.clone(),
        };
        self.current = Some(context.clone());
        context
    }

    fn cancel(&mut self) {
        if let Some(context) = self.current.take() {
            context.cancel();
        }
    }

    fn close(&mut self, now: Instant) -> bool {
        if !self.suggesting {
            return false;
        }
        if self.opened.is_some_and(|opened| {
            ignore_suggestion_close(self.after_reward, now.saturating_duration_since(opened))
        }) {
            return false;
        }
        self.cancel();
        self.opened = None;
        self.after_reward = false;
        self.dismissed = false;
        self.last_suggestion = None;
        self.suggesting = false;
        true
    }

    fn completed(&mut self, generation: u64, era: Option<String>, failed: bool) {
        if !self
            .current
            .as_ref()
            .is_some_and(|context| context.generation == generation && context.is_current())
        {
            return;
        }
        if let Some(era) = era {
            self.last_era = Some(era);
        }
        if failed {
            self.last_reward = None;
        }
    }
}

struct Job {
    trigger: Trigger,
    context: Context,
    fallback_era: Option<String>,
    capture: Option<PendingCapture>,
    updates: mpsc::Sender<Trigger>,
}

pub(crate) fn spawn(
    triggers: mpsc::Receiver<Trigger>,
    sender: mpsc::Sender<Trigger>,
    daemon: OutboundSender,
    ui: mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
) -> thread::JoinHandle<()> {
    spawn_with_worker(triggers, sender, daemon, ui, stopping, run_job)
}

fn spawn_with_worker(
    triggers: mpsc::Receiver<Trigger>,
    sender: mpsc::Sender<Trigger>,
    daemon: OutboundSender,
    ui: mpsc::Sender<UiEvent>,
    stopping: Arc<AtomicBool>,
    work: impl Fn(Job, &OutboundSender, &mpsc::Sender<UiEvent>) -> (Option<String>, bool)
    + Send
    + Sync
    + 'static,
) -> thread::JoinHandle<()> {
    let work = Arc::new(work);
    thread::spawn(move || {
        let mut lifecycle = Lifecycle::default();
        let mut armed: Option<ArmedCapture> = None;
        let mut workers: BTreeMap<u64, thread::JoinHandle<()>> = BTreeMap::new();
        let mut pending: Option<Job> = None;
        while !stopping.load(Ordering::Relaxed) {
            let trigger = triggers.recv_timeout(Duration::from_millis(200));
            if armed.as_ref().is_some_and(ArmedCapture::expired) {
                incident::info("relic.capture_arm_expired", "relic_reward");
                armed = None;
            }
            match trigger {
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Ok(Trigger::ArmCapture(request)) => {
                    incident::info(
                        "relic.capture_armed",
                        format!(
                            "output={} timeout_ms={}",
                            request.directory.display(),
                            request.timeout.as_millis()
                        ),
                    );
                    armed = Some(ArmedCapture::new(&request));
                }
                Ok(Trigger::CancelCapture) => {
                    if armed.take().is_some() {
                        incident::info("relic.capture_arm_cancelled", "relic_reward");
                    }
                }
                Ok(Trigger::GameStopped) => {
                    lifecycle.cancel();
                    lifecycle = Lifecycle {
                        generation: lifecycle.generation,
                        ..Lifecycle::default()
                    };
                    pending = None;
                    armed = None;
                    let _ = ui.send(UiEvent::RelicDismiss);
                }
                Ok(Trigger::CloseSuggestions) => {
                    if lifecycle.close(Instant::now()) {
                        pending = None;
                        let _ = ui.send(UiEvent::RelicDismiss);
                    } else {
                        incident::info("relic.suggestion_close_ignored", "debug_output");
                    }
                }
                Ok(Trigger::DismissSuggestions { generation }) => {
                    if !lifecycle.suggesting
                        || lifecycle
                            .current
                            .as_ref()
                            .is_none_or(|context| context.generation != generation)
                    {
                        continue;
                    }
                    lifecycle.cancel();
                    lifecycle.dismissed = true;
                    lifecycle.opened = None;
                    pending = None;
                    let _ = ui.send(UiEvent::RelicDismiss);
                }
                Ok(Trigger::WorkFinished {
                    generation,
                    era,
                    failed,
                }) => {
                    if let Some(worker) = workers.remove(&generation) {
                        let _ = worker.join();
                    }
                    lifecycle.completed(generation, era, failed);
                }
                Ok(Trigger::SuggestionReady { generation, era }) => {
                    lifecycle.completed(generation, Some(era), false);
                }
                Ok(trigger) => {
                    let now = Instant::now();
                    let mut fallback_era = None;
                    let mut capture = None;
                    let deadline = match &trigger {
                        Trigger::Suggestions { observed_at, .. } => {
                            if lifecycle.dismissed
                                || reject_recent_trigger(
                                    &mut lifecycle.last_suggestion,
                                    SUGGESTION_TRIGGER_DEDUPLICATION,
                                )
                            {
                                continue;
                            }
                            lifecycle.after_reward = lifecycle.last_reward.is_some_and(|seen| {
                                now.saturating_duration_since(seen) < SUGGESTION_REWARD_FALLBACK
                            });
                            if lifecycle.after_reward {
                                fallback_era = lifecycle.last_era.clone();
                            }
                            lifecycle.opened = Some(*observed_at);
                            lifecycle.suggesting = true;
                            None
                        }
                        Trigger::Rewards {
                            game_pid,
                            observed_at,
                            observed_at_unix_ms,
                        } => {
                            if reject_duplicate_reward_trigger(&mut lifecycle.last_reward) {
                                continue;
                            }
                            lifecycle.dismissed = false;
                            lifecycle.opened = None;
                            lifecycle.suggesting = false;
                            capture = armed.take().map(|armed| {
                                begin_armed_capture(
                                    armed,
                                    *game_pid,
                                    *observed_at,
                                    *observed_at_unix_ms,
                                )
                            });
                            Some(*observed_at + REWARD_SCENE_LIFETIME)
                        }
                        Trigger::Screenshot(_) => {
                            lifecycle.suggesting = false;
                            Some(now + REWARD_SCENE_LIFETIME)
                        }
                        _ => unreachable!(),
                    };
                    let context = lifecycle.start(deadline, &stopping);
                    let _ = ui.send(UiEvent::RelicStart(context.clone()));
                    pending = Some(Job {
                        trigger,
                        context,
                        fallback_era,
                        capture,
                        updates: sender.clone(),
                    });
                }
            }
            if workers.len() < MAX_WORKERS
                && let Some(job) = pending.take()
            {
                if !job.context.is_current() {
                    continue;
                }
                let generation = job.context.generation;
                let sender = sender.clone();
                let daemon = daemon.clone();
                let ui = ui.clone();
                let work = work.clone();
                workers.insert(
                    generation,
                    thread::spawn(move || {
                        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            work(job, &daemon, &ui)
                        }));
                        let (era, failed) = result.unwrap_or_else(|_| {
                            incident::error("relic.worker_failed", "worker panicked");
                            (None, true)
                        });
                        let _ = sender.send(Trigger::WorkFinished {
                            generation,
                            era,
                            failed,
                        });
                    }),
                );
            }
        }
        lifecycle.cancel();
        for worker in workers.into_values() {
            let _ = worker.join();
        }
    })
}

fn run_job(
    job: Job,
    daemon: &OutboundSender,
    ui: &mpsc::Sender<UiEvent>,
) -> (Option<String>, bool) {
    if let Trigger::Suggestions {
        game_pid,
        observed_at,
    } = job.trigger
    {
        match show_suggestions(
            daemon,
            ui,
            &job.context,
            game_pid,
            observed_at,
            job.fallback_era.as_deref(),
        ) {
            Ok(era) => {
                let _ = job.updates.send(Trigger::SuggestionReady {
                    generation: job.context.generation,
                    era: era.clone(),
                });
                if job.context.is_current() {
                    show_suggestion_prices(daemon, ui, &job.context, &era);
                }
                (Some(era), false)
            }
            Err(error) => {
                if job.context.is_current() {
                    incident::warn("relic.suggestion_failed", error);
                }
                (None, false)
            }
        }
    } else {
        (
            None,
            !read_rewards(job.trigger, daemon, ui, &job.context, job.capture),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slow_workers_do_not_block_close_and_only_latest_work_is_queued() {
        let (triggers, receiver) = mpsc::channel();
        let (ui, events) = mpsc::channel();
        let (daemon, _) = tokio::sync::mpsc::unbounded_channel();
        let stopping = Arc::new(AtomicBool::new(false));
        let (started, jobs) = mpsc::channel();
        let worker = spawn_with_worker(
            receiver,
            triggers.clone(),
            daemon,
            ui,
            stopping.clone(),
            move |job, _, _| {
                let (release, wait) = mpsc::channel();
                started.send((job.context.generation, release)).unwrap();
                wait.recv_timeout(Duration::from_secs(5)).unwrap();
                (None, false)
            },
        );
        let open = || {
            triggers
                .send(Trigger::Suggestions {
                    game_pid: 1,
                    observed_at: Instant::now() - Duration::from_secs(5),
                })
                .unwrap();
            let UiEvent::RelicStart(context) = events.recv_timeout(Duration::from_secs(2)).unwrap()
            else {
                panic!()
            };
            context
        };
        let close = || {
            triggers.send(Trigger::CloseSuggestions).unwrap();
            assert!(matches!(
                events.recv_timeout(Duration::from_secs(2)).unwrap(),
                UiEvent::RelicDismiss
            ));
        };
        let first = open();
        let (_, release_first) = jobs.recv_timeout(Duration::from_secs(2)).unwrap();
        close();
        assert!(!first.is_current());
        let second = open();
        let (_, release_second) = jobs.recv_timeout(Duration::from_secs(2)).unwrap();
        close();
        let third = open();
        close();
        let fourth = open();
        assert!(!second.is_current());
        assert!(!third.is_current());
        assert!(jobs.try_recv().is_err());
        release_first.send(()).unwrap();
        let (generation, release_fourth) = jobs.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(generation, fourth.generation);
        triggers.send(Trigger::GameStopped).unwrap();
        assert!(matches!(
            events.recv_timeout(Duration::from_secs(2)).unwrap(),
            UiEvent::RelicDismiss
        ));
        assert!(!fourth.is_current());
        stopping.store(true, Ordering::Relaxed);
        release_second.send(()).unwrap();
        release_fourth.send(()).unwrap();
        worker.join().unwrap();
    }

    #[test]
    fn close_reopen_rejects_delayed_scenes_and_price_results() {
        let stopping = Arc::new(AtomicBool::new(false));
        let mut lifecycle = Lifecycle::default();
        let old = lifecycle.start(None, &stopping);
        lifecycle.opened = Some(Instant::now() - Duration::from_secs(4));
        lifecycle.suggesting = true;
        assert!(lifecycle.close(Instant::now()));
        let new = lifecycle.start(None, &stopping);
        lifecycle.completed(old.generation, Some("Axi".to_owned()), false);
        assert_eq!(lifecycle.last_era, None);
        assert!(!old.is_current());
        assert!(new.is_current());
        lifecycle.completed(new.generation, Some("Lith".to_owned()), false);
        assert_eq!(lifecycle.last_era.as_deref(), Some("Lith"));
    }

    #[test]
    fn cancellation_also_invalidates_already_queued_ui_results() {
        let stopping = Arc::new(AtomicBool::new(false));
        let mut lifecycle = Lifecycle::default();
        let context = lifecycle.start(None, &stopping);
        let (sender, receiver) = mpsc::channel();
        send_scene(&sender, &context, Scene::Reading, None);
        lifecycle.cancel();
        let UiEvent::RelicScene { context, .. } = receiver.recv().unwrap() else {
            panic!()
        };
        assert!(!context.is_current());
        let context = lifecycle.start(None, &stopping);
        stopping.store(true, Ordering::Relaxed);
        assert!(!context.is_current());
    }

    #[test]
    fn expired_rewards_cannot_publish() {
        let stopping = Arc::new(AtomicBool::new(false));
        let context = Lifecycle::default().start(Some(Instant::now()), &stopping);
        let (sender, receiver) = mpsc::channel();
        send_scene(&sender, &context, Scene::Reading, context.deadline);
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn suggestion_close_does_not_cancel_rewards() {
        let stopping = Arc::new(AtomicBool::new(false));
        let mut lifecycle = Lifecycle::default();
        let context = lifecycle.start(Some(Instant::now() + REWARD_SCENE_LIFETIME), &stopping);
        assert!(!lifecycle.close(Instant::now()));
        assert!(context.is_current());
    }
}
