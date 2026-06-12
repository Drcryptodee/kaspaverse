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

pub use dag_monitor::{DagEvent, DagMonitor};
pub use error::{ChainError, Result};
// Re-export so downstream crates (bridge) name network types from one place.
pub use kaspa_wrpc_client::prelude::{NetworkId, NetworkType};
