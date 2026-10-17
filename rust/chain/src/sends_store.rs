//! **What a relaunch must not forget about our own sends.** The wallet lane
//! keeps its sends in flight, the legs whose fate is unknown and the notices of
//! legs proven landed in memory ([`crate::wallet_sync::InFlightSends`]); this
//! module keeps them on disk beside the activity log, so a new process starts
//! where the last one stopped: a coin a send in flight spends stays out, and a
//! retry still conflicts with a send that got no answer.
//!
//! Two files, each a versioned JSON object replaced whole
//! ([`crate::durable::atomic_write`]) by one writer:
//! - `<store>.sends`: every leg from just before its request leaves until its
//!   fate is settled, and the notices of legs proven landed or retired;
//! - `<store>.spent`: coins our accepted sends spent, for a read from a node
//!   that has not reached that acceptance yet.
//!
//! Public chain data and local keys only: outpoints, amounts, addresses,
//! scripts, DAA scores, and the key a retry is matched on (a destination, a
//! conversation or a contact). Never a signed transaction or a key (INV-3).
//! The conversation wipe does not reach these keys: a leg in flight keeps its
//! key because the key is what stops a retry paying twice, and a notice keeps
//! its key until it is read or 64 newer ones push it out.
//!
//! A file that does not decode, a record within one that does not decode, and
//! a leg that decodes but cannot be used are kept in `unreadable/` beside it,
//! under a name of its own, never overwritten; those copies keep the same keys,
//! and
//! nothing erases them but the app's own data being cleared. A file that cannot
//! be read at all stays where it is and nothing is written over it for the
//! rest of the run (the next run reads it again), so a send whose record cannot
//! be written is not sent.

use std::io;
use std::path::{Path, PathBuf};

use kaspa_addresses::Address;
use kaspa_consensus_core::tx::{ScriptPublicKey, ScriptVec};
use kaspa_wallet_core::utxo::UtxoEntryReference;
use kaspa_wrpc_client::prelude::{
    RpcHash, RpcTransactionOutpoint, RpcUtxoEntry, RpcUtxosByAddressesEntry,
};
use serde::{Deserialize, Serialize};

use crate::durable::atomic_write;

/// The format both files are written in; any other is set aside unread.
pub(crate) const FORMAT: u32 = 1;

/// The legs file beside the activity log at `store`.
pub fn sends_path(store: &Path) -> PathBuf {
    store.with_extension("sends")
}

/// The spent-coins file beside the activity log at `store`.
pub fn spent_path(store: &Path) -> PathBuf {
    store.with_extension("spent")
}

/// One coin, as a read of the node lists it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(crate) struct CoinRecord {
    pub txid: String,
    pub index: u32,
    pub amount: u64,
    pub address: Option<String>,
    pub script_version: u16,
    pub script: String,
    pub block_daa_score: u64,
    pub is_coinbase: bool,
    pub covenant_id: Option<String>,
}

impl CoinRecord {
    pub(crate) fn of(coin: &UtxoEntryReference) -> Self {
        let utxo = &coin.utxo;
        Self {
            txid: utxo.outpoint.transaction_id().to_string(),
            index: utxo.outpoint.index(),
            amount: utxo.amount,
            address: utxo.address.as_ref().map(|address| address.to_string()),
            script_version: utxo.script_public_key.version(),
            script: to_hex(utxo.script_public_key.script()),
            block_daa_score: utxo.block_daa_score,
            is_coinbase: utxo.is_coinbase,
            covenant_id: utxo.covenant_id.map(|id| id.to_string()),
        }
    }

    /// The coin again, or `None` if any field does not parse.
    pub(crate) fn coin(&self) -> Option<UtxoEntryReference> {
        let address = match &self.address {
            Some(text) => Some(Address::try_from(text.as_str()).ok()?),
            None => None,
        };
        let covenant_id = match &self.covenant_id {
            Some(text) => Some(text.parse::<RpcHash>().ok()?),
            None => None,
        };
        let script = ScriptPublicKey::new(
            self.script_version,
            ScriptVec::from_vec(from_hex(&self.script)?),
        );
        Some(UtxoEntryReference::from(RpcUtxosByAddressesEntry {
            address,
            outpoint: RpcTransactionOutpoint {
                transaction_id: self.txid.parse().ok()?,
                index: self.index,
            },
            utxo_entry: RpcUtxoEntry::new(
                self.amount,
                script,
                self.block_daa_score,
                self.is_coinbase,
                covenant_id,
            ),
        }))
    }
}

