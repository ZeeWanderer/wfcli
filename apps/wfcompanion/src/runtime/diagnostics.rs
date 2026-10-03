use std::collections::{BTreeMap, VecDeque};
use std::io;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::inbox;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
const INTERVAL: Duration = Duration::from_secs(1);
const MAX_WATCHES: usize = 4;
const MAX_HISTORY: usize = 16;
pub(crate) const MAX_REPLY_BYTES: usize = 32 * 1024;

pub(crate) type Sender = inbox::Sender<Command>;
pub(crate) type Receiver = inbox::Receiver<Command>;
pub(crate) type Replies = mpsc::Sender<Response>;

#[derive(Debug)]
pub(crate) struct Response {
    pub(crate) request_id: String,
    pub(crate) data: Value,
}

pub(crate) struct Command {
    id: String,
    action: Action,
    replies: Replies,
    received: Instant,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Action {
    Status,
    Watch { topic: Topic, seconds: u64 },
    Stop { job: String },
    Credit,
    Cancel,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Topic {
    Inventory,
}

impl inbox::Message for Command {
    fn bytes(&self) -> usize {
        size_of::<Self>()
            + self.id.capacity()
            + match &self.action {
                Action::Stop { job } => job.capacity(),
                _ => 0,
            }
    }

    fn control(&self) -> bool {
        matches!(self.action, Action::Cancel | Action::Credit)
    }
}

pub(crate) fn channel() -> (Sender, Receiver) {
    inbox::channel(
        "diagnostics",
        inbox::Limit {
            items: 16,
            bytes: 8192,
        },
        inbox::Limit {
            items: 16,
            bytes: 8192,
        },
    )
}

pub(crate) fn route(message: &Value, requests: &Sender, replies: &Replies) -> io::Result<()> {
    let id = message
        .get("request_id")
        .and_then(Value::as_str)
        .filter(|id| valid_id(id))
        .ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "invalid diagnostic request ID")
        })?;
    let action = serde_json::from_value::<Action>(message["request"].clone());
    let error = match action {
        Ok(action) if matches!(&action, Action::Stop { job } if !valid_id(job)) => {
            Some("invalid diagnostic job ID")
        }
        Ok(action) => requests
            .send(Command {
                id: id.to_owned(),
                action,
                replies: replies.clone(),
                received: Instant::now(),
            })
            .err(),
        Err(_) => Some("invalid diagnostic request"),
    };
    if let Some(error) = error {
        respond(replies, id, json!({"state": "failed", "error": error}));
    }
    Ok(())
}

fn valid_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
}

pub(crate) struct Watches {
    requests: Receiver,
    active: BTreeMap<String, Watch>,
    history: VecDeque<Value>,
}

struct Watch {
    replies: Replies,
    deadline: Instant,
    next: Instant,
    credit: bool,
    started_at: u128,
    expires_at: u128,
    samples: u64,
    skipped: u64,
}

impl Watch {
    fn status(&self, id: &str, state: &str) -> Value {
        json!({"job": id, "topic": "inventory", "state": state,
            "started_at": self.started_at, "expires_at": self.expires_at,
            "samples": self.samples, "skipped": self.skipped})
    }
}

impl Watches {
    pub(crate) fn new(requests: Receiver) -> Self {
        Self {
            requests,
            active: BTreeMap::new(),
            history: VecDeque::new(),
        }
    }

    pub(crate) fn tick(&mut self, mut snapshot: impl FnMut() -> Value) {
        let now = Instant::now();
        self.expire(now);
        for request in self.requests.drain(8) {
            self.command(request, now, &mut snapshot);
        }
        for (id, watch) in &mut self.active {
            if now < watch.next {
                continue;
            }
            let ticks = 1 + now.duration_since(watch.next).as_secs();
            watch.skipped += ticks - u64::from(watch.credit);
            watch.next = now + INTERVAL;
            if watch.credit {
                watch.samples += 1;
                let mut data = watch.status(id, "running");
                data["snapshot"] = snapshot();
                watch.credit = false;
                respond(&watch.replies, id, data);
            }
        }
    }

