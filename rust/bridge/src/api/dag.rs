//! Hello-DAG stream across the FFI. DTOs only (P0 §0.2): chain types never
//! cross the bridge; `u64` scores arrive in Dart as `BigInt` (L3); errors
//! cross as `Result`, never panics (INV-2).
//!
//! DTO shape note: a plain struct, not an enum-with-fields — FRB 2.12 maps
//! data-carrying Rust enums onto Dart via the `freezed` package, and pulling
//! that codegen ceremony into every build isn't worth it for one DTO.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use kaspaverse_chain::{
    link, AcceptanceEvent, AcceptanceTracker, DagEvent, DagMonitor, SignedTxRetention,
};
use tokio::sync::broadcast::{self, error::RecvError};

use crate::api::error::AppError;
use crate::frb_generated::StreamSink;

/// Live view of the DAG tip as seen over wRPC, streamed on every change.
/// Scores stay `u64` end-to-end (they exceed 2^53 — Dart sees `BigInt`, L3).
#[derive(Clone, Default)]
pub struct DagSnapshot {
    pub connected: bool,
    /// Node endpoint picked by the PNN resolver (`None` until first connect).
    pub endpoint: Option<String>,
    pub virtual_daa_score: Option<u64>,
    pub sink_blue_score: Option<u64>,
}

/// Snapshot fan-out, created once per process; every Dart subscription
/// (including after a hot restart) re-attaches to it.
static SNAPSHOTS: tokio::sync::OnceCell<broadcast::Sender<DagSnapshot>> =
    tokio::sync::OnceCell::const_new();
/// Latest folded state, so a fresh subscriber paints without waiting for the
/// next on-chain tick.
static LATEST: Mutex<Option<DagSnapshot>> = Mutex::new(None);

/// The one shared DagMonitor — a single wRPC client for both DAG status and
/// wallet sync (P1 §0.8 / D-005). Created + started exactly once; both
/// [`subscribe_dag_updates`] (here) and the wallet engine (via
/// [`kaspaverse_chain::DagMonitor::rpc`]) bind to this instance, so the header
/// DAA and the wallet's maturity DAA can never come from different nodes.
static MONITOR: tokio::sync::OnceCell<DagMonitor> = tokio::sync::OnceCell::const_new();

/// Get the shared, started monitor (initialising it on the first call).
pub(crate) async fn shared_monitor() -> Result<DagMonitor, AppError> {
    MONITOR
        .get_or_try_init(|| async {
            let monitor = DagMonitor::mainnet().map_err(AppError::chain)?;
            // Last-good-endpoint memory (P1.5 re-audit): main.dart initialises
            // the vault dir before the chain stream attaches, so the path is
            // available here. A miss (tests, exotic boot orders) just means the
            // first connect uses the resolver — self-healing, never fatal.
            match super::vault::endpoint_cache_path() {
                Ok(path) => monitor.set_endpoint_cache(path),
                Err(_) => log::info!("dag: no vault dir yet — endpoint cache off for this boot"),
            }
            monitor.start().await.map_err(AppError::chain)?;
            Ok::<_, AppError>(monitor)
        })
        .await
        .cloned()
}

/// The one shared acceptance tracker (V1 keystone, D-073): watch-set +
/// status fold over the VirtualChainChanged scope on the SAME monitor/socket
/// (D-005). Persisted in the app-private `chain/` dir (public data, INV-3).
static TRACKER: tokio::sync::OnceCell<Arc<AcceptanceTracker>> = tokio::sync::OnceCell::const_new();

/// Get the shared acceptance tracker, bootstrapping it on the first call:
/// load persistence, attach the VCC forward on the shared monitor, spawn the
/// tracker task (which immediately runs the reopen catch-up) and the V3
/// stall-escalation task beside it.
pub(crate) async fn shared_tracker() -> Result<Arc<AcceptanceTracker>, AppError> {
    TRACKER
        .get_or_try_init(|| async {
            let dir = super::vault::chain_store_dir()?;
            let tracker = AcceptanceTracker::load(dir).map_err(AppError::chain)?;
            let monitor = shared_monitor().await?;
            let vcc_rx = monitor.attach_acceptance();
            tracker.run(monitor.rpc(), vcc_rx, monitor.subscribe());
            log::info!("acceptance: tracker started");
            tokio::spawn(escalation_task(tracker.subscribe(), monitor));
            Ok::<_, AppError>(tracker)
        })
        .await
        .cloned()
}

