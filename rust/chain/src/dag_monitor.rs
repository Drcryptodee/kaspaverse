//! Connection lifecycle + notification subscription for the hello-DAG stream.
//!
//! Derived from the pinned rev's `rpc/wrpc/examples/subscriber` example
//! (rusty-kaspa `90dbf074`, INV-9). Key protocol fact from that source:
//! notification scopes live on the node for the lifetime of one RPC
//! connection — they are lost on disconnect, so every `RpcState::Connected`
//! event must re-register the listener and its scopes.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use kaspa_wrpc_client::prelude::*;
use tokio::sync::{broadcast, oneshot};

use crate::error::Result;

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
    event_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    shutdown: Mutex<Option<oneshot::Sender<()>>>,
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
        Ok(Self {
            inner: Arc::new(Inner {
                client,
                is_connected: AtomicBool::new(false),
                notification_tx,
                notification_rx,
                listener_id: Mutex::new(None),
                events,
                event_task: Mutex::new(None),
                shutdown: Mutex::new(None),
            }),
        })
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

        let options = ConnectOptions {
            block_async_connect: false,
            strategy: ConnectStrategy::Retry,
            ..Default::default()
        };
        self.inner.client.connect(Some(options)).await?;
        Ok(())
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
