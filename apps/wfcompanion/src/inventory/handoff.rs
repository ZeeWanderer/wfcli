use serde::{Deserialize, Serialize};

use super::{Baseline, Decoder, observation};
use crate::runtime::session::{ProcessKey, Session};

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Checkpoint {
    process: ProcessKey,
    player_name: Option<String>,
    seen_payloads: std::collections::HashSet<u64>,
    stream: observation::Checkpoint,
    baseline: Option<SavedBaseline>,
}

#[derive(Clone, Serialize, Deserialize)]
struct SavedBaseline {
    sequence: u64,
    captured: u64,
    sync: String,
}

impl Checkpoint {
    pub(crate) fn matches(&self, session: &Session) -> bool {
        self.process == session.key()
    }
}

impl Decoder {
    pub(super) fn checkpoint(self) -> Result<Checkpoint, String> {
        self.session.check()?;
        Ok(Checkpoint {
            process: self.session.key(),
            player_name: self.player_name,
            seen_payloads: self.seen_payloads,
            baseline: self.baseline.map(|baseline| SavedBaseline {
                sequence: baseline.sequence,
                captured: self.stream.elapsed(baseline.captured),
                sync: baseline.sync,
            }),
            stream: self.stream.checkpoint(),
        })
    }

    pub(super) fn restore(&mut self, saved: Checkpoint) -> Result<(), String> {
        self.session.check()?;
        if !saved.matches(&self.session) {
            return Err("inventory checkpoint process has changed".into());
        }
        let stream = observation::Stream::restore(saved.stream, &self.session)?;
        let baseline = saved
            .baseline
            .map(|baseline| {
                Ok::<_, String>(Baseline {
                    sequence: baseline.sequence,
                    captured: stream
                        .instant(baseline.captured)
                        .ok_or("inventory checkpoint capture time is invalid")?,
                    sync: baseline.sync,
                })
            })
            .transpose()?;
        self.stream = stream;
        self.baseline = baseline;
        self.player_name = saved.player_name;
        self.seen_payloads = saved.seen_payloads;
        // A fresh native read also covers changes during the observation gap.
        self.last_native = None;
        Ok(())
    }
}