/// Signed-tx retention for stall escalation (V3): the send path deposits every
/// submitted leg's signed wire form here; [`escalation_task`] takes it on the
/// tracker's one-shot `Stalled`. In-memory only — after a restart there is
/// nothing to resubmit and escalation logs an honest skip.
pub(crate) fn retention() -> &'static SignedTxRetention {
    static RETENTION: OnceLock<SignedTxRetention> = OnceLock::new();
    RETENTION.get_or_init(SignedTxRetention::default)
}

/// Sync peek at the live endpoint (submit-time provenance for retention);
/// `None` before the monitor exists or connects.
pub(crate) fn current_endpoint_url() -> Option<String> {
    MONITOR.get().and_then(|monitor| monitor.current_url())
}

/// V3 deliverable 2 — answer a real stall with evidence, exactly once per
/// txid (the tracker's `Stalled` is one-shot and the retention take is
/// destructive): resubmit the already-signed tx via ONE freshly resolved
/// node (duplicate submission is a clean idempotent error at the node), log
/// the outcome, and strike the incumbent endpoint — with network-alive
/// evidence in hand, since a fresh node just answered. NO blanket fan-out;
/// NO RBF (D-008-deferred; the node itself rebroadcasts High-priority txs
/// ~30 s and they never expire).
async fn escalation_task(mut events: broadcast::Receiver<AcceptanceEvent>, monitor: DagMonitor) {
    loop {
        match events.recv().await {
            Ok(AcceptanceEvent::Stalled { txid, waited_ms }) => {
                let Some((signed_tx, submit_url)) = retention().take(&txid) else {
                    // Restart between submit and stall, or TTL/cap eviction:
                    // resubmission is impossible and saying so beats guessing.
                    log::warn!(
                        "escalation: {txid} stalled ({waited_ms} ms) — no retained signed tx (restart?); skipping resubmit"
                    );
                    continue;
                };
                kaspaverse_chain::spans::mark_with("escalate_start", &txid);
                match link::escalate_stalled_tx(
                    &monitor.resolver(),
                    monitor.network_id(),
                    &txid,
                    signed_tx,
                    std::time::Duration::from_secs(4),
                )
                .await
                {
                    Ok(outcome) => {
                        let (via, note) = match &outcome {
                            link::EscalationOutcome::Resubmitted { via } => {
                                (via.clone(), "resubmitted".to_string())
                            }
                            link::EscalationOutcome::AlreadyKnown { via, detail } => {
                                (via.clone(), format!("already known ({detail})"))
                            }
                        };
                        log::info!("escalation: {txid} via {via} — {note}");
                        kaspaverse_chain::spans::mark_with("escalate_ok", &txid);
                        // The fresh node answered → network alive → the
                        // SUBMIT-TIME endpoint earned this strike (it took
                        // the submit that stalled; whoever the socket has
                        // re-raced to since is innocent — control-group rule,
                        // consensus-audit finding).
                        match &submit_url {
                            Some(url) => monitor.strike_endpoint(url, "stalled submit"),
                            None => {
                                log::info!("escalation: {txid} submit endpoint unknown — no strike")
                            }
                        }
                    }
                    Err(e) => {
                        // Offline or the fresh node refused: no network-alive
                        // evidence, no strike — honesty over blame.
                        log::warn!("escalation: {txid} failed: {e}");
                        kaspaverse_chain::spans::mark_with("escalate_failed", &txid);
                    }
                }
            }
            Ok(_) => {}
            Err(RecvError::Lagged(_)) => continue,
            Err(RecvError::Closed) => break,
        }
    }
}

/// Sync peek at the tracker for non-async call sites (the transport fold);
/// `None` until the first [`shared_tracker`] bootstrap completes.
pub(crate) fn tracker_handle() -> Option<Arc<AcceptanceTracker>> {
    TRACKER.get().cloned()
}

/// One span marker crossing the FFI (V1 observability — findings-register
/// item 6, founder-ratified): PUBLIC data only (marker name, optional txid,
/// timestamp). This is the L40-proof lane: Dart prints/collects these on any
/// build flavor; the perf harness reads the same query.
#[derive(Clone, Debug)]
pub struct SpanMarkerDto {
    pub marker: String,
    /// A txid or small public value (e.g. gap minutes); `None` for bare marks.
    pub detail: Option<String>,
    pub unix_ms: u64,
}

