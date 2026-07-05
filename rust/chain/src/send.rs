//! Send pipeline — build, sign, broadcast a payment, every byte of mass / fee /
//! UTXO-selection / signing consumed from the pinned `kaspa-wallet-core`
//! Generator (INV-9; never hand-rolled). Mirrored API (pin = rev `cfafeb4c`,
//! v2.0.1 — D-058; every line cite below verified byte-identical at the bump):
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
use kaspa_wallet_core::utxo::UtxoEntryReference;

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
    /// Payload bytes on the FINAL built transaction (0 = none) — read back from
    /// the generated tx itself, never echoed from the caller (B7; P2.1
    /// anti-blind-signing parity: the confirm renders what will be signed).
    pub payload_len: u32,
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

    /// The payload carried by the final built transaction (the pinned Generator
    /// places the payload on the FINAL tx of a chain — settings.rs:38 /
    /// generator.rs:1093). Read from the built tx, so a confirm-screen decode
    /// of it is B7-honest. Empty when the send carries no payload.
    pub fn final_payload(&self) -> Vec<u8> {
        self.pending
            .iter()
            .find(|pt| pt.is_final())
            .map(|pt| pt.transaction().payload.clone())
            .unwrap_or_default()
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
    ///
    /// `payload`: raw bytes for the final transaction's payload field (P2.1
    /// transport spine) — priced by the pinned Generator's own mass accounting
    /// upstream of us (settings.rs:38 / generator.rs:1093 at `cfafeb4`, INV-9);
    /// `None` = a plain payment. Size is bounded by the Generator's per-tx mass
    /// ceiling, surfaced as its own typed error — never a magic constant here
    /// (§4 watch-out).
    pub async fn prepare_send(
        &self,
        destination: Address,
        amount_sompi: u64,
        change: Address,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
        payload: Option<Vec<u8>>,
    ) -> Result<PreparedSend> {
        // A plain payment: no priority selection — the Generator draws inputs in
        // its own order. UTXO hygiene (fresh change) is the caller's choice.
        self.prepare_send_inner(
            destination,
            amount_sompi,
            None,
            change,
            signer,
            rpc,
            payload,
        )
        .await
    }

    /// The mature UTXO entries the live context holds at `address` — the source
    /// pool for source-address discipline (D2/P4/D-067). Empty ⇒ the address
    /// has no spendable UTXO right now; the caller decides whether to pin
    /// elsewhere or surface an honest "still confirming" message rather than
    /// silently spend from a different address (which would fragment the
    /// counterpart's view of our identity — the L47 scar). Reads the SAME
    /// `UtxoContext` the balance reflects (no node round-trip): the pinned
    /// `get_utxos` filters the mature set by address (context.rs:757 @ `cfafeb4`).
    pub async fn mature_utxos_at(&self, address: &Address) -> Result<Vec<UtxoEntryReference>> {
        let entries = self
            .context()
            .get_utxos(Some(vec![address.clone()]), None)
            .await?;
        Ok(entries.into_iter().map(Into::into).collect())
    }

    /// Build (unsigned) a send that PINS input[0] to a chosen source address and
    /// routes change back to it — the D2 source-address discipline (P4/D-067,
    /// the L47 scar): a conversation always presents ONE input[0] return address
    /// to the counterpart (Kasia resolves peers by `getUtxoReturnAddress` =
    /// input[0]'s prev-output, `conversation-manager-service.ts:181`), and the
    /// returned change keeps that address funded for the next send.
    ///
    /// The mechanism is the pinned Generator's OWN priority-UTXO facility, not a
    /// consensus edit (INV-9): priority entries are consumed BEFORE the general
    /// UTXO iterator (`generator.rs:588-614` @ `cfafeb4` — stash, then the
    /// first-stage iterator which is `None` on a fresh build, then priority,
    /// then the source iterator) and pushed as inputs in consumption order
    /// (`generator.rs:735-763`), so `priority[0]` lands at input[0]. The entries
    /// are filtered out of the source iterator by outpoint identity
    /// (`UtxoEntryReference` hashes/eqs on its outpoint — consensus/client
    /// `utxo.rs:225/266`), so there is no double-spend. `priority` MUST be
    /// UTXOs of `source` (fetch via [`mature_utxos_at`]); an empty `priority` is
    /// rejected here — a pinned send with nothing to pin is a silent identity
    /// change, exactly the bug this guards against.
    // Mirrors the pinned Generator's own many-param builder (`try_new_with_context`,
    // 10 args); bundling these public tx facts into a struct would obscure, not
    // clarify, a custody-critical call site.
    #[allow(clippy::too_many_arguments)]
    pub async fn prepare_send_pinned(
        &self,
        destination: Address,
        amount_sompi: u64,
        priority: Vec<UtxoEntryReference>,
        source: Address,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
        payload: Option<Vec<u8>>,
    ) -> Result<PreparedSend> {
        if priority.is_empty() {
            return Err(ChainError::Message(
                "source address has no spendable UTXO to pin input[0]".into(),
            ));
        }
        // Change returns to `source` (not a fresh change address): the discipline
        // is input[0] AND change on the bound address so it self-funds.
        self.prepare_send_inner(
            destination,
            amount_sompi,
            Some(priority),
            source,
            signer,
            rpc,
            payload,
        )
        .await
    }

    /// Shared build core for [`prepare_send`] and [`prepare_send_pinned`]:
    /// register the change address, run the pinned Generator over the live
    /// context, iterate the whole (possibly chained) tx set unsigned, and
    /// project the B7 summary from the BUILT txs. `priority` = `None` is the
    /// plain path (byte-identical to the pre-D2 behaviour); `Some(entries)`
    /// pins input[0].
    #[allow(clippy::too_many_arguments)]
    async fn prepare_send_inner(
        &self,
        destination: Address,
        amount_sompi: u64,
        priority: Option<Vec<UtxoEntryReference>>,
        change: Address,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
        payload: Option<Vec<u8>>,
    ) -> Result<PreparedSend> {
        let context = self.context();
        // (ii) Watch the change address so the change UTXO this send returns is
        // visible + spendable (else it would be stranded). Idempotent for an
        // already-watched address (the pinned source is always in the window).
        context
            .scan_and_register_addresses(vec![change.clone()], None)
            .await?;

        let payment: PaymentDestination =
            PaymentOutputs::from((destination.clone(), amount_sompi)).into();
        let settings = GeneratorSettings::try_new_with_context(
            context,
            priority, // None = plain draw; Some = input[0] pinned to the source
            change,   // change_address (registered above + on the signer)
            1,        // sig_op_count — single-sig (§0.2)
            1,        // minimum_signatures
            payment,
            None,                // fee_rate — normal priority
            Fees::SenderPays(0), // priority fee 0; NOT Fees::None (generator.rs:384)
            payload,             // final-tx payload (P2.1 transport spine)
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

        let mut summary = project_summary(&generator.summary(), destination.to_string());
        // B7: the payload size the confirm shows is read back from the BUILT
        // final tx, never echoed from the caller's argument.
        summary.payload_len = final_payload_len(&pending);
        Ok(PreparedSend {
            pending,
            summary,
            rpc,
        })
    }
}

/// Payload bytes on the final tx of a built chain (pure; shared by prepare and
/// tests). The Generator carries the payload on the final tx only.
fn final_payload_len(pending: &[PendingTransaction]) -> u32 {
    pending
        .iter()
        .find(|pt| pt.is_final())
        .map(|pt| pt.transaction().payload.len() as u32)
        .unwrap_or(0)
}

/// Outcome of one signerless probe: can the pinned Generator build a payment of
/// this size from the current UTXO set? (P1.6 re-audit, D-054 — the KIP-9 floor
/// made exact: the Generator itself is the oracle, nothing re-implemented.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProbeOutcome {
    /// A full chain was generated — this amount is sendable right now.
    Builds,
    /// Storage mass exceeded the Generator's per-tx ceiling — amount too small.
    TooSmall,
    /// Amount (plus fees) exceeds spendable funds — amount too large.
    TooLarge,
}

