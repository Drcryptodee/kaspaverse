//! **How far the user has read in each conversation** — the one fact behind
//! the unread count `M1` draws, and the only piece of read state in the stack.
//!
//! **A watermark per conversation, not a flag per message.** A flag would be a
//! second mutable field on every `MessageRecord`, replayed through the
//! conversation log and rewritten every time a thread is looked at; a
//! watermark is one comparison against a pair the store already sorts on. The
//! count is then derived, never stored, so it cannot disagree with the rows.
//!
//! **The pair, not the timestamp.** [`TransportStore::messages_for`] orders on
//! `(unix_ms, txid)` because a block stamps every transaction in it with the
//! same millisecond — two messages that arrive in one block are ordered only
//! by their txid. A watermark of `unix_ms` alone would therefore either
//! re-count or skip the siblings of the row last read, and which of the two
//! depends on the comparison's `>` versus `>=`. The mark carries both halves
//! and compares on both.
//!
//! **Keyed on the conversation id, unlike [`crate::ContactNames`].** A name
//! belongs to a *person* and so keys on their address; how far you have read
//! belongs to a *thread*. The difference is visible exactly once, at a fold:
//! `TransportStore::merge_contact` rehomes a duplicate row's messages onto the
//! host, and those messages have never been seen **in the host thread** — so
//! they land past the host's mark and count as unread, which is the truthful
//! answer rather than an artefact to migrate away.
//!
//! **Device-local, never on the wire and never in a backup.** What you have
//! read is behavioural metadata about a real person's correspondence; the
//! ledger is a poor place for it even encrypted, and a restore from seed
//! starting with everything unread is honest. Same lane as `contact.names`,
//! `fill.cursors` and `stash.state`, for the same reason (D-143: a new borsh
//! field on `ConversationRecord` would stop `replay()` at the first frame an
//! older build wrote).

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::history_fill::write_json;

const READ_MARKS_FILE: &str = "read.marks";

/// One conversation's high-water mark: the newest inbound row the user has
/// actually had on screen.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReadMark {
    /// The row's chain timestamp.
    pub unix_ms: u64,
    /// The row's txid — the tiebreak inside one block (see the module note).
    #[serde(default)]
    pub txid: String,
}

impl ReadMark {
    /// Whether `(unix_ms, txid)` sits strictly past this mark, under the same
    /// ordering [`crate::TransportStore::messages_for`] sorts on.
    pub fn precedes(&self, unix_ms: u64, txid: &str) -> bool {
        (unix_ms, txid) > (self.unix_ms, self.txid.as_str())
    }
}

/// Conversation id → how far it has been read.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReadMarks {
    #[serde(default)]
    pub marks: HashMap<String, ReadMark>,
}

impl ReadMarks {
    /// Infallible: an absent or corrupt file reads as "nothing has been read",
    /// which costs a user one over-count and never a message.
    pub fn load(dir: &Path) -> Self {
        Self::read(dir).unwrap_or_default()
    }

    /// **Absent and UNREADABLE, told apart** — `None` for either, so a caller
    /// that seeds on absence also re-seeds on corruption.
    ///
    /// The write is a plain `write_json` because it happens every time a
    /// thread is opened and durability is not worth an fsync per glance. The
    /// cost of that is a torn file, and a torn file read as
    /// `ReadMarks::default()` by a caller that seeds *only when the file is
    /// missing* would mark every message in every conversation unread at once,
    /// with no route back but opening each thread by hand — the module's
    /// "costs one over-count" argument holds for one conversation, not for the
    /// whole set (`consensus-auditor`, this sitting).
    pub fn read(dir: &Path) -> Option<Self> {
        let bytes = std::fs::read(dir.join(READ_MARKS_FILE)).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        write_json(&dir.join(READ_MARKS_FILE), self)
    }

    pub fn path(dir: &Path) -> PathBuf {
        dir.join(READ_MARKS_FILE)
    }