/// How far a leg had got when it was written.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum LegState {
    /// Logged before its request; no outcome recorded. It may have left.
    Submitting,
    /// A node took it, or the pin kept it after a failure that came after the
    /// request.
    Sent,
    /// Its submit got no answer and the pin cancelled it.
    Unknown,
}

/// One output of a leg, with the address it pays.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(crate) struct OutputRecord {
    pub index: u32,
    pub value: u64,
    pub address: Option<String>,
}

/// One leg of a send of ours.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(crate) struct LegRecord {
    pub txid: String,
    pub state: LegState,
    /// What a build for the same payment carries; empty for a chain's
    /// earlier leg, which pays us.
    pub paid_to: String,
    /// Its inputs other than its own send's earlier legs' outputs.
    pub direct: Vec<CoinRecord>,
    /// Its inputs that are its own send's earlier legs' outputs.
    pub earlier: Vec<CoinRecord>,
    pub outputs: Vec<OutputRecord>,
    /// When it was logged (unix ms) or, for a leg of unknown fate, cancelled.
    pub since_unix_ms: u64,
    /// The DAA score the lane had reached when it was logged (0 if unknown).
    pub since_daa: u64,
}

/// A leg of unknown fate proven landed: ruling [4]'s notice.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(crate) struct LandedRecord {
    pub paid_to: String,
    pub at_unix_ms: u64,
}

/// A leg of unknown fate retired on other evidence, kept in case a record of
/// its own transaction follows.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(crate) struct RetiredRecord {
    pub txid: String,
    pub paid_to: String,
    pub at_unix_ms: u64,
}

/// A coin one of our accepted sends spent.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(crate) struct SpentRecord {
    pub txid: String,
    pub index: u32,
    /// The DAA score the lane had reached when it saw the acceptance: at or
    /// above the acceptance's own.
    pub seen_at_daa: u64,
    /// When it was seen (unix ms).
    #[serde(default)]
    pub seen_at_ms: u64,
}

/// What the legs file holds.
#[derive(Default, Debug, Clone, PartialEq)]
pub(crate) struct Sends {
    pub legs: Vec<LegRecord>,
    pub landed: Vec<LandedRecord>,
    pub retired: Vec<RetiredRecord>,
}

#[derive(Serialize)]
struct SendsOut<'a> {
    format: u32,
    network: &'a str,
    legs: &'a [LegRecord],
    landed: &'a [LandedRecord],
    retired: &'a [RetiredRecord],
}

#[derive(Serialize)]
struct SpentOut<'a> {
    format: u32,
    network: &'a str,
    coins: &'a [SpentRecord],
}

/// Either file as read back: its records stay raw until each is decoded on
/// its own, so one bad record costs that record, not the file.
#[derive(Deserialize)]
struct Envelope {
    format: u32,
    network: String,
    #[serde(default)]
    legs: Vec<serde_json::Value>,
    #[serde(default)]
    landed: Vec<serde_json::Value>,
    #[serde(default)]
    retired: Vec<serde_json::Value>,
    #[serde(default)]
    coins: Vec<serde_json::Value>,
}

pub(crate) fn encode_sends(network: &str, sends: &Sends) -> io::Result<Vec<u8>> {
    serde_json::to_vec(&SendsOut {
        format: FORMAT,
        network,
        legs: &sends.legs,
        landed: &sends.landed,
        retired: &sends.retired,
    })
    .map_err(io::Error::other)
}

pub(crate) fn encode_spent(network: &str, coins: &[SpentRecord]) -> io::Result<Vec<u8>> {
    serde_json::to_vec(&SpentOut {
        format: FORMAT,
        network,
        coins,
    })
    .map_err(io::Error::other)
}

/// What reading one file found.
enum Read {
    /// No file, or an unreadable one set aside: start empty.
    Absent,
    Found(Envelope, Vec<u8>),
    /// A file that could not be read this run, or an unreadable one that could
    /// not be set aside: start empty and write nothing over it.
    Kept,
}

