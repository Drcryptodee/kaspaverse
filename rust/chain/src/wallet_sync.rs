//! Wallet UTXO sync — balance + activity for a derived address set, over the
//! wRPC client SHARED with the P0 [`DagMonitor`] (P1 §0.8 / D-005: one
//! `UtxoProcessor`, one `UtxoContext`, joining the monitor's connection — never
//! a second socket, so the header DAA and the wallet's maturity DAA can never
//! diverge).
//!
//! INV-9 — every byte of UTXO/balance/maturity logic is consumed from the
//! pinned `kaspa-wallet-core` (rev `90dbf07` = v2.0.0), never re-implemented.
//! The wiring mirrors the worked example `wallet/core/src/utxo/test.rs:9`
//! (processor → context → scan_and_register) and the subscription loop in
//! `wallet/core/src/api/transport.rs:210` (`multiplexer().channel()` →
//! `receiver.recv()`). Balance fields pass through verbatim from
//! `Events::Balance` (`utxo/balance.rs:97`); the direction/maturity of an
//! activity row come from `TransactionRecord`'s own helpers
//! (`storage/transaction/record.rs:391/411/418`) — nothing is computed locally.
//!
//! INV-3 — the activity store persists only public chain data (txids, amounts,
//! DAA scores) to an app-private file; no secret type is reachable from this
//! module (it never sees a seed or keychain — the bridge hands it public
//! [`Address`]es only).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};

use borsh::{BorshDeserialize, BorshSerialize};
use kaspa_addresses::Address;
use kaspa_wallet_core::events::Events;
use kaspa_wallet_core::rpc::Rpc;
use kaspa_wallet_core::storage::transaction::{TransactionData, TransactionId, TransactionRecord};
use kaspa_wallet_core::utxo::{Maturity, UtxoContext, UtxoContextBinding, UtxoProcessor};
use kaspa_wrpc_client::prelude::NetworkId;
use tokio::sync::{broadcast, oneshot};

use crate::error::Result;

/// Most rows the feed carries — "recent activity", not full history (§0.10).
const ACTIVITY_CAP: usize = 100;

/// Direction of an activity row, mapped from the wallet-core
/// [`TransactionData`] variant. Receive-only at P1.5; `Outgoing`/`Change`
/// rows appear once send lands (P1.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityDirection {
    Incoming,
    Outgoing,
    Change,
}

/// Maturity of an activity row, from `TransactionRecord::maturity()` evaluated
/// at the latest DAA (`record.rs:391` — Pending until the DAA-based maturity
/// period elapses, then Confirmed). Stasis collapses into Pending (coinbase
/// stasis is never surfaced as a user row).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityMaturity {
    Pending,
    Confirmed,
}

/// A single activity row — the chain-layer projection of a wallet-core
/// [`TransactionRecord`]. Plain public fields; the bridge maps this 1:1 onto
/// the FFI DTO (wallet-core types never reach the FFI surface).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalletActivityRecord {
    pub txid: String,
    pub value_sompi: u64,
    pub unixtime_msec: Option<u64>,
    pub block_daa_score: u64,
    pub direction: ActivityDirection,
    pub is_coinbase: bool,
    pub maturity: ActivityMaturity,
}

/// A folded wallet event. Values are absolute (like [`crate::DagEvent`]), so the
/// bridge's snapshot fold is plain assignment (INV-9 — nothing computed there).
#[derive(Debug, Clone, PartialEq)]
pub enum WalletEvent {
    /// wRPC (re)connected; `url` is the resolver-picked endpoint.
    Connected { url: Option<String> },
    /// wRPC disconnected (the shared client keeps retrying).
    Disconnected,
    /// `UtxoProcStart` — the processor is initialised; the initial scan begins.
    Syncing,
    /// The connected node has no UTXO index — sync cannot proceed on it
    /// (INV-8: surface honestly, never a silent zero).
    UtxoIndexMissing { url: Option<String> },
    /// Absolute balance (sompi). Receiving this — even all-zero — means a real
    /// sync completed: an empty wallet resolves to a live `0`, never unknown.
    Balance {
        mature: u64,
        pending: u64,
        outgoing: u64,
    },
    /// The full current activity list, newest-first (capped at [`ACTIVITY_CAP`]).
    Activity(Vec<WalletActivityRecord>),
    /// A non-fatal processor error (safe to surface; safe to ignore).
    Error(String),
}

