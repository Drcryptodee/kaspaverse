//! The link's STABLE rpc handle — one `Arc<dyn RpcApi>` the app holds for the
//! whole process, routed to whichever per-bind client is currently bound (R4).
//!
//! ## Why this exists
//!
//! R4 gives every socket its own [`KaspaRpcClient`] so that a torn-down
//! socket's ctl event can only reach its OWN listener (D-100/L71: the shared
//! client's teardown event landed after the next bind and killed it, 85 times
//! in 18 minutes). But three consumers bind the monitor's `Rpc` at
//! CONSTRUCTION and never re-read it — wallet-core's `UtxoProcessor` consumes
//! it outright (`wallet_sync.rs`), the acceptance tracker moves it into its
//! task, and a `PreparedSend` parks one across the confirm→commit gesture.
//! Swapping the client under them is the funds-visibility re-plumb L59
//! scarred us on.
//!
//! So the CLIENT rotates and the HANDLE does not: consumers keep the exact
//! object they hold today, and each call lands on the socket that is current
//! at call time. `DagMonitor::rpc()` pairs this with a monitor-owned `RpcCtl`
//! driven only by events the identity gate ACCEPTED, so the wallet lane also
//! sees a de-aliased connect/disconnect stream (D-005 stays true: one socket
//! serves both DAG status and wallet sync — it is simply a different object
//! after each rebind).
//!
//! ## Consequence worth knowing (D-101)
//!
//! `UtxoProcessor::rpc_client()` (pin `processor.rs:137`) reaches the concrete
//! client by downcast, and its ONE call site (`processor.rs:580`) force-
//! disconnects the socket when the processor's own connect negotiation fails.
//! Through this handle that downcast returns `None`, so the wallet lane can no
//! longer tear down a socket the reconnect authority created — exactly the
//! "a socket died that we did not kill" class the item-9 tripwire watches for
//! (D-005/D-081).
//!
//! **The gap this left, and how it is closed now (D-101 → LINK-Q1, D-334).**
//! Closing that path also removed the recovery it happened to provide. The
//! monitor's watchdog does NOT cover it: the monitor's own listener is on the
//! same socket and keeps delivering, so the tick clock stays fresh and the
//! stall line never fires. A negotiation that fails in `init_state_from_server`
//! (the `get_server_info` round trip — the one step a live socket can fail at
//! this pin; `WalletEngine::lane_up` states why) leaves the processor's own
//! `is_connected` false with no further `Connected` edge coming, so the wallet
//! lane sits dark (stale balance, no live deposits) behind a glass that reads
//! connected. *(This file used to name "listener registration" as the residue.
//! That was the wrong step — the registration after the bit cannot fail on a
//! live socket at this pin — and D-334 corrects it here rather than silently.)*
//!
//! It is closed by ownership, not by restoring the kill path: the processor's
//! `UtxoProcError` goes to `DagMonitor::recover_wallet_lane`, which acts only
//! when the lane is down on a socket that is STILL bound — two re-announces of
//! that socket on the monitor's own ctl (the processor renegotiates through
//! its own task), then one rebind at most per ten minutes, then it stops and
//! says so. Bounded, deduped, audited; the monitor stays the one reconnect
//! authority. What CONN-F1's retrospective called five firings of this gap's
//! trigger were five negotiations that died WITH their socket — the next bind
//! renegotiated each in ~2 s by itself — and the check now names that case
//! (`SocketGone`) instead of alarming on it. The case the recovery exists for
//! has not been observed.
//!
//! The method list is the pin's `RpcApi` surface verbatim: a pin bump that
//! changes the trait breaks this file at compile time — loud and desirable.

use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use kaspa_rpc_core::api::connection::DynRpcConnection;
use kaspa_wrpc_client::prelude::*;

/// What every call answers while no socket is bound (mid-race, paused,
/// pre-first-connect). A typed error, never a panic and never a silent
/// success — the callers already treat an RPC error as "ask again later".
const NO_BOUND_SOCKET: &str = "link: no bound socket";

