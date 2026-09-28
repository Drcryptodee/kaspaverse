//! acceptance — the V1 acceptance spine (D-073 hardening; re-exam §3.2).
//!
//! The app's one cheap, continuous truth-feed about what the chain did with
//! the txids it cares about: `VirtualChainChanged { include_accepted_
//! transaction_ids: true }` on the SAME shared socket (D-005), folded by a
//! small tracker into per-txid statuses that three consumers read:
//! send/wallet status honesty, transport reorg tombstones, and the V3 stall
//! signal. Catch-up twin: `get_virtual_chain_from_block(cursor, …)` — the
//! node itself pages the response (`batch_size = mergeset_size_limit × 10`,
//! pin `rpc/service/src/service.rs:737-743` @ `01b532e`), so reopen catch-up is a
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
//!
//! **Second feed since LINK-Q3 (D-344): the message walk's pages.** Messages now
//! come from ACCEPTED transactions (`walk.rs`), so the acceptance is known
//! BEFORE the message is folded, and a watch or a sender lookup the fold
//! registers arrives after the live `VirtualChainChanged` batch that named the
//! txid has already been folded here. Left alone, every inbound message's watch
//! would sit `Submitted` (a pending chip that never settles), its reorg would
//! never displace it, and its sender would wait on the slow locate. So the walk
//! hands the tracker each page's removals and the acceptance of every MATCHED
//! txid, with the accepting block's own header facts, and folds it by the same
//! rules as a live batch ([`AcceptanceTracker::fold_walk`]). What no one watches
//! yet is remembered in a bounded, in-memory set ([`MATCHED_MEMORY_CAPACITY`])
//! that [`AcceptanceTracker::watch`] and
//! [`AcceptanceTracker::note_sender_interest`] consult. The reorg rule is this
//! file's, unchanged: displaced, then tombstone-due past the window unless
//! re-accepted.

use std::collections::{HashMap, HashSet, VecDeque};
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
/// High-priority rebroadcast cadence (pin `flow_context.rs:597-671` @ `01b532e`); V1's
/// own submit→accepted markers refine it.
const STALL_AFTER_MS: u64 = 60_000;

/// Snapshot-level "Confirmed" depth (blue-score depth, read not computed).
/// PROVISIONAL 1000 — the founder's Kaspium-like security framing, ruled at
/// the V2b session (2026-07-10, was 100): ~100 s of chain at 10 bps — a
/// display state, not a consensus claim. The feed chip renders its counter
/// only below the Dart-side `chipCounterCeiling` (100) and goes quiet above
/// it; the 100→1000 tail is the future transaction-details screen's range.
/// V6's observe-before-tuning review re-examines both numbers.
const CONFIRMED_DEPTH_BLUE: u64 = 1_000;

/// Watch hygiene: an accepted watch this deep is terminal — displacement at
/// this depth is exceptional (finality is far deeper; this is bookkeeping,
/// not a finality claim) and the watch is pruned to keep the log bounded.
/// Raised with the Confirmed ruling (2026-07-10) to stay strictly deeper than
/// [`CONFIRMED_DEPTH_BLUE`] — reorg tracking must outlive the Confirmed
/// crossing, not finalize in the same sweep.
const TERMINAL_DEPTH_BLUE: u64 = 2_000;

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
pub(crate) const MAX_VCC_CATCHUP_PAGES: u32 = 16;

/// A page this far below the node's own batch bound means the walk reached
/// the tip (the chain advances ~10 blocks/s between round-trips, so an
/// is-empty test chases the tip to the page budget — observed live,
/// 2026-07-09 sitting). The live stream, buffered since Connected, owns
/// everything past the final short page; overlap folds idempotently.
pub(crate) const VCC_TIP_PAGE_THRESHOLD: usize = 100;

/// Per-page retry budget across a still-dialing socket — the cold-reopen
/// race: the first page routinely fires before the reconnect lands, and one
/// failure must not strand a mid-pending watch (the transport walk's law,
/// the message walk's since LINK-Q3; lived live 2026-07-09).
pub(crate) const VCC_PAGE_ATTEMPTS: u32 = 8;
pub(crate) const VCC_PAGE_RETRY_DELAY: Duration = Duration::from_millis(1000);

/// Throttle for cursor writes on the live VCC stream (~1 chain-block batch
/// per second) — same discipline as the transport scan cursor.
const CURSOR_MIN_WRITE_SECS: u64 = 3;

/// The pruning horizon in milliseconds, READ from the pinned mainnet params
/// (INV-9; founder ruling 2026-07-08): `pruning_depth` blocks ×
/// `target_time_per_block` ms — 1,080,000 × 100 ms = 30 h at the pin, unmoved
/// v2.0.1 → v2.1.0 (`bps.rs` blob-identical; D-324)
/// (`consensus/core/src/config/{params.rs:428,bps.rs:96-107}` @ `01b532e`). Past this
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

/// The accepting block's own timestamp — **the chain's moment of acceptance.**
///
/// Extracted so the read can be asserted. The defect this field was fixed for
/// did not live in the enum or in `on_accepted`, both of which are pure in the
/// value; it lived in one line at the call site that passed the wallet's clock
/// instead of the block's, and a test that chooses the argument itself cannot
/// see that line (`consensus-auditor`, UX-4B).
fn accepted_stamp(block: &kaspa_rpc_core::RpcBlock) -> u64 {
    block.header.timestamp
}

