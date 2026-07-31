//! Connection lifecycle + notification subscription for the hello-DAG stream.
//!
//! Derived from the pinned rev's `rpc/wrpc/examples/subscriber` example
//! (originally at `90dbf074`; pin since bumped to `cfafeb4c` v2.0.1 — D-058;
//! INV-9). Key protocol fact from that source:
//! notification scopes live on the node for the lifetime of one RPC
//! connection — they are lost on disconnect, so every `RpcState::Connected`
//! event must re-register the listener and its scopes.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use kaspa_addresses::Prefix;
use kaspa_consensus_core::Hash;
use kaspa_wallet_core::rpc::Rpc;
use kaspa_wrpc_client::prelude::*;
use tokio::sync::{broadcast, oneshot};

use crate::acceptance::VccBatch;
use crate::error::Result;
use crate::link::{self, EndpointHealth};
use crate::spans;
use crate::transport::{self, TransportEvent};

/// Per-candidate probe budget in the connect race (dial + `get_server_info`).
/// Bounded like the old cached fast path (3 s) plus one health round-trip.
const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

/// Bind budget for the shared socket's dial to the race winner — the node
/// answered a probe milliseconds ago, so a healthy bind is fast; a node that
/// died in between just re-enters the race.
const BIND_TIMEOUT: Duration = Duration::from_secs(3);

/// Parallel `Resolver::get_node` fetches per race round (the resolver API
/// returns ONE node per fetch — spec verified against the pinned source).
const RACE_FETCHES: usize = 3;

/// Envelope bound for the WHOLE winner-bind call (consensus-audit BLOCK at
/// R0): the dial itself is bounded by [`BIND_TIMEOUT`], but
/// `KaspaRpcClient::connect`'s `Fallback` ERROR arm then locks
/// `disconnect_guard` and runs the shutdown handshake (pin
/// `client.rs:463-467`) — the same guard a starved detached teardown can
/// hold indefinitely (a dispatcher that exits via its error path never
/// answers `close()`'s shutdown handshake, so that teardown may never
/// finish). Sized dial 3 s + teardown-wait 5 s + margin. A timeout here is
/// treated as a failed bind and re-raced with NO strike: the endpoint just
/// won a probe — the block is our own guard, and convicting the node for it
/// would be a self-inflicted verdict (auditor item 18).
const BIND_ENVELOPE_TIMEOUT: Duration = Duration::from_secs(10);

/// Pause between race rounds when NO candidate was healthy (offline, resolver
/// unreachable) — the app-owned replacement for the abandoned ws-level
/// `ConnectStrategy::Retry` loop (D-081).
const RACE_RETRY_DELAY: Duration = Duration::from_secs(3);

/// Throttle for the catch-up cursor write in the hot BlockAdded path: at most
/// one tiny hash write this often. A killed app loses at most this much scan
/// progress, which the next open's catch-up re-covers anyway (idempotent — the
/// fold dedups by txid), so a coarse throttle costs nothing but I/O churn.
const TRANSPORT_CURSOR_MIN_WRITE_SECS: u64 = 3;

/// Bound on one catch-up replay (P5). `get_blocks` returns up to
/// ~`mergeset_size_limit`+1 blocks/page (mainnet = 2·ghostdag_k+1 = 249 at
/// 10 bps), so 48 pages ≈ 12k blocks ≈ **~20 min** of gap — a comfortable
/// idle/background window (the P2.3b sitting's first miss came from a 9-min
/// gap that was borderline under the old 24-page cap). The common small gap
/// stops early (a page of just the low_hash = caught up), so this ceiling only
/// costs work on a genuinely long outage — which is NOT fully recovered (an
/// indexer's job, INV-8; the P3 liveness surface tells the user to reconnect).
const MAX_CATCHUP_PAGES: u32 = 48;

/// Per-page `get_blocks` retry budget for the catch-up. The replay fires the
/// instant transport starts — often BEFORE the wRPC reconnect completes on a
/// cold reopen — so the first page routinely races a not-yet-live socket. We
/// retry (rather than give up after one error, the P2.3b sitting's
/// first-of-three miss) so a message that arrived while the app was closed is
/// never lost to a connect-timing race. Exhausting the budget = the node is
/// truly unreachable or the cursor is pruned; the walk then stops honestly.
const CATCHUP_RPC_ATTEMPTS: u32 = 15;
/// Delay between catch-up `get_blocks` retries — long enough to let a cold
/// wRPC socket finish connecting (cached fast-path ≤3 s; resolver a little
/// more), short enough that the recovery feels immediate.
const CATCHUP_RETRY_DELAY: Duration = Duration::from_millis(1000);

/// A chain event observed by the [`DagMonitor`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DagEvent {
    /// RPC connection established to `url` (endpoint picked by the resolver).
    Connected { url: Option<String> },
    /// RPC connection lost; the client keeps retrying in the background.
    Disconnected,
    /// The virtual's DAA score changed.
    VirtualDaaScore(u64),
    /// The blue score of the virtual's selected parent (sink) changed.
    SinkBlueScore(u64),
}

/// Map a node notification onto the events this monitor emits.
///
/// Display-only plumbing: values are passed through verbatim from the pinned
/// crates' notification structs — nothing is computed locally (INV-9).
fn map_notification(notification: &Notification) -> Option<DagEvent> {
    match notification {
        Notification::VirtualDaaScoreChanged(n) => {
            Some(DagEvent::VirtualDaaScore(n.virtual_daa_score))
        }
        Notification::SinkBlueScoreChanged(n) => Some(DagEvent::SinkBlueScore(n.sink_blue_score)),
        _ => None,
    }
}

struct Inner {
    client: Arc<KaspaRpcClient>,
    is_connected: AtomicBool,
    /// Channel handed to the notification subsystem (`ChannelConnection`).
    notification_tx: async_channel::Sender<Notification>,
    notification_rx: async_channel::Receiver<Notification>,
    listener_id: Mutex<Option<ListenerId>>,
    events: broadcast::Sender<DagEvent>,
    /// Payload-transport fan-out (P2.1): matches from the BlockAdded scan.
    /// Separate from `events` — these are discrete deliveries, not foldable
    /// absolute-state snapshots, and they stay sparse (only `ciph_msg:` matches
    /// are ever sent; the ~10 blocks/s stream itself never crosses).
    transport_events: broadcast::Sender<TransportEvent>,
    /// Address prefix for the scan's output-address extraction — derived from
    /// the network this monitor was constructed for.
    address_prefix: Prefix,
    event_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    shutdown: Mutex<Option<oneshot::Sender<()>>>,
    /// App-private file remembering the last node that worked (public data,
    /// INV-3; the PNN resolver is already an untrusted accelerator, INV-8 —
    /// remembering its last answer adds no new trust). `None` until the bridge
    /// learns the app dir.
    endpoint_cache: Mutex<Option<PathBuf>>,
    /// V3/D-081 link layer: our own resolver handle (race fetches + stall
    /// escalation) and the network this monitor serves. The shared client's
    /// internal resolver is never exercised — every shared-socket connect
    /// passes an explicit URL picked by the race.
    resolver: Resolver,
    network_id: NetworkId,
    /// The demotion ledger (finding 11) + its persistence path (a sibling of
    /// the endpoint cache). Loaded when the cache path arrives; advisory —
    /// a missing ledger never blocks connectivity.
    health: Mutex<EndpointHealth>,
    health_path: Mutex<Option<PathBuf>>,
    /// Single-flight guard for the race task — one reconnect authority means
    /// at most ONE race loop alive (D-081; the V2 sitting's doubled
    /// `Connected` was two concurrent ws connect loops).
    race_running: AtomicBool,
    /// The race-kick (C4/D-089 ruling 2): a Reconnect tap, resume, or OS
    /// network-available signal during a live search interrupts the retry
    /// PAUSE — never the in-flight probes (the reaper finding), never a
    /// second search authority. `Notify`'s stored permit means an unconsumed
    /// kick lets the next pause skip once — one spurious immediate round,
    /// accepted (register C4 note).
    race_kick: tokio::sync::Notify,
    /// The OS's last word on the default network (C7/D-089 ruling 4): `true`
    /// once `onLost` fires, back to `false` on `onAvailable`. Initialised
    /// `false` = *not known to be offline* — the callback only speaks on
    /// TRANSITIONS, so a launch with no network may produce no callback at
    /// all, and a phone must never be accused of being offline without the OS
    /// actually saying so. Display-only: it changes no dialing decision
    /// (ruling 4 keeps `network_lost` passive), it lets the glass name the
    /// cause instead of blaming the nodes.
    os_offline: AtomicBool,
    /// Unix-seconds of the last `onLost` TRANSITION (0 = never). Separate from
    /// [`Self::os_offline`] because that flag is cleared by `onAvailable`,
    /// while admissibility (R2 D3) is judged after the network is back — the
    /// moment the boolean has already forgotten. Never cleared: an old stamp
    /// simply falls outside [`link::OS_LOST_ADJACENCY_SECS`].
    os_lost_at: AtomicU64,
    /// Unix-seconds the item-9 tripwire last fired (0 = never) — a prior
    /// listener surviving into a new connect, which proves two `Connected`
    /// arrived with no `Disconnected` between them. R2 D2 established the
    /// cause: the pinned ws client re-dials a dropped socket on its own
    /// (`workflow-websocket` `'outer` loop, `reconnect` still true), so a
    /// socket can exist that our reconnect authority never created. Drops in
    /// that neighbourhood are OURS, and R2 D3 refuses to charge them to a node.
    doubled_connect_at: AtomicU64,
    /// Unix-seconds of the last race round that PROVED the phone's own
    /// network broken (correlated DNS or `ENETUNREACH` — R3 D-099); 0 =
    /// never. A pending drop/stall strike whose socket died at-or-before
    /// this stamp is withheld as [`link::StrikeReason::LinkBlackout`]: the
    /// interposed race is the one witness that saw the link at the time of
    /// death.
    phone_fault_round_at: AtomicU64,
    /// The endpoint whose failure awaits network-alive evidence: committed as
    /// a strike by the NEXT `Connected` event from a DIFFERENT endpoint (the
    /// control-group — the network worked via B while this one stayed dark).
    /// REFUTED (discarded) if the struck endpoint's OWN reconnect produces the
    /// event — an endpoint can't be its own alibi-witness, and under Wi-Fi
    /// churn that self-commit strand-locked the whole ledger (D-084). Also
    /// discarded when stale ([`link::PENDING_STRIKE_TTL_SECS`] — a phone that
    /// spent minutes offline blames no one). Robust to every event ordering,
    /// including a phantom redial the ws layer can land before our
    /// disconnect() takes effect (its dial cannot be aborted mid-flight).
    /// Carries (url, event-unix, why) — `why` is [`link::StrikeReason::Drop`]
    /// for a judged socket death, [`link::StrikeReason::Stall`] for a
    /// watchdog execution, so the ledger records the true proximate cause
    /// (R3 D1) instead of flattening both to `drop`.
    pending_strike: Mutex<Option<(String, u64, link::StrikeReason)>>,
    /// True while the live bind KNOWINGLY went to a demoted endpoint (two
    /// whole race rounds found nothing healthy — connectivity over hygiene).
    /// Gates the Connected-time demotion refusal so the advisory bind isn't
    /// bounced by our own enforcement.
    hygiene_advisory: AtomicBool,
    /// Unix-seconds of the last `Connected` (0 = never) — a drop after a run
    /// of ≥ [`link::CLEAN_RUN_SECS`] clears the endpoint's strikes instead of
    /// adding one. Also the stall-verdict baseline floor (R3 D-099): silence
    /// is measured from `max(last_block_at, connected_at)`.
    connected_at: AtomicU64,
    /// `try_new(url = Some(..))` pins a node explicitly (dev/tests): the race
    /// and demotion machinery stand down and the ws client's own Retry loop
    /// keeps the pinned URL alive — loyalty is CORRECT for a pinned node.
    direct_url: Option<String>,
    /// True between [`DagMonitor::pause`] and [`DagMonitor::resume`] — a
    /// deliberate grace-drop also emits `Disconnected`, and the rotation-restore
    /// logic must not treat it as a dead node and dial right back.
    paused: AtomicBool,
    /// App-private file holding the hash of the last block whose transport scan
    /// we advanced past — the catch-up cursor (P5/D-067). Public chain data
    /// (INV-3). `None` until transport arms it (`set_transport_cursor`); while
    /// armed, the BlockAdded scan persists it (throttled) so a killed app can
    /// replay the gap on next open ([`catch_up_transport`]). Node-only (INV-8):
    /// the replay is `get_blocks` from this hash, never an indexer.
    transport_cursor: Mutex<Option<PathBuf>>,
    /// Unix-seconds of the last cursor write — throttles the hot BlockAdded path
    /// to one small write every [`TRANSPORT_CURSOR_MIN_WRITE_SECS`].
    transport_cursor_written: AtomicU64,
    /// Unix-seconds of the last BlockAdded we scanned (0 = none yet). The
    /// foreground watchdog's liveness signal (P3/D-068): a healthy mainnet
    /// delivers ~10 blocks/s, so a large age while the app is foreground means
    /// the wRPC socket died silently (the "midnight DAA stall") — the UI polls
    /// [`last_block_age_secs`] and forces a [`reconnect`]. A plain atomic store
    /// every block (no I/O), unlike the throttled cursor write.
    last_block_at: AtomicU64,
    /// V1 acceptance spine: where the event task forwards VirtualChainChanged
    /// batches once the tracker is attached ([`DagMonitor::attach_acceptance`]).
    /// Unattached (or a dead receiver) = batches drop harmlessly — the tracker's
    /// own reconnect catch-up recovers anything missed while detached.
    vcc_tx: Mutex<Option<tokio::sync::mpsc::UnboundedSender<VccBatch>>>,
    /// True until the first VirtualDaaScore after a connect — drives the
    /// `first_daa` span marker (V1 observability; closes the L40-scarred
    /// time-to-first-DAA baseline row).
    daa_seen_since_connect: AtomicBool,
}