/// The listener id handed back when a registration could not happen. Chosen so
/// a caller that ignores the warning still cannot subscribe against it: every
/// notify call here refuses it explicitly, because the pin's notifier answers
/// `Ok(())` for an id it does not know — a silent success is the one failure
/// mode a subscription must never have (L59).
const NO_LISTENER: ListenerId = ListenerId::MAX;

/// The stable handle. Cheap to clone (`Arc`), cheap to read (one uncontended
/// mutex per call — the bind pointer is swapped at most once per reconnect).
pub(crate) struct LinkRpc {
    current: Mutex<Option<Arc<KaspaRpcClient>>>,
    /// The last few sockets released, as (identity, whether the cause of
    /// their retirement judged the link) — newest last, at most
    /// [`RETIREMENTS_KEPT`]. The message walk reads it to tell a page that
    /// died with a socket the link lost from one that died under our own hand
    /// (LINK-Q4, [`Self::retired_judged`]).
    retired: Mutex<std::collections::VecDeque<(usize, bool)>>,
}

/// How many released sockets [`LinkRpc`] remembers the cause of. A page call
/// holds its own `Arc` to its socket for as long as it runs, so the identity
/// it compares cannot be reused while it waits; eight covers every retirement
/// a sixty-second page could see (a bind lives at least a probe's dial).
const RETIREMENTS_KEPT: usize = 8;

impl LinkRpc {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            current: Mutex::new(None),
            retired: Mutex::new(std::collections::VecDeque::new()),
        })
    }

    /// Point the handle at the socket that just came up. Called with the bind
    /// ACCEPTED (identity gate passed) and before the monitor signals its ctl
    /// open, so a consumer reacting to `Connected` always finds the new socket.
    pub(crate) fn bind(&self, client: Arc<KaspaRpcClient>) {
        *self.current.lock().unwrap_or_else(PoisonError::into_inner) = Some(client);
    }

    /// Release the retired socket. Calls in flight keep their own `Arc` (they
    /// finish or error against the dying client); calls that arrive afterwards
    /// get [`NO_BOUND_SOCKET`] until the race binds again. `judged` says
    /// whether the cause of the retirement judged the LINK (a silence swap,
    /// the watchdog, the socket's own death) rather than our own hand (a
    /// pause, a repin, a tap, a stop): a page that dies with a socket our hand
    /// retired proves nothing about the page (LINK-Q4).
    pub(crate) fn unbind(&self, judged: bool) {
        let released = self
            .current
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take();
        if let Some(client) = released {
            let mut retired = self.retired.lock().unwrap_or_else(PoisonError::into_inner);
            if retired.len() >= RETIREMENTS_KEPT {
                retired.pop_front();
            }
            retired.push_back((Arc::as_ptr(&client) as usize, judged));
        }
    }

    /// Whether the socket `identity` ([`Self::bound_identity`]) was retired
    /// for a cause that judged the link — `None` when it is not among the
    /// last [`RETIREMENTS_KEPT`] released (still bound, or long gone).
    pub(crate) fn retired_judged(&self, identity: usize) -> Option<bool> {
        self.retired
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .rev()
            .find(|(id, _)| *id == identity)
            .map(|(_, judged)| *judged)
    }

    /// Refuse a subscribe against the never-registered sentinel — loudly, so a
    /// re-arm that did not happen surfaces as an error the wallet lane reports
    /// instead of as a socket that is quietly deaf.
    fn reject_sentinel(id: ListenerId, call: &str) -> RpcResult<()> {
        if id == NO_LISTENER {
            log::warn!("link: {call} against an unregistered listener — refused");
            return Err(RpcError::General(
                "link: listener was never registered".to_string(),
            ));
        }
        Ok(())
    }

    /// Which socket calls land on right now — an identity, never the client:
    /// the message walk compares it across a page call to tell a socket that
    /// died under the call from a node that answered (LINK-Q3). `None` while
    /// nothing is bound.
    pub(crate) fn bound_identity(&self) -> Option<usize> {
        self.current
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .as_ref()
            .map(|client| Arc::as_ptr(client) as usize)
    }

    /// The current socket, or the typed no-socket error. The lock is released
    /// before any await — a bind rotation must never wait on an RPC round trip.
    fn bound(&self) -> RpcResult<Arc<KaspaRpcClient>> {
        self.current
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .ok_or_else(|| RpcError::General(NO_BOUND_SOCKET.to_string()))
    }
}

