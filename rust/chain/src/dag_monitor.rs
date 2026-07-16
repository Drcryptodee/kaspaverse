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
    pending_strike: Mutex<Option<(String, u64)>>,
    /// True while the live bind KNOWINGLY went to a demoted endpoint (two
    /// whole race rounds found nothing healthy — connectivity over hygiene).
    /// Gates the Connected-time demotion refusal so the advisory bind isn't
    /// bounced by our own enforcement.
    hygiene_advisory: AtomicBool,
    /// Unix-seconds of the last `Connected` (0 = never) — a drop after a run
    /// of ≥ [`link::CLEAN_RUN_SECS`] clears the endpoint's strikes instead of
    /// adding one.
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
            // actually resolves (D-081).
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
    fn commit_strike(&self, url: &str, reason: &str) {
        let now = Self::now_unix();
        let demoted = {
            let mut health = self
                .inner
                .health
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let demoted = health.strike(url, now);
            self.save_health(&health);
            demoted
        };
        log::info!(
            "link: strike ({reason}) on {url}{}",
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
    pub fn strike_endpoint(&self, url: &str, reason: &str) {
        self.commit_strike(url, reason);
    }

    /// The endpoint the shared socket is (or was last) bound to — captured by
    /// the send hook at submit time so a later stall strikes the right node.
    pub fn current_url(&self) -> Option<String> {
        self.inner.client.url()
    }

    /// Park a strike until network-alive evidence arrives (the next
    /// `Connected` commits it; staleness discards it).
    fn set_pending_strike(&self, url: String) {
        *self
            .inner
            .pending_strike
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some((url, Self::now_unix()));
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
        if let Some((url, at)) = taken {
            if prover_url == Some(url.as_str()) {
                log::info!(
                    "link: pending strike on {url} refuted by its own reconnect — discarded"
                );
            } else if Self::now_unix().saturating_sub(at) <= link::PENDING_STRIKE_TTL_SECS {
                self.commit_strike(&url, "connection lost");
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
    /// exactly one reconnect authority, D-081).
    fn spawn_race(&self) {
        if self.inner.direct_url.is_some() {
            return; // pinned mode: the ws Retry loop owns the link
        }
        if self.inner.race_running.swap(true, Ordering::SeqCst) {
            return; // a race loop is already on it
        }
        let monitor = self.clone();
        tokio::spawn(async move {
            monitor.race_loop().await;
            monitor.inner.race_running.store(false, Ordering::SeqCst);
        });
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
            let demoted = if advisory {
                // Never strand the wallet on hygiene: two whole rounds found
                // nothing healthy, so demotion degrades to advisory — a
                // flaky node beats no node (connectivity over cleanliness).
                Default::default()
            } else {
                self.inner
                    .health
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .demoted_set(now)
            };
            let cached = self.read_cached_endpoint();
            let outcome = link::race(
                &self.inner.resolver,
                self.inner.network_id,
                cached,
                &demoted,
                RACE_FETCHES,
                PROBE_TIMEOUT,
            )
            .await;

            let Some(winner) = outcome.winner else {
                empty_rounds += 1;
                log::info!(
                    "link: race round {empty_rounds} found no healthy endpoint ({} probe failure(s)) — retrying in {:?}",
                    outcome.failed.len(),
                    RACE_RETRY_DELAY
                );
                tokio::time::sleep(RACE_RETRY_DELAY).await;
                continue;
            };
            empty_rounds = 0;

            // A healthy node answered → the network is alive → probe failures
            // were the NODES' fault: strike them. (The drop that triggered
            // this race is parked as the pending strike and settles at the
            // Connected event — robust to a phantom redial winning first.)
            for url in &outcome.failed {
                self.commit_strike(url, "probe failed");
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
            match self.inner.client.connect(Some(options)).await {
                Ok(_) => {
                    // A pause that landed mid-bind wins: drop the socket.
                    if self.inner.paused.load(Ordering::SeqCst) {
                        let _ = self.inner.client.disconnect().await;
                    }
                    return;
                }
                Err(e) => {
                    // Died between probe and bind — strike (network known
                    // alive: it just answered a probe elsewhere) and re-race.
                    log::warn!(
                        "link: bind to race winner {} failed: {}",
                        winner.url,
                        link::sanitize_node_text(&e.to_string())
                    );
                    self.commit_strike(&winner.url, "bind failed");
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
        self.inner.client.disconnect().await?;
        Ok(())
    }

    /// Foreground resume after a grace-drop: re-race (the cached last-good
    /// endpoint, persisted at most 30 s + grace ago, is candidate 0 and wins
    /// every tie). No-op while already connected (never bounce a healthy
    /// socket).
    pub async fn resume(&self) -> Result<()> {
        spans::mark("resume_start");
        self.inner.paused.store(false, Ordering::SeqCst);
        if self.is_connected() {
            return Ok(());
        }
        self.spawn_race();
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
            if let Some(url) = self.inner.client.url() {
                self.set_pending_strike(url);
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
        let _ = self.inner.client.disconnect().await;
        self.spawn_race();
        Ok(())
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
        self.inner.client.disconnect().await?;
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
                                    let _ = self.inner.client.disconnect().await;
                                    self.spawn_race();
                                    continue;
                                }
                            }
                            match self.handle_connect().await {
                                Ok(()) => {
                                    self.inner.is_connected.store(true, Ordering::SeqCst);
                                    self.inner.connected_at.store(Self::now_unix(), Ordering::Relaxed);
                                    // V1 spans: close the cold-connect leg,
                                    // arm the first-DAA one.
                                    spans::mark("wss_connected");
                                    self.inner.daa_seen_since_connect.store(false, Ordering::Relaxed);
                                    log::info!("dag-monitor: connected to {:?}", self.inner.client.url());
                                    // Remember the node that worked — it is
                                    // candidate 0 (the fast path) of the next
                                    // cold start / post-grace race.
                                    if let Some(url) = self.inner.client.url() {
                                        self.persist_endpoint(&url);
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
                                let _ = self.inner.client.disconnect().await;
                                let run_secs = Self::now_unix().saturating_sub(
                                    self.inner.connected_at.load(Ordering::Relaxed),
                                );
                                match (dropped, link::judge_run(run_secs)) {
                                    (Some(url), link::RunJudgment::CleanRun) => {
                                        self.commit_clean_run(&url);
                                    }
                                    (Some(url), link::RunJudgment::Strike) => {
                                        self.set_pending_strike(url)
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
            log::warn!(
                "dag-monitor: prior listener survived to a new connect — unregistering (item 9)"
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
            monitor.set_pending_strike(URL.to_string());
            monitor.settle_pending_strike(Some(URL));
        }
        assert!(!demoted(&monitor), "own reconnect must refute, not convict");

        // Control group intact: a DIFFERENT prover commits; two commits demote.
        for _ in 0..2 {
            monitor.set_pending_strike(URL.to_string());
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
