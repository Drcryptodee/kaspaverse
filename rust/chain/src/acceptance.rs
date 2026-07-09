//! acceptance — the V1 acceptance spine (D-073 hardening; re-exam §3.2).
//!
//! The app's one cheap, continuous truth-feed about what the chain did with
//! the txids it cares about: `VirtualChainChanged { include_accepted_
//! transaction_ids: true }` on the SAME shared socket (D-005), folded by a
//! small tracker into per-txid statuses that three consumers read:
//! send/wallet status honesty, transport reorg tombstones, and the V3 stall
//! signal. Catch-up twin: `get_virtual_chain_from_block(cursor, …)` — the
//! node itself pages the response (`batch_size = mergeset_size_limit × 10`,
//! pin `rpc/service/src/service.rs:736-742`), so reopen catch-up is a
//! bounded page walk like the transport one.
//!
//! **INV-9 posture:** acceptance, displacement, and blue scores are READ
//! from node data (the VCC notification + `get_block` headers). The only
//! arithmetic is `sink blue score − accepting blue score` for display
//! depth. The pruning horizon is read from the pinned mainnet params, never
//! hardcoded (founder ruling, 2026-07-08 V1 session).
//!
//! **INV-3/8:** everything persisted here is public chain data (txids,
//! block hashes, timestamps) in an app-private kvlog; every read is
//! node-only — no indexer anywhere on this path.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use borsh::{BorshDeserialize, BorshSerialize};
use kaspa_consensus_core::config::params::MAINNET_PARAMS;
use kaspa_consensus_core::Hash;
use kaspa_wallet_core::rpc::Rpc;
use tokio::sync::{broadcast, mpsc};

use crate::error::Result;
use crate::kvlog::Log;
use crate::spans;

/// Tombstone window: a displaced tx not re-accepted within this window is
/// signalled tombstone-due. PROVISIONAL 120 s (founder-nodded 2026-07-08):
/// mainnet re-acceptance is near-immediate, the ghost is reversible either
/// way, and every displacement is logged so V6 tunes this with data — the
/// register's observe-before-tuning law.
const TOMBSTONE_WINDOW_MS: u64 = 120_000;

/// Stall signal: a SEND-sourced watch with no acceptance within this window
/// is signalled stalled (consumer #3 — V3 acts on it; V1 only exposes it).
/// PROVISIONAL 60 s (founder-nodded 2026-07-08): ≥2× the node's ~30 s
/// High-priority rebroadcast cadence (pin `flow_context.rs:626-700`); V1's
/// own submit→accepted markers refine it.
const STALL_AFTER_MS: u64 = 60_000;

/// Snapshot-level "Confirmed" depth (blue-score depth, read not computed).
/// PROVISIONAL: ~10 s of chain at 10 bps — a display state, not a consensus
/// claim; V2's status chips are the real consumer.
const CONFIRMED_DEPTH_BLUE: u64 = 100;

/// Watch hygiene: an accepted watch this deep is terminal — displacement at
/// this depth is exceptional (finality is far deeper; this is bookkeeping,
/// not a finality claim) and the watch is pruned to keep the log bounded.
const TERMINAL_DEPTH_BLUE: u64 = 1_000;

/// Watch-set cap. Eviction (oldest first) is LOGGED, never silent.
const WATCH_CAP: usize = 512;

/// Load-time compaction threshold for the churn-heavy watch log.
const COMPACT_THRESHOLD_BYTES: u64 = 256 * 1024;

/// Window/stall tick cadence.
const TICK: Duration = Duration::from_secs(10);

/// Reopen catch-up page budget. Each node page covers `mergeset_size_limit
/// × 10` merged blocks (≈2480 at 10 bps ≈ ~4 min of chain), so 16 pages
/// ≈ ~1 h of gap. Past it the walk stops honestly: the cursor re-seeds at
/// sink, unresolved watches stay as-persisted, and consumers degrade
/// (wallet-core's own rescan covers sends; V2b's fill covers messages).
const MAX_VCC_CATCHUP_PAGES: u32 = 16;

/// A page this far below the node's own batch bound means the walk reached
/// the tip (the chain advances ~10 blocks/s between round-trips, so an
/// is-empty test chases the tip to the page budget — observed live,
/// 2026-07-09 sitting). The live stream, buffered since Connected, owns
/// everything past the final short page; overlap folds idempotently.
const VCC_TIP_PAGE_THRESHOLD: usize = 100;

/// Per-page retry budget across a still-dialing socket — the cold-reopen
/// race: the first page routinely fires before the reconnect lands, and one
/// failure must not strand a mid-pending watch (the transport walk's law,
/// dag_monitor CATCHUP_RPC_ATTEMPTS; lived live 2026-07-09).
const VCC_PAGE_ATTEMPTS: u32 = 8;
const VCC_PAGE_RETRY_DELAY: Duration = Duration::from_millis(1000);

/// Throttle for cursor writes on the live VCC stream (~1 chain-block batch
/// per second) — same discipline as the transport scan cursor.
const CURSOR_MIN_WRITE_SECS: u64 = 3;

/// The pruning horizon in milliseconds, READ from the pinned mainnet params
/// (INV-9; founder ruling 2026-07-08): `pruning_depth` blocks ×
/// `target_time_per_block` ms — 1,080,000 × 100 ms = 30 h at the v2.0.1 pin
/// (`consensus/core/src/config/{params.rs:496,bps.rs:96-107}`). Past this
/// age nothing about a txid is knowable from any normal node, so a watch
/// older than the horizon is dropped (honest unknown, never a guess).
pub fn pruning_horizon_ms() -> u64 {
    MAINNET_PARAMS.pruning_depth() * MAINNET_PARAMS.blockrate.target_time_per_block
}