    pub fn get(&self, conversation_id: &str) -> Option<&ReadMark> {
        self.marks.get(conversation_id)
    }

    /// Move a conversation's mark forward. **Forward only, and idempotent** —
    /// a stale pull, a re-entered thread or an out-of-order ping can only
    /// re-assert a mark, never rewind one and resurrect a count the user has
    /// already cleared.
    ///
    /// Returns `true` when the mark actually moved, so the caller can decide
    /// whether anything is worth persisting or pinging about.
    pub fn advance(&mut self, conversation_id: &str, unix_ms: u64, txid: &str) -> bool {
        match self.marks.get_mut(conversation_id) {
            Some(mark) if !mark.precedes(unix_ms, txid) => false,
            Some(mark) => {
                mark.unix_ms = unix_ms;
                mark.txid = txid.to_string();
                true
            }
            None => {
                self.marks.insert(
                    conversation_id.to_string(),
                    ReadMark {
                        unix_ms,
                        txid: txid.to_string(),
                    },
                );
                true
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mark_orders_on_the_pair_the_store_sorts_on() {
        let mark = ReadMark {
            unix_ms: 100,
            txid: "bb".to_string(),
        };
        // Same block, a later txid — unread.
        assert!(mark.precedes(100, "cc"));
        // Same block, an earlier txid — already read. This is the case a
        // timestamp-only watermark gets wrong in one direction or the other.
        assert!(!mark.precedes(100, "aa"));
        // The mark's own row is never unread.
        assert!(!mark.precedes(100, "bb"));
        assert!(mark.precedes(101, "aa"));
        assert!(!mark.precedes(99, "zz"));
    }

    #[test]
    fn advance_moves_forward_only() {
        let mut marks = ReadMarks::default();
        assert!(marks.advance("c1", 100, "bb"));
        // Idempotent re-assert.
        assert!(!marks.advance("c1", 100, "bb"));
        // A rewind is refused — the count stays cleared.
        assert!(!marks.advance("c1", 50, "zz"));
        assert_eq!(marks.get("c1").unwrap().unix_ms, 100);
        assert!(marks.advance("c1", 100, "cc"));
        assert_eq!(marks.get("c1").unwrap().txid, "cc");
    }

    #[test]
    fn an_unmarked_conversation_has_no_mark() {
        let marks = ReadMarks::default();
        assert!(marks.get("nobody").is_none());
    }

    fn dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-marks-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn marks_round_trip_and_survive_a_missing_or_corrupt_file() {
        let d = dir("roundtrip");
        // An absent file is "nothing read", never an error.
        assert_eq!(ReadMarks::load(&d), ReadMarks::default());

        std::fs::write(ReadMarks::path(&d), b"{ not json").unwrap();
        assert_eq!(ReadMarks::load(&d), ReadMarks::default(), "corrupt");

        let mut marks = ReadMarks::default();
        marks.advance("c1", 7, "aa");
        marks.save(&d).unwrap();
        assert_eq!(ReadMarks::load(&d), marks);
    }

    /// A torn write must be distinguishable from a fresh install, or the
    /// caller that seeds on absence silently skips the re-seed and every
    /// thread on the device reads as unread.
    #[test]
    fn an_unreadable_file_is_told_apart_from_an_absent_one() {
        let d = dir("torn");
        assert!(ReadMarks::read(&d).is_none(), "absent");

        // A half-written file — what a kill mid-`write_json` leaves.
        std::fs::write(ReadMarks::path(&d), br#"{"marks":{"c1":{"unix_"#).unwrap();
        assert!(ReadMarks::read(&d).is_none(), "torn reads as unusable");

        let mut marks = ReadMarks::default();
        marks.advance("c1", 7, "aa");
        marks.save(&d).unwrap();
        assert_eq!(ReadMarks::read(&d), Some(marks), "a whole file reads back");
    }
}