/// Read one file.
fn read_envelope(path: &Path, network: &str) -> Read {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Read::Absent,
        // Something that is not a file is not a record: it goes aside.
        Err(_) if path.is_dir() => return set_aside(path, "not a file"),
        // A file that could not be read this time may read next time: it
        // stays, and nothing is written over it until then.
        Err(e) => {
            log::warn!(
                "sends: {} could not be read ({:?}); it is left as it is and nothing is \
                 written over it this run",
                path.display(),
                e.kind()
            );
            return Read::Kept;
        }
    };
    match serde_json::from_slice::<Envelope>(&bytes) {
        Ok(envelope) if envelope.format == FORMAT && envelope.network == network => {
            Read::Found(envelope, bytes)
        }
        Ok(envelope) if envelope.format != FORMAT => {
            set_aside(path, &format!("format {}", envelope.format))
        }
        Ok(_) => set_aside(path, "another network's record"),
        Err(e) => set_aside(
            path,
            &format!(
                "{:?} at line {} column {}",
                e.classify(),
                e.line(),
                e.column()
            ),
        ),
    }
}

/// A name for a copy of `path` in `unreadable/` beside it that no earlier copy
/// holds.
fn aside_path(path: &Path) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("record");
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    path.with_file_name("unreadable")
        .join(format!("{name}.{ms}.{}.{n}", std::process::id()))
}

/// Move an unreadable file where the next write cannot reach it.
fn set_aside(path: &Path, why: &str) -> Read {
    let aside = aside_path(path);
    let moved = aside
        .parent()
        .map_or(Ok(()), std::fs::create_dir_all)
        .and_then(|()| std::fs::rename(path, &aside));
    match moved {
        Ok(()) => {
            log::warn!(
                "sends: {} is unreadable ({why}); set aside as {}",
                path.display(),
                aside.display()
            );
            Read::Absent
        }
        Err(e) => {
            log::warn!(
                "sends: {} is unreadable ({why}) and could not be set aside ({:?}); it is \
                 left as it is and nothing is written over it",
                path.display(),
                e.kind()
            );
            Read::Kept
        }
    }
}

/// Keep records the caller could not use beside `path`, and only those.
pub(crate) fn keep_aside<T: Serialize>(path: &Path, records: &[T]) {
    let values: Vec<serde_json::Value> = records
        .iter()
        .filter_map(|record| serde_json::to_value(record).ok())
        .collect();
    if !values.is_empty() {
        copy_aside(path, &values, "could not be used");
    }
}

/// Keep the records dropped for `why`, and only those.
fn copy_aside(path: &Path, dropped: &[serde_json::Value], why: &str) {
    let aside = aside_path(path);
    let kept = serde_json::to_vec(dropped)
        .map_err(io::Error::other)
        .and_then(|bytes| atomic_write(&aside, &bytes));
    match kept {
        Ok(()) => log::warn!(
            "sends: {} record(s) of {} {why} and were dropped; they are kept at {}",
            dropped.len(),
            path.display(),
            aside.display()
        ),
        Err(e) => log::warn!(
            "sends: {} record(s) of {} {why} and were dropped, and could not be kept ({:?})",
            dropped.len(),
            path.display(),
            e.kind()
        ),
    }
}

fn decode<T: serde::de::DeserializeOwned>(
    values: Vec<serde_json::Value>,
    dropped: &mut Vec<serde_json::Value>,
) -> Vec<T> {
    values
        .into_iter()
        .filter_map(|value| match serde_json::from_value(value.clone()) {
            Ok(record) => Some(record),
            Err(_) => {
                dropped.push(value);
                None
            }
        })
        .collect()
}

/// What loading one file found: its records, the bytes it held (what the
/// writer compares its first snapshot with), and whether an unreadable file
/// stays in place, so that nothing may be written over it.
pub(crate) struct Loaded<T> {
    pub records: T,
    pub bytes: Vec<u8>,
    pub kept: bool,
}