/// Who asked for a txid to be watched. First registration wins (idempotent
/// re-watch keeps the original source).
#[derive(BorshSerialize, BorshDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum WatchSource {
    /// The send pipeline (payments AND outbound transport sends) — the only
    /// source that emits `Stalled` (we know exactly when WE submitted; an
    /// inbound message watch starting late must never read as a stall).
    Send,
    /// The transport store (conversation txids, inbound included).
    Transport,
}

/// Persisted per-txid state. `Confirmed` is never persisted — depth is
/// derived at read from the live sink blue score; `Stalled` is never
/// persisted — it is `now − submit_ok` while still Submitted. `Displaced`
/// persists its since-timestamp so the tombstone window survives restart.
#[derive(BorshSerialize, BorshDeserialize, Clone, Debug, PartialEq)]
enum PersistedStatus {
    Submitted {
        submit_ok_unix_ms: u64,
    },
    Accepted {
        accepting_block: String,
        accepting_blue_score: u64,
        accepted_unix_ms: u64,
    },
    Displaced {
        since_unix_ms: u64,
        prior_block: String,
    },
    /// Terminal-depth acceptance (V1 sitting fix, 2026-07-09): the watch is
    /// past [`TERMINAL_DEPTH_BLUE`] — reorg tracking is over (it leaves the
    /// accepting-block index) but the RECORD survives until the horizon/cap
    /// prune, so a restart can still answer "Confirmed" for a send that
    /// wallet-core re-files as Pending (the IDEAS:206 edge the sitting hit
    /// live: delete-at-terminal left the stale Pending row uncorrectable).
    /// Appended variant — pre-fix log frames (variants 0-2) replay unchanged.
    Finalized {
        accepting_block: String,
        accepting_blue_score: u64,
        accepted_unix_ms: u64,
    },
}

/// One watched txid (public chain data only, INV-3).
#[derive(BorshSerialize, BorshDeserialize, Clone, Debug, PartialEq)]
struct WatchRecord {
    txid: String,
    source: WatchSource,
    watched_unix_ms: u64,
    status: PersistedStatus,
}

/// A txid status as consumers see it (the spec's five states).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TxStatus {
    Submitted,
    /// Accepted by a chain block; `blue_depth` = live sink blue score −
    /// accepting block blue score (two node-read values).
    Accepted {
        blue_depth: u64,
    },
    Confirmed {
        blue_depth: u64,
    },
    Displaced,
    /// Send-sourced, no acceptance for [`STALL_AFTER_MS`].
    Stalled {
        waited_ms: u64,
    },
}

/// A tracker state change, broadcast to consumers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AcceptanceEvent {
    /// Accepted (or RE-accepted after displacement — consumer #2 reverses
    /// any tombstone on this).
    Accepted { txid: String },
    /// Crossed [`CONFIRMED_DEPTH_BLUE`].
    Confirmed { txid: String, blue_depth: u64 },
    /// Accepting block left the selected chain; the window starts.
    Displaced { txid: String },
    /// Displaced and not re-accepted within [`TOMBSTONE_WINDOW_MS`] —
    /// consumer #2 tombstones now.
    DisplacedElapsed { txid: String },
    /// Send-sourced watch with no acceptance for [`STALL_AFTER_MS`] —
    /// consumer #3's signal (V3 acts; V1 exposes).
    Stalled { txid: String, waited_ms: u64 },
}

/// The pure fold: watch-set + VCC facts in, events out. No RPC, no clock of
/// its own (every method takes `now_ms`) — fully unit-testable; the async
/// shell owns I/O.
struct TrackerState {
    log: Log<WatchRecord>,
    /// accepting block hash (hex) → watched txids accepted by it.
    by_accepting_block: HashMap<String, Vec<String>>,
    /// One-shot event guards (in-memory; re-emission after restart is
    /// idempotent at the consumers).
    stall_emitted: HashSet<String>,
    elapse_emitted: HashSet<String>,
    confirmed_emitted: HashSet<String>,
    /// Latest sink blue score seen (node-read; 0 = none yet).
    sink_blue: u64,
}

impl TrackerState {
    fn load(path: PathBuf) -> Result<Self> {
        let mut log = Log::load(path, |r: &WatchRecord| r.txid.clone())?;
        log.compact_if_larger_than(COMPACT_THRESHOLD_BYTES)?;
        let mut by_accepting_block: HashMap<String, Vec<String>> = HashMap::new();
        for record in log.records.values() {
            if let PersistedStatus::Accepted {
                accepting_block, ..
            } = &record.status
            {
                by_accepting_block
                    .entry(accepting_block.clone())
                    .or_default()
                    .push(record.txid.clone());
            }
        }
        Ok(Self {
            log,
            by_accepting_block,
            stall_emitted: HashSet::new(),
            elapse_emitted: HashSet::new(),
            confirmed_emitted: HashSet::new(),
            sink_blue: 0,
        })
    }

    fn is_watched(&self, txid: &str) -> bool {
        self.log.records.contains_key(txid)
    }

    /// Register a txid. Idempotent (an existing watch is untouched — first
    /// source wins). Enforces [`WATCH_CAP`] by evicting the oldest watch,
    /// logged (no silent cap).
    fn watch(&mut self, txid: &str, source: WatchSource, now_ms: u64) -> Result<()> {
        if self.is_watched(txid) {
            return Ok(());
        }
        if self.log.records.len() >= WATCH_CAP {
            if let Some(oldest) = self
                .log
                .records
                .values()
                .min_by_key(|r| r.watched_unix_ms)
                .map(|r| r.txid.clone())
            {
                log::warn!("acceptance: watch cap {WATCH_CAP} hit — evicting oldest {oldest}");
                self.drop_watch(&oldest)?;
            }
        }
        self.log.upsert(
            txid.to_string(),
            WatchRecord {
                txid: txid.to_string(),
                source,
                watched_unix_ms: now_ms,
                status: PersistedStatus::Submitted {
                    submit_ok_unix_ms: now_ms,
                },
            },
        )
    }

