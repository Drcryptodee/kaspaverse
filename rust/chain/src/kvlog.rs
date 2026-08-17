//! kvlog — the shared append-only frame log (the proven P1.5 activity-store
//! pattern, extracted from `transport_store.rs` at hardening V1 so the
//! acceptance tracker reuses it instead of re-inventing it).
//!
//! Framing: `[u32 LE len][borsh frame]`, upsert + tombstone + remove, torn-
//! tail-tolerant replay, in-memory map as source of truth with the file as
//! its durable replay log.
//!
//! **Frame compatibility law:** variants are append-only and positional
//! (borsh writes the variant index). `Upsert`=0 and `Remove`=1 are the P2.3
//! wire; `Tombstone`=2 / `Untombstone`=3 were added at V1 — logs written
//! before V1 replay unchanged, because old files simply never contain the
//! new indices. Never reorder or remove a variant.
//!
//! Tombstone vs Remove: `Remove` deletes the record from the map (gone on
//! replay); `Tombstone` keeps the record but flags it — the reversible
//! "ghost" state the reorg lane needs (a displaced message can be
//! re-accepted later; a ghost must be able to come back, D-073 V1 design).

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use borsh::{BorshDeserialize, BorshSerialize};

use crate::error::{ChainError, Result};

/// One persisted frame. See the module docs for the compatibility law.
#[derive(BorshSerialize, BorshDeserialize)]
pub(crate) enum Frame<T> {
    Upsert(T),
    Remove(String),
    Tombstone(String),
    Untombstone(String),
}