/// Generate the delegating impl. Each line is one pin method with its request
/// and response types — the table IS the trait surface, so a pin bump that
/// adds, removes or re-types a call fails to compile here.
macro_rules! link_rpc_delegate {
    ($($method:ident($request:ty) -> $response:ty;)*) => {
        #[async_trait]
        impl RpcApi for LinkRpc {
            $(
                async fn $method(
                    &self,
                    connection: Option<&DynRpcConnection>,
                    request: $request,
                ) -> RpcResult<$response> {
                    self.bound()?.$method(connection, request).await
                }
            )*

            // ── Notification API ───────────────────────────────────────────
            // The monitor registers its OWN listener directly on the bind's
            // client (identity — a scope belongs to one socket); these serve
            // wallet-core, which registers through the handle it was given.

            /// Returns [`NO_LISTENER`] when nothing is bound. The ordering
            /// makes that near-unreachable (the ctl open that makes wallet-core
            /// register is signalled with the bind already published), but a
            /// sentinel beats a panic on a path that touches the funds lane —
            /// and every subscribe call below REFUSES the sentinel, so a
            /// registration that did not happen can never masquerade as a
            /// working subscription. The pin treats an unknown listener id as a
            /// silent no-op (`notify/src/notifier.rs`), which is exactly how
            /// L59 hid: deafness behind working-looking state.
            fn register_new_listener(&self, connection: ChannelConnection) -> ListenerId {
                match self.bound() {
                    Ok(client) => client.register_new_listener(connection),
                    Err(_) => {
                        log::warn!("link: register_new_listener with no bound socket — refused");
                        NO_LISTENER
                    }
                }
            }

            /// Unregistering a listener whose socket is already gone is DONE,
            /// not an error. Erroring here aborts wallet-core's own
            /// `handle_disconnect` before its `cleanup()` (pin
            /// `wallet/core/src/utxo/processor.rs`) — and since the link
            /// unbinds this handle before it signals the ctl close, that is the
            /// DEFAULT ordering on every disconnect, not a rare race. The pin's
            /// own notifier answers `Ok(())` for an unknown id; so do we.
            async fn unregister_listener(&self, id: ListenerId) -> RpcResult<()> {
                match self.bound() {
                    Ok(client) => client.unregister_listener(id).await,
                    Err(_) => Ok(()),
                }
            }

            async fn start_notify(&self, id: ListenerId, scope: Scope) -> RpcResult<()> {
                Self::reject_sentinel(id, "start_notify")?;
                self.bound()?.start_notify(id, scope).await
            }

            async fn stop_notify(&self, id: ListenerId, scope: Scope) -> RpcResult<()> {
                Self::reject_sentinel(id, "stop_notify")?;
                match self.bound() {
                    Ok(client) => client.stop_notify(id, scope).await,
                    Err(_) => Ok(()),
                }
            }
        }
    };
}