/// The legs file at `path`.
pub(crate) fn load_sends(path: &Path, network: &str) -> Loaded<Sends> {
    let (envelope, bytes) = match read_envelope(path, network) {
        Read::Found(envelope, bytes) => (envelope, bytes),
        Read::Absent => {
            return Loaded {
                records: Sends::default(),
                bytes: Vec::new(),
                kept: false,
            }
        }
        Read::Kept => {
            return Loaded {
                records: Sends::default(),
                bytes: Vec::new(),
                kept: true,
            }
        }
    };
    let mut dropped = Vec::new();
    let records = Sends {
        legs: decode(envelope.legs, &mut dropped),
        landed: decode(envelope.landed, &mut dropped),
        retired: decode(envelope.retired, &mut dropped),
    };
    if !dropped.is_empty() {
        copy_aside(path, &dropped, "did not decode");
    }
    Loaded {
        records,
        bytes,
        kept: false,
    }
}

/// The spent-coins file at `path`.
pub(crate) fn load_spent(path: &Path, network: &str) -> Loaded<Vec<SpentRecord>> {
    let (envelope, bytes) = match read_envelope(path, network) {
        Read::Found(envelope, bytes) => (envelope, bytes),
        Read::Absent => {
            return Loaded {
                records: Vec::new(),
                bytes: Vec::new(),
                kept: false,
            }
        }
        Read::Kept => {
            return Loaded {
                records: Vec::new(),
                bytes: Vec::new(),
                kept: true,
            }
        }
    };
    let mut dropped = Vec::new();
    let records = decode(envelope.coins, &mut dropped);
    if !dropped.is_empty() {
        copy_aside(path, &dropped, "did not decode");
    }
    Loaded {
        records,
        bytes,
        kept: false,
    }
}

/// **One writer for one file, for the whole process.** Snapshots are numbered
/// from the file's own counter where they are taken (under the lock that guards
/// what they copy); the writer lands a snapshot only if no newer one has landed
/// and skips one whose bytes equal the last good write. The check and the write
/// run together on a blocking thread under one lock, and that state belongs to
/// the path, not to the record that wrote it: a write still running for a
/// record that has gone (a task aborted at a lane rebuild, an engine dropped)
/// cannot land over a newer record's.
pub(crate) struct DurableFile {
    path: PathBuf,
    writer: std::sync::Arc<Writer>,
    /// An unreadable file is still in place: nothing is written over it.
    kept: bool,
}

struct Writer {
    written: std::sync::Mutex<Written>,
    next: std::sync::atomic::AtomicU64,
}

struct Written {
    generation: u64,
    /// The bytes of the last good write, or as read; `None` before either.
    bytes: Option<Vec<u8>>,
}

/// The writer state of `path` in this process.
fn writer_for(path: &Path) -> std::sync::Arc<Writer> {
    type Writers = std::collections::HashMap<PathBuf, std::sync::Arc<Writer>>;
    static WRITERS: std::sync::OnceLock<std::sync::Mutex<Writers>> = std::sync::OnceLock::new();
    WRITERS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .entry(path.to_path_buf())
        .or_insert_with(|| {
            std::sync::Arc::new(Writer {
                written: std::sync::Mutex::new(Written {
                    generation: 0,
                    bytes: None,
                }),
                next: std::sync::atomic::AtomicU64::new(0),
            })
        })
        .clone()
}

impl DurableFile {
    /// `bytes` is what the file holds now; `kept`, that it holds an unreadable
    /// file that may not be written over.
    pub(crate) fn new(path: PathBuf, bytes: Vec<u8>, kept: bool) -> Self {
        let writer = writer_for(&path);
        {
            let mut written = writer
                .written
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if written.bytes.is_none() {
                written.bytes = Some(bytes);
            }
        }
        Self { path, writer, kept }
    }

    #[cfg(test)]
    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// The number of the next snapshot of this file.
    pub(crate) fn next_generation(&self) -> u64 {
        self.writer
            .next
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1
    }