/// Project a wallet-core record onto a row, classifying with the record's own
/// helpers (INV-9). `current_daa_score` drives maturity — pass the processor's
/// live DAA so a reloaded Pending row promotes the instant the chain advances.
fn map_record(record: &TransactionRecord, current_daa_score: u64) -> WalletActivityRecord {
    let direction = if record.is_outgoing() {
        ActivityDirection::Outgoing
    } else if record.is_change() || record.is_batch() {
        ActivityDirection::Change
    } else {
        match record.transaction_data() {
            TransactionData::TransferOutgoing { .. } => ActivityDirection::Outgoing,
            // Incoming / External / TransferIncoming / Reorg / Stasis read as
            // received (Reorg/Stasis never reach the feed — see the engine).
            _ => ActivityDirection::Incoming,
        }
    };

    let maturity = match record.maturity(current_daa_score) {
        Maturity::Confirmed => ActivityMaturity::Confirmed,
        Maturity::Pending | Maturity::Stasis => ActivityMaturity::Pending,
    };

    WalletActivityRecord {
        txid: record.id().to_string(),
        value_sompi: record.value(),
        unixtime_msec: record.unixtime_msec(),
        block_daa_score: record.block_daa_score(),
        direction,
        is_coinbase: record.is_coinbase(),
        maturity,
    }
}

/// One persisted frame in the append-only activity log. `Upsert` carries a full
/// wallet-core record (its own borsh codec, with a storage magic/version);
/// `Remove` is a reorg tombstone keyed by txid (so replay reconstructs a
/// removal without rewriting the file).
#[derive(BorshSerialize, BorshDeserialize)]
enum StoreFrame {
    // Boxed: borsh serializes `Box<T>` byte-identically to `T` (no on-disk
    // change), and it keeps the enum small (clippy::large_enum_variant — the
    // record is ~400 bytes, the tombstone 32).
    Upsert(Box<TransactionRecord>),
    Remove(TransactionId),
}

