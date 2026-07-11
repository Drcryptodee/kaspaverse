//! Wallet sync across the FFI: balance + activity for the vault's derived
//! address window, over the wRPC client SHARED with the DAG monitor (P1 §0.8 /
//! D-005 — one client, one `UtxoProcessor`). DTOs only (INV-2: `Result`, never
//! a panic). `u64` sompi crosses as Dart `BigInt` (L3); KAS conversion is a
//! render-layer concern, never here.
//!
//! INV-9 — balance and maturity come from the pinned crates via
//! [`kaspaverse_chain::WalletEngine`]; this module only maps the chain-layer
//! event onto a DTO and folds (plain assignment, like `dag.rs`).
//!
//! INV-1 — the engine watches PUBLIC addresses derived inside `vault.rs`
//! (`vault::derive_wallet_addresses`); the seed/keychain never reach this
//! module. INV-3 — the activity store is an app-private file of public chain
//! data, owned by the chain layer.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};

use kaspaverse_chain::{
    AcceptanceEvent, ActivityDirection as ChainDirection, ActivityMaturity as ChainMaturity,
    NetworkId, NetworkType, TxStatus, WalletActivityRecord, WalletEngine, WalletEvent,
};
use tokio::sync::broadcast::{self, error::RecvError};

use crate::api::error::AppError;
use crate::api::{dag, vault};
use crate::frb_generated::StreamSink;

/// BIP44 receive+change scan window, fixed for P1.5 (decision: 30 per chain —
/// covers the gap-of-20 plus headroom; grow-on-use re-scan deferred). A restore
/// of a wallet that used >30 receive addresses can miss funds past the window —
/// a documented limitation, never a silent zero.
pub(crate) const GAP_LIMIT: u32 = 30;

/// The change-branch window to derive/watch/register: the fixed [`GAP_LIMIT`]
/// widened to cover every change index used so far (the persisted cursor, D-041).
/// The SINGLE source for the change window — both the sync engine's initial scan
/// and a send's signer registration call it, so the watched set and the signer
/// can never drift (risk #5). Receive stays fixed at `GAP_LIMIT`.
pub(crate) fn change_window() -> u32 {
    GAP_LIMIT.max(vault::change_cursor().saturating_add(1))
}

/// Direction of an activity row (mapped from the wallet framework's typed
/// transaction data). Receive-only at P1.5; outgoing/change rows arrive with
/// send (P1.6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivityDirection {
    Incoming,
    Outgoing,
    Change,
}

/// Maturity of an activity row. `Pending`/`Confirmed` come from wallet-core
/// (`TransactionRecord::maturity()` at the live DAA — never our own
/// threshold; INV-9). `Accepted` is the V1 acceptance-spine overlay: the
/// chain accepted the txid (VirtualChainChanged, node-read) but wallet-core
/// hasn't folded it yet — this kills the "Pending" lie the V0 baselines
/// measured (≥15 s past on-chain acceptance). V1 renders it on the existing
/// confirmed chip (semantically identical for spends); V2's three-state chip
/// differentiates. `Unknown` is the V2b cold-start honesty state (finding
/// 13): a receive folded before the processor has live DAA is unresolvable —
/// it renders quiet (no chip), never a fake Pending streaming a huge counter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MaturityState {
    Pending,
    Accepted,
    Confirmed,
    Unknown,
}

/// One activity row crossing the FFI. `*_sompi` / DAA stay `u64` (Dart `BigInt`,
/// L3); public chain data only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivityRecord {
    pub txid: String,
    pub value_sompi: u64,
    pub unixtime_msec: Option<u64>,
    pub block_daa_score: u64,
    /// DAA score at which the DAG accepted this spend (`None` for a receive or a
    /// not-yet-accepted spend) — the honest anchor for a send's confirmation-
    /// depth counter (`current_daa − accepted_daa_score`), where
    /// `block_daa_score` on a send is submit time and would overstate.
    pub accepted_daa_score: Option<u64>,
    pub direction: ActivityDirection,
    pub is_coinbase: bool,
    pub maturity: MaturityState,
    /// V2 chip honesty: the tracker has seen no acceptance for this SUBMITTED
    /// txid past the stall threshold (Send-sourced watches only — V1 signal
    /// #3). Rides alongside `maturity` (a stalled row is still Pending);
    /// never persisted — recomputed from the live overrides on every fold.
    pub stalled: bool,
}

