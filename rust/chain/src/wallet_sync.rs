//! Wallet UTXO sync — balance + activity for a derived address set, over the
//! wRPC client SHARED with the P0 [`DagMonitor`] (P1 §0.8 / D-005: one
//! `UtxoProcessor`, one `UtxoContext`, joining the monitor's connection — never
//! a second socket, so the header DAA and the wallet's maturity DAA can never
//! diverge).
//!
//! INV-9 — every byte of UTXO/balance/maturity logic is consumed from the
//! pinned `kaspa-wallet-core` (rev `cfafeb4c` = v2.0.1, D-058), never re-implemented.
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

use std::collections::{HashMap, HashSet};
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

use crate::error::{ChainError, Result};

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
///
/// `Unknown` is the V2b honesty state (finding 13): a receive folded while the
/// processor has NO live DAA yet (the cold-start boot emit) cannot be
/// classified — calling it Pending made hours-settled history masquerade as
/// in-flight and stream huge counters. Unknown renders quiet; the first
/// DAA-bearing fold (or the V1 acceptance overlay) resolves it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivityMaturity {
    Pending,
    Confirmed,
    Unknown,
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
    /// DAA score at which the DAG ACCEPTED this spend (`None` for a receive, or
    /// a spend not yet accepted). The honest anchor for a send's confirmation-
    /// depth counter — `current_daa − accepted_daa_score` is true depth from
    /// acceptance, where `block_daa_score` on a send is only submit time and
    /// would overstate. Surfaced from `TransactionData::Outgoing` (pin).
    pub accepted_daa_score: Option<u64>,
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

/// The amount a wallet-originated send displays: the PAYMENT that left the wallet
/// (`payment_value`), or — for a sweep with no payment output — the net outflow
/// (inputs − change). NEVER the change that returns to us. Pure; unit-tested.
fn spend_value(payment_value: Option<u64>, aggregate_input: u64, change_value: u64) -> u64 {
    payment_value.unwrap_or_else(|| aggregate_input.saturating_sub(change_value))
}

/// True iff every UTXO sits at one of our CHANGE addresses (and there is at
/// least one). A UTXO at a change address is always our own change returning —
/// never a deposit, since change addresses are internal and never handed out.
/// Pure; unit-tested. An unknown (`None`) address is NOT assumed to be change.
fn all_change_addresses(addresses: &[Option<Address>], change_set: &HashSet<Address>) -> bool {
    !addresses.is_empty()
        && addresses
            .iter()
            .all(|a| a.as_ref().is_some_and(|a| change_set.contains(a)))
}

/// A record wallet-core classifies as a receive (an inbound deposit or an
/// externally-observed credit). The two shapes a re-scan can wrongly attach to
/// one of OUR txids after losing outgoing context.
fn is_incoming_data(record: &TransactionRecord) -> bool {
    matches!(
        record.transaction_data(),
        TransactionData::Incoming { .. } | TransactionData::External { .. }
    )
}

/// A record wallet-core classifies as a spend WE originated. If we already hold
/// a txid in one of these shapes, that txid is ours — a later incoming
/// re-report of it is stale context, never a new deposit ([`ActivityStore::upsert`]).
fn is_outgoing_data(record: &TransactionRecord) -> bool {
    matches!(
        record.transaction_data(),
        TransactionData::Outgoing { .. }
            | TransactionData::Change { .. }
            | TransactionData::Batch { .. }
            | TransactionData::TransferOutgoing { .. }
    )
}

/// Whether a record is our own change re-reported as an incoming deposit. After
/// a restart, wallet-core loses its in-memory "this was my send" context, so a
/// re-scan files our returning change as an `Incoming` (`context.rs`
/// handle_utxo_added, `outgoing()` = None). Such a record is NOT a deposit — its
/// UTXOs are all at our change addresses (device find 2026-06-15). The txid-
/// provenance guard in [`ActivityStore::upsert`] now catches the same class when
/// the returning change lands on the conversation-bound RECEIVE address (D2);
/// this address-set check remains for a cold re-scan that never saw the send.
fn is_own_change(record: &TransactionRecord, change_set: &HashSet<Address>) -> bool {
    let utxos = match record.transaction_data() {
        TransactionData::Incoming { utxo_entries, .. }
        | TransactionData::External { utxo_entries, .. } => utxo_entries,
        // Outgoing/Change/Batch are handled as sends; only an incoming-classified
        // record can be our misfiled change.
        _ => return false,
    };
    let addresses: Vec<Option<Address>> = utxos.iter().map(|u| u.address.clone()).collect();
    all_change_addresses(&addresses, change_set)
}

