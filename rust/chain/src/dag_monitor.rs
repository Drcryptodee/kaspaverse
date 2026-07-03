//! Connection lifecycle + notification subscription for the hello-DAG stream.
//!
//! Derived from the pinned rev's `rpc/wrpc/examples/subscriber` example
//! (originally at `90dbf074`; pin since bumped to `cfafeb4c` v2.0.1 — D-058;
//! INV-9). Key protocol fact from that source:
//! notification scopes live on the node for the lifetime of one RPC
//! connection — they are lost on disconnect, so every `RpcState::Connected`
//! event must re-register the listener and its scopes.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use kaspa_addresses::Prefix;
use kaspa_wallet_core::rpc::Rpc;
use kaspa_wrpc_client::prelude::*;
use tokio::sync::{broadcast, oneshot};

use crate::error::Result;
use crate::transport::{self, TransportEvent};

/// How long the cached-endpoint fast path may take before falling back to the
/// resolver (P1.5 re-audit: connection latency — a bounded first try, never a
/// hang; a dead cached node costs at most this before discovery proceeds).
const CACHED_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

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
    /// True while the live connection was dialed directly to the cached URL.
    /// A direct URL bypasses resolver rotation, so on disconnect we must
    /// re-issue a resolver-mode connect or a dead cached node would be
    /// retried forever (regression guard vs. the pure-resolver behavior).
    forced_cached_url: AtomicBool,
    /// True between [`DagMonitor::pause`] and [`DagMonitor::resume`] — a
    /// deliberate grace-drop also emits `Disconnected`, and the rotation-restore
    /// logic must not treat it as a dead node and dial right back.
    paused: AtomicBool,
}

/// Owns one wRPC client plus the event task that tracks its connection state
/// and notification stream, fanning everything out as [`DagEvent`]s.
#[derive(Clone)]
pub struct DagMonitor {
    inner: Arc<Inner>,
}