/// Live wallet state, streamed on every change. Balances are `Option` so the UI
/// can tell "not synced yet" (`None` → DS-1 unknown `—`) from a real, live zero
/// (`Some(0)` → an empty wallet shows `0.00000000`, never unknown). A plain
/// struct, not an enum-with-fields (FRB DTO note, `dag.rs`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WalletSnapshot {
    pub connected: bool,
    /// Between `UtxoProcStart` and the first balance — the initial scan.
    pub syncing: bool,
    /// The connected node has no UTXO index (INV-8 honest degrade).
    pub utxo_index_missing: bool,
    pub mature_sompi: Option<u64>,
    pub pending_sompi: Option<u64>,
    pub outgoing_sompi: Option<u64>,
    /// Newest-first, capped by the chain layer.
    pub activity: Vec<ActivityRecord>,
    pub error: Option<String>,
}

/// The process-lifetime sync engine, kept alive here (its broadcast Sender must
/// outlive the fold task). One vault per process at P1 (a created/restored vault
/// is fixed for the install; switching needs a restart — documented).
static ENGINE: Mutex<Option<WalletEngine>> = Mutex::new(None);

/// Snapshot fan-out, created once; every Dart subscription (incl. after a hot
/// restart) re-attaches to it.
static SNAPSHOTS: tokio::sync::OnceCell<broadcast::Sender<WalletSnapshot>> =
    tokio::sync::OnceCell::const_new();
/// Latest folded state, so a fresh subscriber paints immediately.
static LATEST: Mutex<Option<WalletSnapshot>> = Mutex::new(None);