    fn command(&mut self, request: Command, now: Instant, snapshot: &mut impl FnMut() -> Value) {
        let Command {
            id,
            action,
            replies,
            received,
        } = request;
        if replies.is_closed() {
            return;
        }
        if now.saturating_duration_since(received) >= REQUEST_TIMEOUT {
            respond(
                &replies,
                &id,
                json!({"state": "failed", "error": "request expired"}),
            );
            return;
        }
        match action {
            Action::Status => {
                let jobs = self
                    .active
                    .iter()
                    .map(|(id, watch)| watch.status(id, "running"))
                    .chain(self.history.iter().cloned())
                    .collect::<Vec<_>>();
                respond(
                    &replies,
                    &id,
                    json!({"state": "completed", "snapshot": snapshot(),
                    "jobs": jobs, "watch_interval_ms": INTERVAL.as_millis(),
                    "max_watches": MAX_WATCHES}),
                );
            }
            Action::Watch {
                topic: Topic::Inventory,
                seconds,
            } => {
                if !(1..=1800).contains(&seconds)
                    || self.active.len() >= MAX_WATCHES
                    || self.active.contains_key(&id)
                {
                    respond(
                        &replies,
                        &id,
                        json!({"state": "failed", "error": "invalid duration or watch limit reached"}),
                    );
                    return;
                }
                let started_at = unix_ms();
                let watch = Watch {
                    replies,
                    deadline: now + Duration::from_secs(seconds),
                    next: now + INTERVAL,
                    credit: false,
                    started_at,
                    expires_at: started_at + u128::from(seconds) * 1000,
                    samples: 1,
                    skipped: 0,
                };
                let mut data = watch.status(&id, "running");
                data["snapshot"] = snapshot();
                if respond(&watch.replies, &id, data) {
                    self.active.insert(id, watch);
                }
            }
            Action::Stop { job } => {
                if self.active.contains_key(&job) {
                    self.finish(&job, "cancelled", "requested");
                    respond(
                        &replies,
                        &id,
                        json!({"state": "completed", "job": job,
                                                  "job_state": "cancelled"}),
                    );
                } else {
                    respond(
                        &replies,
                        &id,
                        json!({"state": "failed", "error": "job is not running"}),
                    );
                }
            }
            Action::Credit => {
                if let Some(watch) = self.active.get_mut(&id)
                    && watch.replies.same_channel(&replies)
                {
                    watch.credit = true;
                }
            }
            Action::Cancel => {
                if self
                    .active
                    .get(&id)
                    .is_some_and(|watch| watch.replies.same_channel(&replies))
                {
                    self.finish(&id, "cancelled", "client disconnected");
                }
            }
        }
    }

    fn expire(&mut self, now: Instant) {
        let ended = self
            .active
            .iter()
            .filter_map(|(id, watch)| {
                if watch.replies.is_closed() {
                    Some((id.clone(), "cancelled", "connection closed"))
                } else if now >= watch.deadline {
                    Some((id.clone(), "completed", "duration"))
                } else {
                    None
                }
            })
            .collect::<Vec<_>>();
        for (id, state, reason) in ended {
            self.finish(&id, state, reason);
        }
    }

    fn finish(&mut self, id: &str, state: &str, reason: &str) {
        let watch = self.active.remove(id).unwrap();
        let mut data = watch.status(id, state);
        data["finished_at"] = json!(unix_ms());
        data["reason"] = json!(reason);
        respond(&watch.replies, id, data.clone());
        if self.history.len() == MAX_HISTORY {
            self.history.pop_front();
        }
        self.history.push_back(data);
    }

    pub(crate) fn shutdown(&mut self) {
        for id in self.active.keys().cloned().collect::<Vec<_>>() {
            self.finish(&id, "cancelled", "companion stopping");
        }
    }
}

fn respond(replies: &Replies, id: &str, data: Value) -> bool {
    if replies.is_closed() {
        return false;
    }
    if inbox::value_bytes(&data) > MAX_REPLY_BYTES
        || replies
            .try_send(Response {
                request_id: id.to_owned(),
                data,
            })
            .is_err()
    {
        crate::incident::warn(
            "diagnostics.reply_rejected",
            "diagnostic reply limit reached",
        );
        return false;
    }
    true
}

