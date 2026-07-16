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
//! (`wallet/core/src/tests/rpc_core_mock.rs` at rev cfafeb4 — `#[cfg(test)]`-
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

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
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
}

impl FakeRpc {
    pub fn new(network_id: NetworkId) -> Arc<Self> {
        Arc::new(Self {
            network_id,
            epoch: AtomicU64::new(1),
            calls: Mutex::new(Vec::new()),
            listeners: Mutex::new(HashMap::new()),
            listener_seq: AtomicU64::new(1),
            activity: tokio::sync::Notify::new(),
        })
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
        Ok(GetServerInfoResponse {
            rpc_api_version: 1,
            rpc_api_revision: 0,
            server_version: "fake".to_string(),
            network_id: self.network_id,
            has_utxo_index: true,
            is_synced: true,
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

    // ── Notification API: a hand-rolled registry, no pin Notifier ──────────
    // The harness asserts on the REGISTRATION side (exactly what D-083
    // changed); it never needs to deliver a notification.

    fn register_new_listener(&self, connection: ChannelConnection) -> ListenerId {
        let id = self.listener_seq.fetch_add(1, Ordering::SeqCst);
        self.listeners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(id, connection);
        id
    }

    async fn unregister_listener(&self, id: ListenerId) -> RpcResult<()> {
        self.listeners
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&id);
        Ok(())
    }

    async fn start_notify(&self, _id: ListenerId, scope: Scope) -> RpcResult<()> {
        self.record(RecordedCall::StartNotify {
            epoch: self.current_epoch(),
            scope,
        });
        Ok(())
    }

    async fn stop_notify(&self, _id: ListenerId, _scope: Scope) -> RpcResult<()> {
        Ok(())
    }
}