    fn drop_watch(&mut self, txid: &str) -> Result<()> {
        if let Some(record) = self.log.records.get(txid) {
            if let PersistedStatus::Accepted {
                accepting_block, ..
            } = &record.status
            {
                let block = accepting_block.clone();
                if let Some(txids) = self.by_accepting_block.get_mut(&block) {
                    txids.retain(|t| t != txid);
                    if txids.is_empty() {
                        self.by_accepting_block.remove(&block);
                    }
                }
            }
        }
        self.stall_emitted.remove(txid);
        self.elapse_emitted.remove(txid);
        self.confirmed_emitted.remove(txid);
        self.log.remove(txid)
    }

    /// Fold one accepting block's accepted-txid list (already resolved to
    /// its blue score by the shell). Unwatched txids are ignored here — the
    /// shell pre-filters, this re-check just keeps the fold total.
    fn on_accepted(
        &mut self,
        accepting_block: &str,
        accepting_blue_score: u64,
        txids: &[String],
        now_ms: u64,
    ) -> Result<Vec<AcceptanceEvent>> {
        let mut events = Vec::new();
        for txid in txids {
            let Some(record) = self.log.records.get(txid).cloned() else {
                continue;
            };
            // Re-acceptance in the same block state: nothing changed.
            if matches!(&record.status, PersistedStatus::Accepted { accepting_block: b, .. } if b == accepting_block)
            {
                continue;
            }
            // A→B re-acceptance: drop the txid from A's index entry, or a
            // later (possibly out-of-order) removal of A would falsely
            // displace a tx currently accepted by B (consensus-audit
            // finding 2 — the same cleanup drop_watch does).
            if let PersistedStatus::Accepted {
                accepting_block: old,
                ..
            } = &record.status
            {
                if let Some(txids_in_old) = self.by_accepting_block.get_mut(old) {
                    txids_in_old.retain(|t| t != txid);
                    if txids_in_old.is_empty() {
                        let old = old.clone();
                        self.by_accepting_block.remove(&old);
                    }
                }
            }
            let mut updated = record;
            updated.status = PersistedStatus::Accepted {
                accepting_block: accepting_block.to_string(),
                accepting_blue_score,
                accepted_unix_ms: now_ms,
            };
            self.log.upsert(txid.clone(), updated)?;
            self.by_accepting_block
                .entry(accepting_block.to_string())
                .or_default()
                .push(txid.clone());
            // A (re-)acceptance clears one-shot guards: a later displacement
            // starts a fresh window.
            self.stall_emitted.remove(txid);
            self.elapse_emitted.remove(txid);
            spans::mark_with("accepted", txid);
            events.push(AcceptanceEvent::Accepted { txid: txid.clone() });
        }
        Ok(events)
    }

    /// Fold removed chain blocks: any watched txid whose accepting block is
    /// among them becomes Displaced (window starts at `now_ms`).
    fn on_removed(
        &mut self,
        removed_blocks: &[String],
        now_ms: u64,
    ) -> Result<Vec<AcceptanceEvent>> {
        let mut events = Vec::new();
        for block in removed_blocks {
            let Some(txids) = self.by_accepting_block.remove(block) else {
                continue;
            };
            for txid in txids {
                let Some(record) = self.log.records.get(&txid).cloned() else {
                    continue;
                };
                let mut updated = record;
                updated.status = PersistedStatus::Displaced {
                    since_unix_ms: now_ms,
                    prior_block: block.clone(),
                };
                self.log.upsert(txid.clone(), updated)?;
                self.confirmed_emitted.remove(&txid);
                // Observe-before-tuning: every displacement is a logged data
                // point for the V6 window review (public data).
                log::info!("acceptance: {txid} displaced (accepting block {block} left the chain)");
                events.push(AcceptanceEvent::Displaced { txid });
            }
        }
        Ok(events)
    }

    /// Fold a sink blue score update: emit Confirmed crossings and FINALIZE
    /// terminal-depth watches. Finalizing keeps the record (a restart must
    /// still be able to answer "Confirmed" — the sitting-found IDEAS:206
    /// edge) but ends its reorg tracking: it leaves the accepting-block
    /// index, so no removal can ever displace it again. Records leave the
    /// log only via the horizon/cap prune.
    fn on_sink_blue(&mut self, sink_blue: u64, now_ms: u64) -> Result<Vec<AcceptanceEvent>> {
        self.sink_blue = sink_blue;
        let mut events = Vec::new();
        let mut to_finalize = Vec::new();
        for record in self.log.records.values() {
            let PersistedStatus::Accepted {
                accepting_blue_score,
                ..
            } = &record.status
            else {
                continue;
            };
            let blue_depth = sink_blue.saturating_sub(*accepting_blue_score);
            if blue_depth >= CONFIRMED_DEPTH_BLUE && !self.confirmed_emitted.contains(&record.txid)
            {
                self.confirmed_emitted.insert(record.txid.clone());
                events.push(AcceptanceEvent::Confirmed {
                    txid: record.txid.clone(),
                    blue_depth,
                });
            }
            if blue_depth >= TERMINAL_DEPTH_BLUE {
                to_finalize.push(record.txid.clone());
            }
        }
        for txid in to_finalize {
            self.finalize_watch(&txid)?;
        }
        self.prune_beyond_horizon(now_ms)?;
        Ok(events)
    }

    /// Transition an Accepted watch to Finalized: keep the record, leave the
    /// accepting-block index (reorg tracking over — a late removal of its
    /// block is a no-op by construction).
    fn finalize_watch(&mut self, txid: &str) -> Result<()> {
        let Some(record) = self.log.records.get(txid).cloned() else {
            return Ok(());
        };
        let PersistedStatus::Accepted {
            accepting_block,
            accepting_blue_score,
            accepted_unix_ms,
        } = record.status.clone()
        else {
            return Ok(());
        };
        if let Some(txids) = self.by_accepting_block.get_mut(&accepting_block) {
            txids.retain(|t| t != txid);
            if txids.is_empty() {
                self.by_accepting_block.remove(&accepting_block);
            }
        }
        let mut updated = record;
        updated.status = PersistedStatus::Finalized {
            accepting_block,
            accepting_blue_score,
            accepted_unix_ms,
        };
        self.log.upsert(txid.to_string(), updated)
    }

