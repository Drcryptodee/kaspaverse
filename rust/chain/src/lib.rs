//! kaspaverse-chain — wRPC connection + DAG state.
//!
//! Shell in P0.2: the rusty-kaspa v2.0.0 crates (`kaspa-wrpc-client`,
//! `kaspa-consensus-core`, `kaspa-addresses`) are pinned by rev and compile for
//! Android; P0.3 adds the resolver-based mainnet connection and the
//! virtual-DAA/sink stream. Consensus logic always comes from the pinned
//! crates, never re-implemented here (INV-9); no trusted indexers (INV-8).
