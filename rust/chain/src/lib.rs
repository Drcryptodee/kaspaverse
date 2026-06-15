//! kaspaverse-chain — wRPC connection + DAG state.
//!
//! P0.3: resolver-based mainnet connection (PNN, `Resolver::default()`) and a
//! virtual-DAA / sink-blue-score event stream. Connection pattern derived from
//! the pinned rev's `rpc/wrpc/examples/subscriber` (INV-9); the resolver only
//! *discovers* public node endpoints — all data comes from the node over wRPC,
//! no trusted indexers (INV-8). Consensus logic always comes from the pinned
//! crates, never re-implemented here (INV-9).

#![forbid(unsafe_code)]

mod dag_monitor;
mod error;
mod wallet_sync;

pub use dag_monitor::{DagEvent, DagMonitor};
pub use error::{ChainError, Result};
pub use wallet_sync::{
    ActivityDirection, ActivityMaturity, WalletActivityRecord, WalletEngine, WalletEvent,
};
// Re-export so downstream crates (bridge) name network types, addresses and the
// shared wRPC handle from one place.
pub use kaspa_addresses::Address;
pub use kaspa_wallet_core::rpc::Rpc;
pub use kaspa_wrpc_client::prelude::{NetworkId, NetworkType};
