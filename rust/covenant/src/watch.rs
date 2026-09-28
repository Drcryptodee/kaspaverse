//! The covenant watcher's pure half (A-7 ruling, C1).
//!
//! A-7 ("the watcher can reuse P2.1's scan machinery") was asserted since
//! P2.0 and ruled at C1 by reading the shipped code: the reuse is real, as a
//! **split**. The stream half lives in `rust/chain` and stays there. **Since
//! LINK-Q3 (D-344) it is the message walk** (`walk.rs`): one cursor, one
//! `GetVirtualChainFromBlockV2` fetch per chain move, live and catch-up alike,
//! over ACCEPTED transactions — P3.4 row 2's "acceptance, never sighting" —
//! with reorgs arriving inside the page (`removed_chain_block_hashes`) and
//! the acceptance tracker's tombstones beside it. The covenant matcher enters
//! as a *second `WalkMatcher`* beside the transport matcher, at the walk's ONE
//! call site, sharing its cursor (it replaced the two welded call sites the
//! 2026-08-15 audit note found in `dag_monitor.rs`). The page already carries
//! what the matcher needs at the pin: each output's
//! `covenant: Option<RpcNullableCovenantBinding>`, sent from Low verbosity
//! (`rpc/core/src/convert/verbosity.rs`, `include_covenant: Low`, and
//! `model/optional/tx.rs:335-342` at `01b532e`) — no new subscription, no
//! protocol gap, no indexer (INV-8). One cursor means one readiness: the walk
//! holds while the vault is locked, and a watcher that must run locked
//! revisits that at P3.4.
//!
//! What lives HERE is the pure half: sighting types and the family fold —
//! socketless, publishable, testable against fixture blocks. Chain maps its
//! RPC types into [`CovenantSighting`]s (a mechanical field copy, no
//! consensus logic) and feeds them in.

use kaspa_consensus_core::tx::TransactionOutpoint;
use kaspa_consensus_core::Hash;

use crate::error::Result;
use crate::seam::LiveCovenant;

/// One observation of a covenant-bound output in the block stream — public
/// chain data, mechanically extracted by chain from its existing scan.
#[derive(Clone, Debug)]
pub struct CovenantSighting {
    /// The lineage the output claims (KIP-20).
    pub covenant_id: Hash,
    /// Where the bound output lives.
    pub outpoint: TransactionOutpoint,
    pub value_sompi: u64,
    /// Raw script public key bytes of the bound output (the P2SH
    /// commitment), carried for re-derivation checks.
    pub script_public_key: Vec<u8>,
    /// The input index that authorized this binding.
    pub authorizing_input: u16,
    /// Provenance for the fold and for reorg handling (DP-8, C4).
    pub block_hash: Hash,
    pub daa_score: u64,
}

/// The set of covenant ids this app is watching — its own matches, nothing
/// else. An untrusted accelerator, always chain-verifiable (INV-8).
#[derive(Clone, Debug, Default)]
pub struct WatchSet {
    pub covenant_ids: Vec<Hash>,
}

/// The watcher's fold: sightings in, per-family live state out. Reorg
/// semantics (tombstones, un-acceptance) are DP-8, decided at C4 — the
/// acceptance tracker in `rust/chain` is the shipped prior art this fold
/// will mirror, not re-invent.
#[derive(Debug, Default)]
pub struct CovenantWatch {
    watch: WatchSet,
}

impl CovenantWatch {
    /// A watcher over the given family set.
    pub fn new(watch: WatchSet) -> Self {
        Self { watch }
    }

    /// The families being watched.
    pub fn watch_set(&self) -> &WatchSet {
        &self.watch
    }

    /// Fold one sighting into family state. Consumes its predecessor's
    /// outpoint — a covenant's state does not mutate, it is consumed and
    /// recreated (lexicon §3.2).
    pub fn fold(&mut self, _sighting: CovenantSighting) -> Result<()> {
        todo!("P3.x watcher build: family fold")
    }

    /// The current live UTXO of a watched family, if the fold knows one.
    pub fn live(&self, _covenant_id: &Hash) -> Option<&LiveCovenant> {
        todo!("P3.x watcher build: live lookup")
    }
}
