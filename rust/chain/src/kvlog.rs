//! kvlog — the one durable log every store keeps: the transport store's two
//! logs, the acceptance watch log and, since PRE3-LOG, the wallet activity
//! log, which used to run on its own copy of this code.
//!
//! **Format v2 (PRE3-LOG).** An eight-byte file header, `KVLG` then the
//! version as `u32` little-endian, then frames of
//! `[u32 LE len][u32 LE crc32(len ‖ body)][borsh body]`. The checksum covers
//! the length too, so the zeros a crash can leave where a frame should be are
//! never a valid frame (`crc32` of four zero bytes is not zero), and a corrupt
//! body is caught before the decoder sees it instead of being decoded by luck.
//! v1 had neither header nor checksum (`[u32 LE len][borsh body]`); a v1 file
//! is read once and migrated by an atomic compaction.
//!
//! **Recovery is point-in-time**, the field's default (RocksDB's
//! `kPointInTimeRecovery`; Kafka's `LogSegment.recover` truncating to the last
//! valid byte; SQLite WAL replaying only up to its first invalid frame):
//! replay stops at the first frame that fails its length, checksum or decode
//! and keeps everything before it. What follows the stop is then CUT before
//! anything else is written. The old load cut nothing, so the next frame
//! landed behind the torn bytes and every later start lost it (F3).
//!
//! It is cut without a copy only when it provably holds no frame: shorter
//! than a frame header, all zeros, or (v2) a single torn frame — no
//! checksum-valid frame starts anywhere in it, and its first header's
//! declared extent reaches the end of the file, because one append is in
//! flight when a process dies. Anything else is a bad frame with data behind
//! it, which in v2 only corruption can produce (or a checksum failing on every
//! frame), and in v1 also a torn frame the old writer appended past. Those
//! bytes, and only those (everything before the stop survives in the rewritten
//! log), are copied aside first as
//! `<file>.unreadable-<offset>-<length>-<crc32>`, the block list's quarantine
//! posture, so a repair never destroys bytes it could not read. An erase the
//! user asks for removes the copies ([`Log::remove_asides`], called by the
//! store's scrub and wipe).
//!
//! **The writer always writes at the end it knows is good, and cuts only what
//! it knows is garbage**: a write of its own that failed half-way, or a tail
//! its own load classified and could not rewrite away. A failed write
//! therefore cannot hide the next one either. Bytes some other writer
//! appended are never cut: the write is refused, loudly. Writing at a
//! remembered end assumes one writer per file, where the old append mode
//! tolerated two, so every store keeps one instance per file per process.
//!
//! **A log that cannot be made safe to write is served read-only**, never
//! refused outright and never cut: when the checksum fails its known answer on
//! this device, when a v1 migration cannot be written, or when unreadable
//! bytes cannot be copied aside. Its records still load (the wallet must still
//! open and spend); every write returns `Err`. A store whose writes must not
//! fail silently refuses a held log at its own load ([`Log::hold`]).
//!
//! **Compaction** rewrites the file as one frame per live record plus its
//! tombstone flag, through the crate's one durable write
//! ([`crate::durable::atomic_write`]), and checks that the image replays to
//! the state it was built from before it replaces anything. It runs at load
//! when the file is v1, has a tail to cut, or has grown past
//! [`COMPACT_RATIO`] times its live size and past [`COMPACT_FLOOR`]; and on
//! demand ([`Log::compact`]) after an erase, which also deletes the copies
//! kept aside ([`Log::remove_asides`]).
//!
//! **Frame compatibility law** (unchanged by v2, which changed the framing
//! around the body and never the body): variants are append-only and
//! positional (borsh writes the variant index). `Upsert`=0 and `Remove`=1 are
//! the P2.3 wire; `Tombstone`=2 / `Untombstone`=3 were added at V1. Never
//! reorder or remove a variant.
//!
//! Tombstone vs Remove: `Remove` deletes the record from the map (gone on
//! replay); `Tombstone` keeps the record but flags it — the reversible
//! "ghost" state the reorg lane needs (a displaced message can be
//! re-accepted later; a ghost must be able to come back, D-073 V1 design).

use std::collections::{HashMap, HashSet};
use std::io::{Seek, SeekFrom, Write};
use std::path::PathBuf;

use borsh::{BorshDeserialize, BorshSerialize};

use crate::durable::atomic_write;
use crate::error::{ChainError, Result};

/// One persisted frame. See the module docs for the compatibility law.
#[derive(BorshSerialize, BorshDeserialize)]
pub(crate) enum Frame<T> {
    Upsert(T),
    Remove(String),
    Tombstone(String),
    Untombstone(String),
}

/// The first four bytes of a v2 file. As a v1 frame length it would claim
/// 1.2 GB, so no v1 file this app ever wrote can start with it.
const MAGIC: [u8; 4] = *b"KVLG";
const VERSION: u32 = 2;
const FILE_HEADER_LEN: usize = 8;
const FRAME_HEADER_LEN: usize = 8;
const V1_FRAME_HEADER_LEN: usize = 4;

/// **Compact at load once the file is this many times its live size**, and
/// past [`COMPACT_FLOOR`]: Redis's AOF-rewrite rule
/// (`auto-aof-rewrite-percentage 100`, rewrite when the file has doubled,
/// with a minimum size), which is Kafka's default `min.cleanable.dirty.ratio`
/// of 0.5 seen from the dead side. Each rewrite resets the file to its live
/// size, so rewrite work is amortized over the bytes appended since, and a
/// load starts from at most the larger of [`COMPACT_FLOOR`] and twice the live
/// size the previous load left, plus what was appended since (the rule runs
/// at load, not between).
const COMPACT_RATIO: u64 = 2;

/// **The floor under which a log is left to grow.** Fitted on the funded
/// phone's own stores (2026-10-03, frames counted, nothing decoded): after
/// migration their live sizes are about 1.2 KB (conversations), 1.4 KB
/// (acceptance), 20 KB (messages) and 214 KB (activity), and over the
/// install's 52 days they grew about 0.6, 0.9, 1.1 and 12 KB a day. Below
/// 64 KiB the three small logs rewrite after weeks of growth (about 100, 70
/// and 40 days) instead of every couple of days, and the activity log, the
/// one F62 grows, sits above the floor so the ratio alone governs it (about
/// 18 days at that rate). Those logs were 65–97 % dead bytes at the count
/// (618 KB holding 214 KB live), and the acceptance log's old fixed 256 KiB
/// threshold had never once fired on that phone.
const COMPACT_FLOOR: u64 = 64 * 1024;

/// The standard CRC-32 check value and a 4 KiB pattern long enough to reach
/// the accelerated paths, both computed by zlib, an implementation independent
/// of the one in use.
const CHECK_VALUE: u32 = 0xCBF4_3926;
const LONG_PATTERN_CRC: u32 = 0x5D1C_4EE3;
/// `frame_crc` of a three-byte body `abc` (its length, then the body, through
/// two hasher updates), also from zlib.
const FRAME_ABC_CRC: u32 = 0x66E1_5D33;
/// `frame_crc` of the 4 KiB pattern as a body: a carried state reaching the
/// accelerated path in the second update (zlib; `dependency-steward`).
const FRAME_LONG_CRC: u32 = 0x6F23_BA11;
/// `frame_crc` of bytes 1..4094 of that pattern (4093 bytes): unaligned start,
/// leftover words and trailing bytes on every path (zlib; `dependency-steward`).
const FRAME_UNALIGNED_CRC: u32 = 0x3EE0_5566;

fn long_pattern() -> Vec<u8> {
    (0..4096u32)
        .map(|i| i.wrapping_mul(31).wrapping_add(7) as u8)
        .collect()
}

