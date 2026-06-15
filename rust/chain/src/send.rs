//! Send pipeline — build, sign, broadcast a payment, every byte of mass / fee /
//! UTXO-selection / signing consumed from the pinned `kaspa-wallet-core`
//! Generator (INV-9; never hand-rolled). Mirrored API (pin = rev `90dbf07`):
//!
//! - `GeneratorSettings::try_new_with_context` — settings.rs:97 (the spendable
//!   source is our live [`WalletEngine`] `UtxoContext`, so a send spends only
//!   what the balance shows as mature).
//! - `Generator::try_new(settings, signer, abortable)` — generator.rs:353;
//!   `generate_transaction()` loop — generator.rs:1030; `summary()` —
//!   generator.rs:1242 (the AGGREGATE over the whole tx chain).
//! - `PendingTransaction::try_sign()` (uses the generator's own signer) —
//!   pending.rs:245; `try_submit(&Arc<DynRpcApi>)` — pending.rs:204.
//! - A normal final payment needs `Fees::SenderPays(0)`, NOT `Fees::None`
//!   (generator.rs:384 rejects a no-fee payment output). A cross-network
//!   destination/change is rejected by the Generator (generator.rs:389/418).
//! - A send too large for one tx's 100k-gram mass becomes a CHAIN of txs
//!   (compounding batches + a final); we iterate until `None` and broadcast in
//!   order.
//!
//! INV-1 — secret-free: this module receives a `dyn SignerT` trait object and
//! PUBLIC [`Address`]es; it never sees a keychain or seed. The signer derives
//! keys transiently inside `try_sign` (`rust/core/src/signer.rs`) and zeroizes
//! them. INV-2 — fallible throughout; the one upstream `panic!` (try_submit
//! called twice, pending.rs:207) is structurally unreachable here ([`PreparedSend`]
//! is consumed by `commit`, so each tx is submitted at most once).

use std::sync::Arc;

use kaspa_addresses::Address;
use kaspa_wallet_core::tx::generator::signer::SignerT;
use kaspa_wallet_core::tx::generator::{
    Generator, GeneratorSettings, GeneratorSummary, PendingTransaction,
};
use kaspa_wallet_core::tx::{Fees, PaymentDestination, PaymentOutputs};

use crate::error::{ChainError, Result};
use crate::wallet_sync::WalletEngine;
use crate::Rpc;

/// What crosses to the confirm screen — Rust's decode of the built transaction
/// chain (the aggregate [`GeneratorSummary`] plus the validated destination),
/// NEVER the caller's echoed intent (consensus B7). The confirm renders exactly
/// the [`PreparedSend`] these numbers came from, so the UI can never show one
/// amount while Rust signs another.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendSummary {
    /// The mainnet address Rust validated and built into the payment output.
    pub destination: String,
    /// Final payment amount (sompi) — `GeneratorSummary::final_transaction_amount`.
    pub amount_sompi: u64,
    /// Aggregate fee across the whole chain (sompi) — never "≈ free" (KIP-9).
    pub fee_sompi: u64,
    /// `amount + fee` (what leaves the wallet, excluding returned change).
    pub total_sompi: u64,
    /// Aggregate mass across the chain (grams).
    pub mass: u64,
    /// Number of generated transactions (1 normally; >1 when chained past 100k mass).
    pub tx_count: u32,
    /// Number of UTXOs consumed as inputs.
    pub utxo_count: u32,
}

/// The result of broadcasting the chain. `partial` (consensus B6): if a leg
/// failed AFTER an earlier leg was already on-chain, those UTXOs are really
/// spent — surface it, never hide it behind a flat "failed". The next sync
/// reconciles reality.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendOutcome {
    /// The final (or last successful) tx id, hex.
    pub final_txid: Option<String>,
    /// Legs broadcast (committed to a node's mempool).
    pub submitted: u32,
    /// Legs in the chain.
    pub total: u32,
    /// `submitted < total` after a mid-chain failure (some funds already moved).
    pub partial: bool,
    /// The typed failure message, if a leg failed.
    pub error: Option<String>,
}

/// A built-but-UNSIGNED send, held between the confirm and the hold-to-sign
/// commit. Holding the SAME pending transactions the [`SendSummary`] describes
/// is what makes the confirm honest (B7). The generator inside each pending tx
/// holds the `VaultSigner` (a Weak ref to the keychain), so a vault lock between
/// prepare and commit makes `try_sign` fail VaultLocked — the kill switch holds.
pub struct PreparedSend {
    pending: Vec<PendingTransaction>,
    summary: SendSummary,
    rpc: Rpc,
}

impl PreparedSend {
    /// The Rust-decoded summary the confirm screen renders.
    pub fn summary(&self) -> &SendSummary {
        &self.summary
    }