/// **The pin's `RpcApi` call surface, written once** (PRE3-LANE). Each line is
/// one `_call` method with its request and response types; a delegate macro is
/// handed the whole list. Two handles use it — the link's [`LinkRpc`] and the
/// wallet lane's `LaneRpc` (`wallet_lane.rs`) — so a pin bump that adds,
/// removes or re-types a call breaks both at compile time from this one table.
macro_rules! rpc_call_table {
    ($delegate:ident) => {
        $delegate! {
            ping_call(PingRequest) -> PingResponse;
            get_system_info_call(GetSystemInfoRequest) -> GetSystemInfoResponse;
            get_connections_call(GetConnectionsRequest) -> GetConnectionsResponse;
            get_metrics_call(GetMetricsRequest) -> GetMetricsResponse;
            get_server_info_call(GetServerInfoRequest) -> GetServerInfoResponse;
            get_sync_status_call(GetSyncStatusRequest) -> GetSyncStatusResponse;
            get_current_network_call(GetCurrentNetworkRequest) -> GetCurrentNetworkResponse;
            submit_block_call(SubmitBlockRequest) -> SubmitBlockResponse;
            get_block_template_call(GetBlockTemplateRequest) -> GetBlockTemplateResponse;
            get_peer_addresses_call(GetPeerAddressesRequest) -> GetPeerAddressesResponse;
            get_sink_call(GetSinkRequest) -> GetSinkResponse;
            get_mempool_entry_call(GetMempoolEntryRequest) -> GetMempoolEntryResponse;
            get_mempool_entries_call(GetMempoolEntriesRequest) -> GetMempoolEntriesResponse;
            get_connected_peer_info_call(GetConnectedPeerInfoRequest) -> GetConnectedPeerInfoResponse;
            add_peer_call(AddPeerRequest) -> AddPeerResponse;
            submit_transaction_call(SubmitTransactionRequest) -> SubmitTransactionResponse;
            submit_transaction_replacement_call(SubmitTransactionReplacementRequest)
                -> SubmitTransactionReplacementResponse;
            get_block_call(GetBlockRequest) -> GetBlockResponse;
            get_seq_commit_lane_proof_call(GetSeqCommitLaneProofRequest) -> GetSeqCommitLaneProofResponse;
            get_subnetwork_call(GetSubnetworkRequest) -> GetSubnetworkResponse;
            get_virtual_chain_from_block_call(GetVirtualChainFromBlockRequest)
                -> GetVirtualChainFromBlockResponse;
            get_virtual_chain_from_block_v2_call(GetVirtualChainFromBlockV2Request)
                -> GetVirtualChainFromBlockV2Response;
            get_blocks_call(GetBlocksRequest) -> GetBlocksResponse;
            get_block_count_call(GetBlockCountRequest) -> GetBlockCountResponse;
            get_block_dag_info_call(GetBlockDagInfoRequest) -> GetBlockDagInfoResponse;
            resolve_finality_conflict_call(ResolveFinalityConflictRequest)
                -> ResolveFinalityConflictResponse;
            shutdown_call(ShutdownRequest) -> ShutdownResponse;
            get_headers_call(GetHeadersRequest) -> GetHeadersResponse;
            get_balance_by_address_call(GetBalanceByAddressRequest) -> GetBalanceByAddressResponse;
            get_balances_by_addresses_call(GetBalancesByAddressesRequest)
                -> GetBalancesByAddressesResponse;
            get_utxos_by_addresses_call(GetUtxosByAddressesRequest) -> GetUtxosByAddressesResponse;
            get_sink_blue_score_call(GetSinkBlueScoreRequest) -> GetSinkBlueScoreResponse;
            ban_call(BanRequest) -> BanResponse;
            unban_call(UnbanRequest) -> UnbanResponse;
            get_info_call(GetInfoRequest) -> GetInfoResponse;
            estimate_network_hashes_per_second_call(EstimateNetworkHashesPerSecondRequest)
                -> EstimateNetworkHashesPerSecondResponse;
            get_mempool_entries_by_addresses_call(GetMempoolEntriesByAddressesRequest)
                -> GetMempoolEntriesByAddressesResponse;
            get_coin_supply_call(GetCoinSupplyRequest) -> GetCoinSupplyResponse;
            get_daa_score_timestamp_estimate_call(GetDaaScoreTimestampEstimateRequest)
                -> GetDaaScoreTimestampEstimateResponse;
            get_utxo_return_address_call(GetUtxoReturnAddressRequest) -> GetUtxoReturnAddressResponse;
            get_fee_estimate_call(GetFeeEstimateRequest) -> GetFeeEstimateResponse;
            get_fee_estimate_experimental_call(GetFeeEstimateExperimentalRequest)
                -> GetFeeEstimateExperimentalResponse;
            get_current_block_color_call(GetCurrentBlockColorRequest) -> GetCurrentBlockColorResponse;
            get_block_reward_info_call(GetBlockRewardInfoRequest) -> GetBlockRewardInfoResponse;
        }
    };
}
pub(crate) use rpc_call_table;

