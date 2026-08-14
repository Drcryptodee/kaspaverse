//! kaspaverse-chain — wRPC connection + DAG state.
//!
//! P0.3: resolver-based mainnet connection (PNN, `Resolver::default()`) and a
//! virtual-DAA / sink-blue-score event stream. Connection pattern derived from
//! the pinned rev's `rpc/wrpc/examples/subscriber` (INV-9); the resolver only
//! *discovers* public node endpoints — all data comes from the node over wRPC,
//! no trusted indexers (INV-8). Consensus logic always comes from the pinned
//! crates, never re-implemented here (INV-9).

#![forbid(unsafe_code)]

mod acceptance;
mod dag_monitor;
pub mod discovery;
mod error;
pub mod history_fill;
mod kvlog;
pub mod link;
mod link_rpc;
mod send;
pub mod spans;
mod transport;
mod transport_store;
mod wallet_sync;

pub use acceptance::{
    pruning_horizon_ms, AcceptanceEvent, AcceptanceTracker, TxStatus, VccBatch, WatchSource,
};
pub use dag_monitor::{DagEvent, DagMonitor};
pub use error::{ChainError, Result};
pub use link::{sanitize_node_text, EscalationOutcome, SignedTxRetention};
// The signed-tx DTO the retention/escalation path carries (a broadcast public
// tx — no key material). Named here so the bridge never imports rpc-core.
pub use kaspa_wrpc_client::prelude::RpcTransaction;
pub use send::{PreparedSend, SendOutcome, SendSummary};
pub use transport::{
    compose_bcast, compose_comm_wire, compose_handshake_wire, compose_self_stash_wire,
    decode_envelope_body, parse_payload, resolve_return_address, split_comm_body,
    strip_stash_scope, TransportEvent, HANDSHAKE_BOND_SOMPI, KIND_LEGACY, KIND_UNKNOWN,
    STASH_SCOPE_SAVED_HANDSHAKE,
};
pub use transport_store::{
    ConversationRecord, ConversationStatus, KeyBranch, MessageDirection, MessageRecord, RowSource,
    StoredKind, TransportStore,
};
pub use wallet_sync::{
    ActivityDirection, ActivityMaturity, WalletActivityRecord, WalletEngine, WalletEvent,
};
// Re-export so downstream crates (bridge) name network types, addresses and the
// shared wRPC handle from one place.
pub use kaspa_addresses::Address;
// Block/tx hash type (the transport cursor + V1 gap-age lookups name it).
pub use kaspa_addresses::Version as AddressVersion;
pub use kaspa_consensus_core::Hash;
pub use kaspa_wallet_core::rpc::Rpc;
// The signer trait the bridge coerces its `VaultSigner` into (`Arc<dyn SignerT>`)
// when handing it to [`WalletEngine::prepare_send`] — same trait both crates use.
pub use kaspa_wallet_core::tx::generator::signer::SignerT;
pub use kaspa_wrpc_client::prelude::{NetworkId, NetworkType};