impl DagMonitor {
    /// `url = None` uses the public-node resolver (PNN) for endpoint discovery.
    pub fn try_new(network_id: NetworkId, url: Option<String>) -> Result<Self> {
        let (resolver, url) = if let Some(url) = url {
            (None, Some(url))
        } else {
            (Some(Resolver::default()), None)
        };
        let client = Arc::new(KaspaRpcClient::new_with_args(
            WrpcEncoding::Borsh,
            url.as_deref(),
            resolver,
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
                forced_cached_url: AtomicBool::new(false),
                paused: AtomicBool::new(false),
            }),
        })
    }

    /// Tell the monitor where to remember the last-good endpoint (app-private
    /// file; public data — a wss URL). Callable any time; connects that happen
    /// before this is set simply skip the fast path.
    pub fn set_endpoint_cache(&self, path: PathBuf) {
        *self
            .inner
            .endpoint_cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(path);
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

    /// Spawns the event task and starts a non-blocking connect with
    /// `ConnectStrategy::Retry`: the client itself keeps reconnecting forever;
    /// our event task re-registers notifications on every `Connected`.
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

        self.connect_preferring_cache().await?;
        Ok(())
    }

    /// Connect, preferring the last-good endpoint (bounded fast path), falling
    /// back to resolver discovery with endless retry (the original behavior).
    /// The fast path is what makes cold start + post-grace resume fast (P1.5
    /// re-audit): one TLS+WS dial to a known node instead of resolver
    /// round-trips and a node-quality lottery.
    async fn connect_preferring_cache(&self) -> Result<()> {
        if let Some(url) = self.read_cached_endpoint() {
            let started = std::time::Instant::now();
            let options = ConnectOptions {
                url: Some(url.clone()),
                strategy: ConnectStrategy::Fallback, // fail once, never retry a pinned URL
                block_async_connect: true,
                connect_timeout: Some(CACHED_CONNECT_TIMEOUT),
                ..Default::default()
            };
            match self.inner.client.connect(Some(options)).await {
                Ok(_) => {
                    self.inner.forced_cached_url.store(true, Ordering::SeqCst);
                    log::info!(
                        "dag-monitor: connected via cached endpoint {url} in {:?}",
                        started.elapsed()
                    );
                    return Ok(());
                }
                Err(e) => {
                    log::info!(
                        "dag-monitor: cached endpoint {url} unreachable ({e}) after {:?} — falling back to resolver",
                        started.elapsed()
                    );
                }
            }
        }
        let options = ConnectOptions {
            block_async_connect: false,
            strategy: ConnectStrategy::Retry,
            ..Default::default()
        };
        self.inner.client.connect(Some(options)).await?;
        Ok(())
    }

    /// Background grace-drop (PERFORMANCE_BUDGET "battery posture"): close the
    /// socket and stop the retry loop, keeping the event task and every
    /// subscriber attached. The wallet processor pauses with the shared ctl and
    /// resyncs in lockstep on [`Self::resume`] (§0.8 / D-005).
    pub async fn pause(&self) -> Result<()> {
        self.inner.paused.store(true, Ordering::SeqCst);
        self.inner.forced_cached_url.store(false, Ordering::SeqCst);
        self.inner.client.disconnect().await?;
        Ok(())
    }

    /// Foreground resume after a grace-drop: dial the last-good endpoint first
    /// (persisted at most 30 s + grace ago), resolver fallback otherwise.
    /// No-op while already connected (never bounce a healthy socket).
    pub async fn resume(&self) -> Result<()> {
        self.inner.paused.store(false, Ordering::SeqCst);
        if self.is_connected() {
            return Ok(());
        }
        self.connect_preferring_cache().await
    }

    /// Disconnects, then signals the event task and waits for it to drain.
    pub async fn stop(&self) -> Result<()> {
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
                            match self.handle_connect().await {
                                Ok(()) => {
                                    self.inner.is_connected.store(true, Ordering::SeqCst);
                                    log::info!("dag-monitor: connected to {:?}", self.inner.client.url());
                                    // Remember the node that worked — the next cold
                                    // start / post-grace resume dials it directly.
                                    if let Some(url) = self.inner.client.url() {
                                        self.persist_endpoint(&url);
                                    }
                                    self.emit(DagEvent::Connected { url: self.inner.client.url() });
                                }
                                // Stay "disconnected"; the client's Retry
                                // strategy will produce a fresh Connected event.
                                // KNOWN GAP (audited 2026-06-12, [→ P1]): if the
                                // node accepts the socket but rejects a
                                // subscription, the link idles half-set-up until
                                // the next natural reconnect.
                                Err(e) => log::warn!("dag-monitor: subscription setup failed: {e}"),
                            }
                        }
                        Ok(RpcState::Disconnected) => {
                            log::info!("dag-monitor: disconnected (client keeps retrying)");
                            self.handle_disconnect().await;
                            // A direct-dialed cached URL has no resolver rotation
                            // behind it: restore resolver mode so a node that died
                            // mid-session is replaced, never retried forever. A
                            // deliberate pause() is not a dead node — stay down.
                            if !self.inner.paused.load(Ordering::SeqCst)
                                && self.inner.forced_cached_url.swap(false, Ordering::SeqCst)
                            {
                                log::info!("dag-monitor: cached endpoint dropped — restoring resolver rotation");
                                let options = ConnectOptions {
                                    block_async_connect: false,
                                    strategy: ConnectStrategy::Retry,
                                    ..Default::default()
                                };
                                if let Err(e) = self.inner.client.connect(Some(options)).await {
                                    log::warn!("dag-monitor: resolver re-connect failed: {e}");
                                }
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
                                // Count only — payload bodies are never logged
                                // (§4 plaintext discipline).
                                log::debug!("dag-monitor: {} transport match(es) in block", matches.len());
                            }
                            for event in matches {
                                // Send fails only with zero subscribers — fine.
                                let _ = self.inner.transport_events.send(event);
                            }
                        }
                        Ok(notification) => {
                            if let Some(event) = map_notification(&notification) {
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
