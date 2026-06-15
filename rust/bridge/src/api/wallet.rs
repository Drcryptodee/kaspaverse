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

use std::sync::{Mutex, PoisonError};

use kaspaverse_chain::{
    ActivityDirection as ChainDirection, ActivityMaturity as ChainMaturity, NetworkId, NetworkType,
    WalletActivityRecord, WalletEngine, WalletEvent,
};
use tokio::sync::broadcast::{self, error::RecvError};

use crate::api::error::AppError;
use crate::api::{dag, vault};
use crate::frb_generated::StreamSink;

/// BIP44 receive+change scan window, fixed for P1.5 (decision: 30 per chain —
/// covers the gap-of-20 plus headroom; grow-on-use re-scan deferred). A restore
/// of a wallet that used >30 receive addresses can miss funds past the window —
/// a documented limitation, never a silent zero.
const GAP_LIMIT: u32 = 30;

/// Direction of an activity row (mapped from the wallet framework's typed
/// transaction data). Receive-only at P1.5; outgoing/change rows arrive with
/// send (P1.6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivityDirection {
    Incoming,
    Outgoing,
    Change,
}

/// Maturity of an activity row (from `TransactionRecord::maturity()` at the
/// live DAA — never our own threshold; INV-9).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MaturityState {
    Pending,
    Confirmed,
}

/// One activity row crossing the FFI. `*_sompi` / DAA stay `u64` (Dart `BigInt`,
/// L3); public chain data only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivityRecord {
    pub txid: String,
    pub value_sompi: u64,
    pub unixtime_msec: Option<u64>,
    pub block_daa_score: u64,
    pub direction: ActivityDirection,
    pub is_coinbase: bool,
    pub maturity: MaturityState,
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

fn map_activity(record: WalletActivityRecord) -> ActivityRecord {
    ActivityRecord {
        txid: record.txid,
        value_sompi: record.value_sompi,
        unixtime_msec: record.unixtime_msec,
        block_daa_score: record.block_daa_score,
        direction: match record.direction {
            ChainDirection::Incoming => ActivityDirection::Incoming,
            ChainDirection::Outgoing => ActivityDirection::Outgoing,
            ChainDirection::Change => ActivityDirection::Change,
        },
        is_coinbase: record.is_coinbase,
        maturity: match record.maturity {
            ChainMaturity::Pending => MaturityState::Pending,
            ChainMaturity::Confirmed => MaturityState::Confirmed,
        },
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
            // seed never leaves vault.rs).
            let addresses = vault::derive_wallet_addresses(GAP_LIMIT)?;
            // Bind to the SAME wRPC client the DAG monitor uses (§0.8 / D-005).
            let monitor = dag::shared_monitor().await?;
            let engine = WalletEngine::new(
                monitor.rpc(),
                NetworkId::new(NetworkType::Mainnet),
                vault::wallet_store_path()?,
            )
            .map_err(AppError::chain)?;

            let mut events = engine.subscribe();
            engine.start(addresses).await.map_err(AppError::chain)?;
            // Keep the engine alive for the process (its Sender feeds `events`).
            *ENGINE.lock().unwrap_or_else(PoisonError::into_inner) = Some(engine);

            let (sender, _) = broadcast::channel(64);
            let fan_out = sender.clone();
            tokio::spawn(async move {
                let mut current = WalletSnapshot::default();
                loop {
                    match events.recv().await {
                        Ok(event) => {
                            fold(&mut current, event);
                            *LATEST.lock().unwrap_or_else(PoisonError::into_inner) =
                                Some(current.clone());
                            let _ = fan_out.send(current.clone());
                        }
                        // Lagged: values are absolute, so skipping ahead is safe.
                        Err(RecvError::Lagged(_)) => continue,
                        Err(RecvError::Closed) => break,
                    }
                }
            });
            Ok(sender)
        })
        .await
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
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(snapshot) => {
                    if sink.add(snapshot).is_err() {
                        break; // Dart listener gone (e.g. hot restart).
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