    /// Sign + broadcast every leg, IN ORDER (a batch tx's output funds the next
    /// leg). Signing happens in Rust only; only the tx id leaves. A leg failure
    /// after an earlier broadcast returns a typed partial result (B6) — never a
    /// silent failure that hides spent funds. Consumes `self`, so no tx can be
    /// submitted twice (the upstream double-submit panic is unreachable).
    pub async fn commit(self) -> SendOutcome {
        let total = self.pending.len() as u32;
        let mut submitted = 0u32;
        let mut final_txid = None;
        for pt in &self.pending {
            if let Err(e) = pt.try_sign() {
                return SendOutcome {
                    final_txid,
                    submitted,
                    total,
                    partial: submitted > 0,
                    error: Some(e.to_string()),
                };
            }
            match pt.try_submit(self.rpc.rpc_api()).await {
                Ok(txid) => {
                    submitted += 1;
                    final_txid = Some(txid.to_string());
                }
                Err(e) => {
                    return SendOutcome {
                        final_txid,
                        submitted,
                        total,
                        partial: submitted > 0,
                        error: Some(e.to_string()),
                    };
                }
            }
        }
        SendOutcome {
            final_txid,
            submitted,
            total,
            partial: false,
            error: None,
        }
    }
}

impl WalletEngine {
    /// Build (but do not sign) the transaction chain for a send. `destination`
    /// and `change` are PUBLIC mainnet addresses; `signer` is the vault's
    /// [`SignerT`] (registered for every watched address + this change). The
    /// returned [`PreparedSend`] holds the unsigned txs for the confirm→commit
    /// step. `rpc` is the SHARED wRPC client (`DagMonitor::rpc()`), used by
    /// `commit` to broadcast.
    ///
    /// The fresh `change` is registered with the engine's [`UtxoContext`] here
    /// (consumer ii of the change seam) so the returned change is watched +
    /// spendable on the next send.
    pub async fn prepare_send(
        &self,
        destination: Address,
        amount_sompi: u64,
        change: Address,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
    ) -> Result<PreparedSend> {
        let context = self.context();
        // (ii) Watch the fresh change so the change UTXO this send returns is
        // visible + spendable (else it would be stranded). A fresh address has
        // no UTXOs yet, so this scan is cheap.
        context
            .scan_and_register_addresses(vec![change.clone()], None)
            .await?;

        let payment: PaymentDestination =
            PaymentOutputs::from((destination.clone(), amount_sompi)).into();
        let settings = GeneratorSettings::try_new_with_context(
            context,
            None,   // priority_utxo_entries
            change, // change_address (registered above + on the signer)
            1,      // sig_op_count — single-sig (§0.2)
            1,      // minimum_signatures
            payment,
            None,                // fee_rate — normal priority
            Fees::SenderPays(0), // priority fee 0; NOT Fees::None (generator.rs:384)
            None,                // payload
            None,                // multiplexer
        )?;

        let generator = Generator::try_new(settings, Some(signer), None)?;

        // Iterate the whole chain (compounding batches + final). Unsigned.
        let mut pending = Vec::new();
        loop {
            match generator.generate_transaction() {
                Ok(Some(tx)) => pending.push(tx),
                Ok(None) => break,
                Err(e) => return Err(map_generate_error(e)),
            }
        }

        let summary = project_summary(&generator.summary(), destination.to_string());
        Ok(PreparedSend {
            pending,
            summary,
            rpc,
        })
    }
}

/// Project the pinned aggregate [`GeneratorSummary`] onto the FFI-facing
/// [`SendSummary`]. Pure (INV-9: nothing recomputed — the numbers are the
/// Generator's).
fn project_summary(gs: &GeneratorSummary, destination: String) -> SendSummary {
    let amount = gs.final_transaction_amount().unwrap_or(0);
    let fee = gs.aggregate_fees();
    SendSummary {
        destination,
        amount_sompi: amount,
        fee_sompi: fee,
        total_sompi: amount.saturating_add(fee),
        mass: gs.aggregate_mass(),
        tx_count: gs.number_of_generated_transactions() as u32,
        utxo_count: gs.aggregated_utxos() as u32,
    }
}