/// Owns one wRPC client plus the event task that tracks its connection state
/// and notification stream, fanning everything out as [`DagEvent`]s.
/// What a watchdog stall claim amounts to once judged against the monitor's
/// own clocks (R3 D-099). The claim arrives from Dart with process-lifetime
/// evidence; only the monitor knows the CURRENT socket's age and silence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StallVerdict {
    /// Connected and silent past [`link::WATCHDOG_STALL_SECS`] measured from
    /// this socket's own baseline — a true zombie; execute it.
    Execute { silent_secs: u64 },
    /// Connected but the socket's own silence is inside the threshold — the
    /// claim was built on silence older than the socket. It keeps its window.
    Refuse { silent_secs: u64 },
    /// Not connected: there is no defendant. Kick the hunt (C4) instead.
    Hunting,
}

#[derive(Clone)]
pub struct DagMonitor {
    inner: Arc<Inner>,
}

impl DagMonitor {
    /// `url = None` uses the public-node resolver (PNN) for endpoint discovery
    /// via the connect race (D-081); `url = Some` pins that node (dev/tests).
    pub fn try_new(network_id: NetworkId, url: Option<String>) -> Result<Self> {
        let resolver = Resolver::default();
        let client = Arc::new(KaspaRpcClient::new_with_args(
            WrpcEncoding::Borsh,
            url.as_deref(),
            // The client's internal resolver is a construction requirement for
            // url-less clients; the race supplies explicit URLs so it never
            // actually resolves (D-081). LOAD-BEARING for the bounded-await
            // law (D-089/L64): the ws connect loop's resolver hook runs raw
            // `get_node` OUTSIDE `connect_timeout` (pin ws native.rs:150-156,
            // :178 vs :182; client.rs:233-235) — an unbounded HTTP that
            // cannot fire only because EVERY connect on this client passes
            // `options.url: Some(..)`. A url-less connect here re-opens the
            // D-089 wedge (sweep-table tripwire, CONNECTIVITY_PASS §5).
            url.is_none().then(|| resolver.clone()),
            Some(network_id),
            None,
        )?);
        let (notification_tx, notification_rx) = async_channel::unbounded();
        let (events, _) = broadcast::channel(256);
        let (transport_events, _) = broadcast::channel(256);
        Ok(Self {
            inner: Arc::new(Inner {
                client,
                is_connected: AtomicBool::new(false),
                notification_tx,
                notification_rx,
                listener_id: Mutex::new(None),
                events,
                transport_events,
                address_prefix: Prefix::from(network_id.network_type),
                event_task: Mutex::new(None),
                shutdown: Mutex::new(None),
                endpoint_cache: Mutex::new(None),
                resolver,
                network_id,
                health: Mutex::new(EndpointHealth::default()),
                health_path: Mutex::new(None),
                race_running: AtomicBool::new(false),
                race_kick: tokio::sync::Notify::new(),
                os_offline: AtomicBool::new(false),
                os_lost_at: AtomicU64::new(0),
                doubled_connect_at: AtomicU64::new(0),
                phone_fault_round_at: AtomicU64::new(0),
                pending_strike: Mutex::new(None),
                hygiene_advisory: AtomicBool::new(false),
                connected_at: AtomicU64::new(0),
                direct_url: url,
                paused: AtomicBool::new(false),
                transport_cursor: Mutex::new(None),
                transport_cursor_written: AtomicU64::new(0),
                last_block_at: AtomicU64::new(0),
                vcc_tx: Mutex::new(None),
                daa_seen_since_connect: AtomicBool::new(false),
            }),
        })
    }

    /// Attach the acceptance tracker (V1): returns the receiving end of the
    /// VirtualChainChanged forward. Batches that arrive before attachment
    /// drop harmlessly (the tracker's connect catch-up covers the gap).
    pub fn attach_acceptance(&self) -> tokio::sync::mpsc::UnboundedReceiver<VccBatch> {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        *self
            .inner
            .vcc_tx
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(tx);
        rx
    }

    /// Tell the monitor where to remember the last-good endpoint (app-private
    /// file; public data — a wss URL). Callable any time; connects that happen
    /// before this is set simply skip the fast path. The demotion ledger
    /// (V3, finding 11) lives beside it as `endpoint.health` and loads here.
    pub fn set_endpoint_cache(&self, path: PathBuf) {
        let health_path = path.with_file_name("endpoint.health");
        *self
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            EndpointHealth::load(&health_path);
        *self
            .inner
            .health_path
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(health_path);
        *self
            .inner
            .endpoint_cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(path);
    }