/// A txid status as consumers see it (the spec's five states).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TxStatus {
    Submitted,
    /// Accepted by a chain block; `blue_depth` = live sink blue score −
    /// accepting block blue score (two node-read values).
    ///
    /// `accepted_unix_ms` is the **accepting block's header timestamp** — the
    /// chain's own moment — or `0` when the block could not be fetched. A
    /// receipt prints it under the label `Accepted`, so the device's clock is
    /// not an acceptable substitute: it differs by however long the wallet
    /// took to hear, by hours on a catch-up replay, and by anything at all on
    /// a skewed device.
    Accepted {
        blue_depth: u64,
        accepted_unix_ms: u64,
    },
    Confirmed {
        blue_depth: u64,
        accepted_unix_ms: u64,
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
    /// A txid registered via [`AcceptanceTracker::note_sender_interest`] has
    /// been accepted, and its accepting block's DAA score is now known — the
    /// one input `get_utxo_return_address` needs to name who sent it.
    ///
    /// Emitted instead of resolving here because WHO a sender is matters only
    /// to conversations, and this layer knows nothing about them. Chain facts
    /// out; policy stays in the bridge.
    SenderResolvable {
        txid: String,
        accepting_daa_score: u64,
    },
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
    /// What the live stream took off the chain (LINK-Q3): see [`OffChain`].
    off_chain: OffChain,
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
            off_chain: OffChain::default(),
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

    /// The live stream put these chain blocks (back) on the chain.
    fn note_added(&mut self, added_blocks: &[String]) {
        for block in added_blocks {
            self.off_chain.added(block);
        }
    }

    /// **The walk says `txid` was accepted by `block`** (LINK-Q3). The log is
    /// the ordered live stream's; the walk may speak only where that stream
    /// cannot have spoken for the record — a `Transport` watch not currently
    /// accepted (registered after the live batch naming it had passed, the
    /// ordering flip; or displaced before a re-acceptance the stream folded
    /// while it was still unwatched) — and never onto a block the stream has
    /// removed. A `Send` watch is watched from submission, so every batch
    /// reached it: the walk never moves one (`wallet-security-auditor`). One
    /// correction for any source: the same block's own facts replace the
    /// fallback a failed `get_block` stored (a sink bound, time 0).
    fn walk_accepted(
        &mut self,
        txid: &str,
        block: &str,
        blue_score: u64,
        accepted_unix_ms: u64,
    ) -> Result<Vec<AcceptanceEvent>> {
        let Some(record) = self.log.records.get(txid).cloned() else {
            return Ok(Vec::new());
        };
        match &record.status {
            PersistedStatus::Accepted {
                accepting_block,
                accepted_unix_ms: 0,
                ..
            } if accepting_block == block && accepted_unix_ms != 0 => {
                let mut updated = record;
                updated.status = PersistedStatus::Accepted {
                    accepting_block: block.to_string(),
                    accepting_blue_score: blue_score,
                    accepted_unix_ms,
                };
                self.log.upsert(txid.to_string(), updated)?;
                Ok(Vec::new())
            }
            PersistedStatus::Submitted { .. } | PersistedStatus::Displaced { .. }
                if record.source == WatchSource::Transport && !self.off_chain.contains(block) =>
            {
                self.on_accepted(block, blue_score, &[txid.to_string()], accepted_unix_ms)
            }
            _ => Ok(Vec::new()),
        }
    }

    /// Register a txid whose fate the message walk already read (LINK-Q3): as
    /// accepted by its block (the index a later removal displaces from), or as
    /// displaced since then (the tombstone window already running). Returns
    /// the events the transition makes, as a live fold would.
    fn watch_remembered(
        &mut self,
        txid: &str,
        source: WatchSource,
        now_ms: u64,
        remembered: Remembered,
    ) -> Result<Vec<AcceptanceEvent>> {
        self.watch(txid, source, now_ms)?;
        // The walk remembered an acceptance the live stream has since retired:
        // the watch starts displaced, its window running from now.
        let remembered = match remembered {
            Remembered::Accepted { block, .. } if self.off_chain.contains(&block) => {
                Remembered::Displaced {
                    since_unix_ms: now_ms,
                    prior_block: block,
                }
            }
            other => other,
        };
        match remembered {
            Remembered::Accepted {
                block,
                blue_score,
                accepted_unix_ms,
                ..
            } => self.on_accepted(&block, blue_score, &[txid.to_string()], accepted_unix_ms),
            Remembered::Displaced {
                since_unix_ms,
                prior_block,
            } => {
                let Some(record) = self.log.records.get(txid).cloned() else {
                    return Ok(Vec::new());
                };
                let mut updated = record;
                updated.status = PersistedStatus::Displaced {
                    since_unix_ms,
                    prior_block,
                };
                self.log.upsert(txid.to_string(), updated)?;
                Ok(vec![AcceptanceEvent::Displaced {
                    txid: txid.to_string(),
                }])
            }
        }
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
    /// `accepted_unix_ms` is the **accepting block's own header timestamp**,
    /// or `0` when the block could not be fetched and there is none.
    ///
    /// It used to be `now_ms` — this wallet's clock at the moment it folded —
    /// which is a different fact from the acceptance and is wrong by however
    /// long the wallet took to hear. On a catch-up page replaying hours-old
    /// blocks it is wrong by hours, and on a device with a skewed clock it is
    /// simply false. A receipt prints this under the label **Accepted**, so it
    /// has to be the chain's number or no number (`ffi-leak-auditor`, UX-4B).
    fn on_accepted(
        &mut self,
        accepting_block: &str,
        accepting_blue_score: u64,
        txids: &[String],
        accepted_unix_ms: u64,
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
                accepted_unix_ms,
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
            // The ordered stream's word: only its removals reach here since
            // LINK-Q3 (the walk's never touch the log; see `fold_walk`).
            self.off_chain.removed(block);
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
                accepted_unix_ms,
                ..
            } => {
                let blue_depth = self.sink_blue.saturating_sub(*accepting_blue_score);
                if blue_depth >= CONFIRMED_DEPTH_BLUE {
                    TxStatus::Confirmed {
                        blue_depth,
                        accepted_unix_ms: *accepted_unix_ms,
                    }
                } else {
                    TxStatus::Accepted {
                        blue_depth,
                        accepted_unix_ms: *accepted_unix_ms,
                    }
                }
            }
            // Finality was already established when the record finalized —
            // Confirmed regardless of the (possibly not-yet-received) live
            // sink value; the displayed depth grows as the sink arrives.
            PersistedStatus::Finalized {
                accepting_blue_score,
                accepted_unix_ms,
                ..
            } => TxStatus::Confirmed {
                blue_depth: self.sink_blue.saturating_sub(*accepting_blue_score),
                accepted_unix_ms: *accepted_unix_ms,
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
    /// Txids awaiting SENDER resolution — deliberately NOT the watch log.
    ///
    /// The watch log is persisted and capacity-shared with real in-flight
    /// sends; these txids are attacker-mintable (anyone can put a `comm:`
    /// payload on chain addressed to a published key), so an unbounded or
    /// durable queue keyed on them is a self-inflicted denial of service.
    /// This set is in-memory only, FIFO-evicted at
    /// [`SENDER_INTEREST_CAPACITY`], and forgotten on restart — losing an
    /// entry costs one deferred lookup, never a message.
    sender_interest: Mutex<VecDeque<String>>,
    /// Acceptance facts for matched txids no one watches yet (LINK-Q3): see
    /// [`MATCHED_MEMORY_CAPACITY`]. Lock order: `state` before this, and
    /// `sender_interest` before this; this one is always taken last.
    matched: Mutex<MatchedMemory>,
}

/// How many unresolved senders we will carry at once. Sized for a human
/// conversation rate, not a chain-wide one; the oldest is dropped first.
pub const SENDER_INTEREST_CAPACITY: usize = 256;

/// Which chain block in a page accepted `txid`, if any. Pure over the page.
fn accepting_block_of(accepted: &[(Hash, Vec<Hash>)], txid: Hash) -> Option<Hash> {
    accepted
        .iter()
        .find(|(_, ids)| ids.contains(&txid))
        .map(|(block, _)| *block)
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

/// What the monitor feeds the tracker: the live `VirtualChainChanged` stream,
/// and since LINK-Q3 the message walk's pages (D-344).
#[derive(Debug, Clone)]
pub enum TrackerFeed {
    Vcc(VccBatch),
    Walk(WalkBatch),
}

/// One page of the message walk, reduced to what the tracker needs: the chain
/// blocks it removed, and for each chain block that accepted a MATCHED
/// transaction, that block's own facts and those txids. Never every txid a
/// block accepted: the live stream carries those.
#[derive(Debug, Clone)]
pub struct WalkBatch {
    pub removed_chain_block_hashes: Arc<Vec<Hash>>,
    pub accepted: Vec<WalkAcceptance>,
}

/// A chain block's acceptance of matched txids, as the walk read it (V2 at High
/// carries the header's Low fields, so no `get_block` round trip is needed).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalkAcceptance {
    pub accepting_block: Hash,
    pub blue_score: u64,
    pub daa_score: u64,
    /// The accepting block's own header timestamp, unix ms ([`accepted_stamp`]'s
    /// rule: the chain's moment, never this device's clock).
    pub timestamp_ms: u64,
    pub txids: Vec<Hash>,
}

/// How many matched txids the tracker remembers the acceptance of before
/// anyone watches them. The walk matches by payload prefix, so nearly every
/// entry is a stranger's message and the set is attacker-mintable: bounded,
/// in-memory, forgotten on restart, and never the persisted watch log
/// (the [`SENDER_INTEREST_CAPACITY`] reasoning). Sized far above a page's
/// organic matches (~2 a minute on today's mainnet, ~10 in a four-minute
/// catch-up page), because an entry only has to outlive the fold that folds
/// its message; losing one costs a pending chip or the slower sender locate,
/// never the message.
pub const MATCHED_MEMORY_CAPACITY: usize = 1024;

/// How often an eviction summary may be logged. Evictions are routine under
/// a flood of strangers' matches, so a line each would be the log-eviction
/// weapon the intake's `dropped` rule denies.
const MATCHED_EVICTION_LOG_EVERY_MS: u64 = 10 * 60 * 1000;

/// What the tracker remembers about a matched txid no one watches yet: the
/// same two states a watch can be in after the chain speaks.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Remembered {
    Accepted {
        block: String,
        blue_score: u64,
        daa_score: u64,
        accepted_unix_ms: u64,
    },
    Displaced {
        since_unix_ms: u64,
        prior_block: String,
    },
}

/// The bounded memory behind [`MATCHED_MEMORY_CAPACITY`]: oldest out first.
#[derive(Default)]
struct MatchedMemory {
    order: VecDeque<String>,
    map: HashMap<String, Remembered>,
    evicted: u64,
    logged_at_ms: u64,
}

impl MatchedMemory {
    fn get(&self, txid: &str) -> Option<&Remembered> {
        self.map.get(txid)
    }

    fn remember(&mut self, txid: String, remembered: Remembered, now_ms: u64) {
        if !self.map.contains_key(&txid) {
            if self.order.len() >= MATCHED_MEMORY_CAPACITY {
                if let Some(oldest) = self.order.pop_front() {
                    self.map.remove(&oldest);
                    self.evicted += 1;
                    if now_ms.saturating_sub(self.logged_at_ms) >= MATCHED_EVICTION_LOG_EVERY_MS {
                        log::info!(
                            "acceptance: matched-acceptance memory full — {} oldest evicted since \
                             the last line (a late watch falls back to Submitted, a late sender \
                             lookup to the locate)",
                            self.evicted
                        );
                        self.evicted = 0;
                        self.logged_at_ms = now_ms;
                    }
                }
            }
            self.order.push_back(txid.clone());
        }
        self.map.insert(txid, remembered);
    }

    /// Removed chain blocks displace what they accepted, as for a watch.
    fn displace(&mut self, removed: &[String], now_ms: u64) {
        for remembered in self.map.values_mut() {
            if let Remembered::Accepted { block, .. } = remembered {
                if removed.contains(block) {
                    *remembered = Remembered::Displaced {
                        since_unix_ms: now_ms,
                        prior_block: block.clone(),
                    };
                }
            }
        }
    }
}

/// How many chain blocks the live stream removed (and has not re-added) the
/// tracker remembers. Removals are node facts, a handful a minute on mainnet,
/// never attacker-mintable, so this holds hours; the oldest goes first.
const OFF_CHAIN_CAPACITY: usize = 4096;

/// **The chain blocks the ordered live stream has removed and not re-added**
/// (LINK-Q3). The walk's pages arrive on their own clock and can be older than
/// a live batch; a walk acceptance onto a block in here would resurrect an
/// acceptance the stream has already retired (`consensus-auditor`).
#[derive(Default)]
struct OffChain {
    order: VecDeque<String>,
    set: HashSet<String>,
}

impl OffChain {
    fn removed(&mut self, block: &str) {
        if self.set.insert(block.to_string()) {
            self.order.push_back(block.to_string());
            if self.order.len() > OFF_CHAIN_CAPACITY {
                if let Some(oldest) = self.order.pop_front() {
                    self.set.remove(&oldest);
                }
            }
        }
    }

    fn added(&mut self, block: &str) {
        if self.set.remove(block) {
            self.order.retain(|b| b != block);
        }
    }

    fn contains(&self, block: &str) -> bool {
        self.set.contains(block)
    }
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
            sender_interest: Mutex::new(VecDeque::new()),
            matched: Mutex::new(MatchedMemory::default()),
        }))
    }

    /// New receiver onto the acceptance event fan-out.
    pub fn subscribe(&self) -> broadcast::Receiver<AcceptanceEvent> {
        self.events.subscribe()
    }

    /// Watch a txid (idempotent; first source wins).
    ///
    /// **A txid the message walk already saw accepted is registered as what the
    /// chain said** (LINK-Q3): its acceptance, or its displacement, from the
    /// matched memory. The live batch that named it was folded before this
    /// watch existed, so without the memory it would sit `Submitted` for good.
    pub fn watch(&self, txid: &str, source: WatchSource) {
        let mut events = Vec::new();
        {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.is_watched(txid) {
                return;
            }
            // Only a message watch takes the walk's memory: a Send watch is the
            // ordered stream's alone, registered at the submit ack, which in
            // practice precedes the live batch naming it; a late one stays
            // Submitted for the stall lane (`wallet-security-auditor`, round 4 — the
            // rule `walk_accepted` keeps, made structural here too).
            let remembered = if source == WatchSource::Transport {
                self.matched
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .get(txid)
                    .cloned()
            } else {
                None
            };
            let now_ms = now_unix_ms();
            let outcome = match remembered {
                Some(remembered) => state
                    .watch_remembered(txid, source, now_ms, remembered)
                    .map(|found| events = found),
                None => state.watch(txid, source, now_ms),
            };
            if let Err(e) = outcome {
                log::warn!("acceptance: watch persist failed: {e}");
            }
        }
        self.broadcast(events);
    }

    /// Register a txid whose SENDER we want named once the chain accepts it.
    ///
    /// This is the node-only answer to "who sent this message?" for a payload
    /// that paid us nothing. `get_utxo_return_address` needs the accepting
    /// block's DAA score, and the VCC stream this tracker already consumes is
    /// the only place a node volunteers which chain block accepted which
    /// txids. So the interest is parked here and resolved in
    /// [`Self::fold_batch`] — never by blocking the intake that noticed it.
    ///
    /// Bounded and in-memory by design: see [`Self::sender_interest`].
    /// Idempotent.
    pub fn note_sender_interest(&self, txid: &str) {
        // Lock order: state, then interest, then the memory — `fold_batch`
        // takes state before interest, and the memory is always last.
        let state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut set = self
            .sender_interest
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if set.iter().any(|t| t == txid) {
            return;
        }
        // LINK-Q3: the message walk folds a message AFTER its acceptance, so
        // the batch that would resolve this interest may already have been
        // folded. Its DAA score is then in the matched memory: answer now —
        // unless the live stream has since taken that block off the chain, in
        // which case its score would name nobody (`consensus-auditor`). Taken
        // under the interest lock, so the interest resolves exactly once
        // whichever of this and `fold_walk` lands first.
        let known = match self
            .matched
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(txid)
        {
            Some(Remembered::Accepted {
                daa_score, block, ..
            }) if !state.off_chain.contains(block) => Some(*daa_score),
            _ => None,
        };
        drop(state);
        if let Some(accepting_daa_score) = known {
            drop(set);
            self.broadcast(vec![AcceptanceEvent::SenderResolvable {
                txid: txid.to_string(),
                accepting_daa_score,
            }]);
            return;
        }
        if set.len() >= SENDER_INTEREST_CAPACITY {
            // Oldest out, and say so — a silent eviction here is a message
            // whose sender is never named, which reads to a user as a message
            // that never arrived.
            if let Some(dropped) = set.pop_front() {
                log::info!("acceptance: sender-interest full — dropped tx={dropped}");
            }
        }
        set.push_back(txid.to_string());
    }

    /// Take any interest entries accepted by this batch, with the DAA score
    /// their resolution needs. Removes what it returns — one shot per txid.
    fn take_resolvable(&self, txids: &[String], daa_score: u64) -> Vec<AcceptanceEvent> {
        let mut set = self
            .sender_interest
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut out = Vec::new();
        for txid in txids {
            if let Some(pos) = set.iter().position(|t| t == txid) {
                set.remove(pos);
                out.push(AcceptanceEvent::SenderResolvable {
                    txid: txid.clone(),
                    accepting_daa_score: daa_score,
                });
            }
        }
        out
    }

    /// **Name the chain block that accepted `txid`, given the block that
    /// CARRIED it** — for a message folded out of an old block, whose VCC
    /// batch this tracker walked before anyone was interested in it.
    ///
    /// [`Self::note_sender_interest`] is resolved inside [`Self::fold_batch`],
    /// so it can only ever answer for a batch that arrives AFTER the interest
    /// is noted. A comm folded by the transport lane's own catch-up sits in a
    /// block this tracker's cold-open walk has usually already passed, and
    /// its interest would wait forever — which is exactly the message a user
    /// who reopens the app after a day expects to see (D-307).
    ///
    /// One virtual-chain page from the carrying block, **read and never
    /// folded**: the cursor does not move, no watch changes, no event is
    /// broadcast. The pin's `calculate_chain_path` accepts a non-chain start
    /// (its off-chain ancestors are the `removed` half), so the carrying block
    /// itself is the right cursor; the accepting block sits within the first
    /// page for anything but a deep side chain. Then one `get_block` for the
    /// DAA score the return-address lookup demands exactly
    /// (`find_accepting_chain_block_hash_at_daa_score` is a binary search for
    /// an EQUAL score — an approximate one is `NoTxAtScore`).
    ///
    /// Bounded by the caller: a page is up to `mergeset_size_limit × 10`
    /// chain blocks with their accepted txids, and every unroutable comm on a
    /// public chain can ask for one, so the bridge rate-limits calls and
    /// runs at most one per alias.
    pub async fn locate_accepting_daa_score(
        &self,
        rpc: &Rpc,
        txid: &str,
        carrying_block: Hash,
    ) -> Option<u64> {
        let target = txid.parse::<Hash>().ok()?;
        let resp = self.catch_up_page(rpc, carrying_block).await?;
        let accepted: Vec<(Hash, Vec<Hash>)> = resp
            .accepted_transaction_ids
            .into_iter()
            .map(|a| (a.accepting_block_hash, a.accepted_transaction_ids))
            .collect();
        let accepting = accepting_block_of(&accepted, target)?;
        match rpc.rpc_api().get_block(accepting, false).await {
            Ok(block) => Some(block.header.daa_score),
            Err(e) => {
                // Node-controlled text, sanitized before it reaches the log (L167).
                log::info!(
                    "acceptance: get_block({accepting}) for a sender locate failed ({})",
                    crate::link::sanitize_node_text(&e.to_string())
                );
                None
            }
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
        // Blocks this batch put (back) on the chain leave the off-chain set, so
        // a walk acceptance onto them is admitted again (LINK-Q3).
        if !batch.added_chain_block_hashes.is_empty() {
            let added: Vec<String> = batch
                .added_chain_block_hashes
                .iter()
                .map(|h| h.to_string())
                .collect();
            self.state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .note_added(&added);
        }

        // Acceptances: pre-filter to txids we care about, then resolve scores.
        // Two independent interests share the one `get_block` round trip —
        // watched txids (status folding) and sender-interest txids (naming
        // who sent a message that paid us nothing).
        let mut matches: Vec<(Hash, Vec<String>, Vec<String>)> = Vec::new();
        {
            let state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let interest = self
                .sender_interest
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for (accepting_block, txids) in batch.accepted.iter() {
                let all: Vec<String> = txids.iter().map(|t| t.to_string()).collect();
                let watched: Vec<String> = all
                    .iter()
                    .filter(|t| state.is_watched(t))
                    .cloned()
                    .collect();
                let wanted: Vec<String> = all
                    .iter()
                    .filter(|t| interest.iter().any(|i| i == *t))
                    .cloned()
                    .collect();
                if !watched.is_empty() || !wanted.is_empty() {
                    matches.push((*accepting_block, watched, wanted));
                }
            }
        }
        for (accepting_block, txids, wanted) in matches {
            // `daa_score` is the sibling of the blue score we already fetch —
            // and it is exactly the input `get_utxo_return_address` needs.
            let mut daa_score: Option<u64> = None;
            // The accepting block's OWN timestamp — the chain's moment of
            // acceptance, and the only honest source for a receipt's
            // `Accepted` line. `0` when the block could not be fetched; the
            // bridge maps that to `None` and the glass then shows no time
            // rather than this device's clock.
            let mut accepted_unix_ms: u64 = 0;
            let blue_score = match rpc.rpc_api().get_block(accepting_block, false).await {
                Ok(block) => {
                    daa_score = Some(block.header.daa_score);
                    accepted_unix_ms = accepted_stamp(&block);
                    block.header.blue_score
                }
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
                                    "acceptance: get_block({accepting_block}) failed ({}) and \
                                     no sink blue score available ({}) — fold skipped, \
                                     {} watch(es) stay Submitted",
                                    crate::link::sanitize_node_text(&e.to_string()),
                                    crate::link::sanitize_node_text(&e2.to_string()),
                                    txids.len()
                                );
                                continue;
                            }
                        }
                    }
                    log::warn!(
                        "acceptance: get_block({accepting_block}) failed ({}) — \
                         using sink blue score {sink} as a conservative bound",
                        crate::link::sanitize_node_text(&e.to_string())
                    );
                    sink
                }
            };
            // Sender resolution rides the same block read. Only when the node
            // actually answered: the blue-score fallback above is a bound, not
            // a fact, and a wrong DAA score names the wrong sender.
            if !wanted.is_empty() {
                match daa_score {
                    Some(daa) => self.broadcast(self.take_resolvable(&wanted, daa)),
                    None => log::info!(
                        "acceptance: {} sender lookup(s) deferred — no DAA score for {accepting_block}",
                        wanted.len()
                    ),
                }
            }
            if txids.is_empty() {
                continue;
            }
            let events = {
                let mut state = self
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                state
                    .on_accepted(
                        &accepting_block.to_string(),
                        blue_score,
                        &txids,
                        accepted_unix_ms,
                    )
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

    /// **Fold one page of the message walk** (LINK-Q3, D-344). The log belongs
    /// to the ordered live stream; the walk's page arrives on its own clock and
    /// can be older than a live batch, so it speaks to the log only where the
    /// stream cannot have (`TrackerState::walk_accepted`), and its REMOVALS
    /// never reach the log at all: applied late, they would displace a record
    /// the stream had already re-accepted — a payment read "Displaced by the
    /// network" (`wallet-security-auditor`). Everything else goes to the
    /// bounded memory the walk owns, which a watch or a sender lookup
    /// registered later consults. An interested txid resolves on the page's
    /// own DAA score, unless its block has left the chain. `state` is held
    /// while the memory is written, the order [`Self::watch`] takes them in,
    /// so a watch lands either before (folded here) or after (found in the
    /// memory), never between.
    pub(crate) fn fold_walk(&self, batch: &WalkBatch) {
        let now_ms = now_unix_ms();
        let removed: Vec<String> = batch
            .removed_chain_block_hashes
            .iter()
            .map(|h| h.to_string())
            .collect();
        let mut events = Vec::new();
        let mut resolvable: Vec<(Vec<String>, u64)> = Vec::new();
        {
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut memory = self
                .matched
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !removed.is_empty() {
                memory.displace(&removed, now_ms);
            }
            for acceptance in &batch.accepted {
                let block = acceptance.accepting_block.to_string();
                let off_chain = state.off_chain.contains(&block);
                let txids: Vec<String> = acceptance.txids.iter().map(|t| t.to_string()).collect();
                for txid in &txids {
                    events.extend(
                        state
                            .walk_accepted(
                                txid,
                                &block,
                                acceptance.blue_score,
                                acceptance.timestamp_ms,
                            )
                            .unwrap_or_else(|e| {
                                log::warn!("acceptance: walk acceptance fold persist failed: {e}");
                                Vec::new()
                            }),
                    );
                }
                for txid in &txids {
                    let remembered = if off_chain {
                        Remembered::Displaced {
                            since_unix_ms: now_ms,
                            prior_block: block.clone(),
                        }
                    } else {
                        Remembered::Accepted {
                            block: block.clone(),
                            blue_score: acceptance.blue_score,
                            daa_score: acceptance.daa_score,
                            accepted_unix_ms: acceptance.timestamp_ms,
                        }
                    };
                    memory.remember(txid.clone(), remembered, now_ms);
                }
                if !off_chain {
                    resolvable.push((txids, acceptance.daa_score));
                }
            }
        }
        for (txids, daa_score) in resolvable {
            events.extend(self.take_resolvable(&txids, daa_score));
        }
        self.broadcast(events);
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
                    // Node-controlled text, sanitized before any log lane (L167).
                    log::debug!(
                        "acceptance: catch-up page attempt {attempt} failed ({}); retrying",
                        crate::link::sanitize_node_text(&e.to_string())
                    );
                    tokio::time::sleep(VCC_PAGE_RETRY_DELAY).await;
                }
            }
        }
        None
    }

    /// Spawn the tracker task: folds live VCC batches and the message walk's
    /// pages from `vcc_rx` (one channel, so each feed is folded in its own order), runs
    /// catch-up on every (re)connect via `dag_rx`, folds sink blue score
    /// updates, and ticks the stall/tombstone windows.
    pub fn run(
        self: &Arc<Self>,
        rpc: Rpc,
        mut vcc_rx: mpsc::UnboundedReceiver<TrackerFeed>,
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
                    feed = vcc_rx.recv() => {
                        match feed {
                            Some(TrackerFeed::Vcc(batch)) => tracker.fold_batch(&rpc, &batch).await,
                            Some(TrackerFeed::Walk(batch)) => tracker.fold_walk(&batch),
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

    /// The page reader behind the sender locate: the accepting block is the
    /// one whose accepted list names the txid, and a txid in no list is
    /// `None` rather than the page's last block.
    #[test]
    fn the_accepting_block_is_the_one_whose_list_names_the_txid() {
        let block = |n: u8| Hash::from_bytes([n; 32]);
        let page = vec![
            (block(1), vec![block(10), block(11)]),
            (block(2), vec![block(12)]),
        ];
        assert_eq!(accepting_block_of(&page, block(12)), Some(block(2)));
        assert_eq!(accepting_block_of(&page, block(10)), Some(block(1)));
        assert_eq!(accepting_block_of(&page, block(99)), None);
        assert_eq!(accepting_block_of(&[], block(10)), None);
    }

    fn txid(n: u8) -> String {
        format!("{:02x}", n).repeat(32)
    }

    fn block(n: u8) -> String {
        format!("{:02x}", n ^ 0xFF).repeat(32)
    }

    /// **The seam that actually broke.** `on_accepted` is pure in its stamp
    /// argument, so a test that chooses that argument proves only that a value
    /// travels — it cannot see the one line at the call site that decides
    /// WHICH value. That line passed the wallet's own clock, `ffi-leak-auditor`
    /// caught it, and this asserts the read it was replaced with: the
    /// accepting block's own header timestamp, and nothing that could be
    /// confused with a local clock (`consensus-auditor`, UX-4B).
    #[test]
    fn accepted_stamp_reads_the_blocks_own_timestamp() {
        // Deliberately nothing like `now`: a 1998 stamp cannot be produced by
        // any clock this test could accidentally be reading instead.
        const STAMP: u64 = 883_612_800_000;
        let header = kaspa_rpc_core::RpcHeader {
            hash: Hash::default(),
            version: 0,
            parents_by_level: Vec::new(),
            hash_merkle_root: Hash::default(),
            accepted_id_merkle_root: Hash::default(),
            utxo_commitment: Hash::default(),
            timestamp: STAMP,
            bits: 0,
            nonce: 0,
            daa_score: 0,
            blue_work: 0.into(),
            blue_score: 0,
            pruning_point: Hash::default(),
        };
        let block = kaspa_rpc_core::RpcBlock {
            header,
            transactions: Vec::new(),
            verbose_data: None,
        };
        assert_eq!(accepted_stamp(&block), STAMP);
    }

    /// The sender-interest set is the one queue in this file keyed on
    /// ATTACKER-MINTABLE input: anyone can put a `comm:` payload on chain
    /// addressed to a published key. So it must be bounded, in-memory, and
    /// must never share capacity with the persisted watch log that real
    /// in-flight sends depend on.
    #[test]
    fn the_sender_interest_set_is_bounded_and_separate_from_the_watch_log() {
        let dir = test_dir("sender-interest");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();

        tracker.note_sender_interest(&txid(1));
        tracker.note_sender_interest(&txid(1)); // idempotent
        assert_eq!(
            tracker
                .sender_interest
                .lock()
                .unwrap()
                .iter()
                .filter(|t| **t == txid(1))
                .count(),
            1,
            "re-noting the same txid must not grow the set"
        );

        // It never touches the persisted watch log.
        assert!(
            tracker.status(&txid(1)).is_none(),
            "sender interest must NOT register a watch — that log is capped \
             and shared with real in-flight sends"
        );

        // Resolution is one-shot and carries the DAA score the lookup needs.
        let events = tracker.take_resolvable(&[txid(1)], 4_242);
        assert_eq!(events.len(), 1);
        assert!(matches!(
            &events[0],
            AcceptanceEvent::SenderResolvable { txid: t, accepting_daa_score: 4_242 } if *t == txid(1)
        ));
        assert!(
            tracker.take_resolvable(&[txid(1)], 4_242).is_empty(),
            "a resolved interest is consumed, never re-emitted"
        );

        // FIFO eviction at the cap — the oldest goes, the newest survives.
        for n in 0..(SENDER_INTEREST_CAPACITY + 8) {
            tracker.note_sender_interest(&format!("{n:064x}"));
        }
        let set = tracker.sender_interest.lock().unwrap();
        assert_eq!(set.len(), SENDER_INTEREST_CAPACITY, "bounded");
        assert!(
            !set.iter().any(|t| *t == format!("{:064x}", 0)),
            "oldest evicted"
        );
        assert!(
            set.iter()
                .any(|t| *t == format!("{:064x}", SENDER_INTEREST_CAPACITY + 7)),
            "newest kept"
        );
        drop(set);
        let _ = std::fs::remove_dir_all(&dir);
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
            Some(TxStatus::Accepted {
                blue_depth: 0,
                // The accepting BLOCK's timestamp, carried straight through —
                // this is the number a receipt prints under `Accepted`, and
                // asserting it here is what stops it sliding back to the
                // device's clock.
                accepted_unix_ms: 2_000
            }),
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
                blue_depth: CONFIRMED_DEPTH_BLUE + 1,
                accepted_unix_ms: 2_000
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
        // Re-read at the v2.1.0 bump (D-324): unmoved, bps.rs blob-identical.
        assert_eq!(
            pruning_horizon_ms(),
            MAINNET_PARAMS.pruning_depth() * MAINNET_PARAMS.blockrate.target_time_per_block
        );
        assert_eq!(pruning_horizon_ms(), 108_000_000, "30 h at the v2.1.0 pin");
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

    // ── LINK-Q3: the message walk's feed (D-344) ──────────────────────────────

    fn hb(n: u8) -> Hash {
        Hash::from_bytes([n; 32])
    }

    /// One walk page's worth: `removed`, then `txids` accepted by `block` with
    /// facts no clock could produce by accident.
    fn walk_batch(removed: &[Hash], block: Hash, txids: &[Hash], daa: u64) -> WalkBatch {
        WalkBatch {
            removed_chain_block_hashes: Arc::new(removed.to_vec()),
            accepted: if txids.is_empty() {
                Vec::new()
            } else {
                vec![WalkAcceptance {
                    accepting_block: block,
                    blue_score: 4_000,
                    daa_score: daa,
                    timestamp_ms: 883_612_800_000,
                    txids: txids.to_vec(),
                }]
            },
        }
    }

    /// **The ordering flip, both ways round.** A message is folded AFTER the
    /// live batch that accepted it, so its watch must come out `Accepted` on the
    /// accepting block's own time whether the walk's page reaches the tracker
    /// before the watch (the memory answers) or after it (the fold answers).
    /// Mutation: dropping the memory read in `watch` leaves the first case
    /// `Submitted`, the pending chip that never settles.
    #[test]
    fn a_message_watched_after_its_acceptance_is_accepted_either_way_round() {
        let dir = test_dir("walk-order");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let (early, late) = (hb(0x21), hb(0x22));

        tracker.fold_walk(&walk_batch(&[], hb(0xB1), &[early], 7));
        tracker.watch(&early.to_string(), WatchSource::Transport);

        tracker.watch(&late.to_string(), WatchSource::Transport);
        assert_eq!(tracker.status(&late.to_string()), Some(TxStatus::Submitted));
        tracker.fold_walk(&walk_batch(&[], hb(0xB1), &[late], 7));

        for txid in [early, late] {
            assert!(
                matches!(
                    tracker.status(&txid.to_string()),
                    Some(TxStatus::Accepted {
                        accepted_unix_ms: 883_612_800_000,
                        ..
                    })
                ),
                "{txid} read {:?}",
                tracker.status(&txid.to_string())
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The live stream's fold of a removal or an addition, as `fold_batch`
    /// applies them (no RPC is needed for either).
    fn live_removed(tracker: &AcceptanceTracker, blocks: &[Hash]) {
        let blocks: Vec<String> = blocks.iter().map(|b| b.to_string()).collect();
        let events = tracker
            .state
            .lock()
            .unwrap()
            .on_removed(&blocks, now_unix_ms())
            .unwrap();
        tracker.broadcast(events);
    }

    fn live_accepted(tracker: &AcceptanceTracker, block: Hash, txids: &[Hash]) {
        let mut state = tracker.state.lock().unwrap();
        state.note_added(&[block.to_string()]);
        let txids: Vec<String> = txids.iter().map(|t| t.to_string()).collect();
        state
            .on_accepted(&block.to_string(), 4_100, &txids, 883_612_900_000)
            .unwrap();
    }

    /// **Deliverable 2's fixture: a message whose accepting block leaves the
    /// chain takes this file's rule, unchanged.** Registered from the walk's
    /// facts, the watch sits in the accepting-block index, so the LIVE stream's
    /// removal displaces it: tombstone-due past the window, or accepted again
    /// when the stream re-accepts it. When the removal reached the tracker
    /// BEFORE the watch did, the watch starts displaced (the window already
    /// running), and a re-acceptance the stream folded while it was unwatched
    /// reaches it through the walk's next page.
    #[test]
    fn a_reorged_message_follows_the_spines_displacement_rule() {
        let dir = test_dir("walk-reorg");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let (lost, moved, early) = (hb(0x31), hb(0x32), hb(0x33));
        let (b, b2) = (hb(0xB2), hb(0xB3));

        tracker.fold_walk(&walk_batch(&[], b, &[lost, moved], 9));
        tracker.watch(&lost.to_string(), WatchSource::Transport);
        tracker.watch(&moved.to_string(), WatchSource::Transport);
        live_removed(&tracker, &[b]);
        live_accepted(&tracker, b2, &[moved]);
        assert_eq!(tracker.status(&lost.to_string()), Some(TxStatus::Displaced));
        assert!(matches!(
            tracker.status(&moved.to_string()),
            Some(TxStatus::Accepted { .. })
        ));

        let later = now_unix_ms() + TOMBSTONE_WINDOW_MS + 1;
        let elapsed = tracker.state.lock().unwrap().tick(later);
        assert_eq!(
            elapsed,
            vec![AcceptanceEvent::DisplacedElapsed {
                txid: lost.to_string()
            }]
        );

        // The removal lands before the watch: the watch starts displaced.
        tracker.fold_walk(&walk_batch(&[], hb(0xB4), &[early], 9));
        live_removed(&tracker, &[hb(0xB4)]);
        tracker.watch(&early.to_string(), WatchSource::Transport);
        assert_eq!(
            tracker.status(&early.to_string()),
            Some(TxStatus::Displaced)
        );
        // Re-accepted while it was unwatched: only the walk can say so.
        tracker.fold_walk(&walk_batch(&[], hb(0xB6), &[early], 9));
        assert!(
            matches!(
                tracker.status(&early.to_string()),
                Some(TxStatus::Accepted { .. })
            ),
            "re-accepted inside the window: the ghost is reversed"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The walk's removals reach its own memory** (and only it): an
    /// acceptance no one watches yet, whose block the walk saw leave the
    /// chain, registers displaced even before the live stream says so — the
    /// window runs, and the walk's next page heals it if the block returns.
    #[test]
    fn a_walk_removal_displaces_what_only_the_memory_holds() {
        let dir = test_dir("walk-memory-removal");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let (tx, x) = (hb(0x91), hb(0xA9));
        tracker.fold_walk(&walk_batch(&[], x, &[tx], 2));
        tracker.fold_walk(&walk_batch(&[x], hb(0xAA), &[], 2));
        tracker.watch(&tx.to_string(), WatchSource::Transport);
        assert_eq!(tracker.status(&tx.to_string()), Some(TxStatus::Displaced));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A payment's watch never takes the walk's memory**: a Send watch is
    /// the ordered stream's alone, whatever the walk remembered about the txid.
    #[test]
    fn a_send_watch_never_takes_the_walks_memory() {
        let dir = test_dir("walk-send-memory");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let sent = hb(0x95);
        tracker.fold_walk(&walk_batch(&[], hb(0xAB), &[sent], 2));
        tracker.watch(&sent.to_string(), WatchSource::Send);
        assert_eq!(tracker.status(&sent.to_string()), Some(TxStatus::Submitted));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A stale walk removal never displaces a payment** (`wallet-security-
    /// auditor`, LINK-Q3). The stream removed block X and re-added it with the
    /// payment S accepted; the walk's older page, still saying "X removed",
    /// lands after. S stays accepted: the walk's removals never reach the log.
    /// Mutation: letting `fold_walk` fold removals into the log reads S
    /// `Displaced` — the receipt that invites a second payment.
    #[test]
    fn a_stale_walk_removal_never_displaces_a_payment() {
        let dir = test_dir("walk-stale-removal");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let (payment, x) = (hb(0x51), hb(0xC1));
        tracker.watch(&payment.to_string(), WatchSource::Send);
        live_accepted(&tracker, x, &[payment]);
        live_removed(&tracker, &[x]);
        live_accepted(&tracker, x, &[payment]);
        tracker.fold_walk(&walk_batch(&[x], hb(0xC2), &[], 1));
        assert!(
            matches!(
                tracker.status(&payment.to_string()),
                Some(TxStatus::Accepted { .. })
            ),
            "read {:?}",
            tracker.status(&payment.to_string())
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A stale walk acceptance never lands on a block the stream removed,
    /// and never moves an acceptance the stream already made** (`consensus-
    /// auditor`, LINK-Q3). A message the stream moved to B′ stays on B′; a
    /// Submitted one is not accepted by the removed B, and is by the live B2;
    /// a Send watch is never moved by the walk at all.
    #[test]
    fn a_stale_walk_acceptance_never_overrides_the_stream() {
        let dir = test_dir("walk-stale-acceptance");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let (waiting, moved, sent) = (hb(0x61), hb(0x62), hb(0x63));
        let (b, b_prime, b2) = (hb(0xD1), hb(0xD2), hb(0xD3));
        tracker.watch(&waiting.to_string(), WatchSource::Transport);
        tracker.watch(&moved.to_string(), WatchSource::Transport);
        tracker.watch(&sent.to_string(), WatchSource::Send);
        live_accepted(&tracker, b_prime, &[moved]);
        live_removed(&tracker, &[b]);

        tracker.fold_walk(&walk_batch(&[], b, &[waiting, moved, sent], 3));
        assert_eq!(
            tracker.status(&waiting.to_string()),
            Some(TxStatus::Submitted)
        );
        let accepting =
            |txid: Hash| match &tracker.state.lock().unwrap().log.records[&txid.to_string()].status
            {
                PersistedStatus::Accepted {
                    accepting_block, ..
                } => Some(accepting_block.clone()),
                _ => None,
            };
        assert_eq!(
            accepting(moved),
            Some(b_prime.to_string()),
            "the stream's move stands"
        );
        assert_eq!(
            tracker.status(&sent.to_string()),
            Some(TxStatus::Submitted),
            "a Send watch is the stream's"
        );

        // On a block the stream has NOT removed, the walk still moves only the
        // record it alone can speak for.
        tracker.fold_walk(&walk_batch(&[], b2, &[waiting, moved, sent], 3));
        assert_eq!(accepting(waiting), Some(b2.to_string()));
        assert_eq!(
            accepting(moved),
            Some(b_prime.to_string()),
            "an acceptance the stream made stands"
        );
        assert_eq!(
            tracker.status(&sent.to_string()),
            Some(TxStatus::Submitted),
            "a Send watch is never the walk's"
        );

        // The stream puts B back: a walk acceptance onto it is admitted again.
        let back = hb(0x64);
        tracker.watch(&back.to_string(), WatchSource::Transport);
        tracker.state.lock().unwrap().note_added(&[b.to_string()]);
        tracker.fold_walk(&walk_batch(&[], b, &[back], 3));
        assert_eq!(
            accepting(back),
            Some(b.to_string()),
            "B is on the chain again"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The one correction the walk may make to any record: the same block's
    /// own facts replace the fallback a failed `get_block` stored (time 0).
    #[test]
    fn a_walk_fact_upgrades_a_fallback_acceptance_of_the_same_block() {
        let dir = test_dir("walk-upgrade");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let (sent, x) = (hb(0x71), hb(0xE1));
        tracker.watch(&sent.to_string(), WatchSource::Send);
        tracker
            .state
            .lock()
            .unwrap()
            .on_accepted(&x.to_string(), 9_999, &[sent.to_string()], 0)
            .unwrap();
        tracker.fold_walk(&walk_batch(&[], x, &[sent], 3));
        assert!(matches!(
            tracker.status(&sent.to_string()),
            Some(TxStatus::Accepted {
                accepted_unix_ms: 883_612_800_000,
                ..
            })
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A sender lookup resolves on the page's own DAA score, exactly once,
    /// whichever arrives first.**
    #[tokio::test]
    async fn a_sender_lookup_resolves_once_either_way_round() {
        let dir = test_dir("walk-sender");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let mut events = tracker.subscribe();
        let (after, before) = (hb(0x41), hb(0x42));

        tracker.fold_walk(&walk_batch(&[], hb(0xB7), &[after], 5_150));
        tracker.note_sender_interest(&after.to_string());
        tracker.note_sender_interest(&before.to_string());
        tracker.fold_walk(&walk_batch(&[], hb(0xB7), &[before], 5_151));

        let mut resolved = Vec::new();
        while let Ok(event) = events.try_recv() {
            if let AcceptanceEvent::SenderResolvable {
                txid,
                accepting_daa_score,
            } = event
            {
                resolved.push((txid, accepting_daa_score));
            }
        }
        assert_eq!(
            resolved,
            vec![(after.to_string(), 5_150), (before.to_string(), 5_151)]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The memory's ceiling, at its edge: full holds every entry, one more
    /// evicts exactly the oldest.
    #[test]
    fn the_matched_memory_evicts_exactly_at_its_ceiling() {
        let dir = test_dir("walk-memory-edge");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let txid = |i: u32| {
            let mut bytes = [0x5F; 32];
            bytes[..4].copy_from_slice(&i.to_le_bytes());
            Hash::from_bytes(bytes)
        };
        let upto = |n: u32| (0..n).map(txid).collect::<Vec<_>>();
        tracker.fold_walk(&walk_batch(
            &[],
            hb(0xB9),
            &upto(MATCHED_MEMORY_CAPACITY as u32 - 1),
            1,
        ));
        assert_eq!(
            tracker.matched.lock().unwrap().order.len(),
            MATCHED_MEMORY_CAPACITY - 1
        );
        tracker.fold_walk(&walk_batch(
            &[],
            hb(0xB9),
            &[txid(MATCHED_MEMORY_CAPACITY as u32 - 1)],
            1,
        ));
        let memory = tracker.matched.lock().unwrap();
        assert_eq!(memory.order.len(), MATCHED_MEMORY_CAPACITY);
        assert!(
            memory.get(&txid(0).to_string()).is_some(),
            "full is not over"
        );
        drop(memory);
        tracker.fold_walk(&walk_batch(
            &[],
            hb(0xB9),
            &[txid(MATCHED_MEMORY_CAPACITY as u32)],
            1,
        ));
        let memory = tracker.matched.lock().unwrap();
        assert_eq!(memory.order.len(), MATCHED_MEMORY_CAPACITY);
        assert!(
            memory.get(&txid(0).to_string()).is_none(),
            "one over evicts the oldest"
        );
        assert!(
            memory.get(&txid(1).to_string()).is_some(),
            "and only the oldest"
        );
        drop(memory);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The off-chain set's ceiling, at its edge: full holds every block, one
    /// more forgets exactly the oldest, and a re-add leaves at once.
    #[test]
    fn the_off_chain_set_evicts_exactly_at_its_ceiling() {
        let block = |i: u32| format!("{i:064x}");
        let mut set = OffChain::default();
        for i in 0..OFF_CHAIN_CAPACITY as u32 - 1 {
            set.removed(&block(i));
        }
        assert_eq!(set.order.len(), OFF_CHAIN_CAPACITY - 1);
        set.removed(&block(OFF_CHAIN_CAPACITY as u32 - 1));
        assert_eq!(set.order.len(), OFF_CHAIN_CAPACITY);
        assert!(set.contains(&block(0)), "full is not over");
        set.removed(&block(OFF_CHAIN_CAPACITY as u32));
        assert_eq!(
            (set.order.len(), set.set.len()),
            (OFF_CHAIN_CAPACITY, OFF_CHAIN_CAPACITY)
        );
        assert!(!set.contains(&block(0)), "one over forgets the oldest");
        assert!(set.contains(&block(1)), "and only the oldest");
        set.added(&block(5));
        assert!(!set.contains(&block(5)));
        assert_eq!(set.order.len(), OFF_CHAIN_CAPACITY - 1);
    }

    /// **A sender lookup never resolves on a block the stream removed**
    /// (`consensus-auditor`): the remembered DAA score would name nobody, so
    /// the interest waits for the acceptance that stands.
    #[tokio::test]
    async fn a_sender_lookup_never_resolves_on_a_block_the_stream_removed() {
        let dir = test_dir("walk-sender-offchain");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let mut events = tracker.subscribe();
        let (tx, b, b2) = (hb(0x81), hb(0xF1), hb(0xF2));
        tracker.fold_walk(&walk_batch(&[], b, &[tx], 6_000));
        live_removed(&tracker, &[b]);
        tracker.note_sender_interest(&tx.to_string());
        assert!(events.try_recv().is_err(), "resolved on a retired block");
        tracker.fold_walk(&walk_batch(&[], b2, &[tx], 6_001));
        assert!(matches!(
            events.try_recv(),
            Ok(AcceptanceEvent::SenderResolvable {
                accepting_daa_score: 6_001,
                ..
            })
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The matched memory is the attacker-mintable set here: bounded, oldest
    /// out, and never the persisted watch log.
    #[test]
    fn the_matched_memory_is_bounded_and_never_a_watch() {
        let dir = test_dir("walk-memory");
        let tracker = AcceptanceTracker::load(dir.clone()).unwrap();
        let txids: Vec<Hash> = (0..MATCHED_MEMORY_CAPACITY as u32 + 10)
            .map(|i| {
                let mut bytes = [0x5E; 32];
                bytes[..4].copy_from_slice(&i.to_le_bytes());
                Hash::from_bytes(bytes)
            })
            .collect();
        tracker.fold_walk(&walk_batch(&[], hb(0xB8), &txids, 1));
        let memory = tracker.matched.lock().unwrap();
        assert_eq!(memory.order.len(), MATCHED_MEMORY_CAPACITY);
        assert_eq!(memory.map.len(), MATCHED_MEMORY_CAPACITY);
        assert!(
            memory.get(&txids[0].to_string()).is_none(),
            "the oldest went first"
        );
        assert!(memory.get(&txids.last().unwrap().to_string()).is_some());
        drop(memory);
        assert!(
            tracker.status(&txids[0].to_string()).is_none(),
            "remembering is not watching"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
