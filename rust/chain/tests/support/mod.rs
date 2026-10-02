//! Test double for the pinned RPC layer (V6 reconnect-survival harness).
//!
//! `FakeRpc` implements the pin's `RpcApi` trait at the same seam the app
//! injects (`kaspa_wallet_core::rpc::Rpc` = `Arc<dyn RpcApi>` + `RpcCtl`),
//! so a test OWNS the connection lifecycle: `RpcCtl::signal_open()` /
//! `signal_close()` script connect → disconnect → reconnect against the
//! real `UtxoProcessor` and the real tracker task — the exact lanes D-083
//! proved can go silently deaf (L59/PB-022).
//!
//! The method list is mirrored verbatim from the pin's own reference mock
//! (`wallet/core/src/tests/rpc_core_mock.rs` at rev 01b532e — `#[cfg(test)]`-
//! gated upstream, hence hand-written here): six calls answer meaningfully,
//! everything else returns `Err(RpcError::NotImplemented)` — never
//! `unimplemented!()`, so an unexpected hit surfaces as a recorded failure,
//! not a panic or a hang. A pin bump that changes the trait breaks this file
//! at compile time — loud and desirable (re-verify the connect flow).
//!
//! Every interesting call is recorded tagged with the test-declared
//! **connection epoch** (`begin_epoch()` before each `signal_open()`), so
//! assertions read "the subscription re-fired on the NEW connection", which
//! a total-count assertion cannot distinguish from two epoch-1 firings.
//!
//! Each test binary compiles this module on its own and uses a subset of it
//! (the reconnect suite never delivers a notification; the wallet-lane suite
//! never walks the chain), so dead-code analysis is off for the module.
#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use kaspa_notify::connection::Connection;
use kaspa_notify::events::{EventSwitches, EVENT_TYPE_ARRAY};
use kaspa_notify::listener::ListenerLifespan;
use kaspa_notify::notifier::Notifier;
use kaspa_notify::subscriber::test_helpers::{SubscriptionManagerMock, SubscriptionMessage};
use kaspa_notify::subscriber::Subscriber;
use kaspa_notify::subscription::context::SubscriptionContext;
use kaspa_notify::subscription::{Command, MutationPolicies, UtxosChangedMutationPolicy};
use kaspa_rpc_core::api::connection::DynRpcConnection;
use kaspa_wallet_core::rpc::{Rpc, RpcCtl};
use kaspa_wrpc_client::prelude::*;
use kaspaverse_chain::Address;

/// One recorded RPC interaction, tagged with the connection epoch that was
/// current when it arrived.
#[derive(Debug, Clone)]
pub enum RecordedCall {
    /// `start_notify` — the subscription registration itself (the D-083 lane).
    StartNotify { epoch: u64, scope: Scope },
    /// `get_utxos_by_addresses` — the UTXO-set re-ask. `addresses` is never
    /// asserted on, but it rides the timeout call-dump (the whole point of a
    /// diagnosable failure), which dead-code analysis cannot see.
    UtxoScan {
        epoch: u64,
        #[allow(dead_code)]
        addresses: Vec<Address>,
    },
    /// `get_virtual_chain_from_block` — the tracker's catch-up page walk.
    VirtualChainFrom { epoch: u64 },
    /// `get_sink` — the tracker's cursor seed.
    GetSink { epoch: u64 },
}