rpc_call_table!(link_rpc_delegate);

#[cfg(test)]
mod tests {
    use super::*;

    /// The no-socket answer is an ERROR, never a panic and never a fabricated
    /// success — a call that lands between binds must be re-askable, and the
    /// funds lanes read an RPC error as "not now" (they already do, on every
    /// mid-race call today).
    #[tokio::test]
    async fn calls_between_binds_error_instead_of_panicking() {
        let link = LinkRpc::new();
        let err = link
            .get_sink_call(None, GetSinkRequest {})
            .await
            .expect_err("no socket is bound");
        assert!(
            err.to_string().contains("no bound socket"),
            "the error must name the cause, got: {err}"
        );
    }

    /// The handle is one object for the process; binding and unbinding move
    /// the socket underneath it without ever handing the caller a new handle
    /// (the property the L59 lanes depend on).
    #[tokio::test]
    async fn the_handle_survives_a_rebind() {
        let link = LinkRpc::new();
        let as_api: Arc<dyn RpcApi> = link.clone();
        let client = Arc::new(
            KaspaRpcClient::new_with_args(
                WrpcEncoding::Borsh,
                Some("wss://example.invalid/kaspa/mainnet/wrpc/borsh"),
                None,
                Some(NetworkId::new(NetworkType::Mainnet)),
                None,
            )
            .expect("client constructs without connecting"),
        );
        link.bind(client);
        assert!(Arc::ptr_eq(&as_api, &(link.clone() as Arc<dyn RpcApi>)));
        link.unbind(false);
        // Same handle, still usable, still honest about having no socket.
        let err = as_api
            .get_sink_call(None, GetSinkRequest {})
            .await
            .expect_err("unbound again");
        assert!(err.to_string().contains("no bound socket"));
    }

    /// **A released socket keeps its cause** (LINK-Q4): the walk asks, by the
    /// identity it saw before its page, whether that socket left for a cause
    /// that judged the link. Each socket answers for itself, the newest
    /// release wins for a reused identity, the memory is bounded, and a socket
    /// never released answers nothing.
    #[test]
    fn a_released_socket_keeps_the_cause_it_left_for() {
        let link = LinkRpc::new();
        let socket = || {
            Arc::new(
                KaspaRpcClient::new_with_args(
                    WrpcEncoding::Borsh,
                    Some("wss://example.invalid/kaspa/mainnet/wrpc/borsh"),
                    None,
                    Some(NetworkId::new(NetworkType::Mainnet)),
                    None,
                )
                .expect("client constructs without connecting"),
            )
        };
        let (paused, died) = (socket(), socket());
        link.bind(paused.clone());
        let paused_id = link.bound_identity().expect("bound");
        link.unbind(false);
        link.bind(died.clone());
        let died_id = link.bound_identity().expect("bound");
        assert_eq!(
            link.retired_judged(died_id),
            None,
            "still bound: not released"
        );
        link.unbind(true);
        assert_eq!(link.retired_judged(paused_id), Some(false), "our own hand");
        assert_eq!(link.retired_judged(died_id), Some(true), "the link's loss");
        link.unbind(true);
        assert_eq!(
            link.retired_judged(died_id),
            Some(true),
            "an unbind with nothing bound records nothing"
        );

        // `paused` and `died` are the two oldest; six more fill the memory
        // exactly to its bound, and both are still remembered.
        let kept: Vec<_> = (0..RETIREMENTS_KEPT - 2).map(|_| socket()).collect();
        for client in &kept {
            link.bind(client.clone());
            link.unbind(true);
        }
        assert_eq!(
            link.retired_judged(paused_id),
            Some(false),
            "at the bound: kept"
        );
        let one_more = socket();
        link.bind(one_more.clone());
        link.unbind(true);
        assert_eq!(
            link.retired_judged(paused_id),
            None,
            "one past it: the oldest is forgotten"
        );
        assert_eq!(
            link.retired_judged(died_id),
            Some(true),
            "the next oldest is kept"
        );
    }
}
