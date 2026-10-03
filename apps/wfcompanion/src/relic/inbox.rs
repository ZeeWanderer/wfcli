use crate::runtime::inbox;

use super::Trigger;

#[derive(Clone)]
pub(crate) struct Sender(inbox::Sender<Trigger>);
pub(crate) type Receiver = inbox::Receiver<Trigger>;

pub(crate) fn channel() -> (Sender, Receiver) {
    let (sender, receiver) = inbox::channel(
        "relic",
        inbox::Limit {
            items: 64,
            bytes: 64 * 1024,
        },
        inbox::Limit {
            items: 8,
            bytes: 8192,
        },
    );
    (Sender(sender), receiver)
}

impl Sender {
    pub(crate) fn send(&self, trigger: Trigger) -> Result<(), &'static str> {
        let result = self.0.send(trigger);
        if result.is_err() {
            let _ = self.0.send(Trigger::IntakeGap);
        }
        result
    }

    pub(crate) fn stats(&self) -> inbox::Stats {
        self.0.stats()
    }
}

impl inbox::Message for Trigger {
    fn bytes(&self) -> usize {
        size_of::<Self>()
            + match self {
                Self::Screenshot(path) => path.capacity(),
                Self::ArmCapture(arm) => arm.directory.capacity(),
                Self::SuggestionReady { era, .. } => era.capacity(),
                Self::WorkFinished { era, .. } => era.as_ref().map_or(0, String::capacity),
                _ => 0,
            }
    }

    fn control(&self) -> bool {
        matches!(
            self,
            Self::WorkFinished { .. } | Self::SuggestionReady { .. } | Self::IntakeGap
        )
    }

    fn replaces(&self, queued: &Self) -> bool {
        matches!((self, queued), (Self::IntakeGap, Self::IntakeGap))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overload_preserves_order_and_worker_completion_capacity() {
        let (sender, receiver) = channel();
        for _ in 0..32 {
            sender.send(Trigger::CancelCapture).unwrap();
            sender.send(Trigger::CloseSuggestions).unwrap();
        }
        assert!(sender.send(Trigger::GameStopped).is_err());
        for generation in 0..2 {
            sender
                .send(Trigger::SuggestionReady {
                    generation,
                    era: "axi".to_owned(),
                })
                .unwrap();
            sender
                .send(Trigger::WorkFinished {
                    generation,
                    era: None,
                    failed: false,
                })
                .unwrap();
        }
        assert_eq!(sender.stats().items, 69);
        for _ in 0..32 {
            assert!(matches!(
                receiver.try_recv().unwrap(),
                Trigger::CancelCapture
            ));
            assert!(matches!(
                receiver.try_recv().unwrap(),
                Trigger::CloseSuggestions
            ));
        }
        assert!(matches!(receiver.try_recv().unwrap(), Trigger::IntakeGap));
        assert_eq!(receiver.drain(8).len(), 4);
    }
}