    /// Land snapshot `generation`. An error leaves the last good write as
    /// the one compared with, so the next snapshot is written again.
    pub(crate) async fn write(&self, generation: u64, bytes: Vec<u8>) -> io::Result<()> {
        if self.kept {
            return Err(io::Error::other(
                "an unreadable record is in place and may not be written over",
            ));
        }
        let path = self.path.clone();
        let writer = self.writer.clone();
        tokio::task::spawn_blocking(move || {
            let mut written = writer
                .written
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if generation <= written.generation {
                return Ok(());
            }
            if written.bytes.as_deref() == Some(bytes.as_slice()) {
                written.generation = generation;
                return Ok(());
            }
            atomic_write(&path, &bytes)?;
            *written = Written {
                generation,
                bytes: Some(bytes),
            };
            Ok(())
        })
        .await
        .map_err(io::Error::other)?
    }
}

fn to_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(DIGITS[(byte >> 4) as usize] as char);
        text.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    text
}

fn from_hex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(text.get(at..at + 2)?, 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_txscript::pay_to_address_script;

    fn coin(n: u8) -> UtxoEntryReference {
        let address: Address =
            "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692"
                .try_into()
                .expect("address");
        UtxoEntryReference::from(RpcUtxosByAddressesEntry {
            address: Some(address.clone()),
            outpoint: RpcTransactionOutpoint {
                transaction_id: RpcHash::from_bytes([n; 32]),
                index: u32::from(n),
            },
            utxo_entry: RpcUtxoEntry::new(
                1_000 + u64::from(n),
                pay_to_address_script(&address),
                900_000,
                false,
                None,
            ),
        })
    }

    fn dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-sends-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        dir
    }

    #[test]
    fn a_coin_survives_its_record_whole() {
        let original = coin(7);
        let back = CoinRecord::of(&original).coin().expect("decodes");
        assert_eq!(back.id(), original.id());
        assert_eq!(back.utxo.amount, original.utxo.amount);
        assert_eq!(back.utxo.address, original.utxo.address);
        assert_eq!(back.utxo.script_public_key, original.utxo.script_public_key);
        assert_eq!(back.utxo.block_daa_score, original.utxo.block_daa_score);
        assert_eq!(back.utxo.is_coinbase, original.utxo.is_coinbase);
        assert_eq!(back.utxo.covenant_id, original.utxo.covenant_id);
    }

    /// The copies an unreadable file left in `unreadable/` beside `path`.
    fn asides(path: &Path) -> Vec<PathBuf> {
        let Ok(entries) = std::fs::read_dir(path.with_file_name("unreadable")) else {
            return Vec::new();
        };
        entries
            .filter_map(|entry| Some(entry.ok()?.path()))
            .collect()
    }

    #[test]
    fn the_legs_file_round_trips_and_a_bad_record_costs_only_itself() {
        let dir = dir("roundtrip");
        let path = sends_path(&dir.join("activity.kvlog"));
        let leg = LegRecord {
            txid: RpcHash::from_bytes([1; 32]).to_string(),
            state: LegState::Sent,
            paid_to: "kaspa:payee".into(),
            direct: vec![CoinRecord::of(&coin(1))],
            earlier: vec![],
            outputs: vec![OutputRecord {
                index: 0,
                value: 5,
                address: None,
            }],
            since_unix_ms: 1,
            since_daa: 2,
        };
        let sends = Sends {
            legs: vec![leg.clone()],
            landed: vec![LandedRecord {
                paid_to: "kaspa:payee".into(),
                at_unix_ms: 3,
            }],
            retired: vec![],
        };
        let bytes = encode_sends("mainnet", &sends).expect("encodes");
        atomic_write(&path, &bytes).expect("write");
        let back = load_sends(&path, "mainnet");
        assert_eq!(back.records, sends);
        assert_eq!(back.bytes, bytes);
        assert!(!back.kept);

        // One leg that does not decode is dropped; the rest stand, and only
        // the dropped record is kept aside.
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).expect("json");
        value["legs"]
            .as_array_mut()
            .expect("legs")
            .push(serde_json::json!({"txid": 7}));
        atomic_write(&path, &serde_json::to_vec(&value).expect("json")).expect("write");
        let back = load_sends(&path, "mainnet");
        assert_eq!(back.records.legs, vec![leg]);
        let kept = asides(&path);
        assert_eq!(kept.len(), 1, "{kept:?}");
        let copy: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&kept[0]).expect("copy")).expect("json");
        assert_eq!(copy, serde_json::json!([{"txid": 7}]));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unreadable_or_foreign_file_is_set_aside_not_overwritten() {
        let dir = dir("aside");
        let path = sends_path(&dir.join("activity.kvlog"));
        atomic_write(&path, b"not json").expect("write");
        let back = load_sends(&path, "mainnet");
        assert_eq!(back.records, Sends::default());
        assert!(back.bytes.is_empty() && !back.kept);
        assert!(
            !path.exists(),
            "the unreadable file was left where a write lands"
        );
        let kept = asides(&path);
        assert_eq!(kept.len(), 1);
        assert_eq!(std::fs::read(&kept[0]).expect("aside"), b"not json");

        // Another network's file, and a second bad file: each kept on its own.
        let other = encode_sends("testnet-10", &Sends::default()).expect("encodes");
        atomic_write(&path, &other).expect("write");
        let back = load_sends(&path, "mainnet");
        assert_eq!(back.records, Sends::default());
        assert!(
            !path.exists(),
            "another network's file was read as this one's"
        );
        assert_eq!(asides(&path).len(), 2, "a second copy replaced the first");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A file that cannot be read is set aside too**, as one that cannot be
    /// decoded is; and one that can be neither read nor moved stays in place,
    /// with every write over it refused.
    #[tokio::test]
    async fn a_file_that_cannot_be_read_is_never_written_over() {
        use std::os::unix::fs::PermissionsExt;
        let dir = dir("read-error");
        let path = sends_path(&dir.join("activity.kvlog"));
        std::fs::create_dir_all(path.join("in-the-way")).expect("a directory in its place");
        let back = load_sends(&path, "mainnet");
        assert!(
            !back.kept && !path.exists(),
            "a read error left the path to the next write"
        );
        assert_eq!(asides(&path).len(), 1);

        // A file that cannot be read this time stays, and nothing is written
        // over it.
        let unreadable = sends_path(&dir.join("other.kvlog"));
        std::fs::write(&unreadable, b"{}").expect("a file");
        std::fs::set_permissions(&unreadable, std::fs::Permissions::from_mode(0o000))
            .expect("unreadable");
        let back = load_sends(&unreadable, "mainnet");
        let file = DurableFile::new(unreadable.clone(), back.bytes, back.kept);
        let refused = file.write(file.next_generation(), b"[]".to_vec()).await;
        std::fs::set_permissions(&unreadable, std::fs::Permissions::from_mode(0o644))
            .expect("readable again");
        assert!(back.kept, "a file that could not be read was not kept");
        assert!(
            refused.is_err(),
            "a write landed over a file that could not be read"
        );
        assert_eq!(std::fs::read(&unreadable).expect("read"), b"{}");

        // Neither readable nor movable: a directory in a folder nothing may
        // be renamed out of.
        let locked = dir.join("locked");
        let path = sends_path(&locked.join("activity.kvlog"));
        std::fs::create_dir_all(path.join("in-the-way")).expect("a directory in its place");
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o555))
            .expect("read-only");
        let back = load_sends(&path, "mainnet");
        let file = DurableFile::new(path.clone(), back.bytes, back.kept);
        let refused = file.write(1, b"{}".to_vec()).await;
        std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755))
            .expect("writable again");
        assert!(back.kept, "an unmovable unreadable file was not kept");
        assert!(refused.is_err(), "a write landed over an unreadable file");
        assert!(path.is_dir(), "the unreadable file was disturbed");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn an_older_snapshot_never_lands_after_a_newer_one() {
        let dir = dir("generation");
        let file = DurableFile::new(dir.join("x.sends"), Vec::new(), false);
        file.write(2, b"two".to_vec()).await.expect("write");
        file.write(1, b"one".to_vec()).await.expect("write");
        assert_eq!(std::fs::read(file.path()).expect("read"), b"two");
        file.write(3, b"three".to_vec()).await.expect("write");
        assert_eq!(std::fs::read(file.path()).expect("read"), b"three");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hex_round_trips_and_refuses_odd_or_foreign_text() {
        let bytes = vec![0x00, 0x7f, 0xff, 0x20];
        assert_eq!(from_hex(&to_hex(&bytes)), Some(bytes));
        assert_eq!(from_hex("abc"), None);
        assert_eq!(from_hex("zz"), None);
    }
}