    /// Drop watches older than the pruning horizon — past it no node can
    /// answer for the txid, so keeping the watch would be a silent lie.
    fn prune_beyond_horizon(&mut self, now_ms: u64) -> Result<()> {
        let horizon = pruning_horizon_ms();
        let expired: Vec<String> = self
            .log
            .records
            .values()
            .filter(|r| now_ms.saturating_sub(r.watched_unix_ms) > horizon)
            .map(|r| r.txid.clone())
            .collect();
        for txid in expired {
            log::info!("acceptance: {txid} watch beyond the pruning horizon — dropped (unknown)");
            self.drop_watch(&txid)?;
        }
        Ok(())
    }

    /// The periodic sweep: stall signals (Send-sourced Submitted) and
    /// tombstone-window elapses (Displaced past the window).
    fn tick(&mut self, now_ms: u64) -> Vec<AcceptanceEvent> {
        let mut events = Vec::new();
        for record in self.log.records.values() {
            match &record.status {
                PersistedStatus::Submitted { submit_ok_unix_ms }
                    if record.source == WatchSource::Send =>
                {
                    let waited_ms = now_ms.saturating_sub(*submit_ok_unix_ms);
                    if waited_ms >= STALL_AFTER_MS && !self.stall_emitted.contains(&record.txid) {
                        events.push(AcceptanceEvent::Stalled {
                            txid: record.txid.clone(),
                            waited_ms,
                        });
                    }
                }
                PersistedStatus::Displaced { since_unix_ms, .. } => {
                    let waited_ms = now_ms.saturating_sub(*since_unix_ms);
                    if waited_ms >= TOMBSTONE_WINDOW_MS
                        && !self.elapse_emitted.contains(&record.txid)
                    {
                        events.push(AcceptanceEvent::DisplacedElapsed {
                            txid: record.txid.clone(),
                        });
                    }
                }
                _ => {}
            }
        }
        for event in &events {
            match event {
                AcceptanceEvent::Stalled { txid, waited_ms } => {
                    self.stall_emitted.insert(txid.clone());
                    log::warn!("acceptance: {txid} stalled — no acceptance after {waited_ms} ms");
                }
                AcceptanceEvent::DisplacedElapsed { txid } => {
                    self.elapse_emitted.insert(txid.clone());
                    log::warn!(
                        "acceptance: {txid} displaced > {TOMBSTONE_WINDOW_MS} ms — tombstone due"
                    );
                }
                _ => {}
            }
        }
        events
    }

    /// A consumer-facing status read (depth derived from the live sink blue
    /// score — two node values, one subtraction).
    fn status(&self, txid: &str, now_ms: u64) -> Option<TxStatus> {
        let record = self.log.records.get(txid)?;
        Some(match &record.status {
            PersistedStatus::Submitted { submit_ok_unix_ms } => {
                let waited_ms = now_ms.saturating_sub(*submit_ok_unix_ms);
                if record.source == WatchSource::Send && waited_ms >= STALL_AFTER_MS {
                    TxStatus::Stalled { waited_ms }
                } else {
                    TxStatus::Submitted
                }
            }
            PersistedStatus::Accepted {
                accepting_blue_score,
                ..
            } => {
                let blue_depth = self.sink_blue.saturating_sub(*accepting_blue_score);
                if blue_depth >= CONFIRMED_DEPTH_BLUE {
                    TxStatus::Confirmed { blue_depth }
                } else {
                    TxStatus::Accepted { blue_depth }
                }
            }
            // Finality was already established when the record finalized —
            // Confirmed regardless of the (possibly not-yet-received) live
            // sink value; the displayed depth grows as the sink arrives.
            PersistedStatus::Finalized {
                accepting_blue_score,
                ..
            } => TxStatus::Confirmed {
                blue_depth: self.sink_blue.saturating_sub(*accepting_blue_score),
            },
            PersistedStatus::Displaced { .. } => TxStatus::Displaced,
        })
    }
}

/// The async shell: owns the state under a lock, the event fan-out, the
/// cursor file, and (via [`AcceptanceTracker::run`]) the task that folds
/// live VCC batches, runs reopen catch-up, and ticks the windows.
pub struct AcceptanceTracker {
    state: Mutex<TrackerState>,
    events: broadcast::Sender<AcceptanceEvent>,
    cursor_path: PathBuf,
    cursor_written: AtomicU64,
}

fn now_unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// One live VCC delivery, forwarded verbatim from the DagMonitor's event
/// task (Arc-backed clones of the pinned notification's fields — the full
/// stream never crosses to Dart).
#[derive(Debug, Clone)]
pub struct VccBatch {
    pub removed_chain_block_hashes: Arc<Vec<Hash>>,
    pub added_chain_block_hashes: Arc<Vec<Hash>>,
    /// (accepting block hash, accepted txids) — the pin's
    /// `RpcAcceptedTransactionIds` flattened.
    pub accepted: Arc<Vec<(Hash, Vec<Hash>)>>,
}

impl AcceptanceTracker {
    /// Load (or create) the tracker's persistence in `dir`
    /// (`acceptance.kvlog` + `vcc.cursor`).
    pub fn load(dir: PathBuf) -> Result<Arc<Self>> {
        let state = TrackerState::load(dir.join("acceptance.kvlog"))?;
        let (events, _) = broadcast::channel(256);
        Ok(Arc::new(Self {
            state: Mutex::new(state),
            events,
            cursor_path: dir.join("vcc.cursor"),
            cursor_written: AtomicU64::new(0),
        }))
    }

    /// New receiver onto the acceptance event fan-out.
    pub fn subscribe(&self) -> broadcast::Receiver<AcceptanceEvent> {
        self.events.subscribe()
    }