/// The session's recorded span markers, oldest first. Pull surface — the
/// harness and the debug screen poll it; nothing streams.
pub fn perf_spans() -> Vec<SpanMarkerDto> {
    kaspaverse_chain::spans::snapshot()
        .into_iter()
        .map(|s| SpanMarkerDto {
            marker: s.marker,
            detail: s.detail,
            unix_ms: s.unix_ms,
        })
        .collect()
}

/// Background grace-drop (PERFORMANCE_BUDGET battery posture): close the wRPC
/// socket and stop the retry loop. Dart's ChainService calls this ~30 s after
/// the app backgrounds. A no-op before the first connection exists.
pub async fn dag_pause() -> Result<(), AppError> {
    if let Some(monitor) = MONITOR.get() {
        monitor.pause().await.map_err(AppError::chain)?;
    }
    Ok(())
}

/// Foreground resume after a grace-drop: reconnect, preferring the last-good
/// endpoint (fast path), resolver fallback. No-op while already connected.
pub async fn dag_resume() -> Result<(), AppError> {
    if let Some(monitor) = MONITOR.get() {
        monitor.resume().await.map_err(AppError::chain)?;
    }
    Ok(())
}

/// Honest-liveness snapshot for the connection-health sheet AND the foreground
/// watchdog (P3/D-068). A PULL surface (not the stream): the sheet paints it on
/// open and the watchdog polls it. `last_block_age_secs` is the load-bearing
/// field — a healthy mainnet keeps it near zero (~10 blocks/s); a large value
/// while foreground means a silently dead socket (the midnight DAA stall), the
/// watchdog's trigger to [`dag_reconnect`]. `None` before the first connect.
#[derive(Clone, Default)]
pub struct DagStatusDto {
    pub connected: bool,
    pub endpoint: Option<String>,
    pub last_block_age_secs: Option<u64>,
    pub virtual_daa_score: Option<u64>,
}

/// Read the current connection health (see [`DagStatusDto`]). Endpoint + DAA
/// come from the folded snapshot; connected + block-age come straight from the
/// monitor so a silently dead socket (still `connected` in the snapshot) is
/// caught by a growing block-age.
pub fn dag_status() -> DagStatusDto {
    let latest = LATEST
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
        .unwrap_or_default();
    let (connected, last_block_age_secs) = match MONITOR.get() {
        Some(monitor) => (monitor.is_connected(), monitor.last_block_age_secs()),
        None => (false, None),
    };
    DagStatusDto {
        connected,
        endpoint: latest.endpoint,
        last_block_age_secs,
        virtual_daa_score: latest.virtual_daa_score,
    }
}

/// Force a fresh wRPC connection — the Reconnect button and the watchdog's
/// recovery (P3/D-068). Hard-drops even a socket the client believes is alive,
/// then re-races (the cached endpoint is candidate 0 — the fast path). A no-op
/// before the first connect exists (nothing to bounce).
///
/// `stalled = true` when the CALLER has failure evidence against the current
/// endpoint (the watchdog's 30 s block silence): it becomes a pending strike
/// the race commits only if another healthy node answers (V3 demotion,
/// control-group rule). The manual Reconnect button passes `false` — bouncing
/// a healthy node must never demote it.
pub async fn dag_reconnect(stalled: bool) -> Result<(), AppError> {
    if let Some(monitor) = MONITOR.get() {
        monitor.reconnect(stalled).await.map_err(AppError::chain)?;
    }
    Ok(())
}

/// Minimum spacing between pull-heal resyncs — a swipe is a cheap gesture and
/// a full reconnect + 60-address rescan is not; repeated pulls inside the
/// window re-serve the fold without bouncing the socket.
const RESYNC_MIN_INTERVAL_SECS: u64 = 20;

/// V3 register item 12: the pull heal asks the NODE. A swipe-to-refresh calls
/// this to force a resync — a hard reconnect through the race, which lands in
/// wallet-core's `UtxoProcStart` and a fresh address scan, exactly the
/// detection path a kill/relaunch used to be needed for. Rate-limited; returns
/// `true` when a resync was actually triggered, `false` when the window
/// swallowed it (the caller still re-serves the fold — delivery heal — so a
/// swallowed pull is never a dead gesture).
pub async fn dag_resync() -> Result<bool, AppError> {
    static LAST_RESYNC: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let last = LAST_RESYNC.load(Ordering::Relaxed);
    if now.saturating_sub(last) < RESYNC_MIN_INTERVAL_SECS {
        log::info!(
            "dag: resync request inside the {RESYNC_MIN_INTERVAL_SECS}s window — re-serve only"
        );
        return Ok(false);
    }
    LAST_RESYNC.store(now, Ordering::Relaxed);
    if let Some(monitor) = MONITOR.get() {
        log::info!("dag: pull-heal resync — forcing reconnect + rescan");
        monitor.reconnect(false).await.map_err(AppError::chain)?;
    }
    Ok(true)
}