/// **The checksum is checked before it judges anything.** A broken
/// implementation (a dependency update that changed the output, a faulty
/// hardware path) would fail every frame of every file, and a load would read
/// the logs as empty and cut them. So the known answers are asserted once per
/// process, on this device's own code path (the phone takes crc32fast's
/// hardware-CRC route, which the host gate never runs); if they fail, logs are
/// read without the checksum and served read-only.
fn checksum_holds() -> bool {
    #[cfg(test)]
    if testing::CHECKSUM_BROKEN.with(|broken| broken.get()) {
        return false;
    }
    static HOLDS: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *HOLDS.get_or_init(|| {
        crc32fast::hash(b"123456789") == CHECK_VALUE
            && crc32fast::hash(&long_pattern()) == LONG_PATTERN_CRC
            && frame_crc(&3u32.to_le_bytes(), b"abc") == FRAME_ABC_CRC
            && frame_crc(&4096u32.to_le_bytes(), &long_pattern()) == FRAME_LONG_CRC
            && frame_crc(&4093u32.to_le_bytes(), &long_pattern()[1..4094]) == FRAME_UNALIGNED_CRC
    })
}

/// The growth rule, alone so its boundaries can be tested.
fn grown(file_len: u64, live_len: u64) -> bool {
    file_len > COMPACT_FLOOR && file_len > COMPACT_RATIO.saturating_mul(live_len)
}

fn encode<B: BorshSerialize>(value: &B) -> Result<Vec<u8>> {
    borsh::to_vec(value).map_err(|e| ChainError::Message(format!("kvlog encode: {e}")))
}

/// `Frame::Upsert(record)`'s own bytes (variant 0, then the record) without
/// cloning the record into a frame.
fn upsert_body<T: BorshSerialize>(record: &T) -> Result<Vec<u8>> {
    let mut body = vec![0u8];
    record
        .serialize(&mut body)
        .map_err(|e| ChainError::Message(format!("kvlog encode: {e}")))?;
    Ok(body)
}

fn frame_crc(len: &[u8; 4], body: &[u8]) -> u32 {
    let mut hasher = crc32fast::Hasher::new();
    hasher.update(len);
    hasher.update(body);
    hasher.finalize()
}

fn push_file_header(out: &mut Vec<u8>) {
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
}

fn push_frame(out: &mut Vec<u8>, body: &[u8]) -> Result<()> {
    let len = u32::try_from(body.len())
        .map_err(|_| ChainError::Message("kvlog: frame over 4 GiB".to_string()))?
        .to_le_bytes();
    out.extend_from_slice(&len);
    out.extend_from_slice(&frame_crc(&len, body).to_le_bytes());
    out.extend_from_slice(body);
    Ok(())
}

/// The v1 body was the borsh frame itself; this is its decoder for every log
/// that kept [`Frame`] (the transport store and the acceptance tracker).
fn v1_frame<T: BorshDeserialize>(body: &[u8]) -> Option<Frame<T>> {
    Frame::<T>::try_from_slice(body).ok()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Format {
    Empty,
    V1,
    V2,
}

/// What a load found after the last good frame. Counts in bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tail {
    /// The file ends on a frame boundary.
    Clean,
    /// Bytes that provably hold no frame: cut them.
    Torn(usize),
    /// Bytes that may hold frames: copy them aside, then cut them.
    Unreadable(usize),
}

struct Replayed<T> {
    format: Format,
    records: HashMap<String, T>,
    tombstoned: HashSet<String>,
    frames: usize,
    /// Whether any `Remove` frame was replayed: a removed record's bytes are
    /// still in the file.
    removed: bool,
    /// Byte offset just past the last good frame.
    good_end: usize,
    tail: Tail,
    /// What this state rewrites to, in v2 bytes: the growth rule's yardstick.
    live_len: u64,
}

/// Read one v2 frame at the start of `bytes`: `(body, frame length)` when its
/// length fits and its checksum holds.
fn v2_frame_at(bytes: &[u8]) -> Option<(&[u8], usize)> {
    v2_frame_checked(bytes, true)
}

/// [`v2_frame_at`], with the checksum comparison skippable: only for reading
/// a log read-only when the checksum implementation itself failed its known
/// answers, never for judging a tail.
fn v2_frame_checked(bytes: &[u8], verify: bool) -> Option<(&[u8], usize)> {
    if bytes.len() < FRAME_HEADER_LEN {
        return None;
    }
    let len_bytes: [u8; 4] = bytes[0..4].try_into().ok()?;
    let len = u32::from_le_bytes(len_bytes) as usize;
    let crc = u32::from_le_bytes(bytes[4..8].try_into().ok()?);
    let end = FRAME_HEADER_LEN.checked_add(len)?;
    let body = bytes.get(FRAME_HEADER_LEN..end)?;
    (!verify || frame_crc(&len_bytes, body) == crc).then_some((body, end))
}

fn tombstone_frame_len(key: &str) -> u64 {
    (FRAME_HEADER_LEN + 1 + 4 + key.len()) as u64
}

/// Replay a log file's bytes: last write wins per key, removes delete,
/// tombstones flag. Stops at the first frame that fails, and says what
/// follows it.
fn replay<T: BorshDeserialize>(
    bytes: &[u8],
    key_of: fn(&T) -> String,
    v1: fn(&[u8]) -> Option<Frame<T>>,
    verify: bool,
) -> Result<Replayed<T>> {
    let mut records = HashMap::new();
    let mut tombstoned = HashSet::new();
    let mut sizes: HashMap<String, u64> = HashMap::new();
    let mut frames = 0;
    let mut removed = false;

    let (format, mut at) = if bytes.is_empty() {
        (Format::Empty, 0)
    } else if bytes.len() >= FILE_HEADER_LEN && bytes[..4] == MAGIC {
        let version = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
        if version != VERSION {
            // A newer app wrote this. Reading it as anything else would cut
            // what it cannot parse, so refuse and leave the file as it is.
            return Err(ChainError::Message(format!(
                "kvlog: format version {version} is newer than this build reads ({VERSION})"
            )));
        }
        (Format::V2, FILE_HEADER_LEN)
    } else if bytes.len() < FILE_HEADER_LEN && MAGIC.starts_with(&bytes[..bytes.len().min(4)]) {
        // The first append's header, torn: nothing was ever written behind it.
        (Format::V2, 0)
    } else {
        (Format::V1, 0)
    };

    loop {
        let rest = &bytes[at..];
        let (frame, body_len, step) = match format {
            Format::Empty => break,
            Format::V2 => {
                if at == 0 {
                    break; // a torn file header
                }
                let Some((body, step)) = v2_frame_checked(rest, verify) else {
                    break;
                };
                let Ok(frame) = Frame::<T>::try_from_slice(body) else {
                    break;
                };
                (frame, body.len(), step)
            }
            Format::V1 => {
                if rest.len() < V1_FRAME_HEADER_LEN {
                    break;
                }
                let len = u32::from_le_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
                let Some(body) = rest.get(V1_FRAME_HEADER_LEN..V1_FRAME_HEADER_LEN + len) else {
                    break;
                };
                let Some(frame) = v1(body) else {
                    break;
                };
                (frame, body.len(), V1_FRAME_HEADER_LEN + len)
            }
        };
        match frame {
            Frame::Upsert(record) => {
                let key = key_of(&record);
                sizes.insert(key.clone(), (FRAME_HEADER_LEN + body_len) as u64);
                records.insert(key, record);
            }
            Frame::Remove(key) => {
                records.remove(&key);
                tombstoned.remove(&key);
                sizes.remove(&key);
                removed = true;
            }
            Frame::Tombstone(key) => {
                tombstoned.insert(key);
            }
            Frame::Untombstone(key) => {
                tombstoned.remove(&key);
            }
        }
        frames += 1;
        at += step;
    }

    let tail = classify(format, &bytes[at..]);
    let live_len = FILE_HEADER_LEN as u64
        + sizes.values().sum::<u64>()
        + tombstoned
            .iter()
            .map(|k| tombstone_frame_len(k))
            .sum::<u64>();
    Ok(Replayed {
        format,
        records,
        tombstoned,
        frames,
        removed,
        good_end: at,
        tail,
        live_len,
    })
}