/// Ladder start for the floor search: 0.01 KAS — comfortably below any
/// realistic KIP-9 floor, so the first known-TooSmall bound is found fast.
const PROBE_LADDER_START_SOMPI: u64 = 1_000_000;
/// Bisection precision: 0.001 KAS — display precision; probes are cheap but
/// sompi-exact minima are false precision (fees shift the boundary anyway).
const PROBE_PRECISION_SOMPI: u64 = 100_000;

/// Classify one candidate amount by running a real (unsigned, non-broadcast)
/// generation over the live context. Public data only: simulated payment to our
/// own change address (mass depends on script SIZE, not identity), no signer.
fn probe_context(
    context: &kaspa_wallet_core::utxo::UtxoContext,
    change: &Address,
    amount_sompi: u64,
) -> Result<ProbeOutcome> {
    let payment: PaymentDestination = PaymentOutputs::from((change.clone(), amount_sompi)).into();
    let settings = match GeneratorSettings::try_new_with_context(
        context.clone(),
        None,
        change.clone(),
        1,
        1,
        payment,
        None,
        Fees::SenderPays(0),
        None,
        None,
    ) {
        Ok(settings) => settings,
        Err(e) => return probe_error(e),
    };
    let generator = match Generator::try_new(settings, None, None) {
        Ok(generator) => generator,
        Err(e) => return probe_error(e),
    };
    loop {
        match generator.generate_transaction() {
            Ok(Some(_)) => continue,
            Ok(None) => return Ok(ProbeOutcome::Builds),
            Err(e) => return probe_error(e),
        }
    }
}

