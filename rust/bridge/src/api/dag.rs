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

/// The stored node pin, cached (`(url, dropped)`).
///
/// [`dag_status`] must answer `pinned_node` **before** `MONITOR` exists — it
/// is a `OnceCell` initialised on first stream attach, and the Dart link poll
/// runs in exactly that cold window. Without this it returned `None` there and
/// clobbered a settings surface that had just painted the real pin, reading
/// "public node discovery" while a pin sat on disk (wallet-security audit) —
/// the precise lie `pinned_node` exists to prevent.
///
/// Cached because `dag_status` is a poll documented to take no I/O in its
/// steady state: one small read per process, re-read only after a write.
static STORED_PIN: Mutex<Option<(Option<String>, bool)>> = Mutex::new(None);

/// `(pinned url, dropped)` from disk — see [`STORED_PIN`].
fn stored_pin() -> (Option<String>, bool) {
    let mut slot = STORED_PIN
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(cached) = slot.as_ref() {
        return cached.clone();
    }
    let read = match super::vault::node_config_dir() {
        Ok(dir) => {
            let (config, dropped) = kaspaverse_chain::NodeConfig::load_reporting(&dir);
            (config.url, dropped)
        }
        Err(_) => (None, false),
    };
    *slot = Some(read.clone());
    read
}

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
            // D-187: the user's pin is read BEFORE the first connect, so a
            // pinned wallet never touches the resolver — not even once at
            // boot. A miss (no vault dir yet) reads as discovery, which is
            // the default and the safe degradation.
            // Never drop a pin in silence (ffi-leak audit): everything else
            // here goes to structural lengths to make substitution impossible,
            // so the arms that CAN substitute must at least say so. The vault
            // miss is reachable only for a wallet with no keys and no funds,
            // which is why it degrades rather than refusing to start.
            if let Err(e) = super::vault::node_config_dir() {
                log::warn!(
                    "dag: no vault dir ({}) — cannot read the node pin; using node discovery",
                    e.message
                );
            }
            let (pinned, dropped) = stored_pin();
            if dropped {
                log::warn!("dag: the stored node pin was unreadable and has been dropped");
            }
            if pinned.is_some() {
                log::info!("dag: starting against the user's pinned node");
            }
            let monitor = DagMonitor::mainnet_with_node(pinned).map_err(AppError::chain)?;
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
                        // `via` is a resolver-supplied URL that skipped the
                        // race's intake guard (this lane dials it directly) —
                        // sanitize before the log lane (PB-024; R3
                        // wallet-security delta nit).
                        // HOST only (§19 drain): `sanitize_node_text` strips
                        // control characters but NOT the URL itself, so this
                        // line carried the whole resolver-supplied endpoint.
                        // `via` is log-only — the strike below keys on
                        // `submit_url`, which is untouched.
                        log::info!(
                            "escalation: {txid} via {} — {note}",
                            kaspaverse_chain::link::sanitize_node_text(
                                kaspaverse_chain::link::endpoint_host(&via)
                            )
                        );
                        kaspaverse_chain::spans::mark_with("escalate_ok", &txid);
                        // The fresh node answered → network alive → the
                        // SUBMIT-TIME endpoint earned this strike (it took
                        // the submit that stalled; whoever the socket has
                        // re-raced to since is innocent — control-group rule,
                        // consensus-audit finding).
                        match &submit_url {
                            Some(url) => monitor
                                .strike_endpoint(url, kaspaverse_chain::link::StrikeReason::Stall),
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
///
/// It is ALSO the honest-states lane (C7/D-091): `searching` + `os_offline`
/// ride here rather than on the event stream because the stream only speaks
/// when something HAPPENS — and a hunt is precisely a stretch of nothing
/// happening. A pull is the only lane that can animate it. The call itself
/// takes no network await (one mutex + atomic loads), so polling it while dark
/// cannot block the caller — see the pass §5 sweep row.
#[derive(Clone, Default)]
pub struct DagStatusDto {
    pub connected: bool,
    pub endpoint: Option<String>,
    pub last_block_age_secs: Option<u64>,
    pub virtual_daa_score: Option<u64>,
    /// A connect race is hunting right now (C7's second truth) — held for the
    /// whole multi-round hunt, so the glass can name it honestly instead of a
    /// staleness phrase that reads as "connected, data slightly old".
    ///
    /// **Since P0b it is orthogonal to `connected`** (D-213): a find-then-swap
    /// hunt runs behind a LIVE bind, so the pair `connected && searching` is
    /// legal and reads *looking for a different node…*, while a DARK hunt
    /// still reads *finding a node…* for the ~33 s a weak link takes.
    pub searching: bool,
    /// The OS says the default network is gone (C7's first truth) — the glass
    /// names the phone, never a node. Plain bools, both of them: this surface
    /// stays boolean-only, so no secret material can structurally reach it
    /// (INV-1/3 untouched — no new FFI *function* either, just two more bits
    /// on the existing pull).
    pub os_offline: bool,
    /// The node the user pinned, or `None` for public node discovery (D-187).
    ///
    /// This is what makes a pinned failure VISIBLE. `endpoint` only speaks
    /// once something has connected, so a pinned node that is down leaves it
    /// `None` forever and the glass could only say "not connected" — which
    /// reads as *the network is down* when the truth is *your node is not
    /// answering, and by your instruction nothing else will be tried*. Those
    /// are different sentences and only one of them tells the user what to do.
    /// Public data: a `wss://` URL the user typed (INV-3).
    pub pinned_node: Option<String>,
    /// A pin **was** stored and this boot refused it (corrupt or truncated
    /// file), so the wallet is on public discovery without the user choosing
    /// that. Distinct from `pinned_node == None`, which is the honest
    /// never-pinned state — D-187 Decision 2 requires a *lost* pin to be as
    /// nameable as a *down* one, and silence here is the failure it forbids.
    pub pin_dropped: bool,
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
    let (connected, last_block_age_secs, searching, os_offline) = match MONITOR.get() {
        Some(monitor) => (
            monitor.is_connected(),
            monitor.last_block_age_secs(),
            monitor.is_searching(),
            monitor.os_offline(),
        ),
        // No monitor yet: not connected, and nothing is known — never claim a
        // hunt or accuse the phone on a guess.
        None => (false, None, false, false),
    };
    DagStatusDto {
        connected,
        endpoint: latest.endpoint,
        last_block_age_secs,
        virtual_daa_score: latest.virtual_daa_score,
        searching,
        os_offline,
        // The MONITOR is the truth once it exists (it reflects live repins);
        // before it does, the file is — that cold window is exactly when a
        // settings surface paints.
        pinned_node: match MONITOR.get() {
            Some(monitor) => monitor.pinned_url(),
            None => stored_pin().0,
        },
        pin_dropped: stored_pin().1,
    }
}

/// **The connection card's two live readings** (`T5`).
///
/// A separate pull rather than two more fields on [`DagStatusDto`], and that is
/// deliberate: `dag_status` is documented to take **no I/O in its steady
/// state** and is polled by the money screen's link tick, while these two cost
/// a real round trip each. Putting them on the status poll would have put two
/// RPC calls a second behind every surface in the app to serve one card.
///
/// So this is called only while the node surface is open, on its own slower
/// cadence, exactly as the transport-scan age already is.
#[derive(Clone, Copy, Default)]
pub struct LinkProbeDto {
    /// Round-trip time of a `ping` on the bound socket, in milliseconds.
    /// `None` = the node did not answer, and the surface says so rather than
    /// showing a stale figure (BG-8).
    pub latency_ms: Option<u64>,
    /// How many peers **the node** is connected to. `None` where the call was
    /// refused or unanswered — some nodes disable it, and an absent reading is
    /// its own face rather than a zero.
    pub peers: Option<u32>,
}

/// Probe the live link — see [`LinkProbeDto`]. Returns an empty probe rather
/// than an error when there is no monitor yet: a surface opened during the cold
/// window has nothing to read, which is not a failure.
pub async fn dag_probe_link() -> LinkProbeDto {
    let Some(monitor) = MONITOR.get() else {
        return LinkProbeDto::default();
    };
    let (latency_ms, peers) = monitor.probe_link().await;
    LinkProbeDto { latency_ms, peers }
}

/// The user's node choice (D-187) — the INV-8 escape hatch made reachable.
///
/// `url` is what they chose; `active_url` is what the link is actually bound
/// to right now. When a node is pinned those agree or the second is `None`
/// (down) — they can never name DIFFERENT nodes, because a pinned monitor
/// refuses to bind anything else, and showing both is how a user verifies
/// that rather than taking our word for it.
#[derive(Clone, Default)]
pub struct NodeConfigDto {
    /// The pinned node, or `None` for public node discovery (the default).
    pub url: Option<String>,
    /// The endpoint the socket is bound to, or `None` while dark.
    pub active_url: Option<String>,
    /// A stored pin was refused on load — see `DagStatusDto::pin_dropped`.
    pub dropped: bool,
}

/// Read the node choice (file-backed; defaults to discovery).
pub fn dag_node_config() -> Result<NodeConfigDto, AppError> {
    let (url, dropped) = stored_pin();
    Ok(NodeConfigDto {
        url,
        active_url: current_endpoint_url(),
        dropped,
    })
}

/// Pin the wallet to one node, or clear the pin with `None`.
///
/// Persist-then-apply, in that order: the URL is validated in Rust
/// (`chain::validate_node_url` — the same intake guard a resolver candidate
/// passes, never a second weaker one in Dart), then written, then applied to
/// the live link. A monitor that does not exist yet needs no apply step — it
/// reads the file when it starts.
///
/// **Not atomic, deliberately.** A validated URL is persisted and applied
/// before the first dial is attempted, so an `Err` from this function means
/// *the first dial failed*, never *the pin was rejected* — the pin IS live and
/// its Retry loop keeps working, which is exactly the D-187 ruling (a pinned
/// node that is down stays pinned). Callers must therefore re-read the config
/// on BOTH arms rather than assuming failure means nothing changed; the Dart
/// seam refreshes in a `finally` for this reason. Rejection is the earlier,
/// cheaper failure: it happens in `save`, before anything is written or torn
/// down.
///
/// Applying it live rather than at next launch is deliberate: the case that
/// matters most is a user whose pinned node just died, and telling them to
/// restart the app to escape a setting they can see on screen is the kind of
/// dead end that makes people give up on running their own node.
pub async fn dag_set_node_config(url: Option<String>) -> Result<(), AppError> {
    let dir = super::vault::node_config_dir()?;
    let url = url.map(|u| u.trim().to_string()).filter(|u| !u.is_empty());
    let config = kaspaverse_chain::NodeConfig { url: url.clone() };
    // Validates on the way in; a rejected save leaves the previous config —
    // and the live link — untouched.
    config.save(&dir).map_err(AppError::chain)?;
    *STORED_PIN
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    // `shared_monitor()`, not `MONITOR.get()` (consensus audit): a `get` that
    // lands while the monitor is mid-`get_or_try_init` returns `None`, so the
    // apply would be skipped and the init would finish carrying the value it
    // read BEFORE this save — leaving `dag_status` (monitor) and
    // `dag_node_config` (file) disagreeing for the rest of the process, with
    // two Dart writers to one notifier watching them oscillate. Awaiting the
    // init instead makes the two readers agree by construction.
    shared_monitor()
        .await?
        .set_pinned_node(url)
        .await
        .map_err(AppError::chain)?;
    Ok(())
}

/// The user's "try now" — the Reconnect button and the watchdog's recovery
/// (P3/D-068). A no-op before the first connect exists (nothing to bounce).
///
/// **It is no longer a teardown on the common path** (P0b/D-213). On a
/// CONNECTED, unpinned wallet it starts a bounded find-then-swap hunt BEHIND
/// the live bind and the incumbent is dropped only once a replacement is
/// armed, so a tap that finds nothing costs the user nothing. Drop-then-hunt
/// survives for the gestures that mean it: `stalled = true` after the stall
/// verdict executes, a pinned wallet (there is no different node to find), and
/// `dag_resync`'s hard pull-heal — all of which route through
/// `DagMonitor::hard_reconnect`.
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

/// OS default-network transition (C5/D-089): Android's `ConnectivityManager`
/// default-network callback, relayed by the host activity over the platform
/// channel and forwarded here by Dart. One `bool` in, unit out — no secret
/// material can touch this surface structurally (INV-1 untouched; the
/// ffi-leak auditor samples this fn). Rust decides what the signal means
/// (ruling 4): available with a dead link → redial NOW; available while
/// connected → log only (the watchdog owns staleness); lost → log + span
/// only. A no-op before the monitor exists (nothing to redial yet — the
/// first connect races on its own).
pub async fn dag_network_changed(available: bool) -> Result<(), AppError> {
    if let Some(monitor) = MONITOR.get() {
        monitor.network_changed(available).await;
    }
    Ok(())
}

/// Minimum spacing between HARD pull-heal resyncs — socket teardown + race +
/// full rescan is not a cheap gesture; repeated pulls inside the window
/// re-serve the fold without bouncing the socket.
const RESYNC_MIN_INTERVAL_SECS: u64 = 20;

/// Minimum spacing between SOFT pull refreshes — one `get_utxos_by_addresses`
/// round trip on the live socket, priced accordingly. Independent of the hard
/// window: a soft pull must never delay a genuinely needed hard heal, and a
/// recent hard reconnect must not block a healthy soft pull on its fresh
/// socket.
const SOFT_RESYNC_MIN_INTERVAL_SECS: u64 = 5;

/// Healthy = connected AND blocks flowing within the same stall threshold the
/// Dart watchdog uses (`chain_service.dart` `watchdogStallSecs` = 30) — Rust
/// and Dart agree on what "healthy" means. A `None` block age (no block since
/// BOOT — `last_block_at` is process-lifetime, not per-connection) is NOT
/// healthy: no evidence, hard path. Within ≤30 s of a rebind the age can
/// still carry the PRIOR connection's last block, so a just-reconnected deaf
/// socket can read healthy for that bounded window — the soft rescan is a
/// real node round-trip that errs/times out on a dead lane and escalates, so
/// the window costs one probe, never a missed heal (consensus-audit note).
const SOFT_REFRESH_MAX_BLOCK_AGE_SECS: u64 = 30;

/// Budget for the in-place rescan — a "healthy" socket that hangs the scan
/// was lying; the timeout escalates to the hard reconnect, so the pull's
/// recovery guarantee is never weaker than the V3 behavior.
const SOFT_RESCAN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// The pull heal asks the NODE — soft-first since V6 (amends the V3 register
/// item 12 design, whose unconditional hard reconnect predates the D-083 root
/// cause): on a HEALTHY connection the swipe re-fetches the watched UTXO set
/// in place over the live socket (no teardown, no race, no `UtxoProcStart`
/// storm, no beacon flicker); on an unhealthy one — or when the soft path
/// fails or times out — it falls back to the V3 hard reconnect through the
/// race, exactly the detection path a kill/relaunch used to be needed for.
/// Returns `true` when the node was actually re-asked (either path), `false`
/// when a rate window swallowed the pull (the caller still re-serves the
/// fold — delivery heal — so a swallowed pull is never a dead gesture).
pub async fn dag_resync() -> Result<bool, AppError> {
    static LAST_HARD: AtomicU64 = AtomicU64::new(0);
    static LAST_SOFT: AtomicU64 = AtomicU64::new(0);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let Some(monitor) = MONITOR.get() else {
        return Ok(false);
    };

    let healthy = monitor.is_connected()
        && monitor
            .last_block_age_secs()
            .is_some_and(|age| age <= SOFT_REFRESH_MAX_BLOCK_AGE_SECS);
    if healthy {
        if now.saturating_sub(LAST_SOFT.load(Ordering::Relaxed)) < SOFT_RESYNC_MIN_INTERVAL_SECS {
            log::info!(
                "dag: soft resync inside the {SOFT_RESYNC_MIN_INTERVAL_SECS}s window — re-serve only"
            );
            return Ok(false);
        }
        let Some(engine) = super::wallet::engine_handle() else {
            // Healthy connection, wallet not started (pre-unlock): the DAG
            // lane needs no heal and there is no watched set to re-ask for —
            // a hard reconnect would buy nothing here.
            return Ok(false);
        };
        LAST_SOFT.store(now, Ordering::Relaxed);
        // The pull is also the user's manual lever on address discovery. A pass
        // that has never succeeded normally retries on the next `Connected`, but
        // a socket that stays up while the probe keeps failing (a node without a
        // UTXO index, say) would otherwise wait for a process restart — the
        // recovery gap this whole track exists to close. Detached: the pull
        // keeps its own budget, and re-asking the node happens either way.
        tokio::spawn(super::wallet::retry_discovery_if_unproven());
        match tokio::time::timeout(SOFT_RESCAN_TIMEOUT, engine.rescan()).await {
            Ok(Ok(())) => {
                log::info!("dag: pull soft rescan — node re-asked in place, socket kept");
                kaspaverse_chain::spans::mark_with("pull_resync", "soft");
                return Ok(true);
            }
            Ok(Err(e)) => {
                // Node-controllable error text is sanitized before the
                // evidence lane (INV-10/L53 — the link.rs discipline).
                log::warn!(
                    "dag: soft rescan failed ({}) — escalating to hard reconnect",
                    kaspaverse_chain::link::sanitize_node_text(&e.to_string())
                );
            }
            Err(_) => {
                log::warn!(
                    "dag: soft rescan exceeded {SOFT_RESCAN_TIMEOUT:?} — escalating to hard reconnect"
                );
            }
        }
        // The health reading lied — fall through to the hard path.
    }

    if now.saturating_sub(LAST_HARD.load(Ordering::Relaxed)) < RESYNC_MIN_INTERVAL_SECS {
        log::info!(
            "dag: resync request inside the {RESYNC_MIN_INTERVAL_SECS}s window — re-serve only"
        );
        return Ok(false);
    }
    LAST_HARD.store(now, Ordering::Relaxed);
    log::info!("dag: pull-heal resync — forcing reconnect + rescan");
    kaspaverse_chain::spans::mark_with("pull_resync", "hard");
    // The HARD path, deliberately — not the user's find-then-swap tap (P0b).
    // This line is only reached once the socket has read unhealthy or failed
    // a real round-trip, and what it owes the caller is a NEW socket whose
    // `Connected` drives the rescan. A swap that kept a suspected-deaf
    // incumbent because nothing better answered would do neither, and the
    // `Ok(true)` below ("the node was actually re-asked") would be a lie.
    monitor.hard_reconnect().await.map_err(AppError::chain)?;
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
/// race keeps a socket bound for the life of the process (since R4 each socket
/// is its own bind, with its own task — see `DagMonitor::install_bind`).
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