/// Map a generation error, lifting the wallet-core `InsufficientFunds` into our
/// typed [`ChainError::InsufficientFunds`] so the bridge can distinguish a true
/// shortfall from "not yet spendable" using the live balance.
fn map_generate_error(e: kaspa_wallet_core::error::Error) -> ChainError {
    match e {
        kaspa_wallet_core::error::Error::InsufficientFunds {
            additional_needed, ..
        } => ChainError::InsufficientFunds { additional_needed },
        kaspa_wallet_core::error::Error::StorageMassExceedsMaximumTransactionMass {
            storage_mass,
        } => ChainError::StorageMassExceeded { storage_mass },
        other => ChainError::from(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_wallet_core::tx::generator::PendingTransaction as Pt;
    use kaspa_wallet_core::utils::kaspa_to_sompi;
    use kaspa_wallet_core::utxo::UtxoEntryReference;
    use kaspa_wrpc_client::prelude::{NetworkId, NetworkType};

    // Upstream gen1 mainnet vectors (keychain.rs / hd.rs) — valid, distinct.
    const DEST: &str = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf";
    const CHANGE: &str = "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692";

    fn mainnet() -> NetworkId {
        NetworkId::new(NetworkType::Mainnet)
    }

    fn addr(s: &str) -> Address {
        Address::try_from(s).unwrap()
    }

    /// Build a Generator over simulated UTXOs (no node, no signer needed — we
    /// only build + summarise), mirroring the pin's `make_generator`
    /// (tx/generator/test.rs:411) but via `try_new_with_iterator`.
    fn offline_generator(values_kas: &[f64], send_kas: f64, change: Address) -> Generator {
        let entries: Vec<UtxoEntryReference> = values_kas
            .iter()
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
            .collect();
        let payment: PaymentDestination =
            PaymentOutputs::from((addr(DEST), kaspa_to_sompi(send_kas))).into();
        let settings = GeneratorSettings::try_new_with_iterator(
            mainnet(),
            Box::new(entries.into_iter()),
            None,
            change,
            1,
            1,
            payment,
            None,
            Fees::SenderPays(0),
            None,
            None,
        )
        .unwrap();
        Generator::try_new(settings, None, None).unwrap()
    }

    fn drain(generator: &Generator) -> Vec<Pt> {
        let mut pending = Vec::new();
        while let Some(tx) = generator.generate_transaction().unwrap() {
            pending.push(tx);
        }
        pending
    }

    #[test]
    fn normal_send_is_one_tx_with_a_real_fee() {
        // Two 10-KAS UTXOs cover a 12-KAS send in a single transaction.
        let generator = offline_generator(&[10.0, 10.0], 12.0, addr(CHANGE));
        let pending = drain(&generator);
        assert_eq!(pending.len(), 1, "a small send is a single tx");

        let summary = project_summary(&generator.summary(), DEST.to_string());
        assert_eq!(summary.tx_count, 1);
        assert_eq!(summary.amount_sompi, kaspa_to_sompi(12.0));
        assert!(
            summary.fee_sompi > 0,
            "the fee is exact and non-zero (KIP-9)"
        );
        assert_eq!(
            summary.total_sompi,
            summary.amount_sompi + summary.fee_sompi
        );
        assert_eq!(summary.destination, DEST);
        assert_eq!(summary.utxo_count, 2, "needed both UTXOs to cover 12 KAS");
    }

    #[test]
    fn a_send_too_large_for_one_tx_chains() {
        // Many tiny UTXOs: aggregating enough inputs to cover the send exceeds
        // one tx's 100k-gram mass, so the Generator compounds into a chain
        // (consensus B6 territory). 400 inputs forces >1 transaction.
        let values: Vec<f64> = std::iter::repeat_n(1.0, 400).collect();
        let generator = offline_generator(&values, 350.0, addr(CHANGE));
        let pending = drain(&generator);

        let summary = project_summary(&generator.summary(), DEST.to_string());
        assert!(
            summary.tx_count >= 2,
            "a >100k-mass send must chain (got {} txs)",
            summary.tx_count
        );
        assert_eq!(
            pending.len() as u32,
            summary.tx_count,
            "summary tx-count matches the produced chain length"
        );
        assert!(summary.fee_sompi > 0);
    }

    #[test]
    fn a_tiny_send_from_a_single_utxo_maps_to_storage_mass_exceeded() {
        // KIP-9: a tiny output relative to a large single UTXO blows the
        // storage-mass cap (generator.rs:973). We surface this as a typed
        // [`ChainError::StorageMassExceeded`] so the bridge can guide the user.
        let generator = offline_generator(&[100.0], 0.0001, addr(CHANGE));
        let mapped = loop {
            match generator.generate_transaction() {
                Ok(Some(_)) => continue,
                Ok(None) => panic!("expected a storage-mass error, got a clean chain"),
                Err(e) => break map_generate_error(e),
            }
        };
        assert!(
            matches!(mapped, ChainError::StorageMassExceeded { .. }),
            "a dust-small send must map to StorageMassExceeded, got {mapped:?}"
        );
    }

    #[test]
    fn a_cross_network_change_is_rejected_by_the_pinned_generator() {
        // The Generator backstops a wrong-network change (generator.rs:418):
        // build a mainnet send with a testnet-prefixed change → try_new errs.
        let mainnet_change = addr(CHANGE);
        // Same payload, testnet prefix (the vectors are PubKey/version-0).
        let testnet_change = Address::new(
            kaspa_addresses::Prefix::Testnet,
            kaspa_addresses::Version::PubKey,
            mainnet_change.payload.as_ref(),
        );
        let entries = vec![UtxoEntryReference::simulated(kaspa_to_sompi(10.0))];
        let payment: PaymentDestination =
            PaymentOutputs::from((addr(DEST), kaspa_to_sompi(1.0))).into();
        let settings = GeneratorSettings::try_new_with_iterator(
            mainnet(),
            Box::new(entries.into_iter()),
            None,
            testnet_change,
            1,
            1,
            payment,
            None,
            Fees::SenderPays(0),
            None,
            None,
        )
        .unwrap();
        assert!(
            Generator::try_new(settings, None, None).is_err(),
            "a cross-network change must be rejected (INV-9 backstop)"
        );
    }
}