    /// Watch a txid (idempotent; first source wins).
    pub fn watch(&self, txid: &str, source: WatchSource) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Err(e) = state.watch(txid, source, now_unix_ms()) {
            log::warn!("acceptance: watch persist failed: {e}");
        }
    }

    /// Current status of a watched txid (None = not watched / already
    /// pruned — the consumer falls back to its own truth source).
    pub fn status(&self, txid: &str) -> Option<TxStatus> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .status(txid, now_unix_ms())
    }

    fn broadcast(&self, events: Vec<AcceptanceEvent>) {
        for event in events {
            let _ = self.events.send(event);
        }
    }

    fn read_cursor(&self) -> Option<Hash> {
        let text = std::fs::read_to_string(&self.cursor_path).ok()?;
        text.trim().parse::<Hash>().ok()
    }

    fn write_cursor(&self, hash: &Hash, force: bool) {
        let now = now_unix_ms() / 1000;
        if !force {
            let last = self.cursor_written.load(Ordering::Relaxed);
            if now.saturating_sub(last) < CURSOR_MIN_WRITE_SECS {
                return;
            }
        }
        self.cursor_written.store(now, Ordering::Relaxed);
        if let Some(parent) = self.cursor_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(&self.cursor_path, hash.to_string()) {
            log::warn!("acceptance: cursor write failed: {e}");
        }
    }

    /// Fold one VCC batch (live or catch-up page). Removals fold before
    /// acceptances — a reorg delivers both in one notification, and the
    /// re-acceptance must land AFTER the displacement so the final state is
    /// Accepted. Accepting-block blue scores are resolved via `get_block`
    /// (one call per accepting block that carries a watched txid — sparse).
    async fn fold_batch(&self, rpc: &Rpc, batch: &VccBatch) {
        let now_ms = now_unix_ms();
        // Removals: cheap map lookups, no RPC.
        let removed: Vec<String> = batch
            .removed_chain_block_hashes
            .iter()
            .map(|h| h.to_string())
            .collect();
        if !removed.is_empty() {
            let events = {
                let mut state = self
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                state.on_removed(&removed, now_ms).unwrap_or_else(|e| {
                    log::warn!("acceptance: removal fold persist failed: {e}");
                    Vec::new()
                })
            };
            self.broadcast(events);
        }

        // Acceptances: pre-filter to watched txids, then resolve blue scores.
        let mut matches: Vec<(Hash, Vec<String>)> = Vec::new();
        {
            let state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for (accepting_block, txids) in batch.accepted.iter() {
                let watched: Vec<String> = txids
                    .iter()
                    .map(|t| t.to_string())
                    .filter(|t| state.is_watched(t))
                    .collect();
                if !watched.is_empty() {
                    matches.push((*accepting_block, watched));
                }
            }
        }
        for (accepting_block, txids) in matches {
            let blue_score = match rpc.rpc_api().get_block(accepting_block, false).await {
                Ok(block) => block.header.blue_score,
                Err(e) => {
                    // Conservative fallback: the current sink blue score is an
                    // UPPER bound for the accepting blue score, so depth reads
                    // small — Confirmed is delayed, never premature. BUT a
                    // sink of 0 (no SinkBlueScore folded yet — the cold-open
                    // window) would invert that into an instant fabricated
                    // Confirmed + terminal prune (consensus-audit finding 1):
                    // refresh from the node first, and if the node cannot
                    // answer either, skip the fold — the txids stay Submitted
                    // (honest; wallet-core still converges on its own).
                    let mut sink = self
                        .state
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .sink_blue;
                    if sink == 0 {
                        match rpc.rpc_api().get_sink_blue_score().await {
                            Ok(blue) => {
                                sink = blue;
                                self.state
                                    .lock()
                                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                                    .sink_blue = blue;
                            }
                            Err(e2) => {
                                log::warn!(
                                    "acceptance: get_block({accepting_block}) failed ({e}) and \
                                     no sink blue score available ({e2}) — fold skipped, \
                                     {} watch(es) stay Submitted",
                                    txids.len()
                                );
                                continue;
                            }
                        }
                    }
                    log::warn!(
                        "acceptance: get_block({accepting_block}) failed ({e}) — \
                         using sink blue score {sink} as a conservative bound"
                    );
                    sink
                }
            };
            let events = {
                let mut state = self
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                state
                    .on_accepted(&accepting_block.to_string(), blue_score, &txids, now_ms)
                    .unwrap_or_else(|e| {
                        log::warn!("acceptance: acceptance fold persist failed: {e}");
                        Vec::new()
                    })
            };
            self.broadcast(events);
        }

        if let Some(last_added) = batch.added_chain_block_hashes.last() {
            self.write_cursor(last_added, false);
        }
    }

    /// Reopen/reconnect catch-up: walk `get_virtual_chain_from_block` from
    /// the persisted cursor to the virtual, folding each node-bounded page
    /// like a live batch. No cursor → seed at the current sink (nothing to
    /// recover). A page tolerates a still-dialing socket with a bounded
    /// retry (the 2026-07-09 sitting's cold-reopen race: the FIRST page
    /// routinely fires before the reconnect lands, and one failure must not
    /// abandon a mid-pending watch — same law as the transport walk).
    /// A cursor the node genuinely cannot answer for (pruned) exhausts the
    /// retries → re-seed at sink; watches stay as-persisted (consumers
    /// degrade honestly).
    async fn catch_up(&self, rpc: &Rpc) {
        let Some(mut cursor) = self.read_cursor() else {
            if let Ok(sink) = rpc.rpc_api().get_sink().await {
                self.write_cursor(&sink.sink, true);
            }
            return;
        };
        for _page in 0..MAX_VCC_CATCHUP_PAGES {
            let Some(resp) = self.catch_up_page(rpc, cursor).await else {
                log::warn!("acceptance: catch-up from {cursor} unanswerable — re-seeding at sink");
                if let Ok(sink) = rpc.rpc_api().get_sink().await {
                    self.write_cursor(&sink.sink, true);
                }
                return;
            };
            // Done when the page sits far below the node's own batch bound
            // (mergeset_size_limit × 10 ≈ 1800+ chain blocks): the chain
            // advances ~10 blocks/s between round-trips, so an is-empty test
            // would chase the tip to the page budget forever (observed live,
            // 2026-07-09). A short page = we're at the tip; the live stream
            // (buffered in vcc_rx since Connected) owns everything after —
            // the overlap folds idempotently.
            let done = resp.added_chain_block_hashes.len() < VCC_TIP_PAGE_THRESHOLD;
            let batch = VccBatch {
                removed_chain_block_hashes: Arc::new(resp.removed_chain_block_hashes),
                added_chain_block_hashes: Arc::new(resp.added_chain_block_hashes),
                accepted: Arc::new(
                    resp.accepted_transaction_ids
                        .into_iter()
                        .map(|a| (a.accepting_block_hash, a.accepted_transaction_ids))
                        .collect(),
                ),
            };
            self.fold_batch(rpc, &batch).await;
            if let Some(last) = batch.added_chain_block_hashes.last() {
                cursor = *last;
                self.write_cursor(last, true);
            }
            if done {
                return;
            }
        }
        // Page budget exhausted — a very long gap. Stop honestly at sink.
        log::warn!(
            "acceptance: catch-up page budget ({MAX_VCC_CATCHUP_PAGES}) exhausted — \
             re-seeding at sink; unresolved watches degrade to their consumers' fallbacks"
        );
        if let Ok(sink) = rpc.rpc_api().get_sink().await {
            self.write_cursor(&sink.sink, true);
        }
    }

    /// One catch-up page, tolerant of a still-connecting socket: bounded
    /// retries, then `None` (the node is unreachable or the cursor pruned).
    async fn catch_up_page(
        &self,
        rpc: &Rpc,
        cursor: Hash,
    ) -> Option<kaspa_wrpc_client::prelude::GetVirtualChainFromBlockResponse> {
        for attempt in 0..VCC_PAGE_ATTEMPTS {
            match rpc
                .rpc_api()
                .get_virtual_chain_from_block(cursor, true, None)
                .await
            {
                Ok(resp) => return Some(resp),
                Err(e) => {
                    log::debug!(
                        "acceptance: catch-up page attempt {attempt} failed ({e}); retrying"
                    );
                    tokio::time::sleep(VCC_PAGE_RETRY_DELAY).await;
                }
            }
        }
        None
    }

    /// Spawn the tracker task: folds live VCC batches from `vcc_rx`, runs
    /// catch-up on every (re)connect via `dag_rx`, folds sink blue score
    /// updates, and ticks the stall/tombstone windows.
    pub fn run(
        self: &Arc<Self>,
        rpc: Rpc,
        mut vcc_rx: mpsc::UnboundedReceiver<VccBatch>,
        mut dag_rx: broadcast::Receiver<crate::DagEvent>,
    ) -> tokio::task::JoinHandle<()> {
        let tracker = self.clone();
        tokio::spawn(async move {
            // Prime the sink blue score before anything folds (best-effort):
            // narrows the cold-open window where a get_block fallback would
            // find sink_blue == 0 (consensus-audit finding 1). The socket may
            // still be dialing — the fold-time refresh covers a miss here.
            if let Ok(blue) = rpc.rpc_api().get_sink_blue_score().await {
                tracker
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .sink_blue = blue;
            }
            // Cold open: recover whatever happened while the app was closed.
            tracker.catch_up(&rpc).await;
            let mut tick = tokio::time::interval(TICK);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    batch = vcc_rx.recv() => {
                        match batch {
                            Some(batch) => tracker.fold_batch(&rpc, &batch).await,
                            None => break, // monitor gone
                        }
                    }
                    event = dag_rx.recv() => {
                        match event {
                            Ok(crate::DagEvent::Connected { .. }) => {
                                // Scopes re-registered; recover the gap.
                                tracker.catch_up(&rpc).await;
                            }
                            Ok(crate::DagEvent::SinkBlueScore(blue)) => {
                                let events = {
                                    let mut state = tracker
                                        .state
                                        .lock()
                                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                                    state.on_sink_blue(blue, now_unix_ms()).unwrap_or_else(|e| {
                                        log::warn!("acceptance: sink fold persist failed: {e}");
                                        Vec::new()
                                    })
                                };
                                tracker.broadcast(events);
                            }
                            Ok(_) => {}
                            Err(broadcast::error::RecvError::Lagged(_)) => continue,
                            Err(broadcast::error::RecvError::Closed) => break,
                        }
                    }
                    _ = tick.tick() => {
                        let events = {
                            let mut state = tracker
                                .state
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner);
                            state.tick(now_unix_ms())
                        };
                        tracker.broadcast(events);
                    }
                }
            }
            log::info!("acceptance: tracker task exiting");
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kv-accept-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    fn txid(n: u8) -> String {
        format!("{:02x}", n).repeat(32)
    }

    fn block(n: u8) -> String {
        format!("{:02x}", n ^ 0xFF).repeat(32)
    }

    #[test]
    fn accept_then_confirm_then_terminal_prune() {
        let dir = test_dir("lifecycle");
        let mut state = TrackerState::load(dir.join("acceptance.kvlog")).unwrap();
        state.watch(&txid(1), WatchSource::Send, 1_000).unwrap();
        assert_eq!(state.status(&txid(1), 1_000), Some(TxStatus::Submitted));

        // Acceptance at blue score 5_000.
        let events = state
            .on_accepted(&block(1), 5_000, &[txid(1)], 2_000)
            .unwrap();
        assert_eq!(events, vec![AcceptanceEvent::Accepted { txid: txid(1) }]);
        assert_eq!(
            state.status(&txid(1), 2_000),
            Some(TxStatus::Accepted { blue_depth: 0 }),
            "no sink blue yet — depth 0"
        );

        // Sink advances past the confirmed depth: one Confirmed crossing.
        let events = state
            .on_sink_blue(5_000 + CONFIRMED_DEPTH_BLUE, 3_000)
            .unwrap();
        assert_eq!(
            events,
            vec![AcceptanceEvent::Confirmed {
                txid: txid(1),
                blue_depth: CONFIRMED_DEPTH_BLUE
            }]
        );
        assert!(
            state
                .on_sink_blue(5_000 + CONFIRMED_DEPTH_BLUE + 1, 3_100)
                .unwrap()
                .is_empty(),
            "Confirmed is one-shot"
        );
        assert_eq!(
            state.status(&txid(1), 3_100),
            Some(TxStatus::Confirmed {
                blue_depth: CONFIRMED_DEPTH_BLUE + 1
            })
        );

        // Terminal depth: the watch FINALIZES — the record survives (still
        // answers Confirmed) but reorg tracking is over: a late removal of
        // its accepting block is a no-op by construction.
        state
            .on_sink_blue(5_000 + TERMINAL_DEPTH_BLUE, 4_000)
            .unwrap();
        assert!(
            matches!(
                state.status(&txid(1), 4_000),
                Some(TxStatus::Confirmed { .. })
            ),
            "finalized watch still answers Confirmed"
        );
        assert!(state.on_removed(&[block(1)], 5_000).unwrap().is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The 2026-07-09 sitting regression: a send confirmed >TERMINAL depth,
    /// then the app restarted, wallet-core re-filed the row as Pending
    /// (IDEAS:206) — and the old delete-at-terminal had destroyed the watch,
    /// leaving the lie uncorrectable. Finalized records survive the restart
    /// and answer Confirmed even before the first live sink event.
    #[test]
    fn finalized_watch_survives_restart_and_answers_confirmed() {
        let dir = test_dir("finalized-restart");
        let path = dir.join("acceptance.kvlog");
        {
            let mut state = TrackerState::load(path.clone()).unwrap();
            state.watch(&txid(1), WatchSource::Send, 1_000).unwrap();
            state
                .on_accepted(&block(1), 5_000, &[txid(1)], 2_000)
                .unwrap();
            state
                .on_sink_blue(5_000 + TERMINAL_DEPTH_BLUE, 3_000)
                .unwrap();
        }
        // "Restart": fresh load; NO sink event has arrived yet (sink_blue=0).
        let state = TrackerState::load(path).unwrap();
        assert!(
            matches!(
                state.status(&txid(1), 10_000),
                Some(TxStatus::Confirmed { .. })
            ),
            "the reloaded Finalized record corrects a stale wallet-core Pending"
        );
        assert!(
            state.by_accepting_block.is_empty(),
            "finalized records never re-enter the reorg index on load"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The acceptance-bar unit test: a replayed VCC removal displaces, the
    /// window elapses → tombstone-due; a re-acceptance flips it back and
    /// clears the guards.
    #[test]
    fn displacement_window_and_reacceptance() {
        let dir = test_dir("displace");
        let mut state = TrackerState::load(dir.join("acceptance.kvlog")).unwrap();
        state
            .watch(&txid(1), WatchSource::Transport, 1_000)
            .unwrap();
        state
            .on_accepted(&block(1), 5_000, &[txid(1)], 2_000)
            .unwrap();

        // The accepting block leaves the selected chain.
        let events = state.on_removed(&[block(1)], 10_000).unwrap();
        assert_eq!(events, vec![AcceptanceEvent::Displaced { txid: txid(1) }]);
        assert_eq!(state.status(&txid(1), 10_000), Some(TxStatus::Displaced));

        // Window not yet elapsed: silent.
        assert!(state.tick(10_000 + TOMBSTONE_WINDOW_MS - 1).is_empty());
        // Window elapses: tombstone due, exactly once.
        let events = state.tick(10_000 + TOMBSTONE_WINDOW_MS);
        assert_eq!(
            events,
            vec![AcceptanceEvent::DisplacedElapsed { txid: txid(1) }]
        );
        assert!(
            state.tick(10_000 + TOMBSTONE_WINDOW_MS + 1).is_empty(),
            "one-shot"
        );

        // Late re-acceptance in a new chain block: back to Accepted, and a
        // FUTURE displacement gets a fresh window + fresh elapse.
        let events = state
            .on_accepted(&block(2), 6_000, &[txid(1)], 200_000)
            .unwrap();
        assert_eq!(events, vec![AcceptanceEvent::Accepted { txid: txid(1) }]);
        state.on_removed(&[block(2)], 300_000).unwrap();
        let events = state.tick(300_000 + TOMBSTONE_WINDOW_MS);
        assert_eq!(
            events,
            vec![AcceptanceEvent::DisplacedElapsed { txid: txid(1) }],
            "guards reset on re-acceptance"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Consensus-audit finding 2 regression: an A→B re-acceptance must scrub
    /// the txid from A's index entry, so a LATE removal of A (whose original
    /// removal was never folded — detached tracker, page-budget gap) cannot
    /// falsely displace a tx currently accepted by B.
    #[test]
    fn stale_prior_block_removal_never_displaces_a_reaccepted_tx() {
        let dir = test_dir("stale-idx");
        let mut state = TrackerState::load(dir.join("acceptance.kvlog")).unwrap();
        state.watch(&txid(1), WatchSource::Send, 1_000).unwrap();
        state
            .on_accepted(&block(1), 5_000, &[txid(1)], 2_000)
            .unwrap();
        // Re-accepted by a different chain block WITHOUT a folded removal of
        // block(1) in between (the out-of-order case).
        state
            .on_accepted(&block(2), 6_000, &[txid(1)], 3_000)
            .unwrap();

        // The stale block's removal arrives late: must be a no-op.
        let events = state.on_removed(&[block(1)], 10_000).unwrap();
        assert!(events.is_empty(), "stale removal must not displace");
        assert!(matches!(
            state.status(&txid(1), 10_000),
            Some(TxStatus::Accepted { .. })
        ));

        // The CURRENT accepting block's removal still displaces.
        let events = state.on_removed(&[block(2)], 11_000).unwrap();
        assert_eq!(events, vec![AcceptanceEvent::Displaced { txid: txid(1) }]);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn stall_fires_for_send_sources_only_and_once() {
        let dir = test_dir("stall");
        let mut state = TrackerState::load(dir.join("acceptance.kvlog")).unwrap();
        state.watch(&txid(1), WatchSource::Send, 1_000).unwrap();
        state
            .watch(&txid(2), WatchSource::Transport, 1_000)
            .unwrap();

        assert!(state.tick(1_000 + STALL_AFTER_MS - 1).is_empty());
        let events = state.tick(1_000 + STALL_AFTER_MS);
        assert_eq!(
            events,
            vec![AcceptanceEvent::Stalled {
                txid: txid(1),
                waited_ms: STALL_AFTER_MS
            }],
            "send watch stalls; the transport watch NEVER does (a late-started \
             inbound watch must not read as a stall)"
        );
        assert!(
            state.tick(1_000 + STALL_AFTER_MS + 1).is_empty(),
            "one-shot"
        );
        assert!(matches!(
            state.status(&txid(1), 1_000 + STALL_AFTER_MS),
            Some(TxStatus::Stalled { .. })
        ));
        assert_eq!(
            state.status(&txid(2), 1_000 + STALL_AFTER_MS),
            Some(TxStatus::Submitted)
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Restart mid-pending (IDEAS:206): the watch — and a mid-flight
    /// displacement window — survive a reload.
    #[test]
    fn watch_and_displacement_window_survive_restart() {
        let dir = test_dir("restart");
        let path = dir.join("acceptance.kvlog");
        {
            let mut state = TrackerState::load(path.clone()).unwrap();
            state.watch(&txid(1), WatchSource::Send, 1_000).unwrap();
            state
                .watch(&txid(2), WatchSource::Transport, 1_000)
                .unwrap();
            state
                .on_accepted(&block(2), 5_000, &[txid(2)], 2_000)
                .unwrap();
            state.on_removed(&[block(2)], 10_000).unwrap();
        }
        // "Restart": fresh load from disk.
        let mut state = TrackerState::load(path).unwrap();
        assert_eq!(state.status(&txid(1), 3_000), Some(TxStatus::Submitted));
        assert_eq!(state.status(&txid(2), 3_000), Some(TxStatus::Displaced));
        // The window measures from the PERSISTED since-timestamp. (The Send
        // watch has also been Submitted > STALL_AFTER_MS by now — both
        // signals fire, order unspecified between HashMap entries.)
        let events = state.tick(10_000 + TOMBSTONE_WINDOW_MS);
        assert_eq!(events.len(), 2);
        assert!(events.contains(&AcceptanceEvent::DisplacedElapsed { txid: txid(2) }));
        assert!(events
            .iter()
            .any(|e| matches!(e, AcceptanceEvent::Stalled { txid: t, .. } if *t == txid(1))));
        // The rebuilt accepting-block index still routes a (hypothetical)
        // second removal of a re-accepted block.
        state
            .on_accepted(&block(3), 6_000, &[txid(2)], 200_000)
            .unwrap();
        let events = state.on_removed(&[block(3)], 210_000).unwrap();
        assert_eq!(events, vec![AcceptanceEvent::Displaced { txid: txid(2) }]);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn watch_cap_evicts_oldest_with_a_log_line_never_silently_grows() {
        let dir = test_dir("cap");
        let mut state = TrackerState::load(dir.join("acceptance.kvlog")).unwrap();
        for i in 0..WATCH_CAP {
            let t = format!("{:064x}", i);
            state
                .watch(&t, WatchSource::Send, 1_000 + i as u64)
                .unwrap();
        }
        assert_eq!(state.log.records.len(), WATCH_CAP);
        state
            .watch(&txid(0xAA), WatchSource::Send, 999_999)
            .unwrap();
        assert_eq!(state.log.records.len(), WATCH_CAP, "cap held");
        assert!(
            !state.log.records.contains_key(&format!("{:064x}", 0)),
            "oldest evicted"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn horizon_prune_drops_unknowable_watches() {
        let dir = test_dir("horizon");
        let mut state = TrackerState::load(dir.join("acceptance.kvlog")).unwrap();
        state.watch(&txid(1), WatchSource::Send, 1_000).unwrap();
        let past_horizon = 1_000 + pruning_horizon_ms() + 1;
        state.on_sink_blue(10, past_horizon).unwrap();
        assert_eq!(
            state.status(&txid(1), past_horizon),
            None,
            "a watch older than the pin-read pruning horizon is dropped"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn horizon_reads_thirty_hours_from_the_pin() {
        // The founder's INV-9 ruling made testable: the horizon comes out of
        // MAINNET_PARAMS, and at pin v2.0.1 that is 1,080,000 blocks ×
        // 100 ms = exactly 30 h. If a pin bump changes this, this test
        // CHANGES VALUE with it (never hardcode the horizon elsewhere).
        assert_eq!(
            pruning_horizon_ms(),
            MAINNET_PARAMS.pruning_depth() * MAINNET_PARAMS.blockrate.target_time_per_block
        );
        assert_eq!(pruning_horizon_ms(), 108_000_000, "30 h at the v2.0.1 pin");
    }

    #[test]
    fn watch_is_idempotent_first_source_wins() {
        let dir = test_dir("idem");
        let mut state = TrackerState::load(dir.join("acceptance.kvlog")).unwrap();
        state.watch(&txid(1), WatchSource::Send, 1_000).unwrap();
        state
            .watch(&txid(1), WatchSource::Transport, 2_000)
            .unwrap();
        let record = state.log.records.get(&txid(1)).unwrap();
        assert_eq!(record.source, WatchSource::Send);
        assert_eq!(record.watched_unix_ms, 1_000);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