/// Length-prefix a frame for the append-only log: `[u32 LE len][borsh body]`.
fn frame_bytes(frame: &StoreFrame) -> Result<Vec<u8>> {
    let body = borsh::to_vec(frame)
        .map_err(|e| crate::error::ChainError::Message(format!("activity encode: {e}")))?;
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_le_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

/// Replay an append-only log into the live record set (last-write-wins per txid;
/// tombstones remove). Tolerates a torn final frame (a crash mid-append loses at
/// most the last record, which the next live event re-emits) and a corrupt body
/// (stops, keeping everything decoded so far).
fn replay(bytes: &[u8]) -> HashMap<TransactionId, TransactionRecord> {
    let mut records = HashMap::new();
    let mut cursor = bytes;
    while cursor.len() >= 4 {
        let len = u32::from_le_bytes([cursor[0], cursor[1], cursor[2], cursor[3]]) as usize;
        cursor = &cursor[4..];
        if cursor.len() < len {
            break; // torn tail — stop
        }
        let (body, rest) = cursor.split_at(len);
        cursor = rest;
        match StoreFrame::try_from_slice(body) {
            Ok(StoreFrame::Upsert(record)) => {
                let id = *record.id();
                records.insert(id, *record);
            }
            Ok(StoreFrame::Remove(id)) => {
                records.remove(&id);
            }
            Err(_) => break, // corrupt frame — keep what we have
        }
    }
    records
}

/// Append-only activity store in an app-private file (§0.10). Public chain data
/// only (INV-3). The in-memory map is the source of truth for the feed; the
/// file is its durable replay log.
struct ActivityStore {
    path: PathBuf,
    records: HashMap<TransactionId, TransactionRecord>,
}

impl ActivityStore {
    /// Load by replaying the log; a missing file is an empty store.
    fn load(path: PathBuf) -> Result<Self> {
        let records = match std::fs::read(&path) {
            Ok(bytes) => replay(&bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(e) => return Err(e.into()),
        };
        Ok(Self { path, records })
    }

    fn append(&self, frame: &StoreFrame) -> Result<()> {
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

    fn upsert(&mut self, record: TransactionRecord) -> Result<()> {
        self.append(&StoreFrame::Upsert(Box::new(record.clone())))?;
        self.records.insert(*record.id(), record);
        Ok(())
    }

    fn remove(&mut self, id: &TransactionId) -> Result<()> {
        if self.records.remove(id).is_some() {
            self.append(&StoreFrame::Remove(*id))?;
        }
        Ok(())
    }

    /// Newest-first rows, capped, with maturity resolved at `current_daa_score`.
    fn list(&self, current_daa_score: u64) -> Vec<WalletActivityRecord> {
        let mut records: Vec<&TransactionRecord> = self.records.values().collect();
        records.sort_by(|a, b| {
            b.block_daa_score()
                .cmp(&a.block_daa_score())
                .then(b.unixtime_msec().cmp(&a.unixtime_msec()))
        });
        records
            .into_iter()
            .take(ACTIVITY_CAP)
            .map(|record| map_record(record, current_daa_score))
            .collect()
    }
}

struct Inner {
    processor: UtxoProcessor,
    context: UtxoContext,
    events: broadcast::Sender<WalletEvent>,
    store: Mutex<ActivityStore>,
    event_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    shutdown: Mutex<Option<oneshot::Sender<()>>>,
}

/// Drives one [`UtxoProcessor`] + [`UtxoContext`] over a shared [`Rpc`], folding
/// the wallet framework's event stream into [`WalletEvent`]s and persisting
/// observed records. Clone-able; one engine per unlocked vault.
#[derive(Clone)]
pub struct WalletEngine {
    inner: Arc<Inner>,
}

impl WalletEngine {
    /// Bind a processor to the shared `rpc` (from [`crate::DagMonitor::rpc`]).
    /// One `UtxoContext` = one account (P1 §0.8). `store_path` is an app-private
    /// file for the activity log (INV-3).
    pub fn new(rpc: Rpc, network_id: NetworkId, store_path: PathBuf) -> Result<Self> {
        let processor = UtxoProcessor::new(Some(rpc), Some(network_id), None, None);
        let context = UtxoContext::new(&processor, UtxoContextBinding::default());
        let store = ActivityStore::load(store_path)?;
        let (events, _) = broadcast::channel(256);
        Ok(Self {
            inner: Arc::new(Inner {
                processor,
                context,
                events,
                store: Mutex::new(store),
                event_task: Mutex::new(None),
                shutdown: Mutex::new(None),
            }),
        })
    }

    /// A new receiver onto the folded event fan-out.
    pub fn subscribe(&self) -> broadcast::Receiver<WalletEvent> {
        self.inner.events.subscribe()
    }

    /// Start watching `addresses` (the derived receive+change window — public
    /// strings derived by the bridge from the unlocked vault; this layer never
    /// sees a secret). Spawns the fold task and starts the processor; if the
    /// shared client is already connected the processor fires `UtxoProcStart`
    /// immediately (`processor.rs:704`), which triggers the initial scan.
    ///
    /// Must be called from within a tokio runtime (FRB's).
    pub async fn start(&self, addresses: Vec<Address>) -> Result<()> {
        // Register on the Events multiplexer BEFORE start() so a synchronous
        // UtxoProcStart on an already-connected client is buffered, not missed.
        let channel = self.inner.processor.multiplexer().channel();
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        *self
            .inner
            .shutdown
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(shutdown_tx);

        let engine = self.clone();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    // Drain events before honoring shutdown (mirrors the
                    // upstream biased select in processor.rs:710).
                    biased;
                    msg = channel.receiver.recv() => {
                        match msg {
                            Ok(event) => engine.handle_event(*event, &addresses).await,
                            Err(_) => break, // multiplexer closed
                        }
                    }
                    _ = &mut shutdown_rx => break,
                }
            }
            // Hold the channel for the whole loop so the multiplexer keeps our
            // subscription registered; drop it explicitly on exit.
            drop(channel);
        });
        *self
            .inner
            .event_task
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(task);

        self.inner.processor.start().await?;
        Ok(())
    }

    /// Stop the processor and drain the fold task (e.g. on vault lock — the
    /// shared wRPC socket stays up, owned by the DagMonitor).
    pub async fn stop(&self) -> Result<()> {
        self.inner.processor.stop().await?;
        // Take both handles out from under their locks BEFORE awaiting — never
        // hold a std MutexGuard across an await (clippy::await_holding_lock;
        // mirrors dag_monitor.rs:148).
        let shutdown = self
            .inner
            .shutdown
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(tx) = shutdown {
            let _ = tx.send(());
        }
        let task = self
            .inner
            .event_task
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(task) = task {
            let _ = task.await;
        }
        Ok(())
    }

    fn emit(&self, event: WalletEvent) {
        // Fails only with zero receivers — fine to drop.
        let _ = self.inner.events.send(event);
    }

    fn current_daa(&self) -> u64 {
        self.inner.processor.current_daa_score().unwrap_or(0)
    }

    fn emit_activity(&self) {
        let daa = self.current_daa();
        let list = self
            .inner
            .store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .list(daa);
        self.emit(WalletEvent::Activity(list));
    }

    async fn handle_event(&self, event: Events, addresses: &[Address]) {
        match event {
            Events::UtxoProcStart => {
                self.emit(WalletEvent::Syncing);
                log::info!(
                    "wallet-sync: utxo-proc start — scanning {} addresses",
                    addresses.len()
                );
                // Register the address window and fetch the initial UTXO set;
                // this drives Discovery + Balance events (the latter even for an
                // empty wallet → a live zero). DAA is already stored by
                // handle_connect_impl (processor.rs:529) before UtxoProcStart.
                if let Err(e) = self
                    .inner
                    .context
                    .scan_and_register_addresses(addresses.to_vec(), None)
                    .await
                {
                    self.emit(WalletEvent::Error(e.to_string()));
                }
            }
            Events::Connect { url, .. } => self.emit(WalletEvent::Connected { url }),
            Events::Disconnect { .. } => self.emit(WalletEvent::Disconnected),
            Events::UtxoIndexNotEnabled { url } => {
                log::warn!(
                    "wallet-sync: node has no UTXO index ({url:?}) — degrading honestly (INV-8)"
                );
                self.emit(WalletEvent::UtxoIndexMissing { url });
            }
            Events::Balance { balance, .. } => {
                let (mature, pending, outgoing) = balance
                    .map(|b| (b.mature, b.pending, b.outgoing))
                    .unwrap_or((0, 0, 0));
                // Public chain data (sompi) — lets a "stuck/wrong balance" report
                // be diagnosed from logcat; never a secret (INV-3).
                log::info!(
                    "wallet-sync: balance mature={mature} pending={pending} outgoing={outgoing} sompi"
                );
                self.emit(WalletEvent::Balance {
                    mature,
                    pending,
                    outgoing,
                });
            }
            Events::Pending { record }
            | Events::Maturity { record }
            | Events::Discovery { record } => {
                {
                    let mut store = self
                        .inner
                        .store
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    if let Err(e) = store.upsert(record) {
                        log::warn!("wallet-sync: activity append failed: {e}");
                    }
                }
                self.emit_activity();
            }
            Events::Reorg { record } => {
                log::info!("wallet-sync: reorg — removing tx {}", record.id());
                {
                    let mut store = self
                        .inner
                        .store
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    if let Err(e) = store.remove(record.id()) {
                        log::warn!("wallet-sync: activity tombstone failed: {e}");
                    }
                }
                self.emit_activity();
            }
            // Coinbase stasis is never a user row (events.rs:185).
            Events::Stasis { .. } => {}
            Events::UtxoProcError { message } | Events::Error { message } => {
                self.emit(WalletEvent::Error(message))
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_wallet_core::storage::Binding;
    use kaspa_wallet_core::utxo::UtxoContextId;
    use kaspa_wrpc_client::prelude::{NetworkId, NetworkType};

    fn incoming(id_byte: u8, value: u64, daa: u64) -> TransactionRecord {
        record(
            id_byte,
            value,
            daa,
            TransactionData::Incoming {
                utxo_entries: vec![],
                aggregate_input_value: value,
            },
        )
    }

    fn record(id_byte: u8, value: u64, daa: u64, data: TransactionData) -> TransactionRecord {
        TransactionRecord {
            id: TransactionId::from_bytes([id_byte; 32]),
            unixtime_msec: Some(1_700_000_000_000 + daa),
            value,
            binding: Binding::Custom(UtxoContextId::default()),
            block_daa_score: daa,
            network_id: NetworkId::new(NetworkType::Mainnet),
            transaction_data: data,
            note: None,
            metadata: None,
        }
    }

    #[test]
    fn replay_applies_upserts_and_tombstones() {
        let a = incoming(1, 100, 10);
        let b = incoming(2, 200, 20);
        let mut log = Vec::new();
        log.extend(frame_bytes(&StoreFrame::Upsert(Box::new(a.clone()))).unwrap());
        log.extend(frame_bytes(&StoreFrame::Upsert(Box::new(b.clone()))).unwrap());
        log.extend(frame_bytes(&StoreFrame::Remove(*a.id())).unwrap());

        let records = replay(&log);
        assert_eq!(records.len(), 1, "the tombstoned record is gone");
        assert!(records.contains_key(b.id()));
        assert!(!records.contains_key(a.id()));
    }

    #[test]
    fn replay_overwrites_in_place_on_reupsert() {
        // A Pending then a Maturity for the same txid: last write wins, one row.
        let pending = incoming(7, 500, 100);
        let matured = incoming(7, 500, 100);
        let mut log = Vec::new();
        log.extend(frame_bytes(&StoreFrame::Upsert(Box::new(pending))).unwrap());
        log.extend(frame_bytes(&StoreFrame::Upsert(Box::new(matured))).unwrap());
        assert_eq!(replay(&log).len(), 1);
    }

    #[test]
    fn replay_tolerates_a_torn_tail() {
        let a = incoming(1, 100, 10);
        let mut log = frame_bytes(&StoreFrame::Upsert(Box::new(a.clone()))).unwrap();
        // A second frame that claims 40 bytes but only 3 follow (crash mid-append).
        log.extend_from_slice(&40u32.to_le_bytes());
        log.extend_from_slice(&[9, 9, 9]);

        let records = replay(&log);
        assert_eq!(records.len(), 1, "the intact first frame survives");
        assert!(records.contains_key(a.id()));
    }

    #[test]
    fn map_record_classifies_incoming_and_maturity() {
        // Mainnet user-tx maturity period is 100 DAA (utxo/settings.rs).
        let rec = incoming(3, 1_234, 1_000);

        let pending = map_record(&rec, 1_050);
        assert_eq!(pending.direction, ActivityDirection::Incoming);
        assert_eq!(pending.maturity, ActivityMaturity::Pending);
        assert_eq!(pending.value_sompi, 1_234);
        assert!(!pending.is_coinbase);
        assert_eq!(pending.block_daa_score, 1_000);
        assert_eq!(pending.txid.len(), 64, "txid is 32-byte hash hex");

        let confirmed = map_record(&rec, 1_200);
        assert_eq!(confirmed.maturity, ActivityMaturity::Confirmed);
    }

    #[test]
    fn list_is_newest_first_and_capped() {
        let dir = std::env::temp_dir().join(format!("kv-wsync-{}", std::process::id()));
        let path = dir.join("activity.kvlog");
        let _ = std::fs::remove_file(&path);
        let mut store = ActivityStore::load(path.clone()).unwrap();

        // Insert out of order; expect newest (highest DAA) first.
        store.upsert(incoming(1, 10, 30)).unwrap();
        store.upsert(incoming(2, 20, 10)).unwrap();
        store.upsert(incoming(3, 30, 20)).unwrap();

        let rows = store.list(1_000_000);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].block_daa_score, 30);
        assert_eq!(rows[1].block_daa_score, 20);
        assert_eq!(rows[2].block_daa_score, 10);
        assert_eq!(rows[0].maturity, ActivityMaturity::Confirmed);

        // Reload from disk → the same three survive (replay round-trip).
        let reloaded = ActivityStore::load(path.clone()).unwrap();
        assert_eq!(reloaded.records.len(), 3);

        let _ = std::fs::remove_file(&path);
    }
}
