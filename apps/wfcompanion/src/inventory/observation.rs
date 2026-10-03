use std::time::{Duration, Instant};

use rustix::time::{ClockId, clock_gettime};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::runtime::session::Session;

pub(super) struct Stream {
    boot_id: String,
    started: u64,
    origin: Instant,
    offset: u64,
    sequence: u64,
    game_started: u64,
    generation: u64,
}

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Checkpoint {
    boot_id: String,
    started: u64,
    recorded: u64,
    elapsed: u64,
    sequence: u64,
    game_started: u64,
    generation: u64,
}

impl Stream {
    pub fn new(session: &Session) -> Result<Self, String> {
        let boot_id = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
            .map_err(|error| format!("could not identify inventory boot: {error}"))?;
        let clock = clock_gettime(ClockId::Boottime);
        Ok(Self {
            boot_id: boot_id.trim().into(),
            started: clock.tv_sec as u64 * 1_000_000_000 + clock.tv_nsec as u64,
            origin: Instant::now(),
            offset: 0,
            sequence: 0,
            game_started: session.process_started(),
            generation: session.generation(),
        })
    }

    pub fn checkpoint(&self) -> Checkpoint {
        Checkpoint {
            boot_id: self.boot_id.clone(),
            started: self.started,
            recorded: monotonic_ns(),
            elapsed: self.elapsed(Instant::now()),
            sequence: self.sequence,
            game_started: self.game_started,
            generation: self.generation,
        }
    }

    pub fn restore(saved: Checkpoint, session: &Session) -> Result<Self, String> {
        let fresh = Self::new(session)?;
        if saved.boot_id != fresh.boot_id || saved.game_started != session.process_started() {
            return Err("inventory checkpoint belongs to another game session".into());
        }
        let elapsed = monotonic_ns()
            .checked_sub(saved.recorded)
            .and_then(|gap| gap.checked_add(saved.elapsed))
            .ok_or("inventory checkpoint clock is invalid")?;
        Ok(Self {
            boot_id: saved.boot_id,
            started: saved.started,
            origin: Instant::now(),
            offset: elapsed,
            sequence: saved.sequence,
            game_started: saved.game_started,
            generation: saved.generation,
        })
    }

    pub fn elapsed(&self, instant: Instant) -> u64 {
        if instant >= self.origin {
            self.offset
                .saturating_add(instant.duration_since(self.origin).as_nanos() as u64)
        } else {
            self.offset
                .saturating_sub(self.origin.duration_since(instant).as_nanos() as u64)
        }
    }

    pub fn instant(&self, elapsed: u64) -> Option<Instant> {
        if elapsed > self.offset {
            self.origin
                .checked_add(Duration::from_nanos(elapsed - self.offset))
        } else {
            self.origin
                .checked_sub(Duration::from_nanos(self.offset - elapsed))
        }
    }

    pub fn stamp(&mut self, baseline: Option<u64>, started: Instant, finished: Instant) -> Value {
        self.sequence += 1;
        json!({
            "boot_id": self.boot_id, "stream": self.started,
            "game_started": self.game_started, "generation": self.generation,
            "sequence": self.sequence, "baseline": baseline.unwrap_or(self.sequence),
            "started_ns": self.elapsed(started),
            "finished_ns": self.elapsed(finished),
        })
    }
}

fn monotonic_ns() -> u64 {
    let clock = clock_gettime(ClockId::Monotonic);
    clock.tv_sec as u64 * 1_000_000_000 + clock.tv_nsec as u64
}