fn unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0123456789abcdef0123456789abcdef";

    fn send(sender: &Sender, replies: &Replies, id: &str, action: Value) {
        route(
            &json!({"request_id": id, "request": action}),
            sender,
            replies,
        )
        .unwrap();
    }

    #[test]
    fn status_is_live_and_does_not_start_a_watch() {
        let (sender, receiver) = channel();
        let (replies, mut output) = mpsc::channel(32);
        let mut watches = Watches::new(receiver);
        send(&sender, &replies, ID, json!({"action": "status"}));
        watches.tick(|| json!({"inventory_updates_observed": 42}));
        let response = output.try_recv().unwrap();
        assert_eq!(response.request_id, ID);
        assert_eq!(response.data["snapshot"]["inventory_updates_observed"], 42);
        assert!(watches.active.is_empty());
        assert!(watches.history.is_empty());
    }

    #[test]
    fn watch_requires_credit_and_terminal_reply_does_not() {
        let (sender, receiver) = channel();
        let (replies, mut output) = mpsc::channel(32);
        let mut watches = Watches::new(receiver);
        send(
            &sender,
            &replies,
            ID,
            json!({"action": "watch", "topic": "inventory", "seconds": 60}),
        );
        watches.tick(|| json!({"sample": 1}));
        assert_eq!(output.try_recv().unwrap().data["samples"], 1);
        watches.active.get_mut(ID).unwrap().next = Instant::now() - Duration::from_secs(3);
        watches.tick(|| panic!("unconsumed watch must not build another snapshot"));
        assert!(output.try_recv().is_err());
        send(&sender, &replies, ID, json!({"action": "credit"}));
        watches.active.get_mut(ID).unwrap().next = Instant::now();
        watches.tick(|| json!({"sample": 2}));
        let sample = output.try_recv().unwrap().data;
        assert_eq!(sample["samples"], 2);
        assert_eq!(sample["skipped"], 4);
        watches.active.get_mut(ID).unwrap().deadline = Instant::now();
        watches.tick(|| panic!("expired watch must not sample"));
        assert_eq!(output.try_recv().unwrap().data["state"], "completed");
        assert!(watches.active.is_empty());
        assert_eq!(watches.history.len(), 1);
    }

    #[test]
    fn disconnected_and_expired_requests_cannot_create_jobs() {
        let (sender, receiver) = channel();
        let (replies, output) = mpsc::channel(32);
        let mut watches = Watches::new(receiver);
        send(
            &sender,
            &replies,
            ID,
            json!({"action": "watch", "topic": "inventory", "seconds": 60}),
        );
        drop(output);
        watches.tick(|| panic!("disconnected request"));
        assert!(watches.active.is_empty());
        let (replies, mut output) = mpsc::channel(32);
        sender
            .send(Command {
                id: ID.to_owned(),
                action: Action::Watch {
                    topic: Topic::Inventory,
                    seconds: 60,
                },
                replies,
                received: Instant::now() - REQUEST_TIMEOUT,
            })
            .unwrap();
        watches.tick(|| panic!("expired request"));
        assert_eq!(output.try_recv().unwrap().data["state"], "failed");
        assert!(watches.active.is_empty());
    }

    #[test]
    fn watch_limit_disconnect_and_history_are_bounded() {
        let (sender, receiver) = channel();
        let (replies, mut output) = mpsc::channel(32);
        let mut watches = Watches::new(receiver);
        for n in 0..MAX_WATCHES + 1 {
            send(
                &sender,
                &replies,
                &format!("{n:032x}"),
                json!({"action": "watch", "topic": "inventory", "seconds": 60}),
            );
        }
        watches.tick(|| json!({}));
        assert_eq!(watches.active.len(), MAX_WATCHES);
        for _ in 0..MAX_WATCHES {
            assert_eq!(output.try_recv().unwrap().data["state"], "running");
        }
        assert_eq!(output.try_recv().unwrap().data["state"], "failed");
        drop(output);
        watches.tick(|| panic!("disconnected watches"));
        assert!(watches.active.is_empty());
        assert_eq!(watches.history[0]["state"], "cancelled");
        for n in 0..30 {
            let (replies, mut output) = mpsc::channel(32);
            send(
                &sender,
                &replies,
                &format!("{n:032x}"),
                json!({"action": "watch", "topic": "inventory", "seconds": 60}),
            );
            watches.tick(|| json!({}));
            output.try_recv().unwrap();
            watches.shutdown();
            assert_eq!(output.try_recv().unwrap().data["state"], "cancelled");
        }
        assert_eq!(watches.history.len(), MAX_HISTORY);
    }

    #[test]
    fn malformed_requests_and_full_admission_fail_explicitly() {
        let (sender, _receiver) = channel();
        let (replies, mut output) = mpsc::channel(32);
        assert!(route(&json!({"request_id": "invalid"}), &sender, &replies).is_err());
        send(&sender, &replies, ID, json!({"action": "write_memory"}));
        assert_eq!(output.try_recv().unwrap().data["state"], "failed");
        for _ in 0..17 {
            send(&sender, &replies, ID, json!({"action": "status"}));
        }
        assert_eq!(output.try_recv().unwrap().data["state"], "failed");
        assert_eq!(sender.stats().items, 16);
        send(&sender, &replies, ID, json!({"action": "cancel"}));
        assert_eq!(sender.stats().items, 17);
    }
}