pub struct FakeRpc {
    network_id: NetworkId,
    epoch: AtomicU64,
    calls: Mutex<Vec<RecordedCall>>,
    listeners: Mutex<HashMap<ListenerId, ChannelConnection>>,
    listener_seq: AtomicU64,
    activity: tokio::sync::Notify,
    /// **`unregister_listener` keeps the listener** (PRE3-LANE, run 4's E1).
    /// The production handle answers `Ok(())` WITHOUT unregistering while no
    /// socket is bound (`LinkRpc::unregister_listener`, D-101 item 7), and the
    /// link unbinds before it signals the ctl close — so on every retirement
    /// the processor's listener stays on the retired client's notifier, which
    /// can still deliver. This flag makes the fake behave the same way.
    retain_on_unregister: AtomicBool,
    /// While set, `get_server_info` waits for a permit — the negotiation's
    /// round trip, held open (a slow node, or a socket mid-retirement).
    hold_server_info: Mutex<Option<Arc<tokio::sync::Semaphore>>>,
    /// While set, `start_notify(VirtualDaaScoreChanged)` — the processor's own
    /// subscribe, the step right after it registers its listener — waits.
    hold_daa_subscribe: Mutex<Option<Arc<tokio::sync::Semaphore>>>,
    server_info_calls: AtomicU64,
    /// How many of the next `start_notify(VirtualDaaScoreChanged)` calls
    /// panic — on the processor's own task, inside its negotiation, at a
    /// location outside the wallet framework (`u64::MAX`: every one).
    panic_daa_subscribes: AtomicU64,
    /// How many of the next `get_server_info` answers say the node is NOT
    /// synced — which makes the processor start the pin's sync monitor
    /// (`sync.rs:47-64`, `:113-124`), polling `get_sync_status`.
    report_unsynced: AtomicU64,
    /// How many of the next `get_sync_status` calls panic — on the sync
    /// monitor's own task, which then dies with its `running` flag still set
    /// (`sync.rs:163-166` clears it only on a clean exit).
    panic_sync_status: AtomicU64,
    sync_status_calls: AtomicU64,
    /// How many of the next `start_notify(UtxosChanged)` calls the node
    /// refuses: the call errs and the listener is left WITHOUT the
    /// subscription — a re-arm that failed at connect, the deaf lane KM5's
    /// pull must repair.
    refuse_utxos_subscribes: AtomicU64,
    /// **The node's side of every subscription** (PRE3-LANE, `consensus-
    /// auditor` CONCERNS-3): the pin's own `Notifier`, with the AddressSet
    /// policy the wRPC client uses (`rpc/wrpc/client/src/client.rs:181`),
    /// compounds every listener's calls into what a node would receive, and
    /// the pin's own `SubscriptionManagerMock` records it. A call at the
    /// `RpcApi` seam that the notifier answers with no mutation sends the node
    /// nothing — which the seam-level record (`calls`) cannot show.
    notifier: Arc<Notifier<Notification, ChannelConnection>>,
    node_rx: async_channel::Receiver<SubscriptionMessage>,
    node_seen: Mutex<Vec<SubscriptionMessage>>,
    /// This fake's listener id → the notifier's.
    notifier_ids: Mutex<HashMap<ListenerId, ListenerId>>,
}

impl FakeRpc {
    /// Must be called inside a tokio runtime: the node-side notifier starts
    /// its tasks here.
    pub fn new(network_id: NetworkId) -> Arc<Self> {
        let (node_tx, node_rx) = async_channel::unbounded();
        let enabled: EventSwitches = EVENT_TYPE_ARRAY[..].into();
        let node = Arc::new(Subscriber::new(
            "fake node",
            enabled,
            Arc::new(SubscriptionManagerMock::new(node_tx)),
            0,
        ));
        let notifier = Arc::new(Notifier::new(
            "fake rpc",
            enabled,
            vec![],
            vec![node],
            SubscriptionContext::new(),
            1,
            MutationPolicies::new(UtxosChangedMutationPolicy::AddressSet),
        ));
        notifier.clone().start();
        Arc::new(Self {
            network_id,
            epoch: AtomicU64::new(1),
            calls: Mutex::new(Vec::new()),
            listeners: Mutex::new(HashMap::new()),
            listener_seq: AtomicU64::new(1),
            activity: tokio::sync::Notify::new(),
            retain_on_unregister: AtomicBool::new(false),
            hold_server_info: Mutex::new(None),
            hold_daa_subscribe: Mutex::new(None),
            server_info_calls: AtomicU64::new(0),
            panic_daa_subscribes: AtomicU64::new(0),
            report_unsynced: AtomicU64::new(0),
            panic_sync_status: AtomicU64::new(0),
            sync_status_calls: AtomicU64::new(0),
            refuse_utxos_subscribes: AtomicU64::new(0),
            notifier,
            node_rx,
            node_seen: Mutex::new(Vec::new()),
            notifier_ids: Mutex::new(HashMap::new()),
        })
    }

    /// Refuse the next `n` `start_notify(UtxosChanged)` calls (see the field).
    pub fn refuse_utxos_changed_subscribes(&self, n: u64) {
        self.refuse_utxos_subscribes.store(n, Ordering::SeqCst);
    }

    /// Every `UtxosChanged` subscribe the NODE has received so far, as the
    /// address set of each — what crossed the notifier, not what was asked.
    pub fn node_utxos_changed_subscribes(&self) -> Vec<Vec<Address>> {
        let mut seen = self
            .node_seen
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        while let Ok(message) = self.node_rx.try_recv() {
            seen.push(message);
        }
        seen.iter()
            .filter_map(
                |message| match (&message.mutation.command, &message.mutation.scope) {
                    (Command::Start, Scope::UtxosChanged(scope)) => Some(scope.addresses.clone()),
                    _ => None,
                },
            )
            .collect()
    }