/// Decide what the bytes after the last good frame are. See the module docs.
fn classify(format: Format, rest: &[u8]) -> Tail {
    let n = rest.len();
    if n == 0 {
        return Tail::Clean;
    }
    if rest.iter().all(|&b| b == 0) {
        return Tail::Torn(n);
    }
    match format {
        Format::Empty => Tail::Clean,
        Format::V1 => {
            if n < V1_FRAME_HEADER_LEN {
                Tail::Torn(n)
            } else {
                // No checksum to resync on, and the v1 writer appended past
                // tears: any of these bytes may be a frame.
                Tail::Unreadable(n)
            }
        }
        Format::V2 => {
            // A checksum-valid frame at the stop (whose body would not decode:
            // something wrote it whole) or anywhere after it (LevelDB's reader
            // resyncs the same way, on its block boundaries) is data behind a
            // bad frame. A false match is a 2^-32 event per offset.
            if (0..n).any(|i| v2_frame_at(&rest[i..]).is_some()) {
                return Tail::Unreadable(n);
            }
            if n < FRAME_HEADER_LEN {
                return Tail::Torn(n);
            }
            // **A tear is at most one frame**: one append was in flight when
            // the process died, so its declared extent reaches the end of the
            // file. Anything longer is not a tear, and is copied aside before
            // the cut: it is what a checksum failing on EVERY frame looks like
            // (the dependency steward's case), and a cut without a copy would
            // destroy every frame.
            let len = u32::from_le_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
            if FRAME_HEADER_LEN.saturating_add(len) >= n {
                Tail::Torn(n)
            } else {
                Tail::Unreadable(n)
            }
        }
    }
}

/// One log file and its replayed state. The in-memory maps are the source
/// of truth for readers; the file is their durable replay.
pub(crate) struct Log<T> {
    path: PathBuf,
    key_of: fn(&T) -> String,
    pub(crate) records: HashMap<String, T>,
    tombstoned: HashSet<String>,
    /// Where the next frame goes: just past the last frame this log knows is
    /// good. Zero means the file holds nothing yet, header included.
    end: u64,
    /// The bytes past [`Self::end`] are this log's own garbage, and the next
    /// write may cut them: a write of its own failed, or its load classified a
    /// tail it could not rewrite away. Anything past the end without this is
    /// another writer's, and is never cut.
    cut_owed: bool,
    /// Why this log is read-only, when it is. See the module docs.
    held: Option<&'static str>,
    /// A `Remove` frame is in the file, so a removed record's bytes are too:
    /// replayed at load, or written since the last compaction.
    removed: bool,
}

impl<T: BorshSerialize + BorshDeserialize + Clone> Log<T> {
    pub(crate) fn load(path: PathBuf, key_of: fn(&T) -> String) -> Result<Self> {
        Self::load_with_v1(path, key_of, v1_frame::<T>)
    }