/// Events carry absolute values, so folding is plain assignment (INV-9:
/// nothing is computed locally).
fn fold(snapshot: &mut DagSnapshot, event: DagEvent) {
    match event {
        DagEvent::Connected { url } => {
            snapshot.connected = true;
            snapshot.endpoint = url;
        }
        DagEvent::Disconnected => snapshot.connected = false,
        DagEvent::VirtualDaaScore(value) => snapshot.virtual_daa_score = Some(value),
        DagEvent::SinkBlueScore(value) => snapshot.sink_blue_score = Some(value),
    }
}

/// First call connects to mainnet and spawns the folder task; the monitor's
/// own event task keeps the connection alive for the life of the process.
async fn snapshots() -> Result<&'static broadcast::Sender<DagSnapshot>, AppError> {
    SNAPSHOTS
        .get_or_try_init(|| async {
            // Created + started once in shared_monitor(); we subscribe right
            // after. start() only *initiates* an async connect (non-blocking,
            // ConnectStrategy::Retry) — Connected fires a network round-trip
            // later, long after this subscribe, so it is not missed. The wallet
            // engine binds to this same monitor via its rpc() (§0.8 / D-005).
            let monitor = shared_monitor().await?;
            let mut events = monitor.subscribe();
            let (sender, _) = broadcast::channel(64);
            let fan_out = sender.clone();
            tokio::spawn(async move {
                let mut current = DagSnapshot::default();
                loop {
                    match events.recv().await {
                        Ok(event) => {
                            fold(&mut current, event);
                            *LATEST
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner) =
                                Some(current.clone());
                            // Send fails only with zero subscribers — fine.
                            let _ = fan_out.send(current.clone());
                        }
                        // Lagged: folder fell behind the event buffer; values
                        // are absolute, so skipping ahead is safe.
                        Err(RecvError::Lagged(_)) => continue,
                        Err(RecvError::Closed) => break,
                    }
                }
            });
            Ok(sender)
        })
        .await
}

/// Subscribe to live DAG snapshots from mainnet. The first call connects;
/// later calls share the same connection. Each stream ends only when its
/// Dart listener goes away.
pub async fn subscribe_dag_updates(sink: StreamSink<DagSnapshot>) -> Result<(), AppError> {
    let sender = snapshots().await?;
    // Subscribe while holding the LATEST lock: the folder updates LATEST
    // *before* broadcasting (under the same lock), so everything arriving on
    // `receiver` is >= the snapshot we deliver first — values never regress
    // on (re)attach. Plain Mutex, no await inside the block.
    let (mut receiver, latest) = {
        let guard = LATEST
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        (sender.subscribe(), guard.clone())
    };
    if let Some(snapshot) = latest {
        let _ = sink.add(snapshot);
    }
    // Runs on FRB's tokio runtime; exits when the Dart listener goes away
    // (sink.add fails) — e.g. on hot restart, leaving the connection up.
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(snapshot) => {
                    if sink.add(snapshot).is_err() {
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

    #[test]
    fn folds_events_into_snapshot() {
        let mut snapshot = DagSnapshot::default();
        fold(
            &mut snapshot,
            DagEvent::Connected {
                url: Some("wss://node.example/borsh".into()),
            },
        );
        fold(&mut snapshot, DagEvent::VirtualDaaScore(458_174_109));
        fold(&mut snapshot, DagEvent::SinkBlueScore(456_290_012));
        assert!(snapshot.connected);
        assert_eq!(
            snapshot.endpoint.as_deref(),
            Some("wss://node.example/borsh")
        );
        assert_eq!(snapshot.virtual_daa_score, Some(458_174_109));
        assert_eq!(snapshot.sink_blue_score, Some(456_290_012));

        // Disconnect keeps the last-seen scores but drops the link flag.
        fold(&mut snapshot, DagEvent::Disconnected);
        assert!(!snapshot.connected);
        assert_eq!(snapshot.virtual_daa_score, Some(458_174_109));
    }
}