    /// Wait, bounded, until the node's record satisfies `pred` (the
    /// notifier's subscriber reports on its own task).
    pub async fn wait_node(
        &self,
        what: &str,
        timeout: Duration,
        pred: impl Fn(&[Vec<Address>]) -> bool,
    ) {
        tokio::time::timeout(timeout, async {
            while !pred(&self.node_utxos_changed_subscribes()) {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .unwrap_or_else(|_| {
            panic!(
                "timed out waiting for {what}; the node saw: {:?}",
                self.node_utxos_changed_subscribes()
            )
        });
    }

    /// Make the next `n` processor subscribes panic (see the field).
    pub fn panic_on_daa_subscribes(&self, n: u64) {
        self.panic_daa_subscribes.store(n, Ordering::SeqCst);
    }

    /// Answer the next `n` `get_server_info` calls as an unsynced node.
    pub fn report_unsynced(&self, n: u64) {
        self.report_unsynced.store(n, Ordering::SeqCst);
    }

    /// Make the next `n` `get_sync_status` calls panic (see the field).
    pub fn panic_on_sync_status(&self, n: u64) {
        self.panic_sync_status.store(n, Ordering::SeqCst);
    }

    /// `get_sync_status` calls begun so far.
    pub fn sync_status_calls(&self) -> u64 {
        self.sync_status_calls.load(Ordering::SeqCst)
    }

    /// Take one from a "the next `n`" counter, if any is left.
    fn take_one(counter: &AtomicU64) -> bool {
        counter
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
            .is_ok()
    }

    /// Hold every `get_server_info` until a permit is added to the returned
    /// semaphore (`add_permits(n)` lets `n` through; `add_permits(usize::MAX
    /// >> 4)` opens it for good).
    pub fn hold_server_info(&self) -> Arc<tokio::sync::Semaphore> {
        let hold = Arc::new(tokio::sync::Semaphore::new(0));
        *self
            .hold_server_info
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(hold.clone());
        hold
    }

    /// Hold every `start_notify(VirtualDaaScoreChanged)` the same way.
    pub fn hold_daa_subscribe(&self) -> Arc<tokio::sync::Semaphore> {
        let hold = Arc::new(tokio::sync::Semaphore::new(0));
        *self
            .hold_daa_subscribe
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(hold.clone());
        hold
    }

    /// `get_server_info` calls begun so far (held ones included).
    pub fn server_info_calls(&self) -> u64 {
        self.server_info_calls.load(Ordering::SeqCst)
    }

    /// `start_notify(VirtualDaaScoreChanged)` calls recorded so far, any epoch.
    pub fn daa_subscribes(&self) -> usize {
        self.calls()
            .iter()
            .filter(|c| {
                matches!(
                    c,
                    RecordedCall::StartNotify {
                        scope: Scope::VirtualDaaScoreChanged(_),
                        ..
                    }
                )
            })
            .count()
    }

    async fn pass(hold: &Mutex<Option<Arc<tokio::sync::Semaphore>>>) {
        let hold = hold.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(hold) = hold {
            if let Ok(permit) = hold.acquire().await {
                permit.forget();
            }
        }
    }

    /// Unregister as `LinkRpc` does with nothing bound: answer `Ok(())` and
    /// keep the listener, so it can still be delivered to.
    pub fn retain_listeners_on_unregister(&self) {
        self.retain_on_unregister.store(true, Ordering::SeqCst);
    }

    /// Deliver `notification` to every listener this fake holds, retained ones
    /// included, the way a notifier's broadcaster sends to a connection. A
    /// closed connection is skipped (the broadcaster purges those).
    pub async fn deliver(&self, notification: Notification) -> usize {
        let connections: Vec<ChannelConnection> = self
            .listeners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        let mut delivered = 0;
        for connection in connections {
            if connection.send(notification.clone()).await.is_ok() {
                delivered += 1;
            }
        }
        delivered
    }

    /// The injectable seam: exactly what `DagMonitor::rpc()` hands the app.
    pub fn rpc(self: &Arc<Self>, ctl: RpcCtl) -> Rpc {
        Rpc::new(self.clone(), ctl)
    }

    /// Declare the NEXT connection's identity. Call immediately before each
    /// `signal_open()`; every call recorded afterwards carries this epoch.
    pub fn begin_epoch(&self) -> u64 {
        self.epoch.fetch_add(1, Ordering::SeqCst) + 1
    }

    fn current_epoch(&self) -> u64 {
        self.epoch.load(Ordering::SeqCst)
    }

    fn record(&self, call: RecordedCall) {
        self.calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(call);
        self.activity.notify_waiters();
    }

    pub fn calls(&self) -> Vec<RecordedCall> {
        self.calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Address sets of every `start_notify(UtxosChanged)` recorded in `epoch`.
    pub fn utxos_changed_registrations(&self, epoch: u64) -> Vec<Vec<Address>> {
        self.calls()
            .into_iter()
            .filter_map(|c| match c {
                RecordedCall::StartNotify {
                    epoch: e,
                    scope: Scope::UtxosChanged(scope),
                } if e == epoch => Some(scope.addresses),
                _ => None,
            })
            .collect()
    }

    pub fn utxo_scans(&self, epoch: u64) -> usize {
        self.calls()
            .iter()
            .filter(|c| matches!(c, RecordedCall::UtxoScan { epoch: e, .. } if *e == epoch))
            .count()
    }

    pub fn vcc_calls(&self, epoch: u64) -> usize {
        self.calls()
            .iter()
            .filter(|c| matches!(c, RecordedCall::VirtualChainFrom { epoch: e } if *e == epoch))
            .count()
    }

    pub fn sink_calls(&self, epoch: u64) -> usize {
        self.calls()
            .iter()
            .filter(|c| matches!(c, RecordedCall::GetSink { epoch: e } if *e == epoch))
            .count()
    }

    /// Event-driven bounded wait: no polling loops, no sleeps. Panics with a
    /// dump of every recorded call on timeout so a failure is diagnosable.
    pub async fn wait_until(&self, what: &str, timeout: Duration, pred: impl Fn(&Self) -> bool) {
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            // Arm the waiter BEFORE checking the predicate — a record landing
            // between check and await must not be a lost wakeup.
            let notified = self.activity.notified();
            if pred(self) {
                return;
            }
            tokio::select! {
                _ = notified => {}
                _ = tokio::time::sleep_until(deadline) => {
                    panic!("timed out waiting for {what}; recorded calls: {:#?}", self.calls());
                }
            }
        }
    }

    fn sink_hash() -> RpcHash {
        "1111111111111111111111111111111111111111111111111111111111111111"
            .parse()
            .expect("static sink hash")
    }

    fn next_hash() -> RpcHash {
        "2222222222222222222222222222222222222222222222222222222222222222"
            .parse()
            .expect("static next hash")
    }
}

#[async_trait]
impl RpcApi for FakeRpc {
    // ── Meaningful answers (the connect + rescan + catch-up path) ──────────

    /// Mirrors the pin mock's canned answer (it must succeed while the
    /// client connects).
    async fn get_info_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetInfoRequest,
    ) -> RpcResult<GetInfoResponse> {
        Ok(GetInfoResponse {
            p2p_id: "reconnect-harness".to_string(),
            mempool_size: 0,
            server_version: "fake".to_string(),
            is_utxo_indexed: true,
            is_synced: true,
            has_notify_command: true,
            has_message_id: true,
        })
    }

    /// Healthy, synced, utxo-indexed, right network — anything less and the
    /// processor's `handle_connect_impl` aborts before `UtxoProcStart`, and
    /// the harness would never reach the lane under test. `is_synced: true`
    /// also keeps `sync_proc().track(true)` from spawning its poll task.
    async fn get_server_info_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetServerInfoRequest,
    ) -> RpcResult<GetServerInfoResponse> {
        self.server_info_calls.fetch_add(1, Ordering::SeqCst);
        self.activity.notify_waiters();
        Self::pass(&self.hold_server_info).await;
        let is_synced = !Self::take_one(&self.report_unsynced);
        Ok(GetServerInfoResponse {
            rpc_api_version: 1,
            rpc_api_revision: 0,
            server_version: "fake".to_string(),
            network_id: self.network_id,
            has_utxo_index: true,
            is_synced,
            virtual_daa_score: 1_000_000,
        })
    }

    async fn get_utxos_by_addresses_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        request: GetUtxosByAddressesRequest,
    ) -> RpcResult<GetUtxosByAddressesResponse> {
        self.record(RecordedCall::UtxoScan {
            epoch: self.current_epoch(),
            addresses: request.addresses,
        });
        // Empty wallet: the scan still completes and folds a live zero.
        Ok(GetUtxosByAddressesResponse { entries: vec![] })
    }

