//! The covenant watcher's pure half (A-7 ruling, C1).
//!
//! A-7 ("the watcher can reuse P2.1's scan machinery") was asserted since
//! P2.0 and ruled at C1 by reading the shipped code: the reuse is real, as a
//! **split**. The stream half — single listener, `BlockAdded` + VCC scopes,
//! catch-up page walk, persisted cursor, the acceptance tracker's reorg
//! tombstones — lives in `rust/chain` (`dag_monitor.rs`, `acceptance.rs`) and
//! stays there; the covenant matcher enters as a *second pure matcher* at the
//! two existing call sites (`dag_monitor.rs:758` catch-up, `:1971` live),
//! exactly as `transport::scan_block` does today, with its own events channel
//! and its own cursor. The RPC surface already carries what the matcher
//! needs at the pin: `RpcTransactionOutput.covenant: Option<RpcCovenantBinding>`
//! (`rpc/core/src/model/tx.rs:244-248` at `cfafeb4c`) — no new subscription,
//! no protocol gap, no indexer (INV-8).
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