/// Map a generation error onto a probe outcome (or a real failure).
fn probe_error(e: kaspa_wallet_core::error::Error) -> Result<ProbeOutcome> {
    match map_generate_error(e) {
        ChainError::StorageMassExceeded { .. } => Ok(ProbeOutcome::TooSmall),
        ChainError::InsufficientFunds { .. } => Ok(ProbeOutcome::TooLarge),
        other => Err(other),
    }
}

/// Find the smallest sendable amount by searching the TooSmall→Builds boundary.
/// Pure over an injected probe (unit-tested against synthetic boundaries AND the
/// real Generator). Sendability is not monotonic at the TOP (a near-sweep leaves
/// dusty change), so the search brackets only the BOTTOM boundary:
///
/// 1. doubling ladder from 0.01 KAS until a `Builds` anchor (or the balance
///    ceiling — then a short hunt inside the last window);
/// 2. bisect TooSmall/Builds to display precision.
///
/// `None` = no sendable amount exists below the balance (the honest answer for
/// a dust-only wallet).
fn search_minimum(mut probe: impl FnMut(u64) -> Result<ProbeOutcome>) -> Result<Option<u64>> {
    let mut lo: u64 = 0; // greatest known-TooSmall
    let mut hi: Option<u64> = None; // smallest known-Builds
    let mut ceiling: Option<u64> = None; // smallest known-TooLarge

    // Phase 1 — doubling ladder for a Builds anchor.
    let mut v = PROBE_LADDER_START_SOMPI;
    for _ in 0..20 {
        match probe(v)? {
            ProbeOutcome::Builds => {
                hi = Some(v);
                break;
            }
            ProbeOutcome::TooSmall => {
                lo = v;
                v = v.saturating_mul(2);
            }
            ProbeOutcome::TooLarge => {
                ceiling = Some(v);
                break;
            }
        }
    }

    // Phase 1b — the ladder hit the balance ceiling before any Builds: hunt for
    // a buildable amount inside (lo, ceiling). A handful of probes suffices —
    // if the window holds no Builds, the wallet genuinely cannot send.
    if hi.is_none() {
        let Some(mut top) = ceiling else {
            return Ok(None); // ladder exhausted without Builds or ceiling
        };
        for _ in 0..10 {
            if top.saturating_sub(lo) <= PROBE_PRECISION_SOMPI {
                return Ok(None);
            }
            let mid = lo + (top - lo) / 2;
            match probe(mid)? {
                ProbeOutcome::Builds => {
                    hi = Some(mid);
                    break;
                }
                ProbeOutcome::TooSmall => lo = mid,
                ProbeOutcome::TooLarge => top = mid,
            }
        }
        if hi.is_none() {
            return Ok(None);
        }
    }

    // Phase 2 — bisect the TooSmall/Builds boundary.
    let mut hi = hi.expect("anchored above");
    while hi.saturating_sub(lo) > PROBE_PRECISION_SOMPI {
        let mid = lo + (hi - lo) / 2;
        match probe(mid)? {
            ProbeOutcome::Builds => hi = mid,
            ProbeOutcome::TooSmall => lo = mid,
            // A shrinking window mid-bisect (fees at the margin) — treat as an
            // upper bound and keep closing in.
            ProbeOutcome::TooLarge => hi = mid,
        }
    }
    Ok(Some(hi))
}