/// The live sync engine handle, for send construction (P1.6 [`crate::api::send`]).
/// `None` until the home screen has subscribed (the engine starts lazily on the
/// first subscribe) — a send before then errors honestly.
pub(crate) fn engine_handle() -> Option<WalletEngine> {
    ENGINE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

/// The latest folded snapshot, for send's "insufficient vs still-confirming"
/// classification (reads `pending`/`mature` — nothing recomputed, INV-9).
pub(crate) fn latest_snapshot() -> Option<WalletSnapshot> {
    LATEST
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

fn map_activity(record: WalletActivityRecord) -> ActivityRecord {
    ActivityRecord {
        txid: record.txid,
        value_sompi: record.value_sompi,
        unixtime_msec: record.unixtime_msec,
        block_daa_score: record.block_daa_score,
        accepted_daa_score: record.accepted_daa_score,
        direction: match record.direction {
            ChainDirection::Incoming => ActivityDirection::Incoming,
            ChainDirection::Outgoing => ActivityDirection::Outgoing,
            ChainDirection::Change => ActivityDirection::Change,
        },
        is_coinbase: record.is_coinbase,
        maturity: match record.maturity {
            ChainMaturity::Pending => MaturityState::Pending,
            ChainMaturity::Confirmed => MaturityState::Confirmed,
            ChainMaturity::Unknown => MaturityState::Unknown,
        },
        stalled: false,
    }
}

/// The V1 acceptance overlay: what the tracker knows about a txid, folded
/// onto the wallet-core maturity. Rules (V1 design, founder-nodded):
/// tracker Accepted upgrades Pending but never downgrades a wallet-core
/// Confirmed; tracker Confirmed (blue-score depth, node-read) confirms;
/// Displaced drops the row to Pending — even from Confirmed — because its
/// accepting block left the selected chain (honesty over comfort; wallet-core
/// converges via its own reorg handling). Submitted/Stalled change nothing
/// here (stall surfaces in V3). An `Unknown` row (V2b — no live DAA yet)
/// upgrades on the same rules: the tracker's node-read knowledge is exactly
/// what resolves the cold-start unknown.
fn overlaid(current: MaturityState, status: &TxStatus) -> MaturityState {
    match status {
        TxStatus::Accepted { .. } => match current {
            MaturityState::Confirmed => MaturityState::Confirmed,
            _ => MaturityState::Accepted,
        },
        TxStatus::Confirmed { .. } => MaturityState::Confirmed,
        TxStatus::Displaced => MaturityState::Pending,
        TxStatus::Submitted | TxStatus::Stalled { .. } => current,
    }
}

/// Apply the tracker overrides to every matching activity row (cheap: the
/// list is capped by the chain layer, the map by the tracker's watch cap).
/// `stalled` is recomputed for EVERY row — a row whose override cleared
/// (acceptance landed, or the watch pruned) must drop the flag, never wear
/// it stale.
fn apply_overrides(snapshot: &mut WalletSnapshot, overrides: &HashMap<String, TxStatus>) {
    for row in &mut snapshot.activity {
        let status = overrides.get(&row.txid);
        if let Some(status) = status {
            row.maturity = overlaid(row.maturity, status);
        }
        row.stalled = matches!(status, Some(TxStatus::Stalled { .. }));
    }
}

/// Fold an absolute chain-layer event into the snapshot — plain assignment
/// (INV-9: nothing computed here; balance/maturity already decided by the pin).
fn fold(snapshot: &mut WalletSnapshot, event: WalletEvent) {
    match event {
        WalletEvent::Connected { .. } => {
            snapshot.connected = true;
            snapshot.error = None;
        }
        WalletEvent::Disconnected => snapshot.connected = false,
        WalletEvent::Syncing => snapshot.syncing = true,
        WalletEvent::UtxoIndexMissing { .. } => snapshot.utxo_index_missing = true,
        WalletEvent::Balance {
            mature,
            pending,
            outgoing,
        } => {
            // A real balance arrived (even all-zero): sync resolved. An empty
            // wallet becomes a live `Some(0)`, never unknown / skeleton-forever.
            snapshot.mature_sompi = Some(mature);
            snapshot.pending_sompi = Some(pending);
            snapshot.outgoing_sompi = Some(outgoing);
            snapshot.syncing = false;
            // We computed a balance, so the node's index works — clear any
            // stale degrade flag from a previous (bad) node.
            snapshot.utxo_index_missing = false;
        }
        WalletEvent::Activity(records) => {
            snapshot.activity = records.into_iter().map(map_activity).collect();
        }
        WalletEvent::Error(message) => snapshot.error = Some(message),
    }
}

/// Initialise (once) the shared sync engine over the shared wRPC client and the
/// snapshot fan-out. Requires an unlocked vault (address derivation) — the
/// caller (post-unlock home screen) guarantees this.
async fn snapshots() -> Result<&'static broadcast::Sender<WalletSnapshot>, AppError> {
    SNAPSHOTS
        .get_or_try_init(|| async {
            // Derive the public watch set from the unlocked vault (INV-1: the
            // seed never leaves vault.rs). Change widens with the cursor (D-041)
            // so previously-used change addresses are re-watched on restart; the
            // change subset lets the engine tell our own returning change from a
            // real deposit.
            let (addresses, change_addresses) =
                vault::derive_wallet_addresses(GAP_LIMIT, change_window())?;
            // Bind to the SAME wRPC client the DAG monitor uses (§0.8 / D-005).
            let monitor = dag::shared_monitor().await?;
            let engine = WalletEngine::new(
                monitor.rpc(),
                NetworkId::new(NetworkType::Mainnet),
                vault::wallet_store_path()?,
            )
            .map_err(AppError::chain)?;

            let mut events = engine.subscribe();
            engine
                .start(addresses, change_addresses)
                .await
                .map_err(AppError::chain)?;
            // Keep the engine alive for the process (its Sender feeds `events`).
            *ENGINE.lock().unwrap_or_else(PoisonError::into_inner) = Some(engine);

            // V1 consumer #1: the acceptance tracker's events overlay the
            // snapshot the instant the chain answers — the wallet no longer
            // waits for wallet-core to notice (the V0 ≥15 s "Pending" lie).
            // Soft dependency: a tracker bootstrap failure degrades to the
            // pre-V1 behavior, never blocks the wallet.
            let tracker = match super::dag::shared_tracker().await {
                Ok(tracker) => Some(tracker),
                Err(e) => {
                    log::warn!(
                        "wallet: acceptance tracker unavailable ({}) — status overlay off",
                        e.message
                    );
                    None
                }
            };
            let mut acceptance_rx = tracker.as_ref().map(|t| t.subscribe());

            let (sender, _) = broadcast::channel(64);
            let fan_out = sender.clone();
            tokio::spawn(async move {
                let mut current = WalletSnapshot::default();
                // txid → last tracker status; entries clear when the tracker
                // prunes a watch (status() = None → wallet-core truth resumes).
                let mut overrides: HashMap<String, TxStatus> = HashMap::new();
                loop {
                    tokio::select! {
                        event = events.recv() => {
                            match event {
                                Ok(event) => {
                                    if matches!(event, WalletEvent::Balance { .. }) {
                                        // V1 span: a real sync completed — the
                                        // resume→resynced row pairs this with
                                        // the last `resume_start`.
                                        kaspaverse_chain::spans::mark("wallet_balance");
                                    }
                                    let refresh_rows = matches!(event, WalletEvent::Activity(_));
                                    fold(&mut current, event);
                                    // Restart heal (2026-07-09 sitting): after a
                                    // restart wallet-core re-files old sends as
                                    // Pending (IDEAS:206) and no tracker EVENT
                                    // will fire for an already-settled watch —
                                    // so on every activity refresh, PULL the
                                    // tracker's answer for any Pending row the
                                    // overrides can't explain.
                                    if refresh_rows {
                                        if let Some(tracker) = tracker.as_ref() {
                                            for row in &current.activity {
                                                if row.maturity == MaturityState::Pending
                                                    && !overrides.contains_key(&row.txid)
                                                {
                                                    if let Some(status) = tracker.status(&row.txid) {
                                                        overrides.insert(row.txid.clone(), status);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    apply_overrides(&mut current, &overrides);
                                    *LATEST.lock().unwrap_or_else(PoisonError::into_inner) =
                                        Some(current.clone());
                                    // Counts only (INV-3). The V2 sitting saw
                                    // live sends recorded by the chain layer
                                    // yet missing on the glass — this line +
                                    // the receiver count convict which side
                                    // of the fan-out dropped them.
                                    if refresh_rows {
                                        log::info!(
                                            "wallet: activity fold rows={} receivers={}",
                                            current.activity.len(),
                                            fan_out.receiver_count()
                                        );
                                    }
                                    let _ = fan_out.send(current.clone());
                                }
                                // Lagged: values are absolute — skipping ahead is safe.
                                Err(RecvError::Lagged(_)) => continue,
                                Err(RecvError::Closed) => break,
                            }
                        }
                        acceptance = async {
                            // Guarded by `if` below — unwrap is unreachable otherwise.
                            acceptance_rx.as_mut().unwrap().recv().await
                        }, if acceptance_rx.is_some() => {
                            match acceptance {
                                Ok(event) => {
                                    let txid = match &event {
                                        AcceptanceEvent::Accepted { txid }
                                        | AcceptanceEvent::Confirmed { txid, .. }
                                        | AcceptanceEvent::Displaced { txid }
                                        | AcceptanceEvent::DisplacedElapsed { txid }
                                        | AcceptanceEvent::Stalled { txid, .. } => txid.clone(),
                                    };
                                    // Re-read the tracker's CURRENT status (the
                                    // event is a change signal, not the state).
                                    match tracker.as_ref().and_then(|t| t.status(&txid)) {
                                        Some(status) => {
                                            overrides.insert(txid, status);
                                        }
                                        None => {
                                            overrides.remove(&txid);
                                        }
                                    }
                                    apply_overrides(&mut current, &overrides);
                                    *LATEST.lock().unwrap_or_else(PoisonError::into_inner) =
                                        Some(current.clone());
                                    let _ = fan_out.send(current.clone());
                                }
                                Err(RecvError::Lagged(_)) => continue,
                                Err(RecvError::Closed) => {
                                    acceptance_rx = None;
                                }
                            }
                        }
                    }
                }
            });
            Ok(sender)
        })
        .await
}

/// The latest folded snapshot as a PULL (V2 sitting: the founder's
/// swipe-to-refresh; also the stream-freeze diagnostic — a pull that shows a
/// row the stream missed convicts the delivery lane, not the fold). `None`
/// until the engine has folded anything.
pub fn wallet_snapshot_now() -> Option<WalletSnapshot> {
    latest_snapshot()
}

/// A Dart-side display-state marker routed through the ONE build-flavor-proof
/// log lane (L53 — profile builds drop Dart prints). Markers are OUR OWN
/// short state constants + counts, never content (INV-3); clamped defensively.
pub fn ui_mark(marker: String) {
    let m: String = marker.chars().take(64).collect();
    log::info!("glass: {m}");
}

/// Subscribe to live wallet snapshots (balance + activity) for the unlocked
/// vault's addresses. The first call starts the sync engine; later calls share
/// it. Errors if the vault is locked (the Dart side retries after unlock).
pub async fn subscribe_wallet_updates(sink: StreamSink<WalletSnapshot>) -> Result<(), AppError> {
    let sender = snapshots().await?;
    // Subscribe while holding LATEST: the fold task updates LATEST *before*
    // broadcasting (same lock), so everything on `receiver` is >= the snapshot
    // we deliver first — values never regress on (re)attach (mirrors dag.rs).
    let (mut receiver, latest) = {
        let guard = LATEST.lock().unwrap_or_else(PoisonError::into_inner);
        (sender.subscribe(), guard.clone())
    };
    if let Some(snapshot) = latest {
        let _ = sink.add(snapshot);
    }
    log::info!("wallet: snapshot subscriber attached");
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(snapshot) => {
                    if sink.add(snapshot).is_err() {
                        // Dart listener gone (e.g. hot restart). Logged so a
                        // glass that stops updating is diagnosable from the
                        // liblog lane (V2 sitting: live send rows missing).
                        log::warn!("wallet: snapshot sink detached — forwarding stopped");
                        break;
                    }
                }
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(daa: u64) -> WalletActivityRecord {
        WalletActivityRecord {
            txid: "a".repeat(64),
            value_sompi: 1_000,
            unixtime_msec: Some(1),
            block_daa_score: daa,
            accepted_daa_score: None,
            direction: ChainDirection::Incoming,
            is_coinbase: false,
            maturity: ChainMaturity::Pending,
        }
    }

    #[test]
    fn empty_wallet_balance_is_a_live_zero_not_unknown() {
        let mut snapshot = WalletSnapshot::default();
        assert_eq!(snapshot.mature_sompi, None, "starts unknown");
        fold(&mut snapshot, WalletEvent::Syncing);
        assert!(snapshot.syncing);

        fold(
            &mut snapshot,
            WalletEvent::Balance {
                mature: 0,
                pending: 0,
                outgoing: 0,
            },
        );
        // The critical bar: a synced empty wallet is Some(0) (live zero), not
        // None (unknown), and no longer syncing.
        assert_eq!(snapshot.mature_sompi, Some(0));
        assert_eq!(snapshot.pending_sompi, Some(0));
        assert!(!snapshot.syncing);
    }

    #[test]
    fn folds_balance_and_retains_it_across_disconnect() {
        let mut snapshot = WalletSnapshot::default();
        fold(&mut snapshot, WalletEvent::Connected { url: None });
        fold(
            &mut snapshot,
            WalletEvent::Balance {
                mature: 12_300_000_000,
                pending: 5_000_000,
                outgoing: 0,
            },
        );
        assert!(snapshot.connected);
        assert_eq!(snapshot.mature_sompi, Some(12_300_000_000));
        assert_eq!(snapshot.pending_sompi, Some(5_000_000));

        // A dropped link clears `connected` but keeps last-known balance (DS-1
        // dims it with its age; never blanks to unknown).
        fold(&mut snapshot, WalletEvent::Disconnected);
        assert!(!snapshot.connected);
        assert_eq!(snapshot.mature_sompi, Some(12_300_000_000));
    }

    #[test]
    fn utxo_index_missing_sets_then_clears_on_a_real_balance() {
        let mut snapshot = WalletSnapshot::default();
        fold(&mut snapshot, WalletEvent::UtxoIndexMissing { url: None });
        assert!(
            snapshot.utxo_index_missing,
            "honest degrade flag set (INV-8)"
        );

        // Resolver rotates to an indexed node → a balance arrives → flag clears.
        fold(
            &mut snapshot,
            WalletEvent::Balance {
                mature: 1,
                pending: 0,
                outgoing: 0,
            },
        );
        assert!(!snapshot.utxo_index_missing);
    }

    /// The V1 overlay law: tracker truth upgrades Pending the instant the
    /// chain answers, never downgrades wallet-core Confirmed (except a real
    /// displacement, which must read Pending again — honesty over comfort).
    #[test]
    fn acceptance_overlay_upgrades_never_downgrades_except_displacement() {
        use MaturityState::*;
        // Accepted upgrades Pending, leaves Confirmed alone.
        assert_eq!(
            overlaid(Pending, &TxStatus::Accepted { blue_depth: 3 }),
            Accepted
        );
        assert_eq!(
            overlaid(Confirmed, &TxStatus::Accepted { blue_depth: 3 }),
            Confirmed
        );
        // Tracker-confirmed (blue-score depth, node-read) confirms.
        assert_eq!(
            overlaid(Pending, &TxStatus::Confirmed { blue_depth: 120 }),
            Confirmed
        );
        // Displacement drops ANY state to Pending.
        assert_eq!(overlaid(Confirmed, &TxStatus::Displaced), Pending);
        assert_eq!(overlaid(Accepted, &TxStatus::Displaced), Pending);
        // Submitted/Stalled change nothing at this surface.
        assert_eq!(overlaid(Pending, &TxStatus::Submitted), Pending);
        assert_eq!(
            overlaid(Confirmed, &TxStatus::Stalled { waited_ms: 90_000 }),
            Confirmed
        );
    }

    #[test]
    fn overrides_apply_to_matching_rows_and_survive_activity_refolds() {
        let mut snapshot = WalletSnapshot::default();
        fold(&mut snapshot, WalletEvent::Activity(vec![row(100)]));
        let txid = snapshot.activity[0].txid.clone();
        assert_eq!(snapshot.activity[0].maturity, MaturityState::Pending);

        let mut overrides = HashMap::new();
        overrides.insert(txid, TxStatus::Accepted { blue_depth: 1 });
        apply_overrides(&mut snapshot, &overrides);
        assert_eq!(snapshot.activity[0].maturity, MaturityState::Accepted);

        // A fresh Activity fold resets rows from wallet-core — re-applying
        // the overrides (as the task does after every fold) restores truth.
        let mut unwatched = row(50);
        unwatched.txid = "b".repeat(64);
        fold(
            &mut snapshot,
            WalletEvent::Activity(vec![row(100), unwatched]),
        );
        assert_eq!(snapshot.activity[0].maturity, MaturityState::Pending);
        apply_overrides(&mut snapshot, &overrides);
        assert_eq!(snapshot.activity[0].maturity, MaturityState::Accepted);
        assert_eq!(
            snapshot.activity[1].maturity,
            MaturityState::Pending,
            "unwatched rows untouched"
        );
    }

    #[test]
    fn folds_activity_and_maps_fields() {
        let mut snapshot = WalletSnapshot::default();
        fold(
            &mut snapshot,
            WalletEvent::Activity(vec![row(100), row(50)]),
        );
        assert_eq!(snapshot.activity.len(), 2);
        let first = &snapshot.activity[0];
        assert_eq!(first.direction, ActivityDirection::Incoming);
        assert_eq!(first.maturity, MaturityState::Pending);
        assert_eq!(first.value_sompi, 1_000);
        assert_eq!(first.txid.len(), 64);
        assert!(!first.is_coinbase);
    }
}