    /// One short page (1 added block < VCC_TIP_PAGE_THRESHOLD), so the
    /// tracker's catch-up folds it and stops — no page chase.
    async fn get_virtual_chain_from_block_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetVirtualChainFromBlockRequest,
    ) -> RpcResult<GetVirtualChainFromBlockResponse> {
        self.record(RecordedCall::VirtualChainFrom {
            epoch: self.current_epoch(),
        });
        Ok(GetVirtualChainFromBlockResponse {
            removed_chain_block_hashes: vec![],
            added_chain_block_hashes: vec![Self::next_hash()],
            accepted_transaction_ids: vec![],
        })
    }

    async fn get_sink_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetSinkRequest,
    ) -> RpcResult<GetSinkResponse> {
        self.record(RecordedCall::GetSink {
            epoch: self.current_epoch(),
        });
        Ok(GetSinkResponse {
            sink: Self::sink_hash(),
        })
    }

    async fn get_sink_blue_score_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetSinkBlueScoreRequest,
    ) -> RpcResult<GetSinkBlueScoreResponse> {
        Ok(GetSinkBlueScoreResponse { blue_score: 1_000 })
    }

    // ── Everything else: a clean error, never a panic or a hang ────────────

    async fn ping_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: PingRequest,
    ) -> RpcResult<PingResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_metrics_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetMetricsRequest,
    ) -> RpcResult<GetMetricsResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_connections_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetConnectionsRequest,
    ) -> RpcResult<GetConnectionsResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_system_info_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetSystemInfoRequest,
    ) -> RpcResult<GetSystemInfoResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_sync_status_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetSyncStatusRequest,
    ) -> RpcResult<GetSyncStatusResponse> {
        self.sync_status_calls.fetch_add(1, Ordering::SeqCst);
        self.activity.notify_waiters();
        if Self::take_one(&self.panic_sync_status) {
            panic!("forced: the sync monitor dies inside get_sync_status");
        }
        Err(RpcError::NotImplemented)
    }

    async fn get_current_network_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetCurrentNetworkRequest,
    ) -> RpcResult<GetCurrentNetworkResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn submit_block_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: SubmitBlockRequest,
    ) -> RpcResult<SubmitBlockResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_block_template_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetBlockTemplateRequest,
    ) -> RpcResult<GetBlockTemplateResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_peer_addresses_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetPeerAddressesRequest,
    ) -> RpcResult<GetPeerAddressesResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_mempool_entry_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetMempoolEntryRequest,
    ) -> RpcResult<GetMempoolEntryResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_mempool_entries_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetMempoolEntriesRequest,
    ) -> RpcResult<GetMempoolEntriesResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_connected_peer_info_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetConnectedPeerInfoRequest,
    ) -> RpcResult<GetConnectedPeerInfoResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn submit_transaction_replacement_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: SubmitTransactionReplacementRequest,
    ) -> RpcResult<SubmitTransactionReplacementResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn add_peer_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: AddPeerRequest,
    ) -> RpcResult<AddPeerResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn submit_transaction_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: SubmitTransactionRequest,
    ) -> RpcResult<SubmitTransactionResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_block_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetBlockRequest,
    ) -> RpcResult<GetBlockResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_seq_commit_lane_proof_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetSeqCommitLaneProofRequest,
    ) -> RpcResult<GetSeqCommitLaneProofResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_subnetwork_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetSubnetworkRequest,
    ) -> RpcResult<GetSubnetworkResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_blocks_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetBlocksRequest,
    ) -> RpcResult<GetBlocksResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_block_count_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetBlockCountRequest,
    ) -> RpcResult<GetBlockCountResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_block_dag_info_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetBlockDagInfoRequest,
    ) -> RpcResult<GetBlockDagInfoResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn resolve_finality_conflict_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: ResolveFinalityConflictRequest,
    ) -> RpcResult<ResolveFinalityConflictResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn shutdown_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: ShutdownRequest,
    ) -> RpcResult<ShutdownResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_headers_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetHeadersRequest,
    ) -> RpcResult<GetHeadersResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_balance_by_address_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetBalanceByAddressRequest,
    ) -> RpcResult<GetBalanceByAddressResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_balances_by_addresses_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetBalancesByAddressesRequest,
    ) -> RpcResult<GetBalancesByAddressesResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn ban_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: BanRequest,
    ) -> RpcResult<BanResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn unban_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: UnbanRequest,
    ) -> RpcResult<UnbanResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn estimate_network_hashes_per_second_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: EstimateNetworkHashesPerSecondRequest,
    ) -> RpcResult<EstimateNetworkHashesPerSecondResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_mempool_entries_by_addresses_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetMempoolEntriesByAddressesRequest,
    ) -> RpcResult<GetMempoolEntriesByAddressesResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_coin_supply_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetCoinSupplyRequest,
    ) -> RpcResult<GetCoinSupplyResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_daa_score_timestamp_estimate_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetDaaScoreTimestampEstimateRequest,
    ) -> RpcResult<GetDaaScoreTimestampEstimateResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_fee_estimate_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetFeeEstimateRequest,
    ) -> RpcResult<GetFeeEstimateResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_fee_estimate_experimental_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetFeeEstimateExperimentalRequest,
    ) -> RpcResult<GetFeeEstimateExperimentalResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_current_block_color_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetCurrentBlockColorRequest,
    ) -> RpcResult<GetCurrentBlockColorResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_block_reward_info_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetBlockRewardInfoRequest,
    ) -> RpcResult<GetBlockRewardInfoResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_utxo_return_address_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetUtxoReturnAddressRequest,
    ) -> RpcResult<GetUtxoReturnAddressResponse> {
        Err(RpcError::NotImplemented)
    }

    async fn get_virtual_chain_from_block_v2_call(
        &self,
        _connection: Option<&DynRpcConnection>,
        _request: GetVirtualChainFromBlockV2Request,
    ) -> RpcResult<GetVirtualChainFromBlockV2Response> {
        Err(RpcError::NotImplemented)
    }

    // ── Notification API: a hand-rolled registry, mirrored into the pin's
    // Notifier ──────────────────────────────────────────────────────────────
    // The registry holds each listener's connection, so a test can deliver to
    // it directly (a retired listener included); every call is also mirrored
    // into the node-side `Notifier`, so a test can assert what a node would
    // have received (PRE3-LANE).

    fn register_new_listener(&self, connection: ChannelConnection) -> ListenerId {
        let id = self.listener_seq.fetch_add(1, Ordering::SeqCst);
        let mirrored = self
            .notifier
            .register_new_listener(connection.clone(), ListenerLifespan::Dynamic);
        self.notifier_ids
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id, mirrored);
        self.listeners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id, connection);
        id
    }

    async fn unregister_listener(&self, id: ListenerId) -> RpcResult<()> {
        if self.retain_on_unregister.load(Ordering::SeqCst) {
            return Ok(());
        }
        self.listeners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&id);
        let mirrored = self
            .notifier_ids
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&id);
        if let Some(mirrored) = mirrored {
            let _ = self.notifier.unregister_listener(mirrored);
        }
        Ok(())
    }

    async fn start_notify(&self, id: ListenerId, scope: Scope) -> RpcResult<()> {
        let daa = matches!(scope, Scope::VirtualDaaScoreChanged(_));
        let utxos = matches!(scope, Scope::UtxosChanged(_));
        self.record(RecordedCall::StartNotify {
            epoch: self.current_epoch(),
            scope: scope.clone(),
        });
        if daa {
            let armed = self
                .panic_daa_subscribes
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| match n {
                    0 => None,
                    u64::MAX => Some(u64::MAX),
                    n => Some(n - 1),
                })
                .is_ok();
            if armed {
                panic!("forced: the processor's task dies inside its negotiation");
            }
            Self::pass(&self.hold_daa_subscribe).await;
        }
        if utxos
            && self
                .refuse_utxos_subscribes
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
                .is_ok()
        {
            return Err(RpcError::General(
                "the node refused the subscription".to_string(),
            ));
        }
        let mirrored = self
            .notifier_ids
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&id)
            .copied();
        if let Some(mirrored) = mirrored {
            let _ = self.notifier.try_start_notify(mirrored, scope);
        }
        Ok(())
    }

    async fn stop_notify(&self, id: ListenerId, scope: Scope) -> RpcResult<()> {
        let mirrored = self
            .notifier_ids
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&id)
            .copied();
        if let Some(mirrored) = mirrored {
            let _ = self.notifier.try_stop_notify(mirrored, scope);
        }
        Ok(())
    }
}