impl WalletEngine {
    /// The smallest payment the pinned Generator will build from the CURRENT
    /// mature UTXO set (the KIP-9 floor, exact, for this wallet's coin shape) —
    /// or `None` when no amount below the balance is sendable. Signerless,
    /// offline, public data only; the change address doubles as the probe
    /// destination (identical script size ⇒ identical mass).
    pub fn minimum_sendable(&self, change: Address) -> Result<Option<u64>> {
        let context = self.context();
        search_minimum(|amount| probe_context(&context, &change, amount))
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
        payload_len: 0, // set by the caller from the BUILT chain (B7)
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
        // A payload/output set too heavy for one tx (P2.3: message too large —
        // the compose path maps this to the honest friendly error, §4).
        kaspa_wallet_core::error::Error::GeneratorTransactionIsTooHeavy => {
            ChainError::TransactionTooHeavy
        }
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
        offline_generator_with_payload(values_kas, send_kas, change, None)
    }

    fn offline_generator_with_payload(
        values_kas: &[f64],
        send_kas: f64,
        change: Address,
        payload: Option<Vec<u8>>,
    ) -> Generator {
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
            payload,
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

    /// A generator whose general pool is `pool_kas` at random addresses and whose
    /// PRIORITY set is the single `priority` entry — the D2 pinning shape (the
    /// production path uses `try_new_with_context`; the priority mechanism is the
    /// shared `Context`, so the iterator path proves the identical behaviour).
    fn offline_generator_pinned(
        pool_kas: &[f64],
        priority: UtxoEntryReference,
        send_kas: f64,
        change: Address,
    ) -> Generator {
        let pool: Vec<UtxoEntryReference> = pool_kas
            .iter()
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
            .collect();
        let payment: PaymentDestination =
            PaymentOutputs::from((addr(DEST), kaspa_to_sompi(send_kas))).into();
        let settings = GeneratorSettings::try_new_with_iterator(
            mainnet(),
            Box::new(pool.into_iter()),
            Some(vec![priority]),
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

    /// THE D2 CONSENSUS-TRUTH TEST (P4/D-067): the pinned Generator consumes the
    /// PRIORITY utxo before the general pool, so `priority[0]` lands at input[0]
    /// — the byte the counterpart resolves as our identity
    /// (`getUtxoReturnAddress` = input[0]'s prev-output). Proven for BOTH the
    /// covered case (priority alone suffices → it is the only input) and the
    /// shortfall case (priority + pool → priority is still input[0]). If this
    /// fails, the pinned Generator's ordering changed and the L47 identity-split
    /// scar is back — re-read `generator.rs:588-614` at the pin before touching.
    #[test]
    fn pinned_priority_utxo_is_always_input_zero() {
        let bound = addr(CHANGE);
        // Covered: a 10-KAS priority UTXO funds a 1-KAS send. (The pinned
        // Generator may pull ONE extra pool input to lower KIP-9 storage mass —
        // generator.rs:838-852 — but the priority is consumed first, so it is
        // input[0] regardless.)
        let priority = UtxoEntryReference::simulated_with_address(kaspa_to_sompi(10.0), &bound);
        let priority_txid = priority.transaction_id();
        let generator = offline_generator_pinned(&[100.0], priority, 1.0, bound.clone());
        let pending = drain(&generator);
        let tx = pending
            .iter()
            .find(|pt| pt.is_final())
            .unwrap()
            .transaction();
        assert_eq!(
            tx.inputs[0].previous_outpoint.transaction_id, priority_txid,
            "input[0] is the pinned priority UTXO"
        );

        // Shortfall: a 2-KAS priority UTXO cannot alone cover a 50-KAS send, so
        // the pool is drawn for the REST — but the priority is STILL input[0].
        let priority = UtxoEntryReference::simulated_with_address(kaspa_to_sompi(2.0), &bound);
        let priority_txid = priority.transaction_id();
        let generator = offline_generator_pinned(&[100.0], priority, 50.0, bound.clone());
        let pending = drain(&generator);
        let tx = pending
            .iter()
            .find(|pt| pt.is_final())
            .unwrap()
            .transaction();
        assert!(tx.inputs.len() >= 2, "the pool is drawn for the shortfall");
        assert_eq!(
            tx.inputs[0].previous_outpoint.transaction_id, priority_txid,
            "input[0] is the pinned priority UTXO even when it can't cover alone"
        );
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

    /// P2.1 spine: the payload rides the FINAL built tx, byte-exact, and the
    /// pinned Generator prices its mass — fee and mass strictly higher than the
    /// identical no-payload send (KIP-9: payload bytes are never free).
    #[test]
    fn payload_rides_the_final_tx_and_is_mass_priced() {
        let payload = b"ciph_msg:1:bcast:kv-dev:offline pricing proof".to_vec();

        let without = offline_generator(&[10.0, 10.0], 12.0, addr(CHANGE));
        let pending_without = drain(&without);
        let base = project_summary(&without.summary(), DEST.to_string());

        let with = offline_generator_with_payload(
            &[10.0, 10.0],
            12.0,
            addr(CHANGE),
            Some(payload.clone()),
        );
        let pending_with = drain(&with);
        let priced = project_summary(&with.summary(), DEST.to_string());

        // Byte-exact on the final (here: only) tx; summary length is the BUILT
        // tx's, not an echo.
        assert_eq!(pending_with.last().unwrap().transaction().payload, payload);
        assert_eq!(final_payload_len(&pending_with), payload.len() as u32);
        assert_eq!(final_payload_len(&pending_without), 0);

        // The Generator priced the payload bytes (INV-9: its numbers, not ours).
        assert!(
            priced.mass > base.mass,
            "payload mass must be priced (with {} vs without {})",
            priced.mass,
            base.mass
        );
        assert!(
            priced.fee_sompi > base.fee_sompi,
            "payload fee must be priced (with {} vs without {})",
            priced.fee_sompi,
            base.fee_sompi
        );
    }

    /// THE §0.2 EMISSION TRIPWIRE (D-062 lock; extends the D-054/C5 family):
    /// the pinned Generator emits tx version 0 today (hardcoded at
    /// generator.rs:1093, `cfafeb4`). We deliberately emit whatever the pin
    /// emits — building our own v1 route would re-implement consensus (INV-9).
    /// A pin bump that flips emission MUST fail here loudly: when it does,
    /// re-run the D-061 v0/v1 ruling (decode stays version-neutral either way;
    /// scan neutrality is proven in transport.rs).
    #[test]
    fn v0_emission_tripwire() {
        let generator = offline_generator_with_payload(
            &[10.0, 10.0],
            12.0,
            addr(CHANGE),
            Some(b"ciph_msg:1:bcast:kv-dev:tripwire".to_vec()),
        );
        for pt in drain(&generator) {
            assert_eq!(
                pt.transaction().version,
                0,
                "the pinned Generator's emitted tx version changed — the D-062 \
                 §0.2 emission ruling must be re-derived before this pin ships"
            );
        }
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

    /// A synthetic wallet: TooSmall below `floor`, Builds in [floor, balance],
    /// TooLarge above — the shape `search_minimum` brackets.
    fn synthetic(floor: u64, balance: u64) -> impl FnMut(u64) -> Result<ProbeOutcome> {
        move |v| {
            Ok(if v < floor {
                ProbeOutcome::TooSmall
            } else if v <= balance {
                ProbeOutcome::Builds
            } else {
                ProbeOutcome::TooLarge
            })
        }
    }

    #[test]
    fn search_finds_the_floor_within_precision() {
        // A ~0.23 KAS floor in a 50-KAS wallet (the founder's neighborhood).
        let floor = 23_000_000;
        let min = search_minimum(synthetic(floor, 5_000_000_000))
            .unwrap()
            .unwrap();
        assert!(min >= floor, "reported minimum must be sendable");
        assert!(
            min - floor <= PROBE_PRECISION_SOMPI,
            "within display precision"
        );
    }

    #[test]
    fn search_hunts_inside_a_tiny_balance_window() {
        // Floor 0.05 KAS, balance 0.08 KAS: the doubling ladder hits the
        // ceiling before a Builds — the hunt must still find the window.
        let min = search_minimum(synthetic(5_000_000, 8_000_000))
            .unwrap()
            .unwrap();
        assert!(
            (5_000_000..=5_200_000).contains(&min),
            "min {min} in window"
        );
    }

    #[test]
    fn search_reports_none_when_nothing_is_sendable() {
        // Floor above balance: a dust-only wallet cannot send at all.
        assert_eq!(
            search_minimum(synthetic(10_000_000, 4_000_000)).unwrap(),
            None
        );
    }

    #[test]
    fn real_generator_minimum_sits_at_the_kip9_floor_for_one_big_coin() {
        // A single 100-KAS UTXO (the harshest shape: minimal input relief).
        // KIP-9 at the pin: payment output costs C/p grams (C = 10^12) against
        // wallet-core's frozen 100k ceiling (mass.rs:25) ⇒ p ≥ ~0.1 KAS.
        // This test is ALSO the C5 tripwire: a pin bump that changes
        // wallet-core's post-Toccata ceiling moves this floor and fails here
        // — re-derive D-054's numbers when it does.
        let probe = |amount: u64| -> Result<ProbeOutcome> {
            let entries = vec![UtxoEntryReference::simulated(kaspa_to_sompi(100.0))];
            let payment: PaymentDestination = PaymentOutputs::from((addr(DEST), amount)).into();
            let settings = match GeneratorSettings::try_new_with_iterator(
                mainnet(),
                Box::new(entries.into_iter()),
                None,
                addr(CHANGE),
                1,
                1,
                payment,
                None,
                Fees::SenderPays(0),
                None,
                None,
            ) {
                Ok(settings) => settings,
                Err(e) => return probe_error(e),
            };
            let generator = match Generator::try_new(settings, None, None) {
                Ok(generator) => generator,
                Err(e) => return probe_error(e),
            };
            loop {
                match generator.generate_transaction() {
                    Ok(Some(_)) => continue,
                    Ok(None) => return Ok(ProbeOutcome::Builds),
                    Err(e) => return probe_error(e),
                }
            }
        };
        let min = search_minimum(probe)
            .unwrap()
            .expect("a 100-KAS wallet can send");
        // Expected neighborhood: ~0.1 KAS (10^12/100_000), plus fee margin.
        assert!(
            (9_000_000..=13_000_000).contains(&min),
            "pin-frozen 100k ceiling puts the one-big-coin floor near 0.1 KAS, got {min} sompi"
        );
        // The boundary is real: the reported min builds; just below it does not.
        assert_eq!(probe(min).unwrap(), ProbeOutcome::Builds);
        assert_eq!(
            probe(min - 2 * PROBE_PRECISION_SOMPI).unwrap(),
            ProbeOutcome::TooSmall
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