    /// Current unix-seconds (0 on a pre-epoch clock — never panics).
    fn now_unix() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }

    /// Record a strike against `url` and persist the ledger. Called only with
    /// network-alive evidence in hand (a race just found another healthy node,
    /// or a fresh node just took an escalation resubmit) — a phone in a tunnel
    /// never demotes an innocent endpoint (D-081 control-group rule).
    fn commit_strike(
        &self,
        url: &str,
        reason: link::StrikeReason,
        event_at_unix: u64,
        phone_fault_correlated: bool,
    ) {
        let now = Self::now_unix();
        // R2 D3 — admissibility is judged at the ONE choke point every strike
        // passes, for the same reason the demotion refusal sits at the one
        // choke point every connection passes: a rule enforced at each call
        // site is a rule the next call site forgets.
        //
        // `event_at_unix` is the moment the EVIDENCE arose, which for a parked
        // drop is when the socket died — not now. Judging a settled strike by
        // its settle time would compare the OS window against a clock reading
        // taken after the network already recovered, and quietly convict the
        // exact endpoints this rule exists to protect.
        let verdict = link::judge_admissibility(
            reason,
            event_at_unix,
            self.inner.os_lost_at.load(Ordering::SeqCst),
            self.inner.doubled_connect_at.load(Ordering::SeqCst),
            phone_fault_correlated,
            self.inner.phone_fault_round_at.load(Ordering::SeqCst),
        );
        let reason = match verdict {
            link::Admissibility::Convict(reason) => reason,
            link::Admissibility::Withhold(why) => {
                let withheld = {
                    let mut health = self
                        .inner
                        .health
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    health.withhold(url, why);
                    self.save_health(&health);
                    health.last_reason(url).map_or(0, |(_, n)| n)
                };
                // Recorded, never erased: the ledger must stay auditable for
                // wrongful ACQUITTALS too, not only wrongful convictions.
                log::info!(
                    "link: strike ({}) on {url} WITHHELD as {} — not the node's fault \
                     ({withheld} withheld so far)",
                    reason.as_token(),
                    why.as_token()
                );
                spans::mark_with("endpoint_strike_withheld", url);
                return;
            }
        };
        let demoted = {
            let mut health = self
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let demoted = health.strike(url, now, reason);
            self.save_health(&health);
            demoted
        };
        log::info!(
            "link: strike ({}) on {url}{}",
            reason.as_token(),
            if demoted { " — DEMOTED" } else { "" }
        );
        spans::mark_with(
            if demoted {
                "endpoint_demoted"
            } else {
                "endpoint_strike"
            },
            url,
        );
    }

    /// A connection outlived [`link::CLEAN_RUN_SECS`] — clear its strikes.
    fn commit_clean_run(&self, url: &str) {
        let mut health = self
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        health.clean_run(url);
        self.save_health(&health);
    }

    /// Stamp an observed-healthy moment (C6): a probe win or a `Connected`
    /// on the shared socket. Persisted — the pantry survives restarts.
    fn mark_endpoint_healthy(&self, url: &str) {
        let mut health = self
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        health.mark_healthy(url, Self::now_unix());
        self.save_health(&health);
    }

    fn save_health(&self, health: &EndpointHealth) {
        if let Some(path) = self
            .inner
            .health_path
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
        {
            health.save(path);
        }
    }

    /// Strike a NAMED endpoint — the escalation task's demotion hook (V3
    /// deliverable 2): the stall convicts the SUBMIT-TIME endpoint (retained
    /// with the tx), never whoever the socket re-raced to since
    /// (consensus-audit finding). Only called after a fresh node answered,
    /// so the evidence rule holds.
    pub fn strike_endpoint(&self, url: &str, reason: link::StrikeReason) {
        self.commit_strike(url, reason, Self::now_unix(), false);
    }

    /// The endpoint the shared socket is (or was last) bound to — captured by
    /// the send hook at submit time so a later stall strikes the right node.
    pub fn current_url(&self) -> Option<String> {
        self.inner.client.url()
    }

    /// Park a strike until network-alive evidence arrives (the next
    /// `Connected` commits it; staleness discards it). `why` names the true
    /// proximate cause — `Drop` for a judged socket death, `Stall` for a
    /// watchdog execution (R3 D1).
    fn set_pending_strike(&self, url: String, why: link::StrikeReason) {
        *self
            .inner
            .pending_strike
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some((url, Self::now_unix(), why));
    }

    /// Commit-or-discard the parked strike — called on every `Connected`
    /// (the connect itself is the network-alive proof). `prover_url` is the
    /// endpoint that just connected: when it IS the struck endpoint, the
    /// strike is REFUTED, not proven — the hypothesis behind a strike is
    /// "this endpoint is unhealthy", and its own successful reconnect is the
    /// strongest possible counter-evidence. Committing it anyway is how the
    /// V4 sitting's live-lock spun up (D-084): post-airplane Wi-Fi churn
    /// parked a strike per drop, each endpoint's own reconnect ≤30 s
    /// committed it, the demotion tripped the Connected-time refusal, the
    /// re-race walked to the next endpoint and repeated until the whole
    /// resolver set sat demoted — a connectivity strand. Commit stays for
    /// the true control-group: a DIFFERENT endpoint proved the network alive
    /// while the struck one stayed dark.
    fn settle_pending_strike(&self, prover_url: Option<&str>) {
        let taken = self
            .inner
            .pending_strike
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some((url, at, why)) = taken {
            if prover_url == Some(url.as_str()) {
                log::info!(
                    "link: pending strike on {url} refuted by its own reconnect — discarded"
                );
            } else if Self::now_unix().saturating_sub(at) <= link::PENDING_STRIKE_TTL_SECS {
                // `at` is when the socket DIED, not now — see commit_strike.
                self.commit_strike(&url, why, at, false);
            } else {
                log::info!("link: pending strike on {url} expired unproven — discarded");
            }
        }
    }

    /// The resolver handle the race + escalation share (cheap Arc clone).
    pub fn resolver(&self) -> Resolver {
        self.inner.resolver.clone()
    }

    pub fn network_id(&self) -> NetworkId {
        self.inner.network_id
    }

    fn cache_path(&self) -> Option<PathBuf> {
        self.inner
            .endpoint_cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// The remembered endpoint, if any. Accepts only ws/wss URLs (a corrupt or
    /// hand-edited file must never redirect the wallet elsewhere).
    fn read_cached_endpoint(&self) -> Option<String> {
        let path = self.cache_path()?;
        let url = std::fs::read_to_string(path).ok()?.trim().to_string();
        (url.starts_with("wss://") || url.starts_with("ws://")).then_some(url)
    }

    /// Best-effort persist of the endpoint that just worked.
    fn persist_endpoint(&self, url: &str) {
        if let Some(path) = self.cache_path() {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Err(e) = std::fs::write(&path, url) {
                log::warn!("dag-monitor: endpoint cache write failed: {e}");
            }
        }
    }

    /// Arm the transport catch-up cursor at `path` (called by the transport hub
    /// on start, AFTER it has read the prior value for its replay — see
    /// [`take_transport_cursor`]). Once set, the BlockAdded scan persists the
    /// last-scanned block hash here (throttled), so the next open can replay the
    /// gap. Idempotent; changing paths mid-run just re-homes the cursor.
    pub fn set_transport_cursor(&self, path: PathBuf) {
        *self
            .inner
            .transport_cursor
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(path);
    }

    fn transport_cursor_path(&self) -> Option<PathBuf> {
        self.inner
            .transport_cursor
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// Read the persisted cursor hash from a file WITHOUT arming persistence —
    /// the transport hub calls this at open to get the PRIOR session's last
    /// scan point for the catch-up replay, before it arms the live cursor.
    /// A missing/corrupt file yields `None` (first run, or nothing to recover).
    pub fn read_transport_cursor(path: &PathBuf) -> Option<Hash> {
        let text = std::fs::read_to_string(path).ok()?;
        text.trim().parse::<Hash>().ok()
    }

    /// Best-effort, throttled persist of the last-scanned block hash. Called
    /// from the BlockAdded scan; a write happens at most every
    /// [`TRANSPORT_CURSOR_MIN_WRITE_SECS`] so the ~10 blocks/s stream never
    /// hammers the disk. No-op until the cursor is armed.
    fn persist_transport_cursor(&self, hash: &Hash) {
        let Some(path) = self.transport_cursor_path() else {
            return;
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let last = self.inner.transport_cursor_written.load(Ordering::Relaxed);
        if now.saturating_sub(last) < TRANSPORT_CURSOR_MIN_WRITE_SECS {
            return;
        }
        self.inner
            .transport_cursor_written
            .store(now, Ordering::Relaxed);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(&path, hash.to_string()) {
            log::warn!("dag-monitor: transport cursor write failed: {e}");
        }
    }

    /// Replay the transport scan over the blocks the app missed while closed —
    /// the P5/D-067 catch-up. From `from` (the prior session's cursor), walk the
    /// DAG forward with `get_blocks` (node-only, INV-8), run the SAME
    /// [`transport::scan_block`] the live path uses, and fan the matches out on
    /// the transport channel so the hub folds them exactly like live arrivals
    /// (dedup-by-txid makes the boundary-block overlap harmless). Bounded by
    /// [`MAX_CATCHUP_PAGES`]; a pruned/unknown cursor just ends the walk (the
    /// live scan takes over). Returns the number of matches re-emitted.
    ///
    /// `from = None` (first run / no prior cursor) seeds the cursor at the
    /// current sink so the NEXT gap is coverable, and replays nothing — there is
    /// no prior session whose arrivals could have been missed.
    pub async fn catch_up_transport(&self, from: Option<Hash>) -> Result<usize> {
        let rpc = self.inner.client.rpc_api();
        let Some(mut low) = from else {
            if let Ok(sink) = rpc.get_sink().await {
                self.write_cursor_now(&sink.sink);
            }
            return Ok(0);
        };

        let mut emitted = 0usize;
        let mut last_hash = low;
        for _page in 0..MAX_CATCHUP_PAGES {
            // Retry across a still-connecting socket so a cold-reopen race never
            // strands a closed-app arrival. `None` = unreachable/pruned → stop.
            let Some(resp) = self.catch_up_get_blocks(low).await else {
                log::warn!("dag-monitor: catch-up get_blocks unreachable — stopping");
                break;
            };
            // `low_hash` is returned inclusively; a page of just it = caught up.
            if resp.block_hashes.len() <= 1 {
                if let Some(h) = resp.block_hashes.last() {
                    last_hash = *h;
                }
                break;
            }
            for block in &resp.blocks {
                for event in transport::scan_block(block, self.inner.address_prefix) {
                    if self.inner.transport_events.send(event).is_ok() {
                        emitted += 1;
                    }
                }
            }
            if let Some(h) = resp.block_hashes.last() {
                last_hash = *h;
            }
            // Next page starts at the last hash (re-included, then skipped by
            // the dedup fold). Reaching the sink returns a short/So single page.
            low = last_hash;
        }
        // Advance the persisted cursor to where the replay reached, so a second
        // open doesn't redo the same walk.
        self.write_cursor_now(&last_hash);
        log::info!("dag-monitor: transport catch-up re-emitted {emitted} match(es)");
        Ok(emitted)
    }

    /// One catch-up page, tolerant of a still-connecting or briefly-flaky wRPC
    /// socket. `include_blocks + include_transactions` because we need the
    /// payloads. Retries up to [`CATCHUP_RPC_ATTEMPTS`] with a
    /// [`CATCHUP_RETRY_DELAY`] pause — the first page on a cold reopen commonly
    /// runs before the reconnect lands, and a single failure must NOT abandon
    /// the walk (the closed-app arrival would be lost, the sitting bug).
    /// `None` after the whole budget = the node is unreachable or the cursor is
    /// pruned.
    async fn catch_up_get_blocks(&self, low: Hash) -> Option<GetBlocksResponse> {
        let rpc = self.inner.client.rpc_api();
        for attempt in 0..CATCHUP_RPC_ATTEMPTS {
            match rpc.get_blocks(Some(low), true, true).await {
                Ok(resp) => return Some(resp),
                Err(e) => {
                    log::debug!(
                        "dag-monitor: catch-up get_blocks attempt {attempt} failed ({}); retrying",
                        link::sanitize_node_text(&e.to_string())
                    );
                    tokio::time::sleep(CATCHUP_RETRY_DELAY).await;
                }
            }
        }
        None
    }

    /// Force-write the cursor now (bypassing the throttle) — used at the ends of
    /// catch-up and on seeding, where the exact point matters.
    fn write_cursor_now(&self, hash: &Hash) {
        let Some(path) = self.transport_cursor_path() else {
            return;
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        self.inner
            .transport_cursor_written
            .store(now, Ordering::Relaxed);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Err(e) = std::fs::write(&path, hash.to_string()) {
            log::warn!("dag-monitor: transport cursor write failed: {e}");
        }
    }

    pub fn mainnet() -> Result<Self> {
        Self::try_new(NetworkId::new(NetworkType::Mainnet), None)
    }

    pub fn is_connected(&self) -> bool {
        self.inner.is_connected.load(Ordering::SeqCst)
    }

    /// Is a connect race alive right now — i.e. are we *hunting for a node*
    /// (C7's second truth)? This is the honest search signal and it holds for
    /// the WHOLE hunt, inter-round pauses included, by construction:
    /// [`Self::spawn_race`] sets the flag before spawning and the spawned task
    /// clears it only after `race_loop().await` RETURNS, while every round —
    /// probe fan-out, the [`link::RACE_RETRY_DELAY`] pause, the next round —
    /// happens inside that one await. So a 14–28 s weak-link hunt (the
    /// 2026-07-30 field capture) reads `true` end to end; it can never blink
    /// off between rounds and let the glass claim connected or offline.
    pub fn is_searching(&self) -> bool {
        self.inner.race_running.load(Ordering::SeqCst)
    }

    /// Has the OS told us the default network is gone (C7's first truth)?
    /// Only ever `true` because Android's `ConnectivityManager` said `onLost`
    /// — never inferred from our own failures, so the glass can say *phone
    /// offline* without ever blaming a node for a dead Wi-Fi link. A launch
    /// that never sees a callback reads `false` (unknown ≠ offline), and the
    /// UI additionally requires a dead socket before rendering it: a live
    /// socket is proof of a network, whatever a flapping callback claims.
    pub fn os_offline(&self) -> bool {
        self.inner.os_offline.load(Ordering::SeqCst)
    }

    /// New receiver onto the event fan-out. Subscribers that join late simply
    /// pick up from the next event — scores tick about once per second.
    pub fn subscribe(&self) -> broadcast::Receiver<DagEvent> {
        self.inner.events.subscribe()
    }

    /// New receiver onto the payload-transport fan-out (P2.1): one
    /// [`TransportEvent`] per `ciph_msg:` match seen in the BlockAdded stream.
    /// Live-only by design (D-049/§0.3): a late subscriber sees the next match,
    /// never history — the P2.3 message store owns persistence. Rides the same
    /// socket + pause/resume posture as everything else (foreground-only).
    pub fn subscribe_transport(&self) -> broadcast::Receiver<TransportEvent> {
        self.inner.transport_events.subscribe()
    }

    /// The shared wRPC handle (`rpc_api` + `rpc_ctl`), for binding a wallet-core
    /// `UtxoProcessor` to this same connection — one client for both DAG status
    /// and wallet sync (P1 §0.8 / D-005: no DAA divergence, one socket to
    /// manage). The processor reacts to the client's `RpcState` over the shared
    /// ctl multiplexer, so it connects and resyncs in lockstep with the monitor.
    pub fn rpc(&self) -> Rpc {
        Rpc::new(
            self.inner.client.rpc_api(),
            self.inner.client.rpc_ctl().clone(),
        )
    }

    /// Spawns the event task and initiates the first connect. Resolver mode
    /// starts the race task (non-blocking, D-081 — the app is the one
    /// reconnect authority); an explicitly pinned URL keeps the ws client's
    /// own Retry loop (loyalty is correct for a pinned node).
    ///
    /// Must be called from within a tokio runtime.
    pub async fn start(&self) -> Result<()> {
        // Register on the ctl multiplexer *before* connecting so the first
        // Connected event cannot be missed.
        let ctl_channel = self.inner.client.rpc_ctl().multiplexer().channel();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        *self
            .inner
            .shutdown
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(shutdown_tx);

        let monitor = self.clone();
        let task = tokio::spawn(async move {
            monitor
                .event_loop(ctl_channel.receiver.clone(), shutdown_rx)
                .await;
        });
        *self
            .inner
            .event_task
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(task);

        if let Some(url) = &self.inner.direct_url {
            let options = ConnectOptions {
                url: Some(url.clone()),
                block_async_connect: false,
                strategy: ConnectStrategy::Retry,
                ..Default::default()
            };
            self.inner.client.connect(Some(options)).await?;
        } else {
            self.spawn_race();
        }
        Ok(())
    }

    /// Spawn the race task unless one is already running (single-flight —
    /// exactly one reconnect authority, D-081). Returns whether a NEW loop
    /// was spawned; the already-running path is never silent (C4/D-089 — the
    /// old silent return here was half of the dead-Reconnect symptom) and
    /// callers holding a user gesture escalate it to a [`Self::kick_race`].
    fn spawn_race(&self) -> bool {
        if self.inner.direct_url.is_some() {
            return false; // pinned mode: the ws Retry loop owns the link
        }
        if self.inner.race_running.swap(true, Ordering::SeqCst) {
            log::info!("link: spawn_race — a race loop is already hunting");
            return false;
        }
        let monitor = self.clone();
        tokio::spawn(async move {
            monitor.race_loop().await;
            monitor.inner.race_running.store(false, Ordering::SeqCst);
        });
        true
    }

    /// The tap always acts (C4): when a race is already hunting, interrupt
    /// its retry PAUSE — kicks never abort in-flight probes (the reaper
    /// finding) and never spawn a second search authority (D-081, ruling 2).
    fn kick_race(&self, source: &str) {
        log::info!("link: reconnect tap — race already hunting; kicked the retry pause ({source})");
        spans::mark_with("race_kick", source);
        self.inner.race_kick.notify_one();
    }

    /// Spawn-or-kick (C4): the one entry every recovery gesture routes
    /// through — a fresh race if none is running, a kick into the live one's
    /// retry pause otherwise. Pinned mode does neither (the ws Retry loop
    /// owns a pinned link).
    fn spawn_or_kick_race(&self, source: &str) {
        if !self.spawn_race() && self.inner.direct_url.is_none() {
            self.kick_race(source);
        }
    }

    /// Bound the wait on the SHARED client's teardown (C2 fix, the C1 class):
    /// the pin's `disconnect()` is a dispatcher handshake a blackholed socket
    /// can starve (`workflow-websocket 0.18.0 client/native.rs:322-334` —
    /// `ws_sender.send().await` inside a select arm body), and
    /// `KaspaRpcClient::disconnect` serializes callers on `disconnect_guard`
    /// (pin `client.rs:476-482`), so ONE hung teardown would wedge every
    /// later caller — including the event loop, which calls this inline. The
    /// teardown is detached, never cancelled (the reaper rule), and MAY
    /// never complete (an error-path dispatcher exit orphans the handshake);
    /// the wait is bounded, and the guard it can hold is why the winner bind
    /// carries [`BIND_ENVELOPE_TIMEOUT`].
    async fn bounded_disconnect(&self) {
        link::bounded_disconnect((*self.inner.client).clone(), link::DISCONNECT_WAIT_TIMEOUT).await;
    }

    /// The connect race (V3 deliverable 1): candidates = the cached last-good
    /// endpoint (immediate dial — the fast path; it wins every tie because
    /// resolver candidates first spend an HTTP round-trip) + [`RACE_FETCHES`]
    /// parallel resolver fetches, demoted endpoints excluded; first HEALTHY
    /// probe wins and the shared socket binds to it. Loops (bounded pause)
    /// until bound, paused, or shut down — the replacement for the ws-level
    /// endless Retry.
    async fn race_loop(&self) {
        // V1 span: cold-connect measures from here to `wss_connected`.
        spans::mark("connect_start");
        let mut empty_rounds = 0u32;
        loop {
            if self.inner.paused.load(Ordering::SeqCst) || self.is_connected() {
                return;
            }
            let now = Self::now_unix();
            let advisory = empty_rounds >= 2;
            let cached = self.read_cached_endpoint();
            let (demoted, pantry) = {
                let health = self
                    .inner
                    .health
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let demoted = if advisory {
                    // Never strand the wallet on hygiene: two whole rounds
                    // found nothing healthy, so demotion degrades to advisory
                    // — a flaky node beats no node (connectivity over
                    // cleanliness).
                    Default::default()
                } else {
                    health.demoted_set(now)
                };
                // The pantry (C6): recent-healthy nodes dial immediately, in
                // parallel with the cached endpoint — the common reconnect
                // does zero HTTP before dialing a node it trusted recently.
                // Under the advisory degradation it ignores demotions too
                // (R2 D5): a floor that leaves the fast path dark is not a
                // floor, it is a slower way to reach the same dark wallet.
                let pantry =
                    health.race_pantry(cached.as_deref(), now, link::PANTRY_DIALS, advisory);
                (demoted, pantry)
            };
            let outcome = link::race(
                &self.inner.resolver,
                self.inner.network_id,
                cached,
                pantry,
                &demoted,
                RACE_FETCHES,
                PROBE_TIMEOUT,
            )
            .await;

            // Judge the ROUND before judging its members (R2 field addendum,
            // widened at R3 D-099): whether a DNS/route failure is the node's
            // fault or the phone's is not visible in any single failure, only
            // in how many DISTINCT hosts failed phone-side at the same moment.
            let phone_fault = link::phone_fault_in_round(&outcome.failed);
            let Some(winner) = outcome.winner else {
                empty_rounds += 1;
                // The link-blackout stamp lives in the NO-WINNER arm only
                // (R3 wallet-security finding): a round that produced a live
                // prover proved the phone's network works, and stamping it
                // would let one stray unreachable candidate nullify the very
                // control-group conviction that round earned.
                if phone_fault {
                    self.inner.phone_fault_round_at.store(now, Ordering::SeqCst);
                    log::info!(
                        "link: round failed phone-side across {}+ distinct hosts \
                         (DNS/unreachable) — stamped as link blackout",
                        link::DNS_CORRELATION_MIN
                    );
                }
                // ONE line per empty round (R0 addendum #1, built at R1). An
                // outage used to spend ~9 INFO lines a round (a line per
                // resolver-fetch failure, a line per probe failure, then the
                // round line) — and under the weak-link condition the shared
                // ring retains only ~2 minutes, so the round pressure helped
                // evict its own head before it could be pulled (L65). Every
                // reason is still here, verbatim; only the line count shrank.
                // NOTE the honest bound: coalescing reduces OUR pressure, it
                // does not fix the class — Android's Wi-Fi subsystem is the
                // bigger spammer exactly when connectivity fails.
                log::info!(
                    "link: race round {empty_rounds} found no healthy endpoint ({} probe failure(s), {} other loss(es)) [{}] — retrying in {:?}",
                    outcome.failed.len(),
                    outcome.notes.len().saturating_sub(outcome.failed.len()),
                    link::summarize_losses(&outcome.notes),
                    RACE_RETRY_DELAY
                );
                // Kickable pause (C4): a Reconnect tap / resume / OS
                // network-available signal skips the wait and races NOW.
                // Kicks interrupt the SLEEP only — in-flight probes were
                // already drained by race() above (the reaper finding
                // stands: probes are never aborted).
                tokio::select! {
                    _ = tokio::time::sleep(RACE_RETRY_DELAY) => {}
                    _ = self.inner.race_kick.notified() => {
                        log::info!("link: retry pause kicked — racing immediately");
                    }
                }
                continue;
            };
            // A winning round's losers get the same one-line treatment — the
            // strike lines below name the URLs but not WHY, and the why is what
            // separated `ivy`'s real HTTP 500 from four weak-link timeouts in
            // the 2026-07-30 capture.
            if !outcome.notes.is_empty() {
                log::info!(
                    "link: race round {} lost {} candidate(s) before the winner [{}]",
                    empty_rounds + 1,
                    outcome.notes.len(),
                    link::summarize_losses(&outcome.notes)
                );
            }
            empty_rounds = 0;

            // A healthy node answered → the network is alive → probe failures
            // were the NODES' fault: strike them. (The drop that triggered
            // this race is parked as the pending strike and settles at the
            // Connected event — robust to a phantom redial winning first.)
            // The round-correlation verdict still travels with each loss so
            // correlated DNS/unreachable losses are withheld (D-097 widened).
            if phone_fault {
                log::info!(
                    "link: DNS/route failure across {}+ distinct endpoints this round — \
                     reading it as the phone, not the nodes (those strikes withheld)",
                    link::DNS_CORRELATION_MIN
                );
            }
            for (url, reason) in &outcome.failed {
                self.commit_strike(url, *reason, now, phone_fault);
            }

            // Someone else (a ws-level phantom redial) may have connected
            // while the race ran; the Connected-time demotion check has
            // already judged them. Never bind over a live socket.
            if self.inner.paused.load(Ordering::SeqCst) || self.is_connected() {
                return;
            }

            log::info!(
                "link: race winner {} (server {}, rpc v{}, daa {}){}",
                winner.url,
                winner.server_version,
                winner.rpc_api_version,
                winner.virtual_daa_score,
                if advisory { " [hygiene advisory]" } else { "" }
            );
            spans::mark_with("race_winner", &winner.url);
            // Pantry stamp (C6): a probe win IS an observed-healthy moment.
            self.mark_endpoint_healthy(&winner.url);
            // An advisory bind to a still-demoted endpoint must not be
            // bounced by our own Connected-time enforcement.
            self.inner.hygiene_advisory.store(
                advisory
                    && self
                        .inner
                        .health
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .is_demoted(&winner.url, Self::now_unix()),
                Ordering::SeqCst,
            );

            let options = ConnectOptions {
                url: Some(winner.url.clone()),
                strategy: ConnectStrategy::Fallback,
                block_async_connect: true,
                connect_timeout: Some(BIND_TIMEOUT),
                ..Default::default()
            };
            // Envelope-bounded (BLOCK fix at R0): the connect's error arm
            // can block on the pin's disconnect_guard behind a starved
            // teardown — bound the whole call at OUR boundary (item 19).
            // A dropped connect future is safe under existing law: a
            // Fallback dial failure self-terminates, AlreadyConnected
            // returns before a loop spawns, and a late success is judged
            // at Connected (D-084 machinery — no second authority).
            match tokio::time::timeout(
                BIND_ENVELOPE_TIMEOUT,
                self.inner.client.connect(Some(options)),
            )
            .await
            {
                Ok(Ok(_)) => {
                    // A pause that landed mid-bind wins: drop the socket.
                    if self.inner.paused.load(Ordering::SeqCst) {
                        self.bounded_disconnect().await;
                    }
                    return;
                }
                Ok(Err(e)) => {
                    // Died between probe and bind — strike (network known
                    // alive: it just answered a probe elsewhere) and re-race.
                    log::warn!(
                        "link: bind to race winner {} failed: {}",
                        winner.url,
                        link::sanitize_node_text(&e.to_string())
                    );
                    self.commit_strike(
                        &winner.url,
                        link::StrikeReason::BindFailed,
                        Self::now_unix(),
                        false,
                    );
                }
                Err(_) => {
                    // NO strike: the node just won a probe — this is our own
                    // teardown guard blocking, not the endpoint's fault.
                    log::warn!(
                        "link: bind to race winner {} exceeded {BIND_ENVELOPE_TIMEOUT:?} \
                         (teardown guard suspected) — re-racing, no strike",
                        winner.url
                    );
                }
            }
        }
    }

    /// Background grace-drop (PERFORMANCE_BUDGET "battery posture"): close the
    /// socket and stand the race down, keeping the event task and every
    /// subscriber attached. The wallet processor pauses with the shared ctl and
    /// resyncs in lockstep on [`Self::resume`] (§0.8 / D-005).
    pub async fn pause(&self) -> Result<()> {
        self.inner.paused.store(true, Ordering::SeqCst);
        self.bounded_disconnect().await;
        Ok(())
    }

    /// Foreground resume after a grace-drop: re-race (the cached last-good
    /// endpoint, persisted at most 30 s + grace ago, is candidate 0 and wins
    /// every tie). No-op while already connected (never bounce a healthy
    /// socket); a race already hunting gets kicked instead of ignored (C4).
    pub async fn resume(&self) -> Result<()> {
        spans::mark("resume_start");
        self.inner.paused.store(false, Ordering::SeqCst);
        if self.is_connected() {
            return Ok(());
        }
        self.spawn_or_kick_race("resume");
        Ok(())
    }

    /// Force a fresh connection — the P3 honest-liveness Reconnect control,
    /// the foreground watchdog's recovery (D-068) and the V3 pull-heal resync.
    /// Unlike [`resume`], it does NOT short-circuit on `is_connected()`: a
    /// silently dead wRPC socket can still report connected, so recovering it
    /// needs a hard disconnect + re-race.
    ///
    /// `stalled = true` means the caller HAS failure evidence against the
    /// current endpoint (the watchdog's 30 s block silence) — it enters the
    /// race as a pending strike, committed only if the race finds a healthy
    /// node (control-group rule). A manual Reconnect passes `false`: bouncing
    /// a healthy node must never demote it.
    pub async fn reconnect(&self, stalled: bool) -> Result<()> {
        self.inner.paused.store(false, Ordering::SeqCst);
        if stalled {
            // The watchdog's claim is judged against OUR clocks (R3 D-099).
            // Its Dart-side block-age is process-lifetime, so after a link
            // blackout every fresh bind inherits silence older than itself
            // and used to be executed on the next 10 s tick — runs of ~10 s,
            // repeatedly, one innocent endpoint demoted per cycle (the
            // D-095/D-098 cascade signature). A stall claim now only
            // executes a CONNECTED socket that has ITSELF been silent past
            // the threshold.
            match self.stall_verdict() {
                StallVerdict::Execute { silent_secs } => {
                    if let Some(url) = self.inner.client.url() {
                        let run_secs = Self::now_unix()
                            .saturating_sub(self.inner.connected_at.load(Ordering::Relaxed));
                        log::info!(
                            "link: watchdog stall confirmed on {url} \
                             (socket silent {silent_secs}s) — executing"
                        );
                        self.record_socket_run(&url, run_secs, "watchdog-stall");
                        self.set_pending_strike(url, link::StrikeReason::Stall);
                    }
                }
                StallVerdict::Refuse { silent_secs } => {
                    // No teardown either: the claim is void, and bouncing a
                    // young socket every tick IS the cascade.
                    log::info!(
                        "link: watchdog stall claim refused — socket silent only \
                         {silent_secs}s (< {}s)",
                        link::WATCHDOG_STALL_SECS
                    );
                    return Ok(());
                }
                StallVerdict::Hunting => {
                    // There is no defendant, but the claim still means the
                    // wallet is dark — keep C4's promise and kick the hunt.
                    log::info!("link: watchdog stall claim while hunting — kicking the race");
                    self.spawn_or_kick_race("watchdog-kick");
                    return Ok(());
                }
            }
        }
        // Mark down BEFORE dropping the socket: the ctl Disconnected can be
        // processed DURING disconnect().await, and the event arm's swap-once
        // guard must see "already down" — a deliberate reconnect (pull heal,
        // manual button) must never park a strike against the healthy
        // endpoint it is bouncing (caught live at the V3 sitting: a
        // swipe-to-refresh demoted the innocent incumbent). Also keeps the
        // race loop we spawn from reading a stale `connected` and exiting.
        self.inner.is_connected.store(false, Ordering::SeqCst);
        self.bounded_disconnect().await;
        // Spawn-or-kick (C4): the tap always acts. The old path silently
        // no-opped here whenever a wedged race loop still held the
        // single-flight flag — the dead-Reconnect symptom's second half.
        self.spawn_or_kick_race("reconnect");
        Ok(())
    }

    /// OS default-network transition (C5/D-089 ruling 4), relayed from
    /// Android's `ConnectivityManager` over the platform channel + bridge.
    /// Semantics: available with a dead link → redial NOW (spawn-or-kick)
    /// instead of waiting out a retry pause or the 30 s watchdog; available
    /// while connected → log only (the watchdog owns staleness — OS
    /// callbacks can flap, and a handoff-killed socket fires its own
    /// Disconnected); lost → log + span only (passive first: the socket's
    /// own death drives recovery; more aggression only if the soak proves
    /// the watchdog gap hurts). Paused (backgrounded) → observe, never dial:
    /// the battery posture owns the socket then, and resume() re-races.
    pub fn network_changed(&self, available: bool) {
        // Record it for the glass (C7) before deciding what to DO about it:
        // the honest-states surface needs the OS's word even on the paths that
        // deliberately take no action.
        self.inner.os_offline.store(!available, Ordering::SeqCst);
        if !available {
            // R2 D3: the boolean alone cannot judge admissibility — by the
            // time a parked strike settles, `onAvailable` has usually already
            // flipped it back to false, erasing the very fact the rule needs.
            // Stamp the TRANSITION so the window survives the recovery.
            self.inner
                .os_lost_at
                .store(Self::now_unix(), Ordering::SeqCst);
            spans::mark("network_lost");
            log::info!("link: OS network lost — passive (the socket's own death drives recovery)");
            return;
        }
        spans::mark("network_available");
        if self.inner.paused.load(Ordering::SeqCst) {
            log::info!(
                "link: OS network available while paused — background posture holds, no dial"
            );
        } else if self.is_connected() {
            log::info!(
                "link: OS network available while connected — no action (watchdog owns staleness)"
            );
        } else {
            log::info!("link: OS network available while disconnected — racing now");
            self.spawn_or_kick_race("network_available");
        }
    }

    /// Durably record that a socket's run ended, however it ended (R3 D1).
    /// One greppable lifecycle line + the `last_run_secs` ledger write, from
    /// the SHARED seam both death paths call — the Disconnected arm and the
    /// watchdog execution. The watchdog path used to bypass the Disconnected
    /// arm entirely (it pre-clears `is_connected`, so the swap-once guard
    /// skips the judged branch), which is why D-098 read a column of zeros
    /// after a watchdog-driven cascade: the writer existed and was never on
    /// that path.
    fn record_socket_run(&self, url: &str, run_secs: u64, cause: &str) {
        {
            let mut health = self
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            health.record_run(url, run_secs);
            self.save_health(&health);
        }
        log::info!("link: run ended url={url} run={run_secs}s cause={cause}");
    }

    /// The stall verdict for a watchdog claim (R3 D-099), judged against OUR
    /// clocks: the Dart watchdog's block-age is process-lifetime, so after a
    /// link blackout it reads stale silence against a seconds-old socket.
    /// The evidence baseline is `max(last_block_at, connected_at)` — a socket
    /// cannot be guilty of silence older than itself.
    fn stall_verdict(&self) -> StallVerdict {
        if !self.is_connected() {
            return StallVerdict::Hunting;
        }
        let now = Self::now_unix();
        let baseline = self
            .inner
            .last_block_at
            .load(Ordering::Relaxed)
            .max(self.inner.connected_at.load(Ordering::Relaxed));
        let silent_secs = now.saturating_sub(baseline);
        if baseline != 0 && silent_secs > link::WATCHDOG_STALL_SECS {
            StallVerdict::Execute { silent_secs }
        } else {
            StallVerdict::Refuse { silent_secs }
        }
    }

    /// Record that a block just arrived (the watchdog heartbeat).
    fn mark_block_seen(&self) {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        self.inner.last_block_at.store(now, Ordering::Relaxed);
    }

    /// Seconds since the last BlockAdded, or `None` if none has arrived yet
    /// (fresh boot / never connected). The watchdog's honest-liveness reading:
    /// a healthy mainnet keeps this near zero; a stalled socket lets it grow.
    pub fn last_block_age_secs(&self) -> Option<u64> {
        let last = self.inner.last_block_at.load(Ordering::Relaxed);
        if last == 0 {
            return None;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        Some(now.saturating_sub(last))
    }

    /// Disconnects, then signals the event task and waits for it to drain.
    /// Sets `paused` so a live race loop stands down instead of redialing.
    pub async fn stop(&self) -> Result<()> {
        self.inner.paused.store(true, Ordering::SeqCst);
        self.bounded_disconnect().await;
        let shutdown = self
            .inner
            .shutdown
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(tx) = shutdown {
            let _ = tx.send(());
        }
        let task = self
            .inner
            .event_task
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(task) = task {
            let _ = task.await;
        }
        Ok(())
    }

    fn emit(&self, event: DagEvent) {
        // Send fails only when no receiver is subscribed yet — fine to drop.
        let _ = self.inner.events.send(event);
    }

    async fn event_loop(
        self,
        ctl_rx: async_channel::Receiver<RpcState>,
        mut shutdown_rx: oneshot::Receiver<()>,
    ) {
        let notification_rx = self.inner.notification_rx.clone();
        loop {
            tokio::select! {
                // Poll order matters (biased): drain ctl + notifications
                // before honoring shutdown, mirroring the upstream example.
                biased;
                msg = ctl_rx.recv() => {
                    match msg {
                        Ok(RpcState::Connected) => {
                            // This connect IS the network-alive proof: settle
                            // the parked strike (commit fresh from a DIFFERENT
                            // prover; discard stale or self-refuted — D-084).
                            let prover = self.inner.client.url();
                            self.settle_pending_strike(prover.as_deref());
                            // Demotion enforcement at the one choke point
                            // every connection passes — a demoted endpoint
                            // that sneaks back in (a ws-level phantom redial,
                            // a poisoned cache) is refused and re-raced,
                            // UNLESS the race itself bound it knowingly
                            // (hygiene advisory: nothing healthier exists).
                            if self.inner.direct_url.is_none()
                                && !self.inner.hygiene_advisory.load(Ordering::SeqCst)
                                && !self.inner.paused.load(Ordering::SeqCst)
                            {
                                let demoted_url = self.inner.client.url().filter(|url| {
                                    self.inner
                                        .health
                                        .lock()
                                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                                        .is_demoted(url, Self::now_unix())
                                });
                                if let Some(url) = demoted_url {
                                    log::warn!(
                                        "link: demoted endpoint reconnected — refusing {url} and re-racing"
                                    );
                                    self.bounded_disconnect().await;
                                    self.spawn_race();
                                    continue;
                                }
                            }
                            match self.handle_connect().await {
                                Ok(()) => {
                                    // `connected_at` FIRST, `is_connected` second (R3
                                    // consensus-audit finding): the SeqCst store
                                    // publishes the stamp, so a stall claim landing
                                    // between the two can never judge this fresh
                                    // socket against the PRIOR socket's baseline —
                                    // the exact class D-099 exists to kill.
                                    self.inner.connected_at.store(Self::now_unix(), Ordering::Relaxed);
                                    self.inner.is_connected.store(true, Ordering::SeqCst);
                                    // V1 spans: close the cold-connect leg,
                                    // arm the first-DAA one.
                                    spans::mark("wss_connected");
                                    self.inner.daa_seen_since_connect.store(false, Ordering::Relaxed);
                                    log::info!("dag-monitor: connected to {:?}", self.inner.client.url());
                                    // Remember the node that worked — it is
                                    // candidate 0 (the fast path) of the next
                                    // cold start / post-grace race — and stamp
                                    // it observed-healthy for the pantry (C6).
                                    if let Some(url) = self.inner.client.url() {
                                        self.persist_endpoint(&url);
                                        self.mark_endpoint_healthy(&url);
                                    }
                                    self.emit(DagEvent::Connected { url: self.inner.client.url() });
                                }
                                // Stay "disconnected"; the race re-heal below
                                // answers the Disconnected this failure ends in.
                                // KNOWN GAP (audited 2026-06-12, [→ P1]): if the
                                // node accepts the socket but rejects a
                                // subscription, the link idles half-set-up until
                                // the next natural reconnect.
                                Err(e) => log::warn!(
                                    "dag-monitor: subscription setup failed: {}",
                                    link::sanitize_node_text(&e.to_string())
                                ),
                            }
                        }
                        Ok(RpcState::Disconnected) => {
                            // Swap-once: only a drop of a connection we KNEW
                            // was live re-heals (bind failures and our own
                            // deliberate disconnects also surface here).
                            let was_connected =
                                self.inner.is_connected.swap(false, Ordering::SeqCst);
                            log::info!("dag-monitor: disconnected");
                            self.handle_disconnect().await;
                            if was_connected
                                && !self.inner.paused.load(Ordering::SeqCst)
                                && self.inner.direct_url.is_none()
                            {
                                // The app is the one reconnect authority
                                // (D-081): kill the ws-level loop still loyal
                                // to the dropped URL (best-effort — a dial
                                // already in flight can't be aborted; the
                                // Connected-time checks above judge whatever
                                // it lands), judge the run (a clean run
                                // clears strikes; a short one parks a strike
                                // for the next connect to settle), re-race.
                                let dropped = self.inner.client.url();
                                self.bounded_disconnect().await;
                                let run_secs = Self::now_unix().saturating_sub(
                                    self.inner.connected_at.load(Ordering::Relaxed),
                                );
                                // R2 D4: record the run length for EVERY
                                // judgment before deciding what it means —
                                // the floor can only be re-examined against
                                // the drops it absorbed, and a ledger that
                                // stored only convictions would keep proving
                                // the floor right by construction. Through
                                // the SHARED seam (R3 D1): the watchdog path
                                // records the same way, so a cascade can no
                                // longer zero the very column built to
                                // diagnose it.
                                if let Some(url) = dropped.as_deref() {
                                    self.record_socket_run(url, run_secs, "ctl-drop");
                                }
                                match (dropped, link::judge_run(run_secs)) {
                                    (Some(url), link::RunJudgment::CleanRun) => {
                                        self.commit_clean_run(&url);
                                    }
                                    (Some(url), link::RunJudgment::Strike) => {
                                        self.set_pending_strike(url, link::StrikeReason::Drop)
                                    }
                                    (Some(url), link::RunJudgment::ChurnNoise) => {
                                        // V6 churn-smoothing (item 16): a run
                                        // this short never lived — its death
                                        // says nothing about the endpoint.
                                        log::info!(
                                            "link: drop after {run_secs}s run on {url} — churn noise, no strike"
                                        );
                                    }
                                    (None, _) => {}
                                }
                                self.spawn_race();
                            }
                        }
                        // Ctl channel closed: client is gone, nothing to track.
                        Err(_) => {
                            log::warn!("dag-monitor: ctl channel closed — event task exiting");
                            break;
                        }
                    }
                }
                notification = notification_rx.recv() => {
                    match notification {
                        // P2.1 payload scan: BlockAdded is consumed here — the
                        // ~10 blocks/s stream never leaves this task; only
                        // `ciph_msg:` matches fan out (sparse by design, §0.3).
                        // Version-neutral by construction (transport.rs, §0.2).
                        Ok(Notification::BlockAdded(added)) => {
                            let matches = transport::scan_block(&added.block, self.inner.address_prefix);
                            if !matches.is_empty() {
                                // Three-lights producer log (V3/L55): count +
                                // receiver count only — payload bodies are
                                // never logged (§4 plaintext discipline).
                                // `info`: the liblog lane is Info-max, a
                                // `debug` light is dark on device (L53).
                                log::info!(
                                    "dag-monitor: transport emit matches={} receivers={}",
                                    matches.len(),
                                    self.inner.transport_events.receiver_count()
                                );
                            }
                            for event in matches {
                                // Send fails only with zero subscribers — fine.
                                let _ = self.inner.transport_events.send(event);
                            }
                            // Liveness heartbeat for the watchdog (P3): a block
                            // arrived, the socket is alive right now.
                            self.mark_block_seen();
                            // Advance the catch-up cursor past this scanned block
                            // (throttled; no-op until transport arms it). P5/D-067.
                            self.persist_transport_cursor(&added.block.header.hash);
                        }
                        // V1 acceptance spine: forward the batch to the tracker
                        // task when one is attached (never processed here — the
                        // event loop stays non-blocking; blue-score resolution
                        // and persistence live in the tracker).
                        Ok(Notification::VirtualChainChanged(vcc)) => {
                            let sender = self
                                .inner
                                .vcc_tx
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .clone();
                            if let Some(tx) = sender {
                                let accepted: Vec<(Hash, Vec<Hash>)> = vcc
                                    .accepted_transaction_ids
                                    .iter()
                                    .map(|a| (a.accepting_block_hash, a.accepted_transaction_ids.clone()))
                                    .collect();
                                let _ = tx.send(VccBatch {
                                    removed_chain_block_hashes: vcc.removed_chain_block_hashes.clone(),
                                    added_chain_block_hashes: vcc.added_chain_block_hashes.clone(),
                                    accepted: Arc::new(accepted),
                                });
                            }
                        }
                        Ok(notification) => {
                            if let Some(event) = map_notification(&notification) {
                                // V1 span: the first DAA tick after a connect
                                // closes the time-to-first-DAA row.
                                if matches!(event, DagEvent::VirtualDaaScore(_))
                                    && !self.inner.daa_seen_since_connect.swap(true, Ordering::Relaxed)
                                {
                                    spans::mark("first_daa");
                                }
                                self.emit(event);
                            }
                        }
                        Err(_) => {
                            log::warn!("dag-monitor: notification channel closed — event task exiting");
                            break;
                        }
                    }
                }
                _ = &mut shutdown_rx => break,
            }
        }
        if self.is_connected() {
            self.handle_disconnect().await;
        }
    }

    /// Scopes are per-connection node state — re-register on every connect.
    async fn handle_connect(&self) -> Result<()> {
        let rpc = self.inner.client.rpc_api();
        // Item 9 (V2 sitting, doubled Connected): a listener from a prior
        // connect that survived to here would ALSO receive every notification
        // — same channel, doubled stream bandwidth. The double-connect race
        // is architecturally gone (one reconnect authority, D-081), but a
        // leaked listener must still be impossible: unregister before
        // registering, and say so if one is ever found.
        let prior = self
            .inner
            .listener_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(id) = prior {
            // R2 D2/D3: this is no longer only a hygiene warning. It is the
            // one positive detector we have for "a socket exists that we did
            // not create" — so stamp it, and let the strike path refuse to
            // convict a node for anything dying in its neighbourhood.
            self.inner
                .doubled_connect_at
                .store(Self::now_unix(), Ordering::SeqCst);
            log::warn!(
                "dag-monitor: prior listener survived to a new connect — unregistering (item 9); \
                 strikes are inadmissible for {}s (R2 D3)",
                link::SELF_INFLICTED_ADJACENCY_SECS
            );
            let _ = rpc.unregister_listener(id).await;
        }
        let listener_id = rpc.register_new_listener(ChannelConnection::new(
            "kaspaverse-dag-monitor",
            self.inner.notification_tx.clone(),
            ChannelType::Persistent,
        ));
        *self
            .inner
            .listener_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(listener_id);
        rpc.start_notify(
            listener_id,
            Scope::VirtualDaaScoreChanged(VirtualDaaScoreChangedScope {}),
        )
        .await?;
        rpc.start_notify(
            listener_id,
            Scope::SinkBlueScoreChanged(SinkBlueScoreChangedScope {}),
        )
        .await?;
        // P2.1: the payload-transport scan source. Joins the SAME listener +
        // channel as the score scopes (D-053 single-listener machinery; §0.3) —
        // re-registered on every connect like the others, paused with the
        // socket (foreground-only posture unchanged).
        rpc.start_notify(listener_id, Scope::BlockAdded(BlockAddedScope {}))
            .await?;
        // V1 acceptance spine (D-073): which txids each chain block accepted,
        // plus removed-chain-block hashes on reorg — same listener, same
        // socket (D-005), re-registered per connect like the rest. The stream
        // is consumed by the event task and forwarded (sparse-filtered by the
        // tracker) — it never crosses to Dart.
        rpc.start_notify(
            listener_id,
            Scope::VirtualChainChanged(VirtualChainChangedScope {
                include_accepted_transaction_ids: true,
            }),
        )
        .await?;
        Ok(())
    }

    async fn handle_disconnect(&self) {
        let listener_id = self
            .inner
            .listener_id
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(id) = listener_id {
            // Best-effort: on a dropped connection the node already forgot us.
            let _ = self.inner.client.rpc_api().unregister_listener(id).await;
        }
        self.inner.is_connected.store(false, Ordering::SeqCst);
        self.emit(DagEvent::Disconnected);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_daa_and_blue_score_notifications() {
        let daa = Notification::VirtualDaaScoreChanged(VirtualDaaScoreChangedNotification {
            virtual_daa_score: 123_456_789_012,
        });
        assert_eq!(
            map_notification(&daa),
            Some(DagEvent::VirtualDaaScore(123_456_789_012))
        );

        let blue = Notification::SinkBlueScoreChanged(SinkBlueScoreChangedNotification {
            sink_blue_score: 98_765_432_109,
        });
        assert_eq!(
            map_notification(&blue),
            Some(DagEvent::SinkBlueScore(98_765_432_109))
        );

        let other = Notification::NewBlockTemplate(NewBlockTemplateNotification {});
        assert_eq!(map_notification(&other), None);
    }

    #[test]
    fn constructs_mainnet_monitor_without_network() {
        let monitor = DagMonitor::mainnet().expect("resolver-based client construction is offline");
        assert!(!monitor.is_connected());
    }

    /// D-084 (V4 sitting live-lock): a parked strike settled by the struck
    /// endpoint's OWN successful reconnect is REFUTED — never committed. A
    /// different prover still commits (the true control-group). Without the
    /// self-refute rule, post-airplane Wi-Fi churn demoted every endpoint via
    /// its own reconnect and the Connected-time refusal stranded connectivity.
    #[test]
    fn own_reconnect_refutes_parked_strike_other_prover_commits() {
        const URL: &str = "wss://emma.example/kaspa/mainnet/wrpc/borsh";
        const OTHER: &str = "wss://lena.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");
        let demoted = |m: &DagMonitor| {
            m.inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .is_demoted(URL, DagMonitor::now_unix())
        };

        // Self-refute, twice over (would demote at 2 commits): stays clean.
        for _ in 0..2 {
            monitor.set_pending_strike(URL.to_string(), link::StrikeReason::Drop);
            monitor.settle_pending_strike(Some(URL));
        }
        assert!(!demoted(&monitor), "own reconnect must refute, not convict");

        // Control group intact: a DIFFERENT prover commits; two commits demote.
        for _ in 0..2 {
            monitor.set_pending_strike(URL.to_string(), link::StrikeReason::Drop);
            monitor.settle_pending_strike(Some(OTHER));
            // Past the same-incident dedup window the ledger counts each
            // commit separately; simulate by backdating the last strike.
            monitor
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .backdate_last_strike(URL, link::STRIKE_DEDUP_SECS + 1);
        }
        assert!(demoted(&monitor), "a different prover still convicts");
    }

    /// **R3 D-099 — the stall verdict is judged against the SOCKET's own
    /// clocks.** The D-098 cascade shape: after a link blackout the Dart
    /// watchdog's process-lifetime block-age reads stale silence against a
    /// seconds-old socket and used to execute it on the next 10 s tick.
    /// PB-026: pre-state assertions are bounds, never equalities.
    #[test]
    fn stall_verdict_never_convicts_a_socket_younger_than_the_silence() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let now = DagMonitor::now_unix();

        // Not connected: no defendant — the claim becomes a hunt kick.
        assert_eq!(monitor.stall_verdict(), StallVerdict::Hunting);

        monitor.inner.is_connected.store(true, Ordering::SeqCst);

        // The regression case: blocks last seen 120 s ago (the BLACKOUT'S
        // silence), socket bound 5 s ago (ivy, 2026-07-31 01:00:18) — the
        // old rule executed it; the socket must keep its window.
        monitor
            .inner
            .last_block_at
            .store(now.saturating_sub(120), Ordering::Relaxed);
        monitor
            .inner
            .connected_at
            .store(now.saturating_sub(5), Ordering::Relaxed);
        assert!(
            matches!(monitor.stall_verdict(), StallVerdict::Refuse { silent_secs } if silent_secs <= 10),
            "a fresh socket must not inherit the blackout's silence"
        );

        // A true zombie: connected 40+ s and blockless the whole time.
        monitor
            .inner
            .connected_at
            .store(now.saturating_sub(40), Ordering::Relaxed);
        monitor
            .inner
            .last_block_at
            .store(now.saturating_sub(40), Ordering::Relaxed);
        assert!(
            matches!(monitor.stall_verdict(), StallVerdict::Execute { silent_secs } if silent_secs >= link::WATCHDOG_STALL_SECS),
            "a socket silent past the threshold on its own clock is executed"
        );

        // Blocks flowing now: healthy regardless of age.
        monitor.inner.last_block_at.store(now, Ordering::Relaxed);
        assert!(matches!(
            monitor.stall_verdict(),
            StallVerdict::Refuse { .. }
        ));
    }

    /// **R3 D1 — the instrument's call-site seam is itself proven.** D-098's
    /// `last_run_secs` column read 0 in production with a green unit test,
    /// because the store was tested and the CALLER was not (the watchdog
    /// path bypassed the arm that called it). Both death paths now share
    /// [`DagMonitor::record_socket_run`]; this drives it and asserts the
    /// LEDGER changed, and proves a stall parking carries its true reason.
    #[test]
    fn a_socket_death_lands_in_the_ledger_with_its_true_reason() {
        const URL: &str = "wss://emma.example/kaspa/mainnet/wrpc/borsh";
        const PROVER: &str = "wss://lena.example/kaspa/mainnet/wrpc/borsh";
        let monitor = DagMonitor::mainnet().expect("construct");

        monitor.record_socket_run(URL, 27, "watchdog-stall");
        {
            let health = monitor
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            assert_eq!(
                health.last_run_secs(URL),
                Some(27),
                "the run must land in the durable ledger, not only in a log line"
            );
        }

        // A stall execution parks Stall, and the settle commits it as such —
        // the ledger's `why` distinguishes an executed zombie from a drop.
        monitor.set_pending_strike(URL.to_string(), link::StrikeReason::Stall);
        monitor.settle_pending_strike(Some(PROVER));
        let health = monitor
            .inner
            .health
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        assert_eq!(
            health.last_reason(URL),
            Some((link::StrikeReason::Stall, 0)),
            "the committed strike must carry the stall cause, not a flattened drop"
        );
    }

    #[test]
    fn endpoint_cache_round_trips_and_rejects_non_ws() {
        let monitor = DagMonitor::mainnet().expect("construct");
        // Unset path → no fast path, no persist crash.
        assert_eq!(monitor.read_cached_endpoint(), None);
        monitor.persist_endpoint("wss://node.example:17110/kaspa/mainnet/wrpc/borsh");

        let dir = std::env::temp_dir().join(format!("kv-epcache-{}", std::process::id()));
        let path = dir.join("endpoint.cache");
        let _ = std::fs::remove_file(&path);
        monitor.set_endpoint_cache(path.clone());

        // Missing file → None.
        assert_eq!(monitor.read_cached_endpoint(), None);
        // Round-trip.
        monitor.persist_endpoint("wss://node.example:17110/kaspa/mainnet/wrpc/borsh");
        assert_eq!(
            monitor.read_cached_endpoint().as_deref(),
            Some("wss://node.example:17110/kaspa/mainnet/wrpc/borsh")
        );
        // A corrupt/hand-edited file must never redirect the wallet to a
        // non-websocket scheme (it would fail anyway — refuse early).
        std::fs::write(&path, "https://evil.example/steal").unwrap();
        assert_eq!(monitor.read_cached_endpoint(), None);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn transport_cursor_round_trips_and_rejects_garbage() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let dir = std::env::temp_dir().join(format!("kv-tcursor-{}", std::process::id()));
        let path = dir.join("scan.cursor");
        let _ = std::fs::remove_file(&path);

        // No file → None (first run / nothing to recover).
        assert_eq!(DagMonitor::read_transport_cursor(&path), None);
        // Unarmed: persist is a no-op, no crash.
        monitor.write_cursor_now(&Hash::from_bytes([1u8; 32]));
        assert_eq!(DagMonitor::read_transport_cursor(&path), None);

        // Armed: a forced write round-trips as the exact block hash.
        monitor.set_transport_cursor(path.clone());
        let h = Hash::from_bytes([7u8; 32]);
        monitor.write_cursor_now(&h);
        assert_eq!(DagMonitor::read_transport_cursor(&path), Some(h));

        // A corrupt cursor never misdirects the walk — it reads as None (the
        // replay then just seeds from the current sink).
        std::fs::write(&path, "not-a-hash").unwrap();
        assert_eq!(DagMonitor::read_transport_cursor(&path), None);

        let _ = std::fs::remove_file(&path);
    }

    /// C4 (D-089): a Reconnect while a race already holds the single-flight
    /// flag must KICK the live loop's retry pause — the old path silently
    /// no-opped (the dead-Reconnect symptom's second half). Deterministic
    /// seam: the flag is held manually (a live loop's pause, minus the
    /// loop); the kick must reach a waiter on the Notify. The device flap
    /// sitting is the authoritative end-to-end proof (register C8).
    #[tokio::test(flavor = "multi_thread")]
    async fn reconnect_during_a_live_race_kicks_the_retry_pause() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        let inner = monitor.inner.clone();
        let waiter = tokio::spawn(async move { inner.race_kick.notified().await });
        tokio::task::yield_now().await;
        // reconnect() on a never-connected client: the disconnect is a fast
        // no-op; spawn_or_kick sees the held flag and kicks.
        monitor.reconnect(false).await.expect("reconnect");
        tokio::time::timeout(Duration::from_secs(2), waiter)
            .await
            .expect("the kick must reach the race pause — silent no-op regression")
            .expect("waiter task");
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// C4 stored-permit note: a kick with no pause armed is NOT lost — the
    /// next `notified()` consumes it immediately (one spurious immediate
    /// round, the accepted trade in the register).
    #[tokio::test(flavor = "multi_thread")]
    async fn an_unconsumed_kick_is_stored_not_lost() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor.inner.race_running.store(true, Ordering::SeqCst);
        monitor.reconnect(false).await.expect("reconnect");
        tokio::time::timeout(Duration::from_secs(2), monitor.inner.race_kick.notified())
            .await
            .expect("the stored permit must satisfy the next pause");
        monitor.inner.race_running.store(false, Ordering::SeqCst);
    }

    /// C7 (D-089 ruling 6 / D-091 ruling 1): the two bits the honest-states
    /// glass reads. `os_offline` must be OS-driven only — false until a real
    /// `onLost`, cleared by `onAvailable` — and recording it must not disturb
    /// ruling 4's passivity (a lost signal still dials nothing). `is_searching`
    /// must track the single-flight race flag, which is what makes a
    /// multi-round weak-link hunt render as ONE continuous *finding a node…*.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_glass_reads_os_offline_and_searching_honestly() {
        let monitor = DagMonitor::mainnet().expect("construct");

        // Unknown ≠ offline: a launch that never saw a callback must not
        // accuse the phone (the callback speaks only on transitions).
        assert!(!monitor.os_offline(), "never offline before the OS says so");
        assert!(!monitor.is_searching());

        monitor.network_changed(false);
        assert!(monitor.os_offline(), "onLost must be visible to the glass");
        // Ruling 4 holds: lost is passive — nothing was dialed, so the
        // single-flight race flag is untouched.
        assert!(!monitor.is_searching(), "network_lost must not dial");

        monitor.network_changed(true);
        assert!(!monitor.os_offline(), "onAvailable clears the accusation");
        // available && !connected DOES race (C5) — that flag is now the
        // searching truth the beacon renders.
        assert!(monitor.is_searching(), "available while dark starts a hunt");

        // Stand the detached hunt down (offline unit test — it has no node to
        // find and we never await it).
        monitor.inner.paused.store(true, Ordering::SeqCst);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn pause_before_any_connect_is_a_safe_noop() {
        let monitor = DagMonitor::mainnet().expect("construct");
        monitor
            .pause()
            .await
            .expect("disconnect on a never-connected client is Ok");
        assert!(!monitor.is_connected());
        // resume() with no cache + no network initiates the resolver path
        // non-blocking; constructing the future must not panic. We don't await
        // a connection here (offline unit test) — resume itself must be Ok.
        monitor
            .resume()
            .await
            .expect("resume initiates non-blocking connect");
    }

    /// Live smoke test against mainnet via the PNN resolver — run manually:
    /// `cargo test -p kaspaverse-chain -- --ignored --nocapture`
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "requires network; manual proof for P0.3"]
    async fn live_mainnet_daa_stream() {
        let monitor = DagMonitor::mainnet().expect("construct");
        let mut events = monitor.subscribe();
        monitor.start().await.expect("start");
        let deadline = std::time::Duration::from_secs(60);
        let mut got_daa = None;
        let mut got_blue = None;
        let started = std::time::Instant::now();
        while (got_daa.is_none() || got_blue.is_none()) && started.elapsed() < deadline {
            match tokio::time::timeout(deadline, events.recv()).await {
                Ok(Ok(DagEvent::VirtualDaaScore(v))) => got_daa = Some(v),
                Ok(Ok(DagEvent::SinkBlueScore(v))) => got_blue = Some(v),
                Ok(Ok(event)) => println!("event: {event:?}"),
                Ok(Err(_)) | Err(_) => break,
            }
        }
        monitor.stop().await.expect("stop");
        println!("daa={got_daa:?} blue={got_blue:?}");
        assert!(got_daa.is_some(), "no VirtualDaaScore within {deadline:?}");
        assert!(got_blue.is_some(), "no SinkBlueScore within {deadline:?}");
    }
}