/// Project a wallet-core record onto a row, classifying with the record's own
/// helpers (INV-9). `current_daa_score` drives maturity — pass the processor's
/// live DAA so a reloaded Pending row promotes the instant the chain advances.
/// `None` (no DAA yet — the pre-connect boot emit) classifies receives as
/// [`ActivityMaturity::Unknown`], never a guessed Pending (finding 13: the
/// cold-start confirmation storm was `unwrap_or(0)` here — with DAA 0 every
/// settled receive re-pended and the glass streamed its huge DAA distance).
fn map_record(record: &TransactionRecord, current_daa_score: Option<u64>) -> WalletActivityRecord {
    // A transaction the wallet ORIGINATED (a send) reaches us as TWO records on
    // one txid: an `Outgoing` (pending, on submit) and — when the change UTXO
    // confirms — a `Change` record (wallet-core, context.rs:handle_utxo_added).
    // Both must render as ONE outgoing row showing the PAYMENT (`payment_value`),
    // never the change that returns to us (== the new balance; not a receive).
    // And a send is Confirmed the moment the DAG ACCEPTS it (`accepted_daa_score`)
    // — NOT when its change UTXO separately matures (that left sends stuck on
    // "Pending" until the next event). `record.value()` (= change for a `Change`
    // record) is wrong for this row; we read the typed data instead.
    let (direction, value_sompi, spend_accepted, accepted_daa_score) =
        match record.transaction_data() {
            TransactionData::Outgoing {
                payment_value,
                aggregate_input_value,
                change_value,
                accepted_daa_score,
                ..
            }
            | TransactionData::Change {
                payment_value,
                aggregate_input_value,
                change_value,
                accepted_daa_score,
                ..
            }
            | TransactionData::TransferOutgoing {
                payment_value,
                aggregate_input_value,
                change_value,
                accepted_daa_score,
                ..
            } => (
                ActivityDirection::Outgoing,
                spend_value(*payment_value, *aggregate_input_value, *change_value),
                Some(accepted_daa_score.is_some()),
                *accepted_daa_score,
            ),
            // Internal compounding leg of a >100k-mass chained send.
            TransactionData::Batch {
                aggregate_input_value,
                accepted_daa_score,
                ..
            } => (
                ActivityDirection::Change,
                *aggregate_input_value,
                Some(accepted_daa_score.is_some()),
                *accepted_daa_score,
            ),
            // Incoming / External / TransferIncoming: a receive (Reorg/Stasis never
            // reach the feed — the engine tombstones / ignores them).
            _ => (ActivityDirection::Incoming, record.value(), None, None),
        };

    let maturity = match (spend_accepted, current_daa_score) {
        // A spend: Confirmed once the DAG accepts it; Pending until then.
        // (Acceptance is persisted in the record — no live DAA needed.)
        (Some(accepted), _) if accepted => ActivityMaturity::Confirmed,
        (Some(_), _) => ActivityMaturity::Pending,
        // A receive: matures over the UTXO maturity period (INV-9 — the record's
        // own helper at the live DAA, never our own threshold).
        (None, Some(daa)) => match record.maturity(daa) {
            Maturity::Confirmed => ActivityMaturity::Confirmed,
            Maturity::Pending | Maturity::Stasis => ActivityMaturity::Pending,
        },
        // A receive with no live DAA: honestly unresolved (finding 13).
        (None, None) => ActivityMaturity::Unknown,
    };

    WalletActivityRecord {
        txid: record.id().to_string(),
        value_sompi,
        unixtime_msec: record.unixtime_msec(),
        block_daa_score: record.block_daa_score(),
        accepted_daa_score,
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

    /// Returns whether the record was written (`false` = refused by the
    /// provenance guard below) so the caller's log line can say which — the
    /// finding-8 discriminating lane (V2).
    fn upsert(&mut self, record: TransactionRecord) -> Result<bool> {
        // Provenance guard (D2/P4): once we hold a txid as a SEND we originated
        // (Outgoing / Change / Batch / TransferOutgoing), a later re-scan that
        // re-reports the SAME txid as an Incoming/External deposit is the
        // lost-outgoing-context phenomenon (context.rs handle_utxo_added, restart
        // re-scan), NOT a new receive — refuse the downgrade. Without this,
        // conversation change returning to the bound RECEIVE address (source
        // discipline routes it there, so the address stays funded for the next
        // input[0]) would surface as a phantom "received" row after a restart.
        // The address-set heuristic ([`is_own_change`]) can't catch it — the
        // bound address is a receive address, and marking receive addresses
        // internal would hide REAL deposits to them. Txid provenance is exact:
        // a genuine deposit or a counterpart's bond refund carries THEIR txid,
        // never one we already filed as outgoing.
        if is_incoming_data(&record) {
            if let Some(existing) = self.records.get(record.id()) {
                if is_outgoing_data(existing) {
                    return Ok(false);
                }
            }
        }
        self.append(&StoreFrame::Upsert(Box::new(record.clone())))?;
        self.records.insert(*record.id(), record);
        Ok(true)
    }

    fn remove(&mut self, id: &TransactionId) -> Result<()> {
        if self.records.remove(id).is_some() {
            self.append(&StoreFrame::Remove(*id))?;
        }
        Ok(())
    }

    /// Newest-first rows, capped, with maturity resolved at `current_daa_score`
    /// (`None` — no live DAA yet — resolves receives as Unknown, finding 13).
    /// Hides any record that is our own returning change misfiled as an incoming
    /// (cleans entries a pre-fix restart re-scan may have already persisted).
    fn list(
        &self,
        current_daa_score: Option<u64>,
        change_set: &HashSet<Address>,
    ) -> Vec<WalletActivityRecord> {
        let mut records: Vec<&TransactionRecord> = self
            .records
            .values()
            .filter(|record| !is_own_change(record, change_set))
            .collect();
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
    /// The watched address window `start()` was given — kept so
    /// [`WalletEngine::rescan`] can re-ask the node for the SAME set the
    /// balance reflects (public strings only, INV-3).
    watch: Mutex<Vec<Address>>,
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
                watch: Mutex::new(Vec::new()),
            }),
        })
    }

    /// A new receiver onto the folded event fan-out.
    pub fn subscribe(&self) -> broadcast::Receiver<WalletEvent> {
        self.inner.events.subscribe()
    }

    /// The spendable UTXO source, for send construction (P1.6 [`crate::send`]).
    /// A clone shares the SAME underlying context (Arc) — the exact watched set
    /// the balance reflects, so a send spends only what the UI shows as mature.
    pub fn context(&self) -> UtxoContext {
        self.inner.context.clone()
    }

    /// DAA score at which a recorded activity tx was accepted — for incoming
    /// records this is the UTXO entry's acceptance score (wallet-core
    /// `new_incoming_impl`, pin record.rs:496: `utxos[0].utxo.block_daa_score`),
    /// which is exactly what the node's `get_utxo_return_address` lookup keys
    /// on (P2.3 sender resolution). `None` while the pipeline has not yet
    /// recorded the tx — the caller surfaces "still confirming", never guesses.
    pub fn activity_daa_score(&self, txid: &str) -> Option<u64> {
        let id: TransactionId = txid.parse().ok()?;
        self.inner
            .store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .records
            .get(&id)
            .map(|record| record.block_daa_score())
    }

    /// Start watching `addresses` (the derived receive+change window — public
    /// strings derived by the bridge from the unlocked vault; this layer never
    /// sees a secret). Spawns the fold task and starts the processor; if the
    /// shared client is already connected the processor fires `UtxoProcStart`
    /// immediately (`processor.rs:704`), which triggers the initial scan.
    ///
    /// Must be called from within a tokio runtime (FRB's). `change_addresses` is
    /// the change subset of `addresses` — used to recognise our own returning
    /// change (a UTXO there is never a deposit) so a restart re-scan doesn't
    /// misfile it as an incoming.
    pub async fn start(
        &self,
        addresses: Vec<Address>,
        change_addresses: Vec<Address>,
    ) -> Result<()> {
        // Register on the Events multiplexer BEFORE start() so a synchronous
        // UtxoProcStart on an already-connected client is buffered, not missed.
        let channel = self.inner.processor.multiplexer().channel();
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        *self
            .inner
            .shutdown
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(shutdown_tx);

        let change_set: HashSet<Address> = change_addresses.into_iter().collect();
        *self
            .inner
            .watch
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = addresses.clone();

        // Emit the PERSISTED activity once at start (2026-07-09 V1 sitting
        // find): record events are the only other emission trigger, and a
        // boot where every UTXO is settled own-change fires none — the list
        // rendered "No recent activity" while activity.kvlog held the full
        // history. Earlier boots masked this behind instant Discovery events.
        self.emit_activity(&change_set);

        let engine = self.clone();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    // Drain events before honoring shutdown (mirrors the
                    // upstream biased select in processor.rs:710).
                    biased;
                    msg = channel.receiver.recv() => {
                        match msg {
                            Ok(event) => engine.handle_event(*event, &addresses, &change_set).await,
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

    /// In-place node re-ask (V6 soft pull-refresh, amending the V3 pull heal
    /// — register item 12): re-fetch the watched window's UTXO set over the
    /// LIVE connection using the pin's own scan primitive — the same
    /// `scan_and_register_addresses` call the `UtxoProcStart` arm makes
    /// (INV-9; the known-address filter only gates the subscription half,
    /// the UTXO fetch always runs the full list). No socket drop, no
    /// `UtxoProcStart`, no beacon flicker; Balance/Discovery events flow
    /// through the normal fold. Errs when the engine hasn't started or the
    /// processor has no live DAA — callers treat an `Err` as "soft path
    /// unavailable" and escalate to the hard reconnect.
    pub async fn rescan(&self) -> Result<()> {
        let addresses = self
            .inner
            .watch
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if addresses.is_empty() {
            return Err(ChainError::Message("wallet engine not started".into()));
        }
        let count = addresses.len();
        self.inner
            .context
            .scan_and_register_addresses(addresses, None)
            .await?;
        log::info!("wallet-sync: in-place rescan re-asked the node for {count} addresses");
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

    /// The processor's live DAA — `None` until it has connected and synced
    /// (never a fabricated 0: with DAA 0 every receive classifies Pending,
    /// the finding-13 storm).
    fn current_daa(&self) -> Option<u64> {
        self.inner.processor.current_daa_score()
    }

    fn emit_activity(&self, change_set: &HashSet<Address>) {
        let daa = self.current_daa();
        let list = self
            .inner
            .store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .list(daa, change_set);
        self.emit(WalletEvent::Activity(list));
    }

    async fn handle_event(
        &self,
        event: Events,
        addresses: &[Address],
        change_set: &HashSet<Address>,
    ) {
        match event {
            Events::UtxoProcStart => {
                self.emit(WalletEvent::Syncing);
                log::info!(
                    "wallet-sync: utxo-proc start — scanning {} addresses",
                    addresses.len()
                );
                // Re-arm the LIVE UtxosChanged subscription on THIS connection
                // (V4 sitting conviction, D-083). The pin's per-connect listener
                // subscribes ONLY VirtualDaaScoreChanged (processor.rs:624);
                // UtxosChanged is issued inside register_addresses — but the
                // context filters against its own address set (context.rs:714),
                // which SURVIVES a disconnect (cleanup() clears the processor
                // map, not the context set), so on every reconnect the filtered
                // list is empty and the node is never re-subscribed: the wallet
                // goes deaf to live deposits after the first drop. Calling the
                // processor-level register_addresses directly is unconditional
                // (map insert + start_notify while connected) and idempotent
                // node-side; the context scan below then extends UTXO state.
                let arc_addresses: Vec<Arc<Address>> =
                    addresses.iter().cloned().map(Arc::new).collect();
                match self
                    .inner
                    .processor
                    .register_addresses(arc_addresses, &self.inner.context)
                    .await
                {
                    // Logged on success ONLY (wallet-security audit nit): a
                    // failed re-arm must never print an "armed" line — this
                    // lane exists to diagnose exactly that deafness.
                    Ok(()) => log::info!(
                        "wallet-sync: live utxos-changed re-armed for {} addresses",
                        addresses.len()
                    ),
                    Err(e) => self.emit(WalletEvent::Error(e.to_string())),
                }
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
                // Our own change re-reported as an incoming deposit (a restart
                // re-scan lost the outgoing context) is never a deposit — don't
                // record it (the spend's own record already represents the tx).
                //
                // Every verdict is logged (public chain data, INV-3): the V1
                // sitting's live-deposit miss (finding 8) was undiagnosable
                // because this arm was silent — balance lines proved the fold
                // task alive, but nothing said whether a record event ever
                // arrived or which guard ate it.
                let txid = record.id().to_string();
                if is_own_change(&record, change_set) {
                    log::info!(
                        "wallet-sync: record txid={txid} verdict=own-change (not a deposit)"
                    );
                    return;
                }
                let written = {
                    let mut store = self
                        .inner
                        .store
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner);
                    match store.upsert(record) {
                        Ok(written) => written,
                        Err(e) => {
                            log::warn!("wallet-sync: activity append failed: {e}");
                            false
                        }
                    }
                };
                log::info!(
                    "wallet-sync: record txid={txid} verdict={}",
                    if written {
                        "recorded"
                    } else {
                        "provenance-refused"
                    }
                );
                self.emit_activity(change_set);
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
                self.emit_activity(change_set);
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

    /// An Outgoing record for `id_byte` — a send WE originated. Minimal empty
    /// `Transaction` (the classifier reads the variant + values, not the tx).
    fn outgoing(id_byte: u8, payment: u64, daa: u64) -> TransactionRecord {
        use kaspa_consensus_core::subnets::SUBNETWORK_ID_NATIVE;
        use kaspa_consensus_core::tx::Transaction as CoreTx;
        let tx = CoreTx::new(0, vec![], vec![], 0, SUBNETWORK_ID_NATIVE, 0, vec![]);
        record(
            id_byte,
            payment,
            daa,
            TransactionData::Outgoing {
                fees: 1000,
                aggregate_input_value: payment + 5000,
                aggregate_output_value: payment,
                transaction: tx,
                payment_value: Some(payment),
                change_value: 4000,
                accepted_daa_score: Some(daa),
                utxo_entries: vec![],
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

        let pending = map_record(&rec, Some(1_050));
        assert_eq!(pending.direction, ActivityDirection::Incoming);
        assert_eq!(pending.maturity, ActivityMaturity::Pending);
        assert_eq!(pending.value_sompi, 1_234);
        assert!(!pending.is_coinbase);
        assert_eq!(pending.block_daa_score, 1_000);
        assert_eq!(pending.txid.len(), 64, "txid is 32-byte hash hex");

        let confirmed = map_record(&rec, Some(1_200));
        assert_eq!(confirmed.maturity, ActivityMaturity::Confirmed);

        // Finding 13 (the cold-start confirmation storm): NO live DAA must
        // resolve a receive as Unknown — never a guessed Pending that lets
        // hours-settled history stream in-flight counters at boot.
        let unknown = map_record(&rec, None);
        assert_eq!(unknown.maturity, ActivityMaturity::Unknown);
    }

    #[test]
    fn a_send_displays_the_payment_not_the_returning_change() {
        // The device bug (2026-06-15): a 0.42 KAS send whose ~0.39 change returns
        // to us must show 0.42 — never the change (which equals the new balance).
        // wallet-core's `Change` record has `value() == change_value`, so we must
        // read `payment_value` from the typed data instead.
        let payment = 42_000_000; // 0.42 KAS sent
        let change = 39_284_000; // ~0.393 KAS returned as change
        let input = payment + change + 716_000; // inputs cover payment + change + fee
        assert_eq!(
            spend_value(Some(payment), input, change),
            payment,
            "a send shows the payment, not the change"
        );
        // A sweep (no payment output) shows the net outflow = inputs − change.
        assert_eq!(spend_value(None, input, change), input - change);
    }

    #[test]
    fn own_change_addresses_are_recognised_not_treated_as_deposits() {
        // The device bug (2026-06-15): after a restart, wallet-core re-files our
        // returning change as an `Incoming`. A UTXO at a CHANGE address is never
        // a deposit (change addresses are internal, never handed out).
        let change = Address::try_from(
            "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692",
        )
        .unwrap();
        let receive = Address::try_from(
            "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf",
        )
        .unwrap();
        let change_set: HashSet<Address> = [change.clone()].into_iter().collect();

        assert!(
            all_change_addresses(&[Some(change.clone())], &change_set),
            "a UTXO at our change address is our own change"
        );
        assert!(
            !all_change_addresses(&[Some(receive)], &change_set),
            "a UTXO at a receive address is a real deposit"
        );
        assert!(
            !all_change_addresses(&[Some(change), None], &change_set),
            "an unknown-address UTXO is never assumed to be our change"
        );
        assert!(
            !all_change_addresses(&[], &change_set),
            "no UTXOs ⇒ not our change"
        );
    }

    /// Finding 8 (V2): the app-side live-deposit path, gate by gate. A genuine
    /// external deposit — an `Incoming` record whose UTXO sits at a RECEIVE
    /// address, under a txid we never originated — passes `is_own_change`,
    /// passes the provenance guard, is written, and renders in `list`. Pins
    /// that a live-arrival row loss is NOT this filter stack as written (the
    /// device lane's verdict logs discriminate the rest).
    #[test]
    fn a_live_external_deposit_passes_every_guard() {
        use kaspa_consensus_core::tx::ScriptPublicKey;
        use kaspa_wallet_core::storage::transaction::UtxoRecord;

        let receive = Address::try_from(
            "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf",
        )
        .unwrap();
        let change = Address::try_from(
            "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692",
        )
        .unwrap();
        let change_set: HashSet<Address> = [change].into_iter().collect();

        // A 5 KAS deposit to our receive address (the 2026-07-09 live shape).
        let deposit = record(
            11,
            500_000_000,
            2_000,
            TransactionData::Incoming {
                utxo_entries: vec![UtxoRecord {
                    address: Some(receive),
                    index: 0,
                    amount: 500_000_000,
                    script_public_key: ScriptPublicKey::default(),
                    is_coinbase: false,
                }],
                aggregate_input_value: 500_000_000,
            },
        );

        assert!(
            !is_own_change(&deposit, &change_set),
            "a receive-address deposit is never own change"
        );

        let dir = std::env::temp_dir().join(format!("kv-wsync-dep-{}", std::process::id()));
        let path = dir.join("activity.kvlog");
        let _ = std::fs::remove_file(&path);
        let mut store = ActivityStore::load(path.clone()).unwrap();
        assert!(
            store.upsert(deposit).unwrap(),
            "a fresh external txid is written, never provenance-refused"
        );

        let rows = store.list(Some(2_050), &change_set);
        assert_eq!(rows.len(), 1, "the deposit renders");
        assert_eq!(rows[0].direction, ActivityDirection::Incoming);
        assert_eq!(rows[0].value_sompi, 500_000_000);
        assert_eq!(rows[0].maturity, ActivityMaturity::Pending);

        let _ = std::fs::remove_file(&path);
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

        let rows = store.list(Some(1_000_000), &HashSet::new());
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

    /// The D2 provenance guard: once a txid is a SEND we originated, a restart
    /// re-scan re-reporting that SAME txid as an incoming deposit is refused —
    /// so conversation change returning to the bound RECEIVE address (source
    /// discipline) never surfaces as a phantom "received" row. A DIFFERENT
    /// txid (a real deposit / a counterpart's bond refund) is unaffected.
    #[test]
    fn incoming_never_downgrades_an_originated_send() {
        let dir = std::env::temp_dir().join(format!("kv-wsync-guard-{}", std::process::id()));
        let path = dir.join("activity.kvlog");
        let _ = std::fs::remove_file(&path);
        let mut store = ActivityStore::load(path.clone()).unwrap();

        // We sent tx 7 (a comm; change returns to our receive address).
        store.upsert(outgoing(7, 20_000, 100)).unwrap();
        // Restart re-scan re-reports tx 7's returning change as an Incoming.
        store.upsert(incoming(7, 4_000, 120)).unwrap();

        // The row stays our outgoing send — not a phantom deposit.
        let rows = store.list(Some(1_000_000), &HashSet::new());
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].direction, ActivityDirection::Outgoing);

        // A genuine deposit under a DIFFERENT txid is untouched by the guard.
        store.upsert(incoming(9, 50_000, 130)).unwrap();
        let rows = store.list(Some(1_000_000), &HashSet::new());
        let deposit = rows
            .iter()
            .find(|r| r.direction == ActivityDirection::Incoming);
        assert!(deposit.is_some(), "a real deposit still shows");

        // The guard survives a reload (the rejected incoming was never appended).
        let reloaded = ActivityStore::load(path.clone()).unwrap();
        assert!(is_outgoing_data(
            reloaded
                .records
                .get(&TransactionId::from_bytes([7; 32]))
                .unwrap()
        ));

        let _ = std::fs::remove_file(&path);
    }
}