    /// Load a log whose v1 body was not [`Frame`] (the activity log's). The
    /// decoder is used once, to migrate; v2 bodies are always [`Frame`].
    pub(crate) fn load_with_v1(
        path: PathBuf,
        key_of: fn(&T) -> String,
        v1: fn(&[u8]) -> Option<Frame<T>>,
    ) -> Result<Self> {
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e.into()),
        };
        let verify = checksum_holds();
        let found = replay(&bytes, key_of, v1, verify)?;
        let mut log = Self {
            path,
            key_of,
            records: found.records,
            tombstoned: found.tombstoned,
            end: found.good_end as u64,
            cut_owed: false,
            held: None,
            removed: found.removed,
        };
        let name = log.name();
        let file_len = bytes.len() as u64;

        // Before the empty-file return, or a fresh or wiped log would take
        // frames sealed with the broken checksum (`consensus-auditor` and
        // `dependency-steward`, PRE3-LOG round 3).
        if !verify {
            // Frames were read on their lengths alone, as v1 always was. Judge
            // nothing and write nothing: a write would carry a wrong checksum
            // and a cut would trust one.
            log.held = Some("the checksum fails its known answers on this device");
            log::error!(
                "kvlog: {name}: the checksum fails its known answers here — {} record(s) read \
                 unverified, the log is read-only and nothing was cut",
                log.records.len()
            );
            return Ok(log);
        }
        if found.format == Format::Empty {
            return Ok(log);
        }

        if let Tail::Unreadable(n) = found.tail {
            // Nothing is cut until these bytes are safe somewhere else. Only
            // the cut's bytes: everything before the stop is kept by the
            // rewrite, and copying it too would keep removed rows the user
            // erased (`wallet-security-auditor`, PRE3-LOG).
            let tail = &bytes[found.good_end..];
            let aside = log.aside_path(found.good_end, tail);
            if let Err(e) = atomic_write(&aside, tail) {
                log.held = Some("unreadable bytes could not be copied aside");
                log::error!(
                    "kvlog: {name}: {n} unreadable byte(s) after byte {} could not be copied \
                     aside ({e}) — the log is read-only and nothing was cut",
                    found.good_end
                );
                return Ok(log);
            }
            log::warn!(
                "kvlog: {name}: {n} unreadable byte(s) after byte {} ({} frame(s) kept) — the \
                 unreadable bytes are copied aside as {} before the cut",
                found.good_end,
                found.frames,
                aside.file_name().unwrap_or_default().to_string_lossy()
            );
        }

        let grown = grown(file_len, found.live_len);
        let why = match (found.format, found.tail, grown) {
            (Format::V1, _, _) => Some("migrated v1 → v2"),
            (_, Tail::Torn(_), _) => Some("torn tail cut"),
            (_, Tail::Unreadable(_), _) => Some("unreadable tail cut"),
            (_, Tail::Clean, true) => Some("compacted"),
            _ => None,
        };
        // A tail the load classified is this log's own to cut, by the rewrite
        // below or, if that fails, by the next write.
        log.cut_owed = found.tail != Tail::Clean;
        if let Some(why) = why {
            match log.compact() {
                // Counts only: what the rewrite kept, for a reader with the
                // device log and nothing else (the migration's own witness).
                Ok(()) => log::info!(
                    "kvlog: {name}: {why} — {} frame(s) → {} record(s), {} flagged; {file_len} → \
                     {} bytes",
                    found.frames,
                    log.records.len(),
                    log.tombstoned.len(),
                    log.end
                ),
                // A v2 frame behind v1 bytes would be unreadable, so an
                // unmigrated v1 log takes no write until a load migrates it;
                // its records are still served (the wallet must still open).
                Err(e) if found.format == Format::V1 => {
                    log.held = Some("the v1 file could not be migrated");
                    log::error!(
                        "kvlog: {name}: the v1 → v2 migration failed ({e}) — {} record(s) \
                         served read-only until a later load migrates the file",
                        log.records.len()
                    );
                }
                // A tear's bytes are ours to cut at the next write; growth only
                // costs replay time.
                Err(e) => {
                    log.cut_owed = found.tail != Tail::Clean;
                    log::warn!(
                        "kvlog: {name}: {why} failed ({e}) — kept the file; the next write \
                         lands at byte {}",
                        log.end
                    );
                }
            }
        }
        Ok(log)
    }

    /// Why this log is read-only, when it is. A store whose writes must never
    /// fail silently refuses to open over a held log.
    pub(crate) fn hold(&self) -> Option<&'static str> {
        self.held
    }

    /// Whether a removed record's bytes are still in the file: a `Remove`
    /// frame replayed at load or written since the last compaction.
    pub(crate) fn holds_removed(&self) -> bool {
        self.removed
    }

    fn refuse_if_held(&self) -> Result<()> {
        match self.held {
            Some(why) => Err(ChainError::Message(format!(
                "kvlog: {} is read-only ({why})",
                self.name()
            ))),
            None => Ok(()),
        }
    }

    fn name(&self) -> String {
        self.path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    }

    fn aside_prefix(&self) -> String {
        format!("{}.unreadable-", self.name())
    }

    /// Named by where the cut bytes started, their length and checksum, so a
    /// load retried over the same file (a migration failing on a full disk at
    /// every start) writes the same copy again instead of another one.
    fn aside_path(&self, offset: usize, tail: &[u8]) -> PathBuf {
        self.path.with_file_name(format!(
            "{}{offset}-{}-{:08x}",
            self.aside_prefix(),
            tail.len(),
            crc32fast::hash(tail)
        ))
    }

    /// The copies a load kept of files it could not read whole, and the temp
    /// file a crash can leave mid-copy (`.<name>.unreadable-….tmp`).
    fn asides(&self) -> Result<Vec<PathBuf>> {
        let Some(dir) = self.path.parent() else {
            return Ok(Vec::new());
        };
        let entries = match std::fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e.into()),
        };
        let prefix = self.aside_prefix();
        let temp = format!(".{prefix}");
        let mut out = Vec::new();
        for entry in entries {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with(&prefix) || name.starts_with(&temp) {
                out.push(entry.path());
            }
        }
        Ok(out)
    }

    /// Delete every copy a load kept aside, and say how many. An erase the
    /// user asked for reaches them too: no product surface reads them, and
    /// the cut bytes they hold may include words the user has since erased.
    /// Every copy is tried and the first failure reported, so one that
    /// cannot be deleted does not shield the rest (`wallet-security-auditor`).
    pub(crate) fn remove_asides(&self) -> Result<usize> {
        let asides = self.asides()?;
        let mut first = None;
        for aside in &asides {
            if let Err(e) = std::fs::remove_file(aside) {
                first.get_or_insert(e);
            }
        }
        match first {
            Some(e) => Err(e.into()),
            None => Ok(asides.len()),
        }
    }

    /// Write one frame at [`Self::end`], cutting first only bytes this log
    /// owns (see [`Self::cut_owed`]).
    fn append(&mut self, body: &[u8]) -> Result<()> {
        self.refuse_if_held()?;
        let mut buf = Vec::with_capacity(FILE_HEADER_LEN + FRAME_HEADER_LEN + body.len());
        if self.end == 0 {
            push_file_header(&mut buf);
        }
        push_frame(&mut buf, body)?;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(&self.path)?;
        let on_disk = file.metadata()?.len();
        if on_disk < self.end {
            // Something outside this log shortened the file. Writing at our
            // end would pad the gap with zeros; refuse, loudly.
            return Err(ChainError::Message(format!(
                "kvlog: {} is {on_disk} bytes, shorter than the {} this log wrote — refusing to \
                 write behind a gap",
                self.name(),
                self.end
            )));
        }
        if on_disk > self.end {
            if !self.cut_owed {
                // Not ours: another writer appended (a second instance of this
                // log, which the stores exist to prevent). Cutting would
                // destroy its frames, and writing over them would too.
                log::error!(
                    "kvlog: {} is {on_disk} bytes but this log wrote {} — another writer; \
                     refusing to cut or write",
                    self.name(),
                    self.end
                );
                return Err(ChainError::Message(format!(
                    "kvlog: {} grew behind this log — refusing to write over another writer",
                    self.name()
                )));
            }
            // Our own garbage: a write that failed half-way, or the tail our
            // load classified. Left in place, the frame below would land behind
            // it (F3).
            file.set_len(self.end)?;
        }
        file.seek(SeekFrom::Start(self.end))?;
        let mut write = || -> std::io::Result<()> {
            // The test seam: a write that stops half-way, as a full disk does,
            // failing through the same branch below as a real one.
            #[cfg(test)]
            if let Some(n) = testing::FAIL_WRITE_AFTER.with(|f| f.take()) {
                file.write_all(&buf[..n.min(buf.len())])?;
                return Err(std::io::Error::other(
                    "injected: the write stopped half-way",
                ));
            }
            file.write_all(&buf)?;
            file.sync_all()
        };
        if let Err(e) = write() {
            // Some of these bytes may be on disk: ours to cut next time.
            self.cut_owed = true;
            return Err(e.into());
        }
        self.end += buf.len() as u64;
        self.cut_owed = false;
        Ok(())
    }

    /// Insert or replace a record. Returns `false`, appending nothing, when
    /// the held record is byte-for-byte the same (F62): a re-report that
    /// changes nothing is not a write.
    pub(crate) fn upsert(&mut self, key: String, record: T) -> Result<bool> {
        debug_assert_eq!(
            key,
            (self.key_of)(&record),
            "a record is filed under its own key"
        );
        let body = upsert_body(&record)?;
        if let Some(held) = self.records.get(&key) {
            if upsert_body(held)? == body {
                return Ok(false);
            }
        }
        self.append(&body)?;
        self.records.insert(key, record);
        Ok(true)
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
    ///
    /// The record's bytes stay in the file, behind the `Remove`, until the
    /// next compaction: an erase the user asked for compacts at once
    /// ([`Self::compact`]).
    pub(crate) fn remove(&mut self, key: &str) -> Result<()> {
        if self.records.contains_key(key) {
            self.append(&encode(&Frame::<T>::Remove(key.to_string()))?)?;
            self.records.remove(key);
            self.tombstoned.remove(key);
            self.removed = true;
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
        self.append(&encode(&Frame::<T>::Tombstone(key.to_string()))?)?;
        self.tombstoned.insert(key.to_string());
        Ok(true)
    }

    /// Clear a tombstone (a displaced tx was re-accepted — the ghost comes
    /// back). Idempotent like [`Self::tombstone`].
    pub(crate) fn untombstone(&mut self, key: &str) -> Result<bool> {
        if !self.tombstoned.contains(key) {
            return Ok(false);
        }
        self.append(&encode(&Frame::<T>::Untombstone(key.to_string()))?)?;
        self.tombstoned.remove(key);
        Ok(true)
    }

    pub(crate) fn is_tombstoned(&self, key: &str) -> bool {
        self.tombstoned.contains(key)
    }

    /// Erase every record, on disk and in memory. The copies a load kept aside
    /// are not this function's: a store deletes them itself
    /// ([`Self::remove_asides`]) so that a copy that resists can never stop a
    /// log from being emptied (`consensus-auditor`, PRE3-LOG).
    ///
    /// **The file is emptied before the maps are, and that order is the whole
    /// safety property.** These two must never disagree: clear memory first
    /// and a failed write leaves a log full of records that the next append
    /// would extend, so a restart resurrects everything the user asked to
    /// destroy. Emptying the file first means a failure returns `Err` with
    /// both halves still intact and consistent — the caller retries, and
    /// nothing is half-deleted.
    ///
    /// Atomic and durable through [`atomic_write`]: a crash mid-wipe leaves
    /// either the whole old log or an empty one, never a torn frame, and a
    /// power loss seconds after "delete everything" cannot leave the old log
    /// on disk while the user believes it gone.
    ///
    /// Not `remove_file`: the log is re-opened for writing by the same live
    /// object, and an absent parent directory is a different failure to
    /// diagnose than an empty file.
    pub(crate) fn wipe(&mut self) -> Result<()> {
        self.refuse_if_held()?;
        atomic_write(&self.path, &[])?;
        self.records.clear();
        self.tombstoned.clear();
        self.end = 0;
        self.cut_owed = false;
        self.removed = false;
        Ok(())
    }

    /// The file this state rewrites to: one `Upsert` per live record and one
    /// `Tombstone` per flag, in key order so the same state always makes the
    /// same bytes.
    fn image(&self) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        push_file_header(&mut out);
        let mut keys: Vec<&String> = self.records.keys().collect();
        keys.sort();
        for key in keys {
            push_frame(&mut out, &upsert_body(&self.records[key])?)?;
        }
        let mut flags: Vec<&String> = self.tombstoned.iter().collect();
        flags.sort();
        for key in flags {
            push_frame(&mut out, &encode(&Frame::<T>::Tombstone(key.clone()))?)?;
        }
        Ok(out)
    }

    /// Rewrite the file as its live state, now. The image must replay to
    /// exactly the state it was built from or nothing is replaced: a record
    /// whose decoder does not give back what its encoder wrote would
    /// otherwise be lost by the very rewrite meant to keep it.
    pub(crate) fn compact(&mut self) -> Result<()> {
        self.refuse_if_held()?;
        // [`Self::append`]'s rule, for the rewrite too: a file that GREW behind
        // this log holds another writer's frames, and a rewrite from this
        // log's state would drop them (`ffi-leak-auditor`, PRE3-LOG). A file
        // that shrank behind it is rewritten whole from memory: a restore, not
        // a cut. The real guarantee is one instance per file per process; this
        // only refuses to make a second writer's damage worse.
        let on_disk = match std::fs::metadata(&self.path) {
            Ok(meta) => meta.len(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => 0,
            Err(e) => return Err(e.into()),
        };
        if on_disk > self.end && !self.cut_owed {
            log::error!(
                "kvlog: {} is {on_disk} bytes but this log wrote {} — another writer; refusing \
                 to rewrite over it",
                self.name(),
                self.end
            );
            return Err(ChainError::Message(format!(
                "kvlog: {} grew behind this log — refusing to rewrite over another writer",
                self.name()
            )));
        }
        let image = self.image()?;
        let check = replay(&image, self.key_of, v1_frame::<T>, true)?;
        let same = check.format == Format::V2
            && check.tail == Tail::Clean
            && check.tombstoned == self.tombstoned
            && check.records.len() == self.records.len()
            && check.records.iter().all(|(key, record)| {
                match (self.records.get(key), upsert_body(record)) {
                    (Some(mine), Ok(theirs)) => upsert_body(mine).ok() == Some(theirs),
                    _ => false,
                }
            });
        if !same {
            return Err(ChainError::Message(format!(
                "kvlog: {}: the compacted image does not replay to the state it was built \
                 from — nothing replaced",
                self.name()
            )));
        }
        atomic_write(&self.path, &image)?;
        self.end = image.len() as u64;
        self.cut_owed = false;
        self.removed = false;
        Ok(())
    }
}

/// Test seams other modules' tests share: v1 bytes written the way the v1
/// writer wrote them, and a frame corrupted in place with its checksum
/// recomputed, so a test can reach the record decoder past the checksum.
#[cfg(test)]
pub(crate) mod testing {
    thread_local! {
        /// Make the next frame write on this thread stop after this many
        /// bytes and fail, the way a full disk does. Thread-local, so a test
        /// arms only its own writes.
        pub(crate) static FAIL_WRITE_AFTER: std::cell::Cell<Option<usize>> =
            const { std::cell::Cell::new(None) };

        /// Make the checksum self-check fail on this thread: the device case
        /// the host cannot produce, a crc32fast path that gives wrong answers.
        pub(crate) static CHECKSUM_BROKEN: std::cell::Cell<bool> =
            const { std::cell::Cell::new(false) };
    }

    pub(crate) fn fail_next_write_after(bytes: usize) {
        FAIL_WRITE_AFTER.with(|f| f.set(Some(bytes)));
    }

    /// One v1 frame: `[u32 LE len][body]`. The old framing, kept only to
    /// hand-write old bytes.
    pub(crate) fn v1_frame_bytes(body: &[u8]) -> Vec<u8> {
        let mut out = (body.len() as u32).to_le_bytes().to_vec();
        out.extend_from_slice(body);
        out
    }

    /// Overwrite the last byte of the last frame of a v2 log with `value`
    /// and re-seal that frame's checksum: the frame then fails only in the
    /// record decoder, which is what the decoder's tests need to reach.
    pub(crate) fn corrupt_last_byte_resealed(bytes: &mut [u8], value: u8) {
        let mut at = super::FILE_HEADER_LEN;
        let mut last = None;
        while let Some((_, step)) = super::v2_frame_at(&bytes[at..]) {
            last = Some(at);
            at += step;
        }
        let start = last.expect("a v2 log with at least one frame");
        let end = bytes.len();
        bytes[end - 1] = value;
        let len: [u8; 4] = bytes[start..start + 4].try_into().unwrap();
        let crc = super::frame_crc(&len, &bytes[start + super::FRAME_HEADER_LEN..end]);
        bytes[start + 4..start + 8].copy_from_slice(&crc.to_le_bytes());
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

    fn test_path(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-kvlog-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join("test.kvlog")
    }

    fn key_of(r: &Row) -> String {
        r.id.clone()
    }

    fn files_in(path: &std::path::Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    fn aside_in(names: &[String]) -> &str {
        names
            .iter()
            .find(|n| n.starts_with("test.kvlog.unreadable-"))
            .expect("a copy kept aside")
    }

    /// The bytes a torn append leaves, written behind the log's back.
    fn tear(path: &std::path::Path, tail: &[u8]) {
        let mut bytes = std::fs::read(path).unwrap();
        bytes.extend_from_slice(tail);
        std::fs::write(path, &bytes).unwrap();
    }

    fn sorted_keys(log: &Log<Row>) -> Vec<String> {
        let mut keys: Vec<String> = log.records.keys().cloned().collect();
        keys.sort();
        keys
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
        let mut log = Log::<Row>::load(path.clone(), key_of).unwrap();
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
    /// reload, and no temp file may be left behind to be replayed.
    #[test]
    fn a_wipe_leaves_an_empty_log_and_no_debris() {
        let path = test_path("wipe-debris");
        let mut log = Log::<Row>::load(path.clone(), key_of).unwrap();
        for id in ["a", "b", "c"] {
            log.upsert(id.to_string(), row(id, 1)).unwrap();
        }
        log.tombstone("b").unwrap();
        log.wipe().unwrap();

        assert_eq!(std::fs::metadata(&path).unwrap().len(), 0);
        assert_eq!(
            files_in(&path),
            ["test.kvlog"],
            "nothing but the log itself"
        );
        let mut reloaded = Log::<Row>::load(path.clone(), key_of).unwrap();
        assert!(reloaded.records.is_empty());
        assert!(!reloaded.is_tombstoned("b"));

        // And the next write starts a fresh v2 file, header first.
        reloaded.upsert("d".into(), row("d", 4)).unwrap();
        assert_eq!(&std::fs::read(&path).unwrap()[..4], b"KVLG");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
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

    /// **The v2 bytes, pinned.** One upsert of `row("a", 1)` is the eight-byte
    /// file header, then `[len][crc32(len ‖ body)][body]` — the body being
    /// borsh's own `Frame::Upsert`. Any change to the format turns this red.
    #[test]
    fn the_v2_file_is_header_then_checksummed_frames() {
        let path = test_path("layout");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();

        let body = borsh::to_vec(&Frame::Upsert(row("a", 1))).unwrap();
        assert_eq!(
            body,
            upsert_body(&row("a", 1)).unwrap(),
            "the clone-free body is borsh's own"
        );
        let mut expected = b"KVLG".to_vec();
        expected.extend_from_slice(&2u32.to_le_bytes());
        let len = (body.len() as u32).to_le_bytes();
        let mut hasher = crc32fast::Hasher::new();
        hasher.update(&len);
        hasher.update(&body);
        expected.extend_from_slice(&len);
        expected.extend_from_slice(&hasher.finalize().to_le_bytes());
        expected.extend_from_slice(&body);
        assert_eq!(std::fs::read(&path).unwrap(), expected);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// A log written before the V1 variants existed (Upsert/Remove only, v1
    /// framing) replays unchanged — the compatibility law made testable — and
    /// is migrated to v2 by the load that reads it.
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
            bytes.extend_from_slice(&testing::v1_frame_bytes(&borsh::to_vec(&frame).unwrap()));
        }
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &bytes).unwrap();

        let log = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(log.records.len(), 1);
        assert_eq!(log.records["a"], row("a", 1));
        assert!(!log.is_tombstoned("a"));
        assert_eq!(
            &std::fs::read(&path).unwrap()[..4],
            b"KVLG",
            "migrated on the read"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **v1 → v2 is one atomic compaction, and it happens once.** The
    /// migrated file replays to the same state, a second load leaves its bytes
    /// alone, and a write after it lands as v2.
    #[test]
    fn a_v1_log_migrates_once_and_keeps_every_record() {
        let path = test_path("migrate");
        let mut bytes = Vec::new();
        for frame in [
            Frame::Upsert(row("a", 1)),
            Frame::Upsert(row("b", 2)),
            Frame::Upsert(row("a", 3)),
            Frame::<Row>::Tombstone("b".into()),
            Frame::Upsert(row("c", 4)),
            Frame::<Row>::Remove("c".into()),
        ] {
            bytes.extend_from_slice(&testing::v1_frame_bytes(&borsh::to_vec(&frame).unwrap()));
        }
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &bytes).unwrap();

        let mut log = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(sorted_keys(&log), ["a", "b"]);
        assert_eq!(log.records["a"], row("a", 3));
        assert!(log.is_tombstoned("b"));
        let migrated = std::fs::read(&path).unwrap();
        assert_eq!(&migrated[..8], b"KVLG\x02\x00\x00\x00");

        let again = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(
            std::fs::read(&path).unwrap(),
            migrated,
            "a v2 load rewrites nothing"
        );
        assert_eq!(again.records["a"], row("a", 3));
        assert!(again.is_tombstoned("b"));

        log.upsert("d".into(), row("d", 5)).unwrap();
        let after = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(sorted_keys(&after), ["a", "b", "d"]);
        assert_eq!(
            files_in(&path),
            ["test.kvlog"],
            "a clean migration keeps no copy"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **A v1 file with bytes after its last good frame keeps a copy.** The
    /// v1 writer appended past tears (F3), so those bytes may be frames; the
    /// migration keeps what it read and copies the cut bytes aside before the
    /// cut. Deleting the copies, then wiping, leaves nothing.
    #[test]
    fn a_v1_log_with_an_unreadable_tail_is_copied_aside_before_the_cut() {
        let path = test_path("v1-unreadable");
        let mut bytes =
            testing::v1_frame_bytes(&borsh::to_vec(&Frame::Upsert(row("a", 1))).unwrap());
        let good_end = bytes.len();
        bytes.extend_from_slice(&[40, 0, 0, 0, 9, 9, 9]);
        bytes.extend_from_slice(&testing::v1_frame_bytes(
            &borsh::to_vec(&Frame::Upsert(row("b", 2))).unwrap(),
        ));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &bytes).unwrap();

        let mut log = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(
            sorted_keys(&log),
            ["a"],
            "point in time: what came before the stop"
        );
        let names = files_in(&path);
        assert_eq!(names.len(), 2, "the log and one copy: {names:?}");
        let aside = path.with_file_name(aside_in(&names));
        assert_eq!(
            std::fs::read(&aside).unwrap(),
            &bytes[good_end..],
            "the copy is the bytes the cut removed, and only those"
        );

        let leftover = path.with_file_name(".test.kvlog.unreadable-7-00000000.tmp");
        std::fs::write(&leftover, b"a copy a crash cut short").unwrap();
        assert_eq!(log.remove_asides().unwrap(), 2);
        log.wipe().unwrap();
        assert_eq!(
            files_in(&path),
            ["test.kvlog"],
            "the copy goes, a crash's leftover temp copy too, then the log"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **A bad frame with a good one behind it is corruption, not a tear.**
    /// Point in time: the record before it loads, the ones from it on do not,
    /// and the file is copied aside before the cut, so the good frame's bytes
    /// still exist.
    #[test]
    fn a_v2_frame_failing_with_data_behind_it_is_copied_aside() {
        let path = test_path("v2-unreadable");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        let after_a = std::fs::metadata(&path).unwrap().len() as usize;
        log.upsert("b".into(), row("b", 2)).unwrap();
        log.upsert("c".into(), row("c", 3)).unwrap();

        let mut bytes = std::fs::read(&path).unwrap();
        bytes[after_a + FRAME_HEADER_LEN + 3] ^= 0x40; // inside b's body
        std::fs::write(&path, &bytes).unwrap();

        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(sorted_keys(&reloaded), ["a"]);
        let names = files_in(&path);
        assert_eq!(names.len(), 2, "the log and its copy: {names:?}");
        assert_eq!(
            std::fs::read(path.with_file_name(aside_in(&names))).unwrap(),
            &bytes[after_a..],
            "the bad frame and everything behind it"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **The checksum is what catches a body that still decodes.** A flipped
    /// bit inside the row's value leaves valid borsh behind; v1 would have
    /// loaded the wrong number. v2 refuses the frame, and with nothing after
    /// it the frame is a tear: cut, no copy.
    #[test]
    fn a_corrupt_body_that_still_decodes_is_refused_by_the_checksum() {
        let path = test_path("crc");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        log.upsert("b".into(), row("b", 2)).unwrap();

        let mut bytes = std::fs::read(&path).unwrap();
        let last = bytes.len() - 8; // the low byte of b's u64 value
        bytes[last] ^= 0x01;
        assert!(
            Frame::<Row>::try_from_slice(
                &bytes[bytes.len() - upsert_body(&row("b", 2)).unwrap().len()..]
            )
            .is_ok(),
            "the corrupted body still decodes: only the checksum can tell"
        );
        std::fs::write(&path, &bytes).unwrap();

        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(
            sorted_keys(&reloaded),
            ["a"],
            "b's corrupt value is never loaded"
        );
        assert_eq!(
            files_in(&path),
            ["test.kvlog"],
            "a last-frame failure is a tear: no copy"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn replay_tolerates_torn_tail_and_corrupt_frames() {
        let path = test_path("torn");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        tear(&path, &[40, 0, 0, 0, 9, 9, 9]); // claims 40 bytes, has 3

        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(reloaded.records.len(), 1, "intact frame survives");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **F3, E2's clone repro (product-audit run 4), red at `d76ab91`.** A torn
    /// frame used to hide every frame appended after it, on every later start:
    /// replay stopped at the tear, load never cut it, and the append landed
    /// behind the torn bytes, where no replay could reach it. The file came out
    /// 43 bytes long (18 + 7 + 18) holding one record.
    #[test]
    fn audit4_append_after_torn_tail_survives_reload() {
        let path = test_path("audit4");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        tear(&path, &[40, 0, 0, 0, 9, 9, 9]);

        let mut reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(
            sorted_keys(&reloaded),
            ["a"],
            "the torn frame is not a record"
        );
        reloaded.upsert("b".into(), row("b", 2)).unwrap();

        let again = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(
            sorted_keys(&again),
            ["a", "b"],
            "the frame written after the tear survives the next start"
        );
        assert_eq!(
            files_in(&path),
            ["test.kvlog"],
            "a tear holds no frame: no copy"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// The tail a crash leaves when the file's new size reached the disk and
    /// its data did not: zeros (ext4's documented zero-length class; the
    /// phone's `/data` is f2fs, which has no `auto_da_alloc` to soften it).
    #[test]
    fn append_after_a_zero_filled_tail_survives_reload() {
        let path = test_path("zero-tail");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        tear(&path, &[0u8; 16]);

        let mut reloaded = Log::load(path.clone(), key_of).unwrap();
        reloaded.upsert("b".into(), row("b", 2)).unwrap();

        let again = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(sorted_keys(&again), ["a", "b"]);
        assert_eq!(
            files_in(&path),
            ["test.kvlog"],
            "zeros hold no frame: no copy"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// A write that fails half-way inside a running session (a full disk)
    /// leaves torn bytes the log never acknowledged. The next write must land
    /// at the end the log knows is good, or it repeats F3 without a restart.
    #[test]
    fn a_write_after_a_half_written_one_survives_reload() {
        let path = test_path("half-written");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        testing::fail_next_write_after(6);
        assert!(
            log.upsert("b".into(), row("b", 2)).is_err(),
            "the half-finished write fails"
        );
        assert!(!log.records.contains_key("b"), "and is not a record");
        log.upsert("c".into(), row("c", 3)).unwrap();

        let again = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(sorted_keys(&again), ["a", "c"]);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **Another writer's frames are refused, never cut** (wallet-security and
    /// consensus, PRE3-LOG). A second instance of a log on the same file used
    /// to be harmless under append mode; writing at a remembered end would
    /// destroy its frames, so a file that grew behind this log is not touched.
    #[test]
    fn another_writer_s_frames_are_refused_never_cut() {
        let path = test_path("two-writers");
        let mut first = Log::load(path.clone(), key_of).unwrap();
        first.upsert("a".into(), row("a", 1)).unwrap();
        let mut second = Log::load(path.clone(), key_of).unwrap();
        second.upsert("b".into(), row("b", 2)).unwrap();

        assert!(
            first.upsert("c".into(), row("c", 3)).is_err(),
            "refused, loudly"
        );
        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(
            sorted_keys(&reloaded),
            ["a", "b"],
            "the other writer's frame survives"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **The load cuts a torn tail itself**, before anything is written: the
    /// file ends at its last good frame the moment it is read. (The writer's
    /// own cut would also catch it at the next write; this pins the load's.)
    #[test]
    fn the_load_cuts_a_torn_tail_before_any_write() {
        let path = test_path("load-cuts");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        let clean = std::fs::read(&path).unwrap();
        tear(&path, &[40, 0, 0, 0, 9, 9, 9]);

        let _ = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), clean);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// A file something else shortened behind the log is refused, never
    /// padded: writing at the log's end would fill the gap with zeros.
    #[test]
    fn a_file_shortened_behind_the_log_is_refused_not_padded() {
        let path = test_path("shortened");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        std::fs::write(&path, b"").unwrap();

        assert!(log.upsert("b".into(), row("b", 2)).is_err());
        assert_eq!(std::fs::metadata(&path).unwrap().len(), 0, "nothing padded");
        assert!(!log.records.contains_key("b"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **The checksum gives the standard answers** (dependency-steward,
    /// PRE3-LOG): the CRC-32 check value and a 4 KiB pattern, both computed by
    /// zlib. A dependency update that changed the output turns this red before
    /// it can make every frame on every phone fail. The same check runs once
    /// per process on the device's own code path.
    #[test]
    fn the_checksum_gives_the_standard_answers() {
        assert_eq!(crc32fast::hash(b"123456789"), CHECK_VALUE);
        assert_eq!(crc32fast::hash(&long_pattern()), LONG_PATTERN_CRC);
        assert_eq!(
            frame_crc(&3u32.to_le_bytes(), b"abc"),
            FRAME_ABC_CRC,
            "the log's own hasher"
        );
        assert_eq!(
            frame_crc(&4096u32.to_le_bytes(), &long_pattern()),
            FRAME_LONG_CRC,
            "and a long body in its second update"
        );
        assert_eq!(
            frame_crc(&4093u32.to_le_bytes(), &long_pattern()[1..4094]),
            FRAME_UNALIGNED_CRC,
            "and an unaligned one"
        );
        assert!(checksum_holds());
        assert_ne!(
            frame_crc(&[0; 4], &[]),
            0,
            "a header of zeros is never a valid frame"
        );
    }

    /// **The growth rule at its boundaries**: strictly past the floor, and
    /// strictly past twice the live size. (The consensus auditor's mutants
    /// found both comparisons and the ratio unpinned.)
    #[test]
    fn the_growth_rule_holds_at_its_boundaries() {
        assert!(!grown(COMPACT_FLOOR, 100), "at the floor: left alone");
        assert!(grown(COMPACT_FLOOR + 1, 100), "past it: compacted");
        let live = COMPACT_FLOOR; // above the floor, the ratio decides
        assert!(
            !grown(live * 3 / 2, live),
            "one and a half times live: left alone"
        );
        assert!(!grown(2 * live, live), "exactly twice live: left alone");
        assert!(grown(2 * live + 1, live), "past twice live: compacted");
    }

    /// **A checksum failing on every frame is not a tear**: one append is in
    /// flight when a process dies, so a tear is at most one frame. A file
    /// whose every checksum fails (a broken implementation, the steward's
    /// case) has every frame copied aside before the cut; the live log reads
    /// empty, and the bytes survive in the copy.
    #[test]
    fn a_file_whose_every_checksum_fails_is_copied_aside_before_the_cut() {
        let path = test_path("all-crc-bad");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        for id in ["a", "b", "c"] {
            log.upsert(id.into(), row(id, 1)).unwrap();
        }
        let mut bytes = std::fs::read(&path).unwrap();
        let mut at = FILE_HEADER_LEN;
        while at + FRAME_HEADER_LEN <= bytes.len() {
            let len = u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
            bytes[at + 4] ^= 0xFF; // every frame's checksum
            at += FRAME_HEADER_LEN + len;
        }
        std::fs::write(&path, &bytes).unwrap();

        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert!(
            reloaded.records.is_empty(),
            "point in time: nothing before the first frame, so the live log is empty"
        );
        let names = files_in(&path);
        assert_eq!(
            std::fs::read(path.with_file_name(aside_in(&names))).unwrap(),
            &bytes[FILE_HEADER_LEN..],
            "every frame is kept aside"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **A migration that cannot be written serves the records read-only**
    /// (wallet-security, PRE3-LOG): the wallet's activity log must still open
    /// so the wallet can spend, and no v2 frame may land behind v1 bytes. A
    /// later load migrates it.
    #[test]
    fn a_failed_migration_serves_the_records_read_only() {
        let path = test_path("migrate-fails");
        let mut bytes = Vec::new();
        for frame in [Frame::Upsert(row("a", 1)), Frame::Upsert(row("b", 2))] {
            bytes.extend_from_slice(&testing::v1_frame_bytes(&borsh::to_vec(&frame).unwrap()));
        }
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &bytes).unwrap();
        // The durable write cannot create its temp file: a directory sits on
        // the name.
        let blocker = path.with_file_name(".test.kvlog.tmp");
        std::fs::create_dir_all(&blocker).unwrap();

        let mut log = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(sorted_keys(&log), ["a", "b"], "the records are served");
        assert!(log.hold().is_some(), "read-only");
        assert!(log.upsert("c".into(), row("c", 3)).is_err());
        assert!(log.compact().is_err());
        assert_eq!(
            std::fs::read(&path).unwrap(),
            bytes,
            "the v1 file is untouched"
        );

        std::fs::remove_dir(&blocker).unwrap();
        let migrated = Log::load(path.clone(), key_of).unwrap();
        assert!(migrated.hold().is_none());
        assert_eq!(
            &std::fs::read(&path).unwrap()[..4],
            b"KVLG",
            "a later load migrates"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// Unreadable bytes that cannot be copied aside are not cut: the log is
    /// served read-only and the file left exactly as it was.
    #[test]
    fn unreadable_bytes_that_cannot_be_copied_aside_hold_the_log() {
        let path = test_path("aside-fails");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        let after_a = std::fs::metadata(&path).unwrap().len() as usize;
        log.upsert("b".into(), row("b", 2)).unwrap();
        log.upsert("c".into(), row("c", 3)).unwrap();
        let mut bytes = std::fs::read(&path).unwrap();
        bytes[after_a + FRAME_HEADER_LEN + 6] ^= 0x01; // inside b's body: c stays behind it
        std::fs::write(&path, &bytes).unwrap();
        let tail = &bytes[after_a..];
        let temp = path.with_file_name(format!(
            ".test.kvlog.unreadable-{after_a}-{}-{:08x}.tmp",
            tail.len(),
            crc32fast::hash(tail)
        ));
        std::fs::create_dir_all(&temp).unwrap();

        let mut held = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(sorted_keys(&held), ["a"]);
        assert!(held.hold().is_some());
        assert!(held.upsert("d".into(), row("d", 4)).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes, "nothing was cut");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **A checksum that fails its known answers judges nothing and writes
    /// nothing.** The records still load, on their lengths alone as v1 always
    /// did, so the wallet still opens; the log is read-only; neither a v2 file
    /// nor a v1 file awaiting migration is touched.
    #[test]
    fn a_broken_checksum_serves_the_records_read_only_and_touches_nothing() {
        let v2 = test_path("crc-broken-v2");
        let mut log = Log::load(v2.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        log.upsert("b".into(), row("b", 2)).unwrap();
        let v2_bytes = std::fs::read(&v2).unwrap();

        let v1 = test_path("crc-broken-v1");
        let v1_bytes =
            testing::v1_frame_bytes(&borsh::to_vec(&Frame::Upsert(row("c", 3))).unwrap());
        std::fs::create_dir_all(v1.parent().unwrap()).unwrap();
        std::fs::write(&v1, &v1_bytes).unwrap();

        let fresh = test_path("crc-broken-fresh");

        testing::CHECKSUM_BROKEN.with(|broken| broken.set(true));
        let mut held = Log::load(v2.clone(), key_of).unwrap();
        let mut unmigrated = Log::load(v1.clone(), key_of).unwrap();
        let mut empty = Log::load(fresh.clone(), key_of).unwrap();
        testing::CHECKSUM_BROKEN.with(|broken| broken.set(false));

        assert!(empty.hold().is_some(), "a missing file is held too");
        assert!(empty.upsert("y".into(), row("y", 8)).is_err());
        assert!(!fresh.exists(), "and nothing was written");

        assert_eq!(
            sorted_keys(&held),
            ["a", "b"],
            "read unverified, not dropped"
        );
        assert!(held.hold().is_some());
        assert!(held.upsert("x".into(), row("x", 9)).is_err());
        assert_eq!(
            std::fs::read(&v2).unwrap(),
            v2_bytes,
            "nothing judged, nothing cut"
        );
        assert_eq!(sorted_keys(&unmigrated), ["c"]);
        assert!(
            unmigrated.compact().is_err(),
            "no migration under a broken checksum"
        );
        assert_eq!(std::fs::read(&v1).unwrap(), v1_bytes);
        let _ = std::fs::remove_dir_all(v2.parent().unwrap());
        let _ = std::fs::remove_dir_all(v1.parent().unwrap());
        let _ = std::fs::remove_dir_all(fresh.parent().unwrap());
    }

    /// A removal marks the file until a compaction drops the removed bytes,
    /// and a load reads the mark from the file itself.
    #[test]
    fn a_removal_marks_the_file_until_a_compaction() {
        let path = test_path("removed-mark");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        log.upsert("a".into(), row("a", 1)).unwrap();
        assert!(!log.holds_removed());
        log.remove("a").unwrap();
        assert!(log.holds_removed());
        assert!(Log::<Row>::load(path.clone(), key_of)
            .unwrap()
            .holds_removed());
        log.compact().unwrap();
        assert!(!log.holds_removed());
        assert!(!Log::<Row>::load(path.clone(), key_of)
            .unwrap()
            .holds_removed());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// A newer format is refused, and the file is left exactly as it was:
    /// cutting what this build cannot parse would destroy a newer app's data.
    #[test]
    fn a_newer_format_version_is_refused_and_left_untouched() {
        let path = test_path("version");
        let mut bytes = b"KVLG".to_vec();
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8, 9]);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &bytes).unwrap();

        assert!(Log::<Row>::load(path.clone(), key_of).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **F62: an equal upsert appends nothing.**
    #[test]
    fn an_equal_upsert_appends_nothing() {
        let path = test_path("equal");
        let mut log = Log::load(path.clone(), key_of).unwrap();
        assert!(log.upsert("a".into(), row("a", 1)).unwrap());
        let len = std::fs::metadata(&path).unwrap().len();
        assert!(
            !log.upsert("a".into(), row("a", 1)).unwrap(),
            "nothing new, nothing written"
        );
        assert_eq!(std::fs::metadata(&path).unwrap().len(), len);
        assert!(
            log.upsert("a".into(), row("a", 2)).unwrap(),
            "a change is still a write"
        );
        assert!(std::fs::metadata(&path).unwrap().len() > len);
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

        log.compact().unwrap();
        let after = std::fs::metadata(&path).unwrap().len();
        assert!(after < before, "compaction shrank the file");

        let verify = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(verify.records.len(), 4);
        assert_eq!(verify.records["k3"], row("k3", 198));
        assert!(verify.is_tombstoned("k3"));
        assert!(!verify.records.contains_key("k4"));

        // And the log keeps writing where the compacted file ends.
        log.upsert("k9".into(), row("k9", 9)).unwrap();
        assert_eq!(Log::load(path.clone(), key_of).unwrap().records.len(), 5);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **The growth rule at load**: past the floor and past twice its live
    /// size, a log is compacted by the load that reads it; under the floor,
    /// however dead, it is left alone.
    #[test]
    fn a_log_grown_past_the_floor_and_the_ratio_compacts_at_load() {
        // One key rewritten until the file passes the floor, built in memory
        // (thousands of fsyncs would make the test the slow part of the suite).
        let churned = |frames: u64| {
            let mut bytes = Vec::new();
            push_file_header(&mut bytes);
            for i in 0..frames {
                push_frame(&mut bytes, &upsert_body(&row("k", i)).unwrap()).unwrap();
            }
            bytes
        };
        let path = test_path("growth");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut frames = 0;
        let mut bytes = Vec::new();
        while bytes.len() as u64 <= COMPACT_FLOOR {
            frames += 100;
            bytes = churned(frames);
        }
        std::fs::write(&path, &bytes).unwrap();
        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(reloaded.records["k"], row("k", frames - 1));
        assert!(
            std::fs::metadata(&path).unwrap().len() < bytes.len() as u64 / 100,
            "rewritten to its one live row"
        );

        // Under the floor, however dead: left alone.
        let small = test_path("small-dead");
        std::fs::create_dir_all(small.parent().unwrap()).unwrap();
        let before = churned(50);
        std::fs::write(&small, &before).unwrap();
        let _ = Log::load(small.clone(), key_of).unwrap();
        assert_eq!(
            std::fs::read(&small).unwrap(),
            before,
            "under the floor: untouched"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
        let _ = std::fs::remove_dir_all(small.parent().unwrap());
    }

    /// A record whose decoder does not give back what its encoder wrote.
    #[derive(BorshSerialize, Clone, Debug)]
    struct Lossy {
        id: String,
        value: u64,
    }

    impl BorshDeserialize for Lossy {
        fn deserialize_reader<R: borsh::io::Read>(reader: &mut R) -> borsh::io::Result<Self> {
            let id = String::deserialize_reader(reader)?;
            let _ = u64::deserialize_reader(reader)?;
            Ok(Self { id, value: 0 })
        }
    }

    /// **A compaction that would lose a record replaces nothing.** The image
    /// is replayed before it is written; one that does not come back as the
    /// state it was built from is refused, and the file keeps its frames.
    #[test]
    fn a_compaction_image_that_does_not_replay_whole_is_refused() {
        let path = test_path("lossy");
        let mut log = Log::<Lossy>::load(path.clone(), |r: &Lossy| r.id.clone()).unwrap();
        log.upsert(
            "a".into(),
            Lossy {
                id: "a".into(),
                value: 7,
            },
        )
        .unwrap();
        let before = std::fs::read(&path).unwrap();
        assert!(
            log.compact().is_err(),
            "the image would have lost the value"
        );
        assert_eq!(
            std::fs::read(&path).unwrap(),
            before,
            "and nothing was replaced"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **A rewrite keeps the writer's rule**: a file that grew behind this log
    /// holds another writer's frames, and compacting from this log's state
    /// would drop them, so the compaction refuses as the append does.
    #[test]
    fn another_writer_s_frames_survive_this_log_s_compaction() {
        let path = test_path("two-writers-compact");
        let mut first = Log::load(path.clone(), key_of).unwrap();
        first.upsert("a".into(), row("a", 1)).unwrap();
        let mut second = Log::load(path.clone(), key_of).unwrap();
        second.upsert("b".into(), row("b", 2)).unwrap();

        assert!(first.compact().is_err(), "refused, as the append is");
        let reloaded = Log::load(path.clone(), key_of).unwrap();
        assert_eq!(sorted_keys(&reloaded), ["a", "b"]);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// **Deleting copies tries every one** (`wallet-security-auditor`,
    /// PRE3-LOG): one that cannot be deleted is reported, and the copies on
    /// either side of it go anyway, whatever order the directory lists them in.
    #[test]
    fn deleting_copies_tries_every_one() {
        let path = test_path("asides-every");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let log = Log::<Row>::load(path.clone(), key_of).unwrap();
        for n in 1..=3 {
            std::fs::write(
                path.with_file_name(format!("test.kvlog.unreadable-{n}-1-0")),
                b"w",
            )
            .unwrap();
        }
        std::fs::create_dir_all(path.with_file_name("test.kvlog.unreadable-4-1-0").join("x"))
            .unwrap();
        for n in 5..=7 {
            std::fs::write(
                path.with_file_name(format!("test.kvlog.unreadable-{n}-1-0")),
                b"w",
            )
            .unwrap();
        }

        assert!(
            log.remove_asides().is_err(),
            "the undeletable copy is reported"
        );
        let names = files_in(&path);
        assert_eq!(
            names,
            ["test.kvlog.unreadable-4-1-0"],
            "every other copy is gone"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