/// Length-prefix a frame: `[u32 LE len][borsh body]`.
fn frame_bytes<T: BorshSerialize>(frame: &Frame<T>) -> Result<Vec<u8>> {
    let body =
        borsh::to_vec(frame).map_err(|e| ChainError::Message(format!("kvlog encode: {e}")))?;
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

/// Replay an append-only log (last-write-wins per key; removes delete;
/// tombstones flag). Tolerates a torn final frame and stops at a corrupt
/// body, keeping everything decoded so far — same crash posture as the P1.5
/// activity store.
fn replay<T: BorshDeserialize>(
    bytes: &[u8],
    key_of: impl Fn(&T) -> String,
) -> (HashMap<String, T>, HashSet<String>) {
    let mut records = HashMap::new();
    let mut tombstoned = HashSet::new();
    let mut cursor = bytes;
    while cursor.len() >= 4 {
        let len = u32::from_le_bytes([cursor[0], cursor[1], cursor[2], cursor[3]]) as usize;
        cursor = &cursor[4..];
        if cursor.len() < len {
            break; // torn tail
        }
        let (body, rest) = cursor.split_at(len);
        cursor = rest;
        match Frame::<T>::try_from_slice(body) {
            Ok(Frame::Upsert(record)) => {
                records.insert(key_of(&record), record);
            }
            Ok(Frame::Remove(key)) => {
                records.remove(&key);
                tombstoned.remove(&key);
            }
            Ok(Frame::Tombstone(key)) => {
                tombstoned.insert(key);
            }
            Ok(Frame::Untombstone(key)) => {
                tombstoned.remove(&key);
            }
            Err(_) => break, // corrupt frame — keep what we have
        }
    }
    (records, tombstoned)
}

/// One append-only log file + its replayed state.
pub(crate) struct Log<T> {
    path: PathBuf,
    pub(crate) records: HashMap<String, T>,
    tombstoned: HashSet<String>,
}

impl<T: BorshSerialize + BorshDeserialize + Clone> Log<T> {
    pub(crate) fn load(path: PathBuf, key_of: impl Fn(&T) -> String) -> Result<Self> {
        let (records, tombstoned) = match std::fs::read(&path) {
            Ok(bytes) => replay(&bytes, key_of),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Default::default(),
            Err(e) => return Err(e.into()),
        };
        Ok(Self {
            path,
            records,
            tombstoned,
        })
    }

    fn append(&self, frame: &Frame<T>) -> Result<()> {
        use std::io::Write;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        file.write_all(&frame_bytes(frame)?)?;
        file.sync_all()?;
        Ok(())
    }

    pub(crate) fn upsert(&mut self, key: String, record: T) -> Result<()> {
        self.append(&Frame::Upsert(record.clone()))?;
        self.records.insert(key, record);
        Ok(())
    }

    /// Delete a record for good.
    ///
    /// **Append first, mutate second** — the same law [`Self::wipe`] states,
    /// and this used to have it backwards. Dropping the record from the map
    /// before the frame is durable means a failed write leaves an empty screen
    /// over a log that still holds the `Upsert`, so everything the caller
    /// reported as deleted comes back at the next start. Callers that swallow
    /// the error (the message-purge lanes do) turned that into a silent lie.
    /// This order makes a failure honest: nothing is removed, and the `Err`
    /// says so.
    pub(crate) fn remove(&mut self, key: &str) -> Result<()> {
        if self.records.contains_key(key) {
            self.append(&Frame::Remove(key.to_string()))?;
            self.records.remove(key);
            self.tombstoned.remove(key);
        }
        Ok(())
    }

    /// Flag a record as tombstoned (the reversible ghost). Returns `false` —
    /// without touching the log — for an unknown key or one already
    /// tombstoned, so re-fired reorg events never grow the file.
    pub(crate) fn tombstone(&mut self, key: &str) -> Result<bool> {
        if !self.records.contains_key(key) || self.tombstoned.contains(key) {
            return Ok(false);
        }
        self.append(&Frame::Tombstone(key.to_string()))?;
        self.tombstoned.insert(key.to_string());
        Ok(true)
    }

    /// Clear a tombstone (a displaced tx was re-accepted — the ghost comes
    /// back). Idempotent like [`Self::tombstone`].
    pub(crate) fn untombstone(&mut self, key: &str) -> Result<bool> {
        if !self.tombstoned.contains(key) {
            return Ok(false);
        }
        self.append(&Frame::Untombstone(key.to_string()))?;
        self.tombstoned.remove(key);
        Ok(true)
    }

    pub(crate) fn is_tombstoned(&self, key: &str) -> bool {
        self.tombstoned.contains(key)
    }

    /// Erase every record, on disk and in memory.
    ///
    /// **The file is emptied before the maps are, and that order is the whole
    /// safety property.** These two must never disagree: clear memory first
    /// and a failed write leaves a log full of records that the next append
    /// would extend, so a restart resurrects everything the user asked to
    /// destroy. Emptying the file first means a failure returns `Err` with
    /// both halves still intact and consistent — the caller retries, and
    /// nothing is half-deleted.
    ///
    /// Atomic via temp-file + rename, like [`Self::compact_if_larger_than`]:
    /// a crash mid-wipe leaves either the whole old log or an empty one, never
    /// a torn frame that `replay` would stop at.
    ///
    /// **And durable, not merely atomic.** The empty file is fsynced before
    /// the rename and the directory entry is fsynced after it. Without both,
    /// a power loss seconds after "delete everything" can leave the old log
    /// on disk and the user believing it is gone — every ordinary
    /// [`Self::append`] on this log already pays `sync_all`, so an erase that
    /// did not would be the one write we left to chance.
    ///
    /// Not `remove_file`: the log is re-opened for append by the same live
    /// object, and an absent parent directory is a different failure to
    /// diagnose than an empty file.
    pub(crate) fn wipe(&mut self) -> Result<()> {
        let parent = self.path.parent();
        if let Some(parent) = parent {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = self.path.with_extension("wipe.tmp");
        std::fs::File::create(&tmp)?.sync_all()?;
        std::fs::rename(&tmp, &self.path)?;
        // The rename itself is metadata; without this the directory entry can
        // still be the old one after a crash. Best-effort: on the platforms
        // that refuse a directory fsync this is not an erase failure, and the
        // data write above is already durable.
        if let Some(parent) = parent {
            if let Ok(dir) = std::fs::File::open(parent) {
                let _ = dir.sync_all();
            }
        }
        self.records.clear();
        self.tombstoned.clear();
        Ok(())
    }

    /// Rewrite the file as one Upsert per live record (+ its tombstone flag)
    /// when it has outgrown `threshold_bytes` — churn-heavy logs (the
    /// acceptance watch-set) stay bounded. Called at load time only, before
    /// any concurrent writer exists; atomic via temp-file + rename so a
    /// crash mid-compaction leaves the original intact.
    pub(crate) fn compact_if_larger_than(&mut self, threshold_bytes: u64) -> Result<()> {
        let size = std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0);
        if size <= threshold_bytes {
            return Ok(());
        }
        let mut out = Vec::new();
        for record in self.records.values() {
            out.extend_from_slice(&frame_bytes(&Frame::Upsert(record.clone()))?);
        }
        for key in &self.tombstoned {
            out.extend_from_slice(&frame_bytes::<T>(&Frame::Tombstone(key.clone()))?);
        }
        let tmp = self.path.with_extension("compact.tmp");
        std::fs::write(&tmp, &out)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(BorshSerialize, BorshDeserialize, Clone, Debug, PartialEq)]
    struct Row {
        id: String,
        value: u64,
    }

    fn row(id: &str, value: u64) -> Row {
        Row {
            id: id.to_string(),
            value,
        }
    }

    /// A REMOVE THAT FAILS MUST REMOVE NOTHING.
    ///
    /// `remove` used to drop the record from the map and only then append the
    /// frame, so a failed write left an empty screen over a log that still
    /// held the `Upsert` — everything reported deleted came back at the next
    /// start. The append is made to fail by putting a FILE where the log's
    /// parent directory has to be, so `create_dir_all` cannot succeed.
    #[test]
    fn a_failed_remove_leaves_the_record_intact() {
        let dir = std::env::temp_dir().join(format!("kv-kvlog-remove-fail-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let path = dir.join("log.kvlog");
        let mut log = Log::<Row>::load(path.clone(), |r| r.id.clone()).unwrap();
        log.upsert("a".to_string(), row("a", 1)).unwrap();

        // Replace the log's parent with a regular file: every subsequent
        // append fails, and so must every remove.
        std::fs::remove_dir_all(&dir).unwrap();
        std::fs::write(&dir, b"not a directory").unwrap();

        assert!(
            log.remove("a").is_err(),
            "a remove that cannot append must fail"
        );
        assert!(
            log.records.contains_key("a"),
            "and it must leave the record where the durable log still has it"
        );

        let _ = std::fs::remove_file(&dir);
    }

    /// A wipe is durable, not merely atomic: the emptied file must survive a
    /// reload, and the temp file must never be left behind to be replayed.
    #[test]
    fn a_wipe_leaves_an_empty_log_and_no_debris() {
        let path = test_path("wipe-debris");
        let mut log = Log::<Row>::load(path.clone(), |r| r.id.clone()).unwrap();
        for id in ["a", "b", "c"] {
            log.upsert(id.to_string(), row(id, 1)).unwrap();
        }
        log.tombstone("b").unwrap();
        log.wipe().unwrap();

        assert_eq!(std::fs::metadata(&path).unwrap().len(), 0);
        assert!(
            !path.with_extension("wipe.tmp").exists(),
            "the temp file must be renamed away, never left to confuse a later read"
        );
        let reloaded = Log::<Row>::load(path, |r| r.id.clone()).unwrap();
        assert!(reloaded.records.is_empty());
        assert!(!reloaded.is_tombstoned("b"));
    }

    fn test_path(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-kvlog-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join("test.kvlog")
    }

    fn key_of(r: &Row) -> String {
        r.id.clone()
    }

    #[test]
    fn upsert_remove_round_trip() {
        let path = test_path("basic");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        log.upsert("b".into(), row("b", 2)).unwrap();
        log.upsert("a".into(), row("a", 3)).unwrap(); // last write wins
        log.remove("b").unwrap();
        log.remove("never-there").unwrap(); // no-op, no frame

        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(reloaded.records.len(), 1);
        assert_eq!(reloaded.records["a"], row("a", 3));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn tombstone_flags_without_removing_and_reverses() {
        let path = test_path("tomb");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();

        assert!(log.tombstone("a").unwrap());
        assert!(!log.tombstone("a").unwrap(), "idempotent — no second frame");
        assert!(!log.tombstone("unknown").unwrap(), "unknown key is a no-op");
        assert!(log.is_tombstoned("a"));
        assert!(log.records.contains_key("a"), "the record STAYS (ghost)");

        // The flag survives replay.
        let mut reloaded = Log::load(path.clone(), key_of).unwrap();
        assert!(reloaded.is_tombstoned("a"));
        assert_eq!(reloaded.records["a"], row("a", 1));

        // Reversal (re-acceptance) survives replay too.
        assert!(reloaded.untombstone("a").unwrap());
        assert!(!reloaded.untombstone("a").unwrap(), "idempotent");
        let again = Log::load(path.clone(), key_of).unwrap();
        assert!(!again.is_tombstoned("a"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn remove_clears_a_tombstone_flag() {
        let path = test_path("rm-tomb");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        log.tombstone("a").unwrap();
        log.remove("a").unwrap();

        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert!(reloaded.records.is_empty());
        assert!(!reloaded.is_tombstoned("a"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// A log written before the V1 variants existed (Upsert/Remove only)
    /// replays unchanged — the compatibility law made testable.
    #[test]
    fn pre_v1_logs_replay_unchanged() {
        let path = test_path("compat");
        // Hand-write frames exactly as the P2.3 code did (variants 0 and 1).
        let mut bytes = Vec::new();
        for frame in [
            Frame::Upsert(row("a", 1)),
            Frame::Upsert(row("b", 2)),
            Frame::<Row>::Remove("b".into()),
        ] {
            bytes.extend_from_slice(&frame_bytes(&frame).unwrap());
        }
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &bytes).unwrap();

        let log = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(log.records.len(), 1);
        assert_eq!(log.records["a"], row("a", 1));
        assert!(!log.is_tombstoned("a"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn replay_tolerates_torn_tail_and_corrupt_frames() {
        let path = test_path("torn");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();

        let mut bytes = std::fs::read(&path).unwrap();
        bytes.extend_from_slice(&40u32.to_le_bytes());
        bytes.extend_from_slice(&[9, 9, 9]); // claims 40 bytes, has 3
        std::fs::write(&path, &bytes).unwrap();

        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(reloaded.records.len(), 1, "intact frame survives");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn compaction_shrinks_churned_logs_and_preserves_state() {
        let path = test_path("compact");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        // Churn: many upserts + removes on a small live set.
        for i in 0..200u64 {
            let id = format!("k{}", i % 5);
            log.upsert(id.clone(), row(&id, i)).unwrap();
        }
        log.remove("k4").unwrap();
        log.tombstone("k3").unwrap();
        let before = std::fs::metadata(&path).unwrap().len();

        let mut reloaded = Log::load(path.clone(), key_of).unwrap();
        reloaded.compact_if_larger_than(64).unwrap();
        let after = std::fs::metadata(&path).unwrap().len();
        assert!(after < before, "compaction shrank the file");

        let verify = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(verify.records.len(), 4);
        assert_eq!(verify.records["k3"], row("k3", 198));
        assert!(verify.is_tombstoned("k3"));
        assert!(!verify.records.contains_key("k4"));

        // Under the threshold: untouched.
        let mut small = Log::load(path.clone(), key_of).unwrap();
        small.compact_if_larger_than(u64::MAX).unwrap();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
