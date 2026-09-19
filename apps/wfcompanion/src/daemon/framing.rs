use std::io;

use bytes::BytesMut;
use tokio_util::codec::{Decoder, LinesCodec};

pub(super) const MAX_SERVER_FRAME_BYTES: usize = 64 * 1024 * 1024;

pub(super) struct ServerFrames(LinesCodec);

impl ServerFrames {
    pub(super) fn new() -> Self {
        Self(LinesCodec::new_with_max_length(MAX_SERVER_FRAME_BYTES))
    }
}

// Keep Decoder's strict EOF check; LinesCodec accepts an unterminated final line.
impl Decoder for ServerFrames {
    type Item = serde_json::Value;
    type Error = io::Error;

    fn decode(&mut self, bytes: &mut BytesMut) -> io::Result<Option<Self::Item>> {
        self.0
            .decode(bytes)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
            .map(|line| {
                let message: serde_json::Value = serde_json::from_str(&line)?;
                if !message.is_object() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "daemon frame is not an object",
                    ));
                }
                Ok(message)
            })
            .transpose()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures_util::StreamExt;
    use tokio::io::AsyncWriteExt;
    use tokio_util::codec::FramedRead;

    #[test]
    fn rejects_malformed_oversized_and_truncated_frames() {
        for frame in [b"{invalid}\n".as_slice(), b"[]\n", b"\xff\n", b"{\"id\":1}"] {
            let mut frames = ServerFrames::new();
            assert!(frames.decode_eof(&mut BytesMut::from(frame)).is_err());
        }
        let mut frames = ServerFrames(LinesCodec::new_with_max_length(8));
        assert!(
            frames
                .decode(&mut BytesMut::from(&b"123456789"[..]))
                .is_err()
        );
        assert!(
            ServerFrames::new()
                .decode_eof(&mut BytesMut::new())
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn limit_is_per_frame_and_includes_exact_boundary() {
        let frame = b"{\"id\":1}\n{\"id\":2}\n";
        let mut frames = ServerFrames(LinesCodec::new_with_max_length(8));
        let mut bytes = BytesMut::from(&frame[..]);
        assert_eq!(frames.decode(&mut bytes).unwrap().unwrap()["id"], 1);
        assert_eq!(frames.decode(&mut bytes).unwrap().unwrap()["id"], 2);
        assert!(bytes.is_empty());
    }

    #[tokio::test]
    async fn cancelled_receive_retains_fragments() {
        let (mut writer, reader) = tokio::io::duplex(128);
        let mut frames = FramedRead::new(reader, ServerFrames::new());
        writer.write_all(b"{\"id\":").await.unwrap();
        tokio::select! {
            biased;
            result = frames.next() => panic!("partial frame completed: {result:?}"),
            _ = std::future::ready(()) => {}
        }
        writer.write_all(b"7}\n{\"id\":8}\n").await.unwrap();
        writer.shutdown().await.unwrap();
        assert_eq!(frames.next().await.unwrap().unwrap()["id"], 7);
        assert_eq!(frames.next().await.unwrap().unwrap()["id"], 8);
        assert!(frames.next().await.is_none());
    }
}
