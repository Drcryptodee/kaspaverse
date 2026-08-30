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
use kaspa_consensus_core::tx::Transaction;
use kaspa_txscript::extract_script_pub_key_address;
use kaspa_wallet_core::tx::generator::signer::SignerT;
use kaspa_wallet_core::tx::generator::{
    Generator, GeneratorSettings, GeneratorSummary, PendingTransaction,
};
use kaspa_wallet_core::tx::{Fees, PaymentDestination, PaymentOutputs};
use kaspa_wallet_core::utxo::{OutgoingTransaction, UtxoEntryReference};

use crate::error::{ChainError, Result};
use crate::spend_policy;
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
    /// Aggregate OVERALL mass across the chain (grams) — the max-of-dimensions
    /// number that includes KIP-9 storage mass. The fee is NOT priced from
    /// this (storage is excluded from the relay-fee floor), so the two never
    /// reconcile: a 1 KAS send from a fat UTXO reports ~10,000 here and pays
    /// for ~2,036. Diagnostic only — never render it beside `fee_sompi`
    /// without saying which it is (the confirm screen shows the fee alone).
    pub mass: u64,
    /// Number of generated transactions (1 normally; >1 when chained past 100k mass).
    pub tx_count: u32,
    /// Number of UTXOs consumed as inputs.
    pub utxo_count: u32,
    /// How many coins this send LEAVES at its destination — the answer to
    /// "merges N coins into how many?", and deliberately NOT derivable from
    /// `tx_count`.
    ///
    /// The two drain arms both chain past one transaction and leave opposite
    /// results: the native `Drain` compound is N transactions ending in ONE
    /// output (`verify_drain` refuses anything else), while a batched merge is
    /// N transactions each leaving its own coin. A render layer that branched
    /// on `tx_count` to tell a user how many coins they end with was wrong on
    /// the commoner of the two (ux audit, this sitting) — so the layer that
    /// KNOWS which arm ran publishes the fact instead of letting Dart infer it.
    ///
    /// `0` where the question does not apply: an ordinary payment leaves change
    /// whose count is not this field's business.
    pub resulting_coins: u32,
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
    /// EVERY broadcast leg's txid, in submit order — including the legs of a
    /// partial outcome (they are on-chain and must be acceptance-tracked; V1
    /// feeds these to the tracker's watch-set).
    pub submitted_txids: Vec<String>,
}

/// Per-leg submit hook: fires with the acked txid and the leg's signed wire
/// form (a broadcast public tx) — the V1 watch hook + V3 escalation retention.
pub type SubmitHook<'a> =
    &'a mut (dyn FnMut(&str, kaspa_wrpc_client::prelude::RpcTransaction) + Send);

/// A built-but-UNSIGNED send, held between the confirm and the hold-to-sign
/// commit. Holding the SAME pending transactions the [`SendSummary`] describes
/// is what makes the confirm honest (B7). The generator inside each pending tx
/// holds the `VaultSigner` (a Weak ref to the keychain), so a vault lock between
/// prepare and commit makes `try_sign` fail VaultLocked — the kill switch holds.
pub struct PreparedSend {
    pending: Vec<PendingTransaction>,
    summary: SendSummary,
    rpc: Rpc,
    /// The live [`UtxoContext`], carried ONLY for a drain built on the
    /// `ReceiverPays` arm — see [`PreparedSend::commit`] for why that arm alone
    /// needs it. `None` for every ordinary payment and for the `Change`-
    /// destination drain, whose accounting the pin already gets exactly right.
    discharge_outgoing: Option<kaspa_wallet_core::utxo::UtxoContext>,
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
    ///
    /// `on_submitted` fires the moment EACH leg's submit is acked — the V1
    /// acceptance watch hook. Registering per-leg (not after the whole chain)
    /// closes the window where a fast acceptance of an early leg would slip
    /// past the live VCC stream before the watch existed (consensus-audit
    /// finding 3). Pass `None` when nothing tracks.
    ///
    /// V3: the hook also receives the leg's SIGNED `RpcTransaction` (a
    /// broadcast public tx — no key material crosses anywhere) so the caller
    /// can retain it for stall escalation; the `PendingTransaction` itself is
    /// consumed here and its `try_submit` panics on reuse, so a resubmit must
    /// ride this extracted copy.
    pub async fn commit(self, mut on_submitted: Option<SubmitHook<'_>>) -> SendOutcome {
        let total = self.pending.len() as u32;
        let mut submitted = 0u32;
        let mut final_txid = None;
        let mut submitted_txids = Vec::new();
        for pt in &self.pending {
            if let Err(e) = pt.try_sign() {
                return SendOutcome {
                    final_txid,
                    submitted,
                    total,
                    partial: submitted > 0,
                    error: Some(e.to_string()),
                    submitted_txids,
                };
            }
            match pt.try_submit(self.rpc.rpc_api()).await {
                Ok(txid) => {
                    submitted += 1;
                    // The typed id outlives the string form: the discharge
                    // below needs it, and it must run AFTER the acceptance hook.
                    let tx_id = txid;
                    let txid = tx_id.to_string();
                    // V1 span: the node acked this submit RPC — the anchor
                    // that decomposes broadcast-lag from chain-lag in the
                    // submit→accepted baseline (public txid only, INV-3).
                    crate::spans::mark_with("submit_ok", &txid);
                    if let Some(hook) = on_submitted.as_deref_mut() {
                        // Extracted AFTER try_sign: this is the signed wire
                        // form the node just accepted (escalation resubmits
                        // it verbatim, V3).
                        hook(&txid, pt.rpc_transaction());
                    }
                    final_txid = Some(txid.clone());
                    submitted_txids.push(txid);
                    // Discharge the pin's outgoing record for a `ReceiverPays`
                    // EXIT drain, the moment `try_submit` has registered it
                    // (pending.rs:214-219 @ `cfafeb4`).
                    //
                    // WHY THIS ARM. `UtxoContext::calculate_balance`
                    // (context.rs:506-547) adjusts the mature balance by
                    // `+aggregate_input_value - (fees + payment_value)` for
                    // every outgoing tx that is not yet accepted. That identity
                    // is exact when the fee is paid ON TOP of the payment,
                    // which is every shape upstream can reach.
                    // `Fees::ReceiverPays` deducts the fee FROM the payment
                    // while `payment_value` stays the full REQUESTED amount
                    // (fixed at generator.rs:432, before the deduction at
                    // generator.rs:1067-1073), so the fee is counted twice and
                    // the balance reads exactly one fee short. The
                    // `Change`-destination drain needs nothing: `payment_value()`
                    // is `None` there (generator.rs:376-380), taking the
                    // compound branch where `fees + aggregate_output_value ==
                    // aggregate_input_value` and the adjustment nets to zero.
                    //
                    // WHY ONLY THE EXIT. The record retires itself as soon as
                    // one of the transaction's outputs lands in the wallet:
                    // `tag_as_accepted_at_daa_score` (outgoing.rs:68) is called
                    // from `handle_utxo_added` (context.rs:577, tag at :625),
                    // after which
                    // `calculate_balance` filters it out. A consolidation's coin
                    // comes home to `receive/0`, so a `ReceiverPays` MERGE
                    // self-heals — and its record must stay, because
                    // `outgoing_without_batch_tx` (context.rs:528) is the sole
                    // input to the "still settling from your last send"
                    // classifier (consensus finding 7); discharging it early
                    // would re-open that regression from the other side. A
                    // sweep pays an external address, so nothing ever lands,
                    // nothing is ever tagged, and the only purge
                    // (`handle_outgoing`, processor.rs:337-348) is gated on that
                    // tag and never fires. `context.clear()` is then the only
                    // discharge left — which is exactly why this residue
                    // survives an address-discovery pass and dies on a restart.
                    //
                    // Measured on device 2026-08-23: after a sweep, five
                    // 1.00000000 KAS deposits displayed as 4.99796400 — short by
                    // the sweep's 203,600 sompi fee — cleared by a process
                    // restart, not by a rescan. Funds were never at risk (the
                    // drain path reads the mature ENTRY SET, not this figure);
                    // the number lied.
                    //
                    // The processor's own copy is deliberately left alone:
                    // `update_utxos` reads it for `force_maturity_if_outgoing`
                    // and `settling_at` reads it for the messages lane.
                    if let Some(context) = &self.discharge_outgoing {
                        // NOT a `debug_assert!`: everything here runs AFTER an
                        // irreversible broadcast, and this file's own law is
                        // fallible-throughout (INV-2). A pin that stopped
                        // registering the record must be reported, never
                        // panicked — least of all in the one build where the
                        // panic costs the founder an exit that already left.
                        if context.remove_outgoing_transaction(&tx_id).is_none() {
                            log::warn!(
                                "send: the pin no longer registers the outgoing tx — \
                                 the drain discharge is a no-op"
                            );
                        }
                        // Publish the corrected figure now. `try_submit` already
                        // pushed a balance carrying the double-count, so without
                        // this the wrong number stands until the next balance
                        // event (on a sweep, that is the next deposit).
                        if let Err(e) = context.update_balance().await {
                            log::warn!("send: balance refresh after drain discharge failed ({e})");
                        }
                    }
                }
                Err(e) => {
                    return SendOutcome {
                        final_txid,
                        submitted,
                        total,
                        partial: submitted > 0,
                        error: Some(e.to_string()),
                        submitted_txids,
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
            submitted_txids,
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
    #[allow(clippy::too_many_arguments)]
    pub async fn prepare_send(
        &self,
        destination: Address,
        amount_sompi: u64,
        change: Address,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
        payload: Option<Vec<u8>>,
        exclude: &[Address],
    ) -> Result<PreparedSend> {
        // A plain payment: no pinned block — the spend order is wholly the
        // wallet policy's (spend_policy.rs: riders first, then largest-first,
        // reserved coins dead last).
        self.prepare_send_inner(
            destination,
            amount_sompi,
            None,
            change,
            signer,
            rpc,
            payload,
            exclude,
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

    /// Is something on its way to `address` that will make it spendable — i.e.
    /// is waiting worth anything, or is this address simply unfunded?
    ///
    /// **Address-LOCAL, because that is the question being asked.** The wallet's
    /// folded `pending`/`outgoing` balance answers it for the WHOLE wallet, and
    /// the two answers disagree in both directions: a payment settling on an
    /// unrelated address makes the wallet look busy while this address stays
    /// empty forever, and a wallet whose balance snapshot has not landed yet
    /// looks idle while this address is mid-settle. Either way the caller says a
    /// sentence the code never checked — the L92 scar.
    ///
    /// Two sets are read, and for our OWN change the first one is the whole
    /// answer — the 100-DAA hold does not apply to it:
    ///
    /// 1. **Submitted, not yet accepted** — the change output exists only inside
    ///    our own outgoing transaction; no UTXO exists anywhere yet. Read from
    ///    the processor's outgoing set, decoding each output's script back to an
    ///    address with the pin's own standard decoder (INV-9 — the same
    ///    `extract_script_pub_key_address` the receive scan uses). This is the
    ///    live window for a send of ours: when the `UtxosChanged` notification
    ///    lands, `handle_utxo_added` passes `force_maturity_if_outgoing` for any
    ///    UTXO whose txid it recognises as an outgoing transaction of ours
    ///    (context.rs:590), and `insert` then puts it **straight into `mature`**,
    ///    skipping `pending` entirely (context.rs:299-300).
    /// 2. **Accepted, not yet mature** — held immature for
    ///    `user_transaction_maturity_period_daa = 100` (settings.rs:49). By the
    ///    note above this is NOT where our own change waits; it catches a
    ///    third-party payment arriving at the address, and our own change when a
    ///    rescan re-inserts it through `extend_from_scan` (context.rs:447),
    ///    which knows nothing about outgoing transactions and so cannot force
    ///    maturity. Read from the processor's pending set, which the pin keeps
    ///    live: every context insert mirrors into it (context.rs:310-315),
    ///    `handle_pending` retains away entries that matured
    ///    (processor.rs:279-285) and `remove` prunes it (context.rs:364-368).
    ///    This leg matches on the entry's own `address` field as the node
    ///    reported it (`consensus/client/src/utxo.rs:174`), NOT by decoding a
    ///    script the way leg 1 does — the two legs do not share leg 1's
    ///    provenance. Safe here because the field going `None` fails toward a
    ///    refusal, never toward spending, and because what it gates is whether
    ///    to wait, never an amount (INV-8).
    ///
    /// **Blind spot, deliberate:** a coinbase inside
    /// `coinbase_transaction_stasis_period_daa` (500) sits in a third map,
    /// `stasis` (context.rs:303-308), which is not read here. Mining to a bound
    /// address therefore reads as "not settling" — correctly, for this
    /// caller's purpose: 500 DAA is fifty times the wait budget, so waiting
    /// would be worse than refusing. The refusal sentence must not claim
    /// receiving is the only way forward.
    ///
    /// Maturity is never classified here — the pin decides what is pending and
    /// what is outgoing; this only asks which of ITS answers name `address`.
    /// Synchronous on purpose: it holds sharded map guards, which must not be
    /// carried across an `.await`.
    pub fn settling_at(&self, address: &Address) -> bool {
        let context = self.context();
        let processor = context.processor();

        // Submitted, not yet accepted. Clone the handles OUT of the map first
        // (each is an `Arc` bump): `transaction()` takes the pending
        // transaction's own lock, and taking it while a DashMap shard guard is
        // still alive is a lock order this module has no reason to own.
        let outgoing: Vec<OutgoingTransaction> = processor
            .outgoing()
            .iter()
            .map(|outgoing| outgoing.value().clone())
            .collect();
        if outgoing
            .iter()
            .any(|outgoing| pays_to(&outgoing.pending_transaction().transaction(), address))
        {
            return true;
        }

        // Accepted, not yet mature. Bound, not returned directly: `processor`
        // borrows `context`, which must outlive the shard guards this iterator
        // holds.
        let pending_here = processor
            .pending()
            .iter()
            .any(|pending| pending.value().entry().address().as_ref() == Some(address));
        pending_here
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
        exclude: &[Address],
    ) -> Result<PreparedSend> {
        let priority = pinned_priority_or_refuse(priority)?;
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
            exclude,
        )
        .await
    }

    /// Shared build core for [`prepare_send`] and [`prepare_send_pinned`] —
    /// see [`pinned_priority_or_refuse`] for the pinned path's covenant guard.
    /// register the change address, run the pinned Generator over the live
    /// context in the spend-policy order, iterate the whole (possibly chained)
    /// tx set unsigned, and project the B7 summary from the BUILT txs.
    /// `priority` = `None` is the plain path (policy order: riders, then
    /// largest-first); `Some(entries)` is the pinned path (the same policy
    /// with the pinned block wholly first — input[0] identity, D-067).
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
        exclude: &[Address],
    ) -> Result<PreparedSend> {
        let context = self.context();
        // (ii) Watch the change address so the change UTXO this send returns is
        // visible + spendable (else it would be stranded). Idempotent for an
        // already-watched address (the pinned source is always in the window).
        // BEFORE the snapshot below, so a coin this scan surfaces is in the
        // policy's pool.
        context
            .scan_and_register_addresses(vec![change.clone()], None)
            .await?;

        // The spend order is wallet policy (spend_policy.rs): the pinned block
        // wholly first (D-067 — input[0] identity), then up to RIDER_LIMIT of
        // the smallest coins, then the rest largest-first. Handed to the
        // Generator as its native priority list over the LIVE context —
        // never `try_new_with_iterator`, which would trade the context's
        // mature/pending bookkeeping for a dead snapshot. A coin maturing
        // after this snapshot still flows through the context iterator behind
        // the list (ascending, as the pin keeps it) — spendable, merely last.
        let mature: Vec<UtxoEntryReference> = context
            .get_utxos(None, None)
            .await?
            .into_iter()
            .map(Into::into)
            .collect();
        let pinned = priority.unwrap_or_default();
        let ridered = spend_policy::select_spend_priority(
            &mature,
            &pinned,
            spend_policy::RIDER_LIMIT,
            exclude,
        );

        let (pending, summary) = {
            let (ridden, ridden_summary) = generate_chain(
                &context,
                ridered,
                &change,
                PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
                Fees::SenderPays(0),
                payload.clone(),
                signer.clone(),
            )?;
            // BOTH shapes are always generated now, and the second generation
            // is no longer just the leg check. The pinned Generator is the only
            // judge of either limit — nothing here prices anything (INV-9);
            // generation is side-effect-free, so the losing chain simply drops.
            //
            // **The comparison shape is a QUESTION, never a gate**, so it is
            // `.ok()` and not `?`. Its failure is a fact about a transaction we
            // may never ship, and propagating it would refuse a payment the
            // ridden shape already built. Not theoretical: the riderless order
            // stops one coin earlier and leaves SMALLER change, and the pin's
            // `calculate_mass` (generator.rs:970-972) errors before the
            // storage-mass input-relief block at :849 can pull another input —
            // so on the founder's own measured wallet, moving the amount 0.01
            // KAS (100.90 → 100.91) kills the cheap shape while the ridden one
            // builds in a single transaction. Found by the consensus audit of
            // this change; the cliff is frozen in
            // `a_refusing_comparison_shape_never_refuses_the_send`.
            let comparison = generate_chain(
                &context,
                spend_policy::select_spend_priority(&mature, &pinned, 0, exclude),
                &change,
                PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
                Fees::SenderPays(0),
                payload.clone(),
                signer.clone(),
            )
            .ok();
            shipped_shape((ridden, ridden_summary), comparison, || {
                let order = spend_policy::select_spend_priority(
                    &mature,
                    &pinned,
                    spend_policy::RIDER_LIMIT,
                    exclude,
                );
                let order = (!order.is_empty()).then_some(order);
                // Same law as the comparison generation: the floor is a
                // DECORATION on a decision, and `riderless_wins` already fails
                // closed onto the riders when it is unknown
                // (`an_unknown_floor_keeps_the_riders`). A probe error may not
                // become the send's error.
                search_minimum(
                    |amount| probe_context(&context, &change, amount, order.as_deref()),
                    free_balance(&mature, exclude),
                )
                .ok()
                .flatten()
            })
        };

        Ok(finish_prepared_send(
            pending,
            &summary,
            &mature,
            &pinned,
            exclude,
            &destination,
            rpc,
        ))
    }
}

/// The shared tail of every ordinary send: the reserved-draw trace, then the
/// B7 projection off the BUILT chain. Extracted so the two ways
/// `prepare_send_inner` can settle on a shape — the comparison decided it, or
/// the comparison never built — run the same code rather than a copy of it.
/// How many coins this send drew from ANOTHER conversation's reserve.
///
/// The pinned block is subtracted first, and that is the whole subtlety: on a
/// transport send the pinned coins ARE a bound address, so `is_reserved` matches
/// them and they are always consumed — input[0] identity, D-067. Counting them
/// would make every message from an off-identity conversation report that a
/// payment had raided a reserve, which is the opposite of what this trace exists
/// to say (wallet-security delta re-review, this sitting). Pure; fenced in both
/// directions.
fn reserved_coins_drawn(
    mature: &[UtxoEntryReference],
    pinned: &[UtxoEntryReference],
    consumed: &std::collections::HashMap<(kaspa_consensus_core::tx::TransactionId, u32), u64>,
    exclude: &[Address],
) -> usize {
    fn key(entry: &UtxoEntryReference) -> (kaspa_consensus_core::tx::TransactionId, u32) {
        (
            entry.utxo.outpoint.transaction_id(),
            entry.utxo.outpoint.index(),
        )
    }
    let own: std::collections::HashSet<_> = pinned.iter().map(key).collect();
    mature
        .iter()
        .filter(|entry| spend_policy::is_reserved(entry, exclude))
        .filter(|entry| !own.contains(&key(entry)))
        .filter(|entry| consumed.contains_key(&key(entry)))
        .count()
}

fn finish_prepared_send(
    pending: Vec<PendingTransaction>,
    summary: &GeneratorSummary,
    mature: &[UtxoEntryReference],
    pinned: &[UtxoEntryReference],
    exclude: &[Address],
    destination: &Address,
    rpc: Rpc,
) -> PreparedSend {
    // Observability for the one outcome the demotion cannot prevent: the free
    // coins did not cover the payment, so it reached into ANOTHER conversation's
    // reserve and that conversation may now be unfunded. Counts only (INV-3),
    // and silent when nothing was reserved. This is the only trace that answers
    // "my messages stopped working after I paid someone".
    if !exclude.is_empty() {
        let consumed = wallet_coins_consumed(&pending);
        let drew = reserved_coins_drawn(mature, pinned, &consumed, exclude);
        if drew > 0 {
            log::info!(
                "send: drew {drew} reserved coin(s) — the free coins did not cover this send"
            );
        }
    }

    let mut summary = project_summary(summary, destination.to_string());
    // B7: the payload size the confirm shows is read back from the BUILT final
    // tx, never echoed from the caller's argument.
    summary.payload_len = final_payload_len(&pending);
    PreparedSend {
        pending,
        summary,
        rpc,
        // An ordinary payment's outgoing record is LOAD-BEARING while the
        // change is unconfirmed: the pin adds it back so the user sees their
        // money immediately. Never discharge it here.
        discharge_outgoing: None,
    }
}

/// One full (unsigned) generation over the live context with an explicit spend
/// order — **the shippable door**, and the only one whose output may be signed.
///
/// The signer is deliberately NOT an `Option` here even though [`build_chain`]
/// below takes one. A chain built without a signer is unsignable in a specific
/// and unpleasant way: the pin's `PendingTransaction::try_sign` reaches it as
/// `…signer().as_ref().expect("no signer in tx generator")` (pending.rs:246 @
/// `cfafeb4`) — a **panic**, not an `Err`, on the one path INV-2 says must
/// never panic across the bridge. Making the parameter mandatory means a caller
/// cannot arrive there by defaulting an argument; reaching it now requires
/// choosing [`price_chain`] by name, whose own doc says it must not be shipped.
fn generate_chain(
    context: &kaspa_wallet_core::utxo::UtxoContext,
    order: Vec<UtxoEntryReference>,
    change: &Address,
    payment: PaymentDestination,
    fees: Fees,
    payload: Option<Vec<u8>>,
    signer: Arc<dyn SignerT>,
) -> Result<(Vec<PendingTransaction>, GeneratorSummary)> {
    build_chain(context, order, change, payment, fees, payload, Some(signer))
}

/// The same generation **without a signer** — a priced probe, never a shippable
/// plan.
///
/// The absent signer moves no fee: `signer` is stored by `Generator::try_new`
/// and read back only by `pending.rs`'s signing path, touching no mass, fee or
/// output computation, so a priced chain's numbers equal the shipped one's.
/// That is what lets the live fee preview share this code with the real build
/// instead of mirroring it and drifting (`consensus-auditor`, UX-4B).
///
/// **Its output must never reach the stash.** `PreparedSend::commit` calls
/// `try_sign`, and on a chain built here that is the `.expect` named above:
/// a panic crossing the FFI rather than an `AppError`. Price with it, read the
/// summary, drop the chain.
fn price_chain(
    context: &kaspa_wallet_core::utxo::UtxoContext,
    order: Vec<UtxoEntryReference>,
    change: &Address,
    payment: PaymentDestination,
    fees: Fees,
    payload: Option<Vec<u8>>,
) -> Result<(Vec<PendingTransaction>, GeneratorSummary)> {
    build_chain(context, order, change, payment, fees, payload, None)
}

/// The shared engine behind [`generate_chain`] and [`price_chain`]. Generation
/// never mutates the context (context registration happens only in
/// `try_submit`, pending.rs:214-219 @ `cfafeb4`), so running it twice is
/// side-effect-free and a discarded chain simply drops.
fn build_chain(
    context: &kaspa_wallet_core::utxo::UtxoContext,
    order: Vec<UtxoEntryReference>,
    change: &Address,
    payment: PaymentDestination,
    fees: Fees,
    payload: Option<Vec<u8>>,
    signer: Option<Arc<dyn SignerT>>,
) -> Result<(Vec<PendingTransaction>, GeneratorSummary)> {
    let settings = GeneratorSettings::try_new_with_context(
        context.clone(),
        // The full spend order as priority entries: consumed in list order
        // BEFORE the context iterator, and de-duplicated out of that iterator
        // by outpoint identity (generator.rs:588-614 @ `cfafeb4`). An empty
        // order (empty wallet) degrades to the plain draw.
        (!order.is_empty()).then_some(order),
        change.clone(), // change_address (registered by the caller + on the signer)
        1,              // sig_op_count — single-sig (§0.2)
        1,              // minimum_signatures
        payment,
        // fee_rate = None is the RELAY-FEE FLOOR, not a "normal" bucket:
        // `calc_fee_rate` returns 0 for None (generator.rs:804-805), so the
        // fee is `calc_minimum_transaction_fee_from_mass(compute_mass)`
        // (generator.rs:649). That basis is the wallet's minimum-relay proxy:
        // mostly compute mass, with the payload component hardened to account
        // for normalized transient byte mass (generator.rs:646-648) — the
        // mempool's own post-Toccata floor is max(compute, normalized
        // transient) (check_transaction_standard.rs:145). STORAGE mass is the
        // one dimension excluded from the floor, which is why a dust-heavy
        // send reports an overall mass far above what it pays for.
        None,
        // The caller's fee mode. Payments: Fees::SenderPays(0), NOT Fees::None
        // (generator.rs:384 rejects a no-fee payment output). Sweeps invert
        // BOTH rules (generator.rs:375-386): PaymentDestination::Change
        // REQUIRES Fees::None, and a full-balance ReceiverPays deducts the fee
        // from the payment itself.
        fees,
        payload, // final-tx payload (P2.1 transport spine)
        None,    // multiplexer
    )?;

    let generator = Generator::try_new(settings, signer, None)?;

    // Iterate the whole chain (compounding batches + final). Unsigned.
    let mut pending = Vec::new();
    loop {
        match generator.generate_transaction() {
            Ok(Some(tx)) => pending.push(tx),
            Ok(None) => break,
            Err(e) => return Err(map_generate_error(e)),
        }
    }
    covenant_fence(&pending)?;
    let summary = generator.summary();
    Ok((pending, summary))
}

/// The covenant fence (D-211): no covenant-bound coin ever funds a plain
/// send, sweep, or merge. The policy layer WITHHOLDS these coins from the
/// priority order (`spend_policy::is_covenant_bound`), but a coin the order
/// omits still flows through the context iterator behind it (generator.rs:
/// 588-614 @ `cfafeb4`) — policy alone is a demotion in disguise. So the
/// fence judges the BUILT chain, the same station [`verify_drain`] judges:
/// a covenant-bound input is a refusal, never a broadcast.
///
/// Why refuse, precisely (wallet-security audit, pin-verified): a plain
/// spend of a covenant-labeled coin is consensus-VALID — enforcement is
/// script-side, and an input followed by no covenant outputs is simply a
/// terminated lineage (`crypto/txscript/src/covenants.rs::from_tx` @
/// `cfafeb4`). That is worse, not better: a plain payment would DESTROY the
/// covenant's state machine, and any stake riding it, as a side effect — and
/// unlike a stranded conversation (the reservation's demote-only argument),
/// a destroyed lineage is not recoverable.
fn pinned_priority_or_refuse(priority: Vec<UtxoEntryReference>) -> Result<Vec<UtxoEntryReference>> {
    // Covenant-bound coins cannot pin input[0] — the policy layer would
    // silently drop them from the pinned block, and a pinned send whose
    // whole pin evaporated is the silent identity change the empty-pin guard
    // exists to stop (D-211, wallet-security finding 1). Filter FIRST, so an
    // all-covenant pin hits the honest refusal instead of proceeding with
    // the wrong input[0].
    let priority: Vec<UtxoEntryReference> = priority
        .into_iter()
        .filter(|entry| !spend_policy::is_covenant_bound(entry))
        .collect();
    if priority.is_empty() {
        return Err(ChainError::Message(
            "source address has no spendable UTXO to pin input[0]".into(),
        ));
    }
    Ok(priority)
}

fn covenant_fence(pending: &[PendingTransaction]) -> Result<()> {
    for tx in pending {
        if let Some(entry) = tx
            .utxo_entries()
            .values()
            .find(|entry| spend_policy::is_covenant_bound(entry))
        {
            return Err(ChainError::CovenantBoundInput {
                outpoint: format!(
                    "{}:{}",
                    entry.utxo.outpoint.transaction_id(),
                    entry.utxo.outpoint.index()
                ),
            });
        }
    }
    Ok(())
}

/// The wallet's OWN coins a built chain consumes, by outpoint, with their
/// values: every input entry except the compounding edges (an intermediate
/// leg's output feeding the next leg, which is this chain's own money, not the
/// wallet's pile).
///
/// This is the VALUE-side read, used by the rider comparison to price what one
/// shape absorbs and another leaves behind. [`verify_drain`] keeps its own
/// INPUT-side walk deliberately: a custody check must judge the transaction's
/// actual inputs and fail closed on one with no matching entry, which a map of
/// entries cannot express. Same notion, two jobs, and the difference is the
/// reason they are not one function.
fn wallet_coins_consumed(
    pending: &[PendingTransaction],
) -> std::collections::HashMap<(kaspa_consensus_core::tx::TransactionId, u32), u64> {
    let chain_txids: std::collections::HashSet<_> = pending.iter().map(|pt| pt.id()).collect();
    pending
        .iter()
        .flat_map(|pt| pt.utxo_entries().values().cloned().collect::<Vec<_>>())
        .filter(|entry| !chain_txids.contains(&entry.utxo.outpoint.transaction_id()))
        .map(|entry| {
            (
                (
                    entry.utxo.outpoint.transaction_id(),
                    entry.utxo.outpoint.index(),
                ),
                entry.amount(),
            )
        })
        .collect()
}

/// Which of the two generated shapes the send ships — the whole decision in one
/// testable place, so the untestable half of `prepare_send_inner` (it needs a
/// live `UtxoContext`) is only plumbing.
///
/// `comparison` is `None` when the riderless shape did not build at all. That
/// is a fact about a transaction we may never ship and never a reason to refuse
/// the send: the proven shape ships. `floor` is LAZY — it costs ~a dozen
/// Generator probes and only one branch of the decision reads it, so a shape
/// that cannot win never pays for it.
///
/// **What the second generation costs, measured** (consensus audit asked, so it
/// was measured rather than argued). Release build, x86 desktop, an 88-coin
/// wallet — the fragmented, chat-active shape the rider exists for: one ridden
/// generation ~22 µs, the added riderless generation ~14 µs, a full
/// `search_minimum` floor lookup ~177 µs. Worst case on a send is therefore
/// ~0.2 ms, three orders of magnitude under the 200 ms design bar — and on a
/// genuinely fragmented wallet the floor lookup never runs at all, because
/// fragments worth more than their pickup make the cheap shape fail
/// [`riderless_is_candidate`] before it is reached. Desktop numbers; the device
/// is arm64 and slower, and the margin is wide enough that it does not matter.
fn shipped_shape(
    ridden: (Vec<PendingTransaction>, GeneratorSummary),
    comparison: Option<(Vec<PendingTransaction>, GeneratorSummary)>,
    floor: impl FnOnce() -> Option<u64>,
) -> (Vec<PendingTransaction>, GeneratorSummary) {
    let Some((riderless, riderless_summary)) = comparison else {
        // `info!`, not `debug!`: the bridge's facade caps at `Info` on device
        // AND on host (logging.rs:57/64), so a `debug!` here would be a
        // diagnostic that cannot emit in any build — L40 one level down. It
        // fires at most once per prepare (wallet-security audit, this sitting).
        log::info!("send: the riderless comparison shape did not build — keeping the riders");
        return ridden;
    };
    let ridden_fee = ridden.1.aggregate_fees();
    let riderless_fee = riderless_summary.aggregate_fees();
    // What the cheap shape would LEAVE BEHIND, read off the built transaction —
    // the Generator's own change figure (pending.rs:175 @ `cfafeb4`), zero when
    // it absorbed the change into the fee.
    let riderless_change = riderless
        .iter()
        .find(|pt| pt.is_final())
        .map_or(0, PendingTransaction::change_value);
    // What dropping the riders would COST the wallet: the coins the ridden
    // chain absorbs and the cheap one leaves behind, at their own values. Read
    // off both built chains — nothing predicted.
    let kept_back = wallet_coins_consumed(&riderless);
    let extra_absorbed = wallet_coins_consumed(&ridden.0)
        .iter()
        .filter(|(outpoint, _)| !kept_back.contains_key(*outpoint))
        .fold(0u64, |acc, (_, value)| acc.saturating_add(*value));
    // A change of zero manufactures no coin at all, so it needs no floor.
    let floor = if riderless_is_candidate(
        ridden.0.len(),
        riderless.len(),
        ridden_fee,
        riderless_fee,
        extra_absorbed,
    ) && riderless_change != 0
    {
        floor()
    } else {
        None
    };
    if riderless_wins(
        ridden.0.len(),
        riderless.len(),
        ridden_fee,
        riderless_fee,
        riderless_change,
        extra_absorbed,
        floor,
    ) {
        (riderless, riderless_summary)
    } else {
        ridden
    }
}

/// The cheap-shape GATE: same number of transactions, strictly lower fee, and
/// the coins it declines to absorb are worth LESS than the fee it saves.
///
/// Split out from [`riderless_wins`] so the expensive half of the rule (the
/// wallet's floor, ~a dozen Generator probes) is paid for only by a shape that
/// could actually win. Every number here is the Generator's own aggregate or a
/// coin's own value; nothing computes a fee (INV-9).
fn riderless_is_candidate(
    ridden_legs: usize,
    riderless_legs: usize,
    ridden_fee: u64,
    riderless_fee: u64,
    extra_absorbed: u64,
) -> bool {
    riderless_legs == ridden_legs
        && riderless_fee < ridden_fee
        && extra_absorbed <= ridden_fee - riderless_fee
}

/// Which of the two built shapes a send ships — the rider law's limits, judged
/// on BUILT chains only.
///
/// 1. **The leg law (D-165, unchanged).** A rider may never add a transaction
///    to the chain. A shorter riderless chain therefore wins outright: an extra
///    leg is a whole extra transaction's fee, which no absorption repays.
/// 2. **The self-financing law.** Where the two shapes are the same length, the
///    riders may only be dropped if the coins they would have absorbed are
///    worth LESS than the fee dropping them saves. The wallet never pays more
///    to pick up a coin than the coin is worth — and, the other way round, it
///    never declines to pick up a coin worth many times the pickup.
/// 3. **The change-shape law.** And even then, only if the cheap shape does not
///    manufacture a coin the wallet could not afterwards send alone.
///
/// **Why not a coin-count threshold.** "Skip the riders when the wallet is
/// tidy" was measured against the founder's real wallet on 2026-08-23 and
/// refuted: coins 0.481524 + 1.0 + 100.0 KAS, sending 100.90, the riderless
/// shape costs 315,400 with 2 inputs but leaves change of 9,684,600 sompi —
/// below that wallet's own floor. The cheap path manufactures a new trap coin
/// on the very send that saved 0.0011 KAS, and a count threshold fires
/// precisely there (three coins is "tidy" by any threshold proposed).
///
/// **Why limit 2 exists as well as limit 3** (measured while building this, and
/// the reason this rule is not the two-clause version the backlog proposed).
/// The change-shape clause ALONE was run over the canonical 22-coin fragmented
/// fixture (`riders_strictly_drain_a_fragmented_wallet`): it dropped the riders
/// on all eight rounds and left every one of the twelve 0.5 KAS fragments in
/// place, because a fat wallet's riderless change is always healthy. That is
/// D-165's hygiene half repealed in exactly the wallet the rider exists for.
/// The self-financing clause restores it — a 0.5 KAS fragment absorbed for
/// ~0.0011 KAS is worth 447× its pickup — while still dropping riders that
/// genuinely destroy value (a 0.0005 KAS speck costing 0.0011 to collect).
///
/// `extra_absorbed` is the value of the coins the RIDDEN chain consumes and the
/// riderless one does not — read off both built chains, never predicted.
/// `floor` is the wallet's own smallest sendable amount (the number the send
/// screen shows), or `None` when it could not be computed; unknown fails CLOSED
/// onto the ridden shape. A `riderless_change` of zero was absorbed into the
/// fee and leaves no coin to strand.
fn riderless_wins(
    ridden_legs: usize,
    riderless_legs: usize,
    ridden_fee: u64,
    riderless_fee: u64,
    riderless_change: u64,
    extra_absorbed: u64,
    floor: Option<u64>,
) -> bool {
    if riderless_legs < ridden_legs {
        return true;
    }
    riderless_is_candidate(
        ridden_legs,
        riderless_legs,
        ridden_fee,
        riderless_fee,
        extra_absorbed,
    ) && (riderless_change == 0 || floor.is_some_and(|floor| riderless_change >= floor))
}

/// How a drain (sweep / consolidation) is expressed to the pinned Generator —
/// chosen by [`plan_drain`], because no single Generator mode covers every
/// case (each limit below is measured at the pin `cfafeb4` and held by the
/// permanent tests in this module):
///
/// - **`ReceiverPays`** — a full-balance payment with `Fees::ReceiverPays(0)`:
///   the fee comes out of the payment output, so change is zero by
///   construction and a SINGLE coin can be swept. This is the arm that frees
///   the founder's trap: a one-coin wallet has NO ordinary-send shape that
///   empties it — measured 2026-08-23 on a single 0.481524 KAS coin, every
///   `SenderPays` amount above 0.373 KAS dies of the change side's KIP-9
///   storage mass (surfacing as `StorageMassExceeded` / the Generator's own
///   post-build `MassCalculationError`), and the Generator's native sweep
///   refuses one coin outright (`aggregated_utxos < 2` → NoOp,
///   generator.rs:777-780). It is also the only arm that can respect an
///   exclusion list, because the drawn set is bounded by the priority entries
///   plus the amount. Within one stage the accumulator's ReceiverPays gate is
///   `inputs >= amount − fees_of_FINALIZED_stages` (generator.rs:700-705), and
///   nothing has finalized yet — so a single-transaction ReceiverPays drain
///   draws the ENTIRE offered set, and [`verify_drain`]'s balance check holds
///   to the sompi. This arm DOES ride the pin's `Fees::ReceiverPays` final-tx
///   branch — the one its own author marks "TODO - currently unreachable at
///   the API level" (generator.rs:865) — which is why every use is defended
///   twice: sompi-exact pin tests in this module, and the runtime
///   `swept + fee == consumed` refusal. A CHAINED ReceiverPays could
///   additionally stop drawing early once stage fees accumulate, so
///   [`finish_drain`] refuses that shape outright.
///
///   The arm's one sharp edge is guarded BEFORE generation: when the offered
///   value cannot cover the shape's own fee, the pin's finalizer would
///   underflow `output.value -= transaction_fees` (generator.rs:1071 — a
///   debug-build panic). [`receiver_pays_fee_floor`] reads that fee from the
///   Generator itself and the drain refuses typed below it.
/// - **`Drain`** — the Generator's native sweep: `PaymentDestination::Change`
///   with `Fees::None` (generator.rs:375-386: a Change destination REQUIRES
///   `Fees::None`, the exact inverse of the payment rule) and the change
///   address set to the drain's destination. Consumes EVERY coin the context
///   iterator yields — exactly right for a whole-wallet exit across all
///   watched addresses, exactly wrong under exclusions.
enum DrainArm {
    ReceiverPays {
        amount_sompi: u64,
        priority: Vec<UtxoEntryReference>,
    },
    Drain,
}

/// Split the mature snapshot into (offered, reserved_count, covenant_count)
/// for a drain. Address-matched, and under an exclusion list it FAILS CLOSED
/// on the corner the pin's types leave open: a coin whose `utxo.address` is
/// `None` cannot be matched to an exclusion, so offering it would bypass the
/// one custody check `verify_drain` enforces — it is counted reserved
/// instead. (Unreachable for coins this context scanned — they arrive via
/// address registration — but the type says Option, so the code refuses to
/// guess.) With no exclusions (a sweep — the total exit) everything
/// *spendable* is offered — covenant-bound coins are withheld even then
/// (D-211), because their exit is their contract's, not this sweep's.
fn drain_included(
    mature: Vec<UtxoEntryReference>,
    exclude: &[Address],
) -> (Vec<UtxoEntryReference>, usize, usize) {
    // Covenant-bound coins are withheld from EVERY drain, the total sweep
    // included (D-211): they move only through their covenant's own paths,
    // and a swept covenant coin is not recoverable. Counted separately from
    // the reservation so the refusal copy never mislabels a contract coin as
    // a conversation's.
    let (spendable, covenant): (Vec<UtxoEntryReference>, Vec<UtxoEntryReference>) = mature
        .into_iter()
        .partition(|entry| !spend_policy::is_covenant_bound(entry));
    let covenant_count = covenant.len();
    if exclude.is_empty() {
        return (spendable, 0, covenant_count);
    }
    let total = spendable.len();
    let included: Vec<UtxoEntryReference> = spendable
        .into_iter()
        .filter(|entry| {
            entry
                .utxo
                .address
                .as_ref()
                .is_some_and(|address| !exclude.contains(address))
        })
        .collect();
    let reserved_count = total - included.len();
    (included, reserved_count, covenant_count)
}

/// Pick the Generator mode for a drain over `included` coins. Pure; the
/// permanent tests drive every branch. `has_exclusions` is whether the CALLER
/// is withholding coins (consolidation around live conversation addresses) —
/// it forces the bounded arm even when `included` is large.
fn plan_drain(included: Vec<UtxoEntryReference>, has_exclusions: bool) -> Result<DrainArm> {
    if included.is_empty() {
        return Err(ChainError::Message(
            "nothing spendable to move right now".into(),
        ));
    }
    if has_exclusions || included.len() == 1 {
        let amount_sompi = included.iter().map(|entry| entry.amount()).sum();
        // Order is cosmetic for a full draw; ascending keeps the built
        // transaction's input list deterministic for a given coin set.
        let mut priority = included;
        priority.sort_by_key(|entry| entry.amount());
        return Ok(DrainArm::ReceiverPays {
            amount_sompi,
            priority,
        });
    }
    Ok(DrainArm::Drain)
}

/// What a verified drain will do — every number read back from the BUILT
/// chain (B7), never echoed from intent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DrainFacts {
    /// What the destination receives: the final transaction's single output.
    swept_sompi: u64,
    /// The Generator's aggregate fee across the chain.
    fee_sompi: u64,
    /// Wallet coins consumed (chain-internal edge outputs not counted).
    absorbed_utxos: u32,
}

/// Verify a built drain chain before it is allowed anywhere near a stash:
/// the final transaction pays the drain destination and NOTHING else (a
/// residue output would mean the wallet is not emptied — the whole point);
/// under an exclusion list every consumed wallet coin is one the caller
/// offered (the custody line: a conversation's coin must never ride out
/// inside a "consolidation"); and on a single-transaction result the
/// arithmetic balances to the sompi against the coins actually consumed —
/// `swept + fee == consumed`, so "the wallet ends at exactly zero" is proven
/// by construction, not claimed. Fails typed and closed; a drain that cannot
/// prove itself is refused, never broadcast.
fn verify_drain(
    pending: &[PendingTransaction],
    summary: &GeneratorSummary,
    destination: &Address,
    included: Option<&[UtxoEntryReference]>,
) -> Result<DrainFacts> {
    let final_pt = pending.iter().find(|pt| pt.is_final()).ok_or_else(|| {
        // One coin through the native sweep NoOps upstream; plan_drain routes
        // that to ReceiverPays, so reaching this is a plan/Generator drift.
        ChainError::Message("the drain built no final transaction — refusing".into())
    })?;
    let final_tx = final_pt.transaction();
    if final_tx.outputs.len() != 1 {
        return Err(ChainError::Message(format!(
            "the drain would leave {} outputs instead of one — refusing",
            final_tx.outputs.len()
        )));
    }
    if !pays_to(&final_tx, destination) {
        return Err(ChainError::Message(
            "the drain's output does not pay the drain destination — refusing".into(),
        ));
    }
    // A chained drain's intermediate legs pay the SAME destination (the
    // Generator's sweep target is its change slot) — asserted per leg, not
    // trusted from the Generator's shape: the chained arm moves the whole
    // wallet, so it gets the same runtime proof the single-tx arm gets.
    for pt in pending.iter().filter(|pt| !pt.is_final()) {
        let leg = pt.transaction();
        if !leg.outputs.iter().all(|output| {
            extract_script_pub_key_address(&output.script_public_key, destination.prefix)
                .is_ok_and(|decoded| &decoded == destination)
        }) {
            return Err(ChainError::Message(
                "a drain leg pays outside the drain destination — refusing".into(),
            ));
        }
    }

    // Wallet coins consumed = inputs whose previous outpoint is NOT a
    // transaction of this very chain (those are the compounding edges).
    let chain_txids: std::collections::HashSet<_> = pending.iter().map(|pt| pt.id()).collect();
    let consumed: Vec<_> = pending
        .iter()
        .flat_map(|pt| pt.transaction().inputs.clone())
        .filter(|input| !chain_txids.contains(&input.previous_outpoint.transaction_id))
        .collect();

    if let Some(included) = included {
        let offered: std::collections::HashSet<(kaspa_consensus_core::tx::TransactionId, u32)> =
            included
                .iter()
                .map(|entry| {
                    (
                        entry.utxo.outpoint.transaction_id(),
                        entry.utxo.outpoint.index(),
                    )
                })
                .collect();
        for input in &consumed {
            let key = (
                input.previous_outpoint.transaction_id,
                input.previous_outpoint.index,
            );
            if !offered.contains(&key) {
                return Err(ChainError::Message(
                    "the drain drew a coin outside its offered set — refusing".into(),
                ));
            }
        }
    }

    let swept_sompi = final_tx.outputs[0].value;
    let fee_sompi = summary.aggregate_fees();
    if pending.len() == 1 {
        let consumed_value: u64 = final_pt
            .utxo_entries()
            .values()
            .map(|entry| entry.amount())
            .sum();
        if swept_sompi.saturating_add(fee_sompi) != consumed_value {
            return Err(ChainError::Message(
                "the drain's arithmetic does not balance — refusing".into(),
            ));
        }
    }
    Ok(DrainFacts {
        swept_sompi,
        fee_sompi,
        absorbed_utxos: consumed.len() as u32,
    })
}

impl WalletEngine {
    /// Send max — empty every watched address to `destination` in one
    /// transaction (the wallet's EXIT: a self-custody wallet whose answer to
    /// "get all my money out" is "use another wallet" has a hole in the
    /// property it sells). The workable amount is `balance − fee` and the fee
    /// depends on the transaction spending it, so the BUILDER solves it — via
    /// the Generator's own modes ([`DrainArm`]), never an amount computed in
    /// the UI. `change_home` is our own address for the ReceiverPays arm's
    /// never-materializing change slot; the native-sweep arm's target is the
    /// destination itself.
    ///
    /// A wallet too fragmented for a one-transaction sweep is REFUSED toward
    /// consolidation rather than chained: the native sweep's intermediate
    /// legs pay the sweep target, and with an external destination those legs
    /// would be unsignable by us — a partial, confusing broadcast. Refusal is
    /// typed and the way out (consolidate, then sweep) ships beside it.
    pub async fn prepare_sweep(
        &self,
        destination: Address,
        change_home: Address,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
    ) -> Result<PreparedSend> {
        self.prepare_drain(destination, change_home, &[], true, signer, rpc)
            .await
    }

    /// Consolidate — absorb the wallet's spendable coins into ONE coin at
    /// `destination` (our own receive/0), so future sends pay the one-input
    /// floor instead of dragging the fragment pile. `exclude` withholds the
    /// bound addresses of live conversations: since D-148 nothing refills a
    /// non-identity bound address, so a consolidation that swallowed those
    /// coins would strand every off-identity conversation (the open item at
    /// `await_spendable_at`) — the exclusion keeps the chat lane funded and
    /// [`verify_drain`] enforces it on the BUILT transaction, not on intent.
    pub async fn prepare_consolidate(
        &self,
        destination: Address,
        exclude: &[Address],
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
    ) -> Result<PreparedSend> {
        self.prepare_drain(
            destination.clone(),
            destination,
            exclude,
            false,
            signer,
            rpc,
        )
        .await
    }

    /// The refusal half of the drain's observability (see the plan/built lines
    /// inside): a wrapper so that EVERY typed refusal exit — the empty offer,
    /// the fee floor, the custody checks, the chain-shape rules — emits exactly
    /// one line, without threading a log call through each `?`.
    ///
    /// The refusal REASON is deliberately absent: a typed chain error can carry
    /// amounts (`InsufficientFunds`, `StorageMassExceeded`) and this lane is
    /// lifecycle only (INV-3). The preceding plan line is what localises it —
    /// a refusal with no plan line never reached the Generator.
    async fn prepare_drain(
        &self,
        destination: Address,
        change_home: Address,
        exclude: &[Address],
        is_exit: bool,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
    ) -> Result<PreparedSend> {
        let result = self
            .prepare_drain_inner(destination, change_home, exclude, is_exit, signer, rpc)
            .await;
        if result.is_err() {
            log::info!("drain: {} refused", drain_kind(is_exit));
        }
        result
    }

    #[allow(clippy::too_many_arguments)]
    async fn prepare_drain_inner(
        &self,
        destination: Address,
        change_home: Address,
        exclude: &[Address],
        is_exit: bool,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
    ) -> Result<PreparedSend> {
        let context = self.context();
        let mature: Vec<UtxoEntryReference> = context
            .get_utxos(None, None)
            .await?
            .into_iter()
            .map(Into::into)
            .collect();
        let (included, excluded_count, covenant_count) = drain_included(mature, exclude);
        // Covenant withholding is an exclusion in every mechanical sense: it
        // forces the priority arm (which draws exactly the offered set, so the
        // withheld coins behind the context iterator are never reached) and it
        // arms `verify_drain`'s input-set check on the built chain (D-211).
        let has_withheld = !exclude.is_empty() || covenant_count > 0;
        let included_for_verify = has_withheld.then(|| included.clone());

        if !is_exit && included.len() < 2 {
            // One coin in, one coin out is a pure fee burn — nothing merges.
            // Name the real cause when a withholding line is what emptied the
            // offer (counts only, never an address) — and never mislabel a
            // contract coin as a conversation's.
            // The tail clause states what the rest actually IS — a lone coin
            // or nothing at all (closure-audit F-5: "the rest is already one
            // coin" was false at an empty offer).
            let rest = if included.is_empty() {
                "and nothing else is spendable"
            } else {
                "and the rest is already one coin"
            };
            return Err(ChainError::Message(
                match (excluded_count, covenant_count) {
                    (0, 0) => {
                        "nothing to merge — your spendable coins are already consolidated".into()
                    }
                    (r, 0) => format!(
                        "nothing to merge — {r} coin(s) stay reserved \
                     for your conversations, {rest}"
                    ),
                    (0, c) => format!(
                        "nothing to merge — {c} coin(s) are locked in contracts and \
                     move only through their own paths, {rest}"
                    ),
                    (r, c) => format!(
                        "nothing to merge — {r} coin(s) stay reserved for your \
                     conversations and {c} are locked in contracts, {rest}"
                    ),
                },
            ));
        }

        // The one user guaranteed to be confused — sweeping a wallet that
        // visibly holds funds, all of them contract-locked — gets the real
        // reason, not plan_drain's generic empty-offer line (D-211,
        // consensus-audit CONCERNS-3).
        if included.is_empty() && covenant_count > 0 {
            return Err(ChainError::Message(format!(
                "nothing spendable to move — {covenant_count} coin(s) are locked \
                 in contracts and move only through their own paths"
            )));
        }
        let offered_count = included.len();
        let arm = plan_drain(included, has_withheld)?;
        let chained_drain_allowed = !is_exit && matches!(arm, DrainArm::Drain);
        // The diagnosis lane for every "sweep won't work" report. Counts and
        // state words ONLY — never an amount, never an address (INV-3; the
        // transport lane's `module_logs_are_lifecycle_only` is the template,
        // and `send_logs_are_lifecycle_only` below is this file's copy of it).
        // The arm is chosen from data no screen shows, and the 2026-08-23
        // device sitting had to reason about a drain refusal from screenshots.
        log::info!(
            "drain: {} planning the {} arm over {offered_count} coin(s), \
             {excluded_count} reserved, {covenant_count} contract-locked",
            drain_kind(is_exit),
            drain_arm_name(&arm)
        );
        // Read BEFORE the match consumes `arm`.
        let discharge = discharges_outgoing(&arm, is_exit);
        let (pending, summary) = match arm {
            DrainArm::ReceiverPays {
                amount_sompi,
                priority,
            } => {
                let network_id = context.processor().network_id()?;
                let fee_floor = receiver_pays_fee_floor(network_id, &priority, &destination)?;
                if amount_sompi <= fee_floor {
                    return Err(ChainError::Message(
                        "these coins are worth less than the network fee to move them".into(),
                    ));
                }
                let built = generate_chain(
                    &context,
                    priority.clone(),
                    &change_home,
                    PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
                    Fees::ReceiverPays(0),
                    None,
                    signer.clone(),
                )?;
                // The one shape that used to dead-end: a MERGE the bounded arm
                // cannot fit in one transaction. It is not a dead end — it is
                // several one-transaction merges over disjoint coins (D-166's
                // debt, repaid). A SWEEP still refuses toward "merge first":
                // its legs would pay an external address and be unsignable by
                // us, which batching does not change.
                if !is_exit && built.0.len() > 1 {
                    let (pending, summary) =
                        batched_merge(priority, &destination, excluded_count, &mut |coins| {
                            try_batch(
                                &context,
                                coins,
                                &destination,
                                &change_home,
                                &signer,
                                network_id,
                            )
                        })?;
                    log::info!(
                        "drain: merge built — {} coin(s) absorbed across {} tx",
                        summary.utxo_count,
                        summary.tx_count
                    );
                    return Ok(PreparedSend {
                        pending,
                        summary,
                        rpc,
                        discharge_outgoing: discharge.then(|| context.clone()),
                    });
                }
                built
            }
            DrainArm::Drain => generate_chain(
                &context,
                Vec::new(),
                &destination, // the native sweep's target IS the change slot
                PaymentDestination::Change,
                Fees::None,
                None,
                signer,
            )?,
        };

        let summary = finish_drain(
            &pending,
            &summary,
            &destination,
            included_for_verify.as_deref(),
            chained_drain_allowed,
            is_exit,
        )?;
        log::info!(
            "drain: {} built — {} coin(s) absorbed across {} tx",
            drain_kind(is_exit),
            summary.utxo_count,
            summary.tx_count
        );
        Ok(PreparedSend {
            pending,
            summary,
            rpc,
            discharge_outgoing: discharge.then(|| context.clone()),
        })
    }
}

/// The bounded multi-pass merge — D-166's conscious debt, repaid.
///
/// A consolidation forced onto the bounded arm by live conversations used to
/// have NO one-tap answer once the offered pile outgrew a single transaction:
/// the refusal named ordinary sends and a full sweep and stopped there, which
/// is a liveness dead-end for exactly the wallet consolidation exists for
/// (long-lived, chat-active, fragmented). It is not a dead end — it is several
/// one-transaction merges over DISJOINT coin sets, previewed as one ceremony.
///
/// **Why disjoint batches are safe where a chain was not.** The bounded arm
/// cannot chain (its accumulator under-draws once stage fees exist, and its
/// multi-stage behaviour is upstream-untested — see [`DrainArm`]). Batches
/// avoid that entirely: each is a SINGLE `ReceiverPays` transaction over its
/// own coins, so each gets the same sompi-exact `swept + fee == consumed`
/// proof, the same one-output check, and the same offered-set custody check as
/// a lone merge. Generation does not mutate the context, and the batches share
/// no outpoint, so building them all against the same live snapshot cannot
/// double-spend. `commit` broadcasts them in order and already reports a typed
/// partial result if one fails after another has landed (L8).
///
/// Coins are taken SMALLEST FIRST, because reducing the count is the point and
/// the small end is where the pile lives; [`largest_single_tx_batch`] grows the
/// batch past any below-fee prefix rather than refusing at it.
///
/// The result leaves one coin PER BATCH, not one coin — the confirm says so,
/// and the action is idempotent, so a second tap merges those.
fn batched_merge(
    mut rest: Vec<UtxoEntryReference>,
    destination: &Address,
    reserved_count: usize,
    build: &mut impl FnMut(&[UtxoEntryReference]) -> Result<BatchFit>,
) -> Result<(Vec<PendingTransaction>, SendSummary)> {
    // Smallest first: a batch of k coins becomes one coin whatever the k, so
    // the count reduction is the same either way — but starting at the bottom
    // is what actually clears a fragment pile.
    rest.sort_by_key(UtxoEntryReference::amount);

    let mut all_pending: Vec<PendingTransaction> = Vec::new();
    let mut swept_total = 0u64;
    let mut fee_total = 0u64;
    let mut mass_total = 0u64;
    let mut absorbed_total = 0u32;
    let mut passes = 0usize;

    while passes < MERGE_BATCH_LIMIT && rest.len() >= 2 {
        let Some((taken, pending, summary)) = largest_single_tx_batch(&rest, build)? else {
            break;
        };
        // The SAME custody proof a single-transaction merge gets, per batch:
        // one output, paying our own address, drawing only coins this batch
        // offered, and balancing to the sompi.
        let facts = verify_drain(&pending, &summary, destination, Some(&rest[..taken]))?;
        swept_total = swept_total.saturating_add(facts.swept_sompi);
        fee_total = fee_total.saturating_add(facts.fee_sompi);
        mass_total = mass_total.saturating_add(summary.aggregate_mass());
        absorbed_total = absorbed_total.saturating_add(facts.absorbed_utxos);
        all_pending.extend(pending);
        rest.drain(..taken);
        passes += 1;
    }

    if all_pending.is_empty() {
        // Nothing could be batched at all — say which wall was hit rather than
        // repeating the old dead-end sentence. The reserve is named ONLY when
        // coins were actually withheld: a live conversation whose binding holds
        // no mature coin still forces this arm, and blaming a reserve that took
        // nothing sends the next reader to the wrong subsystem
        // (wallet-security audit, this sitting).
        return Err(ChainError::Message(if reserved_count > 0 {
            "these coins can't be merged right now — what is left over after \
             your conversations' reserves is worth less than the fee to move it. \
             Nothing was sent — ordinary sends absorb a few fragments each, so \
             this clears as you spend, and Send everything still empties the \
             wallet."
                .into()
        } else {
            "these coins can't be merged right now — they are worth less than \
             the network fee to move them. Nothing was sent — ordinary sends \
             absorb a few fragments each, so this clears as you spend."
                .to_string()
        }));
    }

    log::info!(
        "drain: merge batched into {passes} pass(es), {} coin(s) left over",
        rest.len()
    );

    Ok((
        all_pending,
        SendSummary {
            destination: destination.to_string(),
            amount_sompi: swept_total,
            fee_sompi: fee_total,
            total_sompi: swept_total.saturating_add(fee_total),
            mass: mass_total,
            // One transaction per batch, by construction — every batch is
            // verified `pending.len() == 1` before it is accepted.
            tx_count: passes as u32,
            utxo_count: absorbed_total,
            // One coin per pass — the arm where the two counts coincide, and
            // exactly why they must still be separate fields.
            resulting_coins: passes as u32,
            payload_len: 0,
        },
    ))
}

/// How many transactions ONE merge tap may broadcast.
///
/// Wallet policy, not a consensus number (INV-9 is untouched — every fee, mass
/// and fit here is still the Generator's answer). One hold-to-sign should not
/// fire an unbounded burst at the node, and every pass costs its own fee. Four
/// passes clear a few hundred coins at the pin's per-transaction input ceiling,
/// and whatever remains merges on the next tap: the action is idempotent, and
/// the confirm says how many transactions it is about to send.
const MERGE_BATCH_LIMIT: usize = 4;

/// One attempt at a batch of a given size.
enum BatchFit {
    /// The Generator built it — with however many transactions it needed.
    Built(Vec<PendingTransaction>, GeneratorSummary),
    /// The coins offered are worth less than the fee to move them: the batch is
    /// too SMALL, and the answer is to take more coins, not fewer.
    BelowFee,
}

/// Build one bounded (`ReceiverPays`) drain over exactly `coins`, with the
/// pin's `output.value -= fees` underflow guarded before generation — the same
/// two steps the single-transaction arm takes, factored out so the batching
/// loop runs the identical code path rather than a copy of it.
fn try_batch(
    context: &kaspa_wallet_core::utxo::UtxoContext,
    coins: &[UtxoEntryReference],
    destination: &Address,
    change_home: &Address,
    signer: &Arc<dyn SignerT>,
    network_id: kaspa_wrpc_client::prelude::NetworkId,
) -> Result<BatchFit> {
    let amount_sompi = coins
        .iter()
        .fold(0u64, |acc, entry| acc.saturating_add(entry.amount()));
    let fee_floor = receiver_pays_fee_floor(network_id, coins, destination)?;
    if amount_sompi <= fee_floor {
        return Ok(BatchFit::BelowFee);
    }
    let (pending, summary) = generate_chain(
        context,
        coins.to_vec(),
        change_home,
        PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
        Fees::ReceiverPays(0),
        None,
        signer.clone(),
    )?;
    Ok(BatchFit::Built(pending, summary))
}

/// The LARGEST prefix of `coins` the pinned Generator moves in ONE
/// transaction — built, not predicted.
///
/// The valid batch sizes form an interval, and the two ways out of it push in
/// opposite directions: too few coins and the set is worth less than the fee to
/// move it (take MORE), too many and the Generator splits the chain (take
/// FEWER). Both are read from real attempts, so the bisection needs no model of
/// mass or of the pin's input ceiling (INV-9). What it returns is the chain it
/// actually built at that size, so nothing is re-generated on the way out.
///
/// `None` = no batch of two or more coins works from here at all.
fn largest_single_tx_batch(
    coins: &[UtxoEntryReference],
    build: &mut impl FnMut(&[UtxoEntryReference]) -> Result<BatchFit>,
) -> Result<Option<(usize, Vec<PendingTransaction>, GeneratorSummary)>> {
    // A batch of one coin is a pure fee burn — one coin in, the same coin out
    // minus the fee. Nothing merges, so two is the floor.
    let mut lo = 2usize;
    let mut hi = coins.len();
    let mut best = None;
    while lo <= hi {
        let mid = lo + (hi - lo) / 2;
        match build(&coins[..mid])? {
            BatchFit::Built(pending, summary) if pending.len() == 1 => {
                best = Some((mid, pending, summary));
                lo = mid + 1;
            }
            // Chained: this many coins do not fit one transaction.
            BatchFit::Built(_, _) => hi = mid - 1,
            // Worth less than its own fee: this is too FEW coins, not too many.
            BatchFit::BelowFee => lo = mid + 1,
        }
    }
    Ok(best)
}

/// The fee of the ReceiverPays drain SHAPE (n inputs, one output), read from
/// the pinned Generator itself — the guard that keeps a below-fee coin set
/// out of the pin's unchecked `output.value -= transaction_fees`
/// (generator.rs:1071, a debug-build panic when fees exceed value; INV-2).
///
/// The probe runs the SAME shape with every coin value raised far above any
/// fee, so the probe itself cannot underflow. The fee transfers exactly: a
/// transaction's compute mass prices bytes (input count, script sizes), not
/// values, and the one-output sweep's storage term is ~0 on both sides
/// (output ≈ inputs). Nothing here computes mass — the Generator prices both
/// shapes (INV-9).
fn receiver_pays_fee_floor(
    network_id: kaspa_wrpc_client::prelude::NetworkId,
    priority: &[UtxoEntryReference],
    destination: &Address,
) -> Result<u64> {
    // ~10,000 KAS of headroom per coin: not a protocol constant, purely "so
    // large the probed fee can never reach it" — the fee it shields against
    // is ~10^5 sompi per shape at the pin's floor.
    const PROBE_HEADROOM_SOMPI: u64 = 1_000_000_000_000;
    let probe_entries: Vec<UtxoEntryReference> = priority
        .iter()
        .map(|entry| {
            let address = entry
                .utxo
                .address
                .clone()
                .unwrap_or_else(|| destination.clone());
            UtxoEntryReference::simulated_with_address(
                entry.amount().saturating_add(PROBE_HEADROOM_SOMPI),
                &address,
            )
        })
        .collect();
    // Saturating: the inflation is artificial, so an enormous coin count
    // could overflow a plain sum (a debug panic — the exact class this guard
    // exists to kill). Saturated, the Generator refuses typed and the drain
    // refuses with it.
    let probe_amount: u64 = probe_entries
        .iter()
        .fold(0u64, |acc, entry| acc.saturating_add(entry.amount()));
    let payment: PaymentDestination =
        PaymentOutputs::from((destination.clone(), probe_amount)).into();
    let settings = GeneratorSettings::try_new_with_iterator(
        network_id,
        Box::new(probe_entries.into_iter()),
        None,
        destination.clone(),
        1,
        1,
        payment,
        None,
        Fees::ReceiverPays(0),
        None,
        None,
    )?;
    match probe_shape(settings)? {
        Some((_, fee)) => Ok(fee),
        // The inflated shape refusing to build means the Generator cannot
        // price this coin set at all — refuse rather than guess a fee.
        None => Err(ChainError::Message(
            "these coins cannot be priced for a sweep right now".into(),
        )),
    }
}

/// The two drain kinds, in the user's own words — for logs only.
fn drain_kind(is_exit: bool) -> &'static str {
    if is_exit {
        "sweep"
    } else {
        "merge"
    }
}

/// Which Generator mode a drain planned onto — for logs only. The names are
/// this module's own vocabulary ([`DrainArm`]), not upstream identifiers, so a
/// logcat line stays readable beside the doc that explains the choice.
fn drain_arm_name(arm: &DrainArm) -> &'static str {
    match arm {
        DrainArm::ReceiverPays { .. } => "bounded",
        DrainArm::Drain => "native",
    }
}

/// Does this drain need the pin's outgoing record discharged after submit?
///
/// Both halves are load-bearing and each protects a different regression:
///
/// - `ReceiverPays` ONLY, because that is the arm whose fee the pin's
///   `calculate_balance` double-counts (the `Change` arm's adjustment nets to
///   zero — see [`PreparedSend::commit`]).
/// - EXIT ONLY, because a record retires itself as soon as one of the
///   transaction's outputs lands in the wallet. A consolidation's coin comes
///   home to `receive/0` and self-heals, and its `outgoing` bucket is the sole
///   input to the "still settling from your last send" classifier (consensus
///   finding 7) — discharging it early re-opens that regression from the other
///   side. Only a sweep pays an address the wallet does not watch, so only a
///   sweep is never retired.
fn discharges_outgoing(arm: &DrainArm, is_exit: bool) -> bool {
    matches!(arm, DrainArm::ReceiverPays { .. }) && is_exit
}

/// The shared post-generation tail of every drain — chain policy, the
/// [`verify_drain`] custody checks, and the B7 projection — extracted so the
/// offline tests run the EXACT code production runs, not a mirror of it.
///
/// `chained_drain_allowed` is true only for a consolidation on the native
/// Drain arm (the Generator's canonical compound, every leg paying our own
/// address). Since D-170 the merge half of the refusal below is a BACKSTOP:
/// production intercepts a bounded merge that outgrew one transaction and
/// routes it to [`batched_merge`] before this is reached. It still guards every
/// other caller, including the offline harness that proves it. An EXIT must be
/// one transaction — the native sweep's
/// intermediate legs pay the sweep target, and with an external destination
/// those legs would be unsignable by us: a partial, confusing broadcast. And
/// a chained ReceiverPays rides the upstream branch marked unreachable (see
/// [`DrainArm`]). Both are refused typed, with the way out named.
fn finish_drain(
    pending: &[PendingTransaction],
    summary: &GeneratorSummary,
    destination: &Address,
    included: Option<&[UtxoEntryReference]>,
    chained_drain_allowed: bool,
    is_exit: bool,
) -> Result<SendSummary> {
    if pending.len() > 1 && !chained_drain_allowed {
        // Two different users hit this wall; neither may get the other's
        // advice. A SWEEP can consolidate first (that action exists and
        // chains freely). A consolidation forced onto the bounded arm by
        // conversation reservations has no one-transaction answer today —
        // say what IS true: ordinary sends drain fragments (the rider), and
        // the total exit remains available. The bounded multi-pass merge is
        // ledgered debt, not silence.
        return Err(ChainError::Message(if is_exit {
            "too many coins to sweep in one transaction — merge your coins first, then sweep".into()
        } else {
            "too many coins to merge in one transaction while some stay reserved for your \
             conversations — ordinary sends absorb a few fragments each, so retry after \
             spending, or sweep everything to a new wallet"
                .into()
        }));
    }

    let facts = verify_drain(pending, summary, destination, included)?;

    // B7: what the confirm renders is the BUILT chain's own facts — the
    // destination receives `swept`, not the ReceiverPays arm's requested
    // amount (which includes the fee the Generator deducts).
    Ok(SendSummary {
        destination: destination.to_string(),
        amount_sompi: facts.swept_sompi,
        fee_sompi: facts.fee_sompi,
        total_sompi: facts.swept_sompi.saturating_add(facts.fee_sompi),
        mass: summary.aggregate_mass(),
        tx_count: summary.number_of_generated_transactions() as u32,
        utxo_count: facts.absorbed_utxos,
        // ONE, however many transactions it took: `verify_drain` has already
        // refused any chain whose final transaction has more than one output,
        // so the compound arm provably ends in a single coin.
        resulting_coins: 1,
        payload_len: 0,
    })
}

/// The consolidation preview's honesty pair: what one representative send
/// costs from TODAY's coin shape versus from the ONE coin the consolidation
/// will leave — both numbers generated by the pinned Generator over real
/// shapes, never computed here (INV-9). The "after" probe prices against a
/// coin with the BUILT output's exact value and the destination's exact
/// standard script (only the outpoint is simulated, and outpoints carry no
/// mass) — the comparison is against the coin the user will actually hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpendComparison {
    /// The representative amount both sides were priced at (half the
    /// consolidated value — a mid-shape ordinary send).
    pub amount_sompi: u64,
    /// Inputs an ordinary send of that amount draws TODAY (policy order).
    pub now_utxos: u32,
    /// Its fee today.
    pub now_fee_sompi: u64,
    /// The same send's fee from the single consolidated coin.
    pub after_fee_sompi: u64,
}

impl WalletEngine {
    /// Price the consolidation's "what it saves per future send" line. `None`
    /// when either side cannot be priced (a probe refusing is a shape fact,
    /// not an error — the preview then simply omits the savings line rather
    /// than invent one). Signerless, offline, public data only.
    pub fn consolidation_savings(
        &self,
        prepared: &PreparedSend,
        exclude: &[Address],
    ) -> Result<Option<SpendComparison>> {
        let summary = prepared.summary();
        let amount_sompi = summary.amount_sompi / 2;
        if amount_sompi == 0 {
            return Ok(None);
        }
        let destination = match Address::try_from(summary.destination.as_str()) {
            Ok(address) => address,
            Err(_) => return Ok(None),
        };

        // TODAY: an ordinary send from the live context in the real spend
        // order (riders + largest-first) — the fee the user pays now.
        let context = self.context();
        let mature = mature_snapshot_sync(&context)?;
        let order =
            spend_policy::select_spend_priority(&mature, &[], spend_policy::RIDER_LIMIT, exclude);
        let payment: PaymentDestination =
            PaymentOutputs::from((destination.clone(), amount_sompi)).into();
        let settings = GeneratorSettings::try_new_with_context(
            context.clone(),
            (!order.is_empty()).then_some(order),
            destination.clone(),
            1,
            1,
            payment,
            None,
            Fees::SenderPays(0),
            None,
            None,
        )?;
        let Some((now_utxos, now_fee_sompi)) = probe_shape(settings)? else {
            return Ok(None);
        };

        // AFTER: the same send from the coin the consolidation will create —
        // exact value, exact standard script for the destination (mass depends
        // on script size and values, and `simulated_with_address` builds the
        // real `pay_to_address_script`); only the outpoint is simulated, and
        // outpoints carry no mass.
        // A BATCHED merge leaves one coin per pass, not one coin, so the
        // "after" premise — price the same send from the single coin this
        // creates — is simply false. The preview then says nothing rather than
        // pricing against the first batch's coin and understating the fee.
        //
        // Gated on the FACT, never on `tx_count`: the native compound arm
        // chains freely and still ends in ONE coin, so a transaction-count gate
        // deleted a true savings line on the commoner arm — and then logged
        // "a probe shape refused" when no probe had run (consensus delta
        // re-review, this sitting).
        if summary.resulting_coins > 1 {
            return Ok(None);
        }
        let Some(final_pt) = prepared.pending.iter().find(|pt| pt.is_final()) else {
            return Ok(None);
        };
        let final_tx = final_pt.transaction();
        let Some(output) = final_tx.outputs.first() else {
            return Ok(None);
        };
        let entry = UtxoEntryReference::simulated_with_address(output.value, &destination);
        let network_id = context.processor().network_id()?;
        let payment: PaymentDestination =
            PaymentOutputs::from((destination.clone(), amount_sompi)).into();
        let settings = GeneratorSettings::try_new_with_iterator(
            network_id,
            Box::new(std::iter::once(entry)),
            None,
            destination,
            1,
            1,
            payment,
            None,
            Fees::SenderPays(0),
            None,
            None,
        )?;
        let Some((_, after_fee_sompi)) = probe_shape(settings)? else {
            return Ok(None);
        };

        Ok(Some(SpendComparison {
            amount_sompi,
            now_utxos,
            now_fee_sompi,
            after_fee_sompi,
        }))
    }
}

/// Run one signerless generation and read (inputs, fee) from its summary —
/// `None` when the shape refuses to build (too small / too large / dead
/// zone), which for a PREVIEW is an answer, not an error.
fn probe_shape(settings: GeneratorSettings) -> Result<Option<(u32, u64)>> {
    let generator = match Generator::try_new(settings, None, None) {
        Ok(generator) => generator,
        Err(e) => return probe_shape_refusal(e),
    };
    loop {
        match generator.generate_transaction() {
            Ok(Some(_)) => continue,
            Ok(None) => break,
            Err(e) => return probe_shape_refusal(e),
        }
    }
    let summary = generator.summary();
    Ok(Some((
        summary.aggregated_utxos() as u32,
        summary.aggregate_fees(),
    )))
}

/// A build refusal is `Ok(None)` for a preview; a real failure propagates.
fn probe_shape_refusal(e: kaspa_wallet_core::error::Error) -> Result<Option<(u32, u64)>> {
    match probe_error(e) {
        Ok(_) => Ok(None),
        Err(other) => Err(other),
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

/// Does any output of `tx` pay `address`?
///
/// The script is decoded back to an address with the pin's own standard decoder
/// rather than by comparing raw script bytes: the same function the receive scan
/// uses (`transport.rs`), so a script shape it can read is a script shape this
/// agrees with. A non-standard output simply does not match — it cannot be an
/// ordinary address payment.
fn pays_to(tx: &Transaction, address: &Address) -> bool {
    tx.outputs.iter().any(|output| {
        extract_script_pub_key_address(&output.script_public_key, address.prefix)
            .is_ok_and(|decoded| &decoded == address)
    })
}

/// Classify one candidate amount by running a real (unsigned, non-broadcast)
/// generation over the live context. Public data only: simulated payment to our
/// own change address (mass depends on script SIZE, not identity), no signer.
/// `order` is the SAME spend order a real send would use (spend_policy) — an
/// amount can build under one input order and die of storage mass under
/// another, so probing a different order would advertise a floor for a
/// transaction the wallet never builds.
fn probe_context(
    context: &kaspa_wallet_core::utxo::UtxoContext,
    change: &Address,
    amount_sompi: u64,
    order: Option<&[UtxoEntryReference]>,
) -> Result<ProbeOutcome> {
    let payment: PaymentDestination = PaymentOutputs::from((change.clone(), amount_sompi)).into();
    let settings = match GeneratorSettings::try_new_with_context(
        context.clone(),
        order.map(<[UtxoEntryReference]>::to_vec),
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
            Ok(Some(tx)) => {
                if let Some(outcome) = probe_classify(&tx) {
                    return Ok(outcome);
                }
                continue;
            }
            Ok(None) => return Ok(ProbeOutcome::Builds),
            Err(e) => return probe_error(e),
        }
    }
}

/// A probe that could only build by drawing a covenant-bound coin is
/// advertising an amount the fenced real send refuses (D-211,
/// consensus-audit CONCERNS-1): classify it TooLarge — the free coins ran
/// out, which is exactly what that outcome means. `None` = keep probing.
/// Pinned by test (closure-audit F-4).
fn probe_classify(tx: &PendingTransaction) -> Option<ProbeOutcome> {
    if covenant_fence(std::slice::from_ref(tx)).is_err() {
        return Some(ProbeOutcome::TooLarge);
    }
    None
}

/// Map a generation error onto a probe outcome (or a real failure).
///
/// `MassCalculationError` is classified TooSmall alongside `StorageMassExceeded`:
/// at the pin it is the Generator's own post-build mass double-check
/// (generator.rs:1108-1110/1166-1168 — "should never occur") tripping when a
/// near-balance amount leaves change whose storage mass the accumulation-phase
/// estimate under-counted. Measured on a single 0.481524 KAS coin: amounts in
/// the dead zone between "max ordinary send" and "sweep" surface as THIS error,
/// not StorageMassExceeded. Both mean the same thing for a probe — this amount
/// does not fit this coin shape — and both bound the search from below.
fn probe_error(e: kaspa_wallet_core::error::Error) -> Result<ProbeOutcome> {
    if matches!(e, kaspa_wallet_core::error::Error::MassCalculationError) {
        return Ok(ProbeOutcome::TooSmall);
    }
    match map_generate_error(e) {
        ChainError::StorageMassExceeded { .. } => Ok(ProbeOutcome::TooSmall),
        ChainError::InsufficientFunds { .. } => Ok(ProbeOutcome::TooLarge),
        other => Err(other),
    }
}

/// Fractions of the spendable balance to probe when the ladder finds no anchor,
/// as numerators over 1024. Dense just under 1/2 and widening downward.
///
/// Storage mass is harmonic in the OUTPUT values — the pin computes
/// `C * (|O|/H(O) − |I|/A(I))` over the output harmonic mean
/// (`consensus/core/src/mass/mod.rs:439-470 @ cfafeb4`) — so for a one-input
/// two-output shape it is smallest when the payment and the change are EQUAL.
/// The buildable band, when one exists, therefore straddles the equal-output
/// point `(B − fee)/2`, which is just below half the spendable value. The
/// audit's measured repro agrees: a 0.303 KAS coin has its band centred at
/// 0.993 × B/2.
///
/// This is a heuristic about WHERE TO PROBE, never a mass computation (INV-9),
/// and a missed sample costs a rescue that does not fire — never a wrong answer.
///
/// Scope of that claim, precisely: **the rescue phase sets `hi` only from a
/// probe that returned `Builds`**, so it never introduces an unbuilt value. It
/// does NOT upgrade `search_minimum`'s contract, which stays what
/// [`search_maximum`] already documents — a BOUND, not a promise: phase 2's
/// shrinking-window arm closes on `TooLarge` as well, so the returned floor may
/// be a value the Generator refused. That is why `search_maximum` re-probes its
/// anchor, and it is unchanged here.
///
/// **Two limits, both conservative, both deliberate:**
/// - The spacing nearest the centre is `8/1024` = 0.78% of `B`, so a band
///   narrower than that can be stepped over. F3's own band was 2.7% of `B`, so
///   it is caught with room; a narrower one simply is not rescued.
/// - `balance` is the FREE balance, but `select_spend_priority` only DEMOTES
///   reserved coins to the tail — it never withholds them — so the Generator's
///   reachable pool can exceed `balance` and the true centre can sit above
///   `512/1024`. The four fractions above half are the cheap cover for that,
///   probed last so the descending sweep still finds the lowest anchor first.
const PROBE_BAND_FRACTIONS_1024: [u64; 18] = [
    // Descending from the equal-output point: the first hit is the lowest
    // sampled anchor, and any anchor is enough (the bisect below re-finds the
    // band's true bottom from it).
    512, 504, 496, 488, 480, 464, 448, 416, 384, 320, 256, 192, 128, 64,
    // Last resort: a reachable pool larger than the free balance (see above).
    544, 576, 640, 768,
];

/// Find the smallest sendable amount by searching the TooSmall→Builds boundary.
/// Pure over an injected probe (unit-tested against synthetic boundaries AND the
/// real Generator). Sendability is not monotonic at the TOP (a near-sweep leaves
/// dusty change), so the search brackets only the BOTTOM boundary:
///
/// 1. **phase 1/1b** — doubling ladder from 0.01 KAS until a `Builds` anchor
///    (or the balance ceiling — then a short hunt inside the last window);
/// 2. **phase 1c, the rescue** — neither found an anchor, so probe where a band
///    actually lives (see below);
/// 3. **phase 2** — bisect TooSmall/Builds to display precision.
///
/// `None` = no sendable amount exists below the balance (the honest answer for
/// a dust-only wallet).
///
/// ## Why phase 1c exists (product-audit run 3, F3)
///
/// [`probe_error`] collapses BOTH storage-mass refusals into
/// [`ProbeOutcome::TooSmall`], and the two mean opposite things: below the band
/// the PAYMENT is dust, above it the CHANGE is. The ladder reads every TooSmall
/// as "the band is higher" and only ever raises `lo`. So when a rung lands above
/// a band narrower than the gap beneath it, `lo` is pinned above the entire
/// buildable range, phase 1b hunts empty space, and the function returns `None`
/// — which every consumer reads as a fund fact ("your balance can't cover a
/// message right now", and the send screen's floor line simply vanishes).
///
/// Reproduced against the real Generator on one coin of 30,300,000 sompi: rungs
/// 1M/2M/4M/8M/16M all TooSmall (16M is CHANGE-dust, above the band), 32M
/// TooLarge, result `None` — while 818 distinct amounts in
/// `[14_639_000, 15_457_000]` build.
///
/// Phase 1c is strictly a RESCUE: it runs only where the function would
/// otherwise have returned `None`, so every input that already produced an
/// answer still produces the same one, byte for byte. `balance` is the free
/// (spendable) balance; pass 0 to disable the rescue.
fn search_minimum(
    mut probe: impl FnMut(u64) -> Result<ProbeOutcome>,
    balance: u64,
) -> Result<Option<u64>> {
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
    // a buildable amount inside (lo, ceiling). A handful of probes suffices.
    //
    // Neither exit from this hunt may return `None` directly, and that is the
    // half F3 turned on: this window is `(lo, ceiling)`, and `lo` is only sound
    // if every TooSmall rung below it was a PAYMENT-side refusal. When one was a
    // change-side refusal the band sits BELOW `lo`, this window is empty by
    // construction, and an early return here would concede `None` over a wallet
    // that can send. Both exits therefore fall through to phase 1c.
    if hi.is_none() {
        if let Some(mut top) = ceiling {
            for _ in 0..10 {
                if top.saturating_sub(lo) <= PROBE_PRECISION_SOMPI {
                    break;
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
        }
    }

    // Phase 1c — the rescue (F3). The ladder proved nothing about the band: its
    // TooSmall rungs may have STEPPED OVER it, in which case `lo` is a lie and
    // phase 1b hunted the wrong window. Probe the place a band actually lives —
    // straddling half the spendable value — before conceding `None`.
    //
    // Descending, so the first hit is the lowest of the sampled anchors; and any
    // anchor is enough, because below a value the Generator BUILT the only way
    // left to fail is the payment side, which IS monotone. That is the same
    // asymmetry `search_maximum` documents from the other end.
    if hi.is_none() && balance > 0 {
        for numerator in PROBE_BAND_FRACTIONS_1024 {
            // u128 so the multiply cannot wrap on a whole-supply balance.
            let candidate = ((balance as u128 * numerator as u128) / 1024) as u64;
            if candidate == 0 {
                break;
            }
            if probe(candidate)? == ProbeOutcome::Builds {
                hi = Some(candidate);
                // `lo` is discarded on purpose: it was set by TooSmall rungs
                // that may have been CHANGE-side refusals above the band, so as
                // a lower bound it is unsound. Below a proven anchor the search
                // is monotone from zero, so zero is the honest bracket.
                lo = 0;
                break;
            }
        }
    }

    if hi.is_none() {
        return Ok(None);
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

/// Find the largest KNOWN-BUILDABLE amount, by climbing from a tested anchor
/// toward the balance. The mirror of [`search_minimum`] — and deliberately NOT
/// its symmetric twin, because the two boundaries are not symmetric.
///
/// Sendability is monotone at the bottom (below the floor the PAYMENT is dust,
/// and it stays dust all the way down) but it is NOT monotone at the top: above
/// the ceiling the CHANGE is dust, except at the single point where the change
/// vanishes into the fee entirely. So a bisection here cannot prove it found
/// the true supremum, and an unproven upper bound is worse than none — it would
/// send a user to an amount that refuses again.
///
/// The contract is therefore weaker and honest: **every value this returns was
/// probed and built**. `lo` starts at a re-probed anchor and only ever moves to
/// a value the Generator accepted, so the answer is a real transaction shape,
/// under-reported by at most [`PROBE_PRECISION_SOMPI`] — the conservative
/// direction for a ceiling.
///
/// `balance` is the mature total, used as the initial not-Builds bound without
/// probing it: with `Fees::SenderPays` the fee rides ON TOP of the payment
/// (generator.rs:862 @ `cfafeb4`), so an amount equal to the whole balance
/// cannot build. If a pin bump ever made that false, this returns a value below
/// the true maximum — conservative, never a bound that does not build.
fn search_maximum(
    mut probe: impl FnMut(u64) -> Result<ProbeOutcome>,
    anchor: u64,
    balance: u64,
) -> Result<Option<u64>> {
    // No room to climb ⇒ nothing was searched ⇒ no superlative to report. The
    // anchor does build, so returning it would be TRUE — and it would still be
    // "the largest that works right now" asserted over a space this function
    // never looked at, which is the same overclaim an unproven bound would be.
    // The copy degrades to its numberless sentence instead (consensus delta
    // re-review, this sitting). Checked BEFORE the anchor probe, so the
    // hopeless case costs nothing.
    if balance <= anchor {
        return Ok(None);
    }
    // The anchor is RE-PROBED rather than trusted. `search_minimum` closes its
    // bisection on `TooLarge` as well as `Builds` (the shrinking-window arm),
    // so its answer is a bound, not a promise — and this function's entire
    // contract is that what it hands back was built.
    if probe(anchor)? != ProbeOutcome::Builds {
        return Ok(None);
    }
    let mut lo = anchor; // greatest known-Builds — the answer, always tested
    let mut hi = balance; // known not-Builds (see the doc note above)
    while hi.saturating_sub(lo) > PROBE_PRECISION_SOMPI {
        let mid = lo + (hi - lo) / 2;
        match probe(mid)? {
            ProbeOutcome::Builds => lo = mid,
            // TooSmall here is the CHANGE being dust, not the payment: above a
            // buildable anchor the only way to fail downward is the change
            // side. Either refusal bounds the window from above.
            ProbeOutcome::TooSmall | ProbeOutcome::TooLarge => hi = mid,
        }
    }
    Ok(Some(lo))
}

impl WalletEngine {
    /// The smallest payment the pinned Generator will build from the CURRENT
    /// mature UTXO set (the KIP-9 floor, exact, for this wallet's coin shape) —
    /// or `None` when no amount below the balance is sendable. Signerless,
    /// offline, public data only; the change address doubles as the probe
    /// destination (identical script size ⇒ identical mass).
    ///
    /// `pinned`: the priority entries the real send will pin (D-067) — pass
    /// the same set handed to [`Self::prepare_send_pinned`], or `&[]` for a
    /// plain send. The probe walks the coins in the send's own order
    /// (spend_policy), so the floor it reports is the floor of the transaction
    /// that actually gets built.
    pub fn minimum_sendable(
        &self,
        change: Address,
        pinned: &[UtxoEntryReference],
        exclude: &[Address],
    ) -> Result<Option<u64>> {
        let context = self.context();
        let mature = mature_snapshot_sync(&context)?;
        let order = spend_policy::select_spend_priority(
            &mature,
            pinned,
            spend_policy::RIDER_LIMIT,
            exclude,
        );
        let order = (!order.is_empty()).then_some(order);
        search_minimum(
            |amount| probe_context(&context, &change, amount, order.as_deref()),
            free_balance(&mature, exclude),
        )
    }

    /// **The fee the ceremony will print, computed the same way it computes
    /// it** — a preview for the send screen, so the cost is on the glass
    /// before Review rather than after it.
    ///
    /// **It runs the REAL decision, not a copy of it.** The first cut built
    /// the ridden shape alone and called that "the same fee"; `prepare_send`
    /// builds **two** chains — ridden and riderless — and ships whichever
    /// [`shipped_shape`] selects, so the preview could differ in both
    /// directions. Measured on the founder's own wallet at **427_200 against
    /// 315_400 sompi**, 0.001118 KAS apart, and this file's own tests assert
    /// both the case where the cheap shape wins and the case where the leg law
    /// ships the dearer one (`consensus-auditor`, UX-4B). Two numbers for one
    /// send is precisely the confusion B7 exists to prevent, so this now calls
    /// the same `generate_chain` and the same `shipped_shape` with the same
    /// floor closure. The only differences from a real prepare are that the
    /// Generator gets **no signer** — which moves no fee — and that nothing is
    /// stashed.
    ///
    /// **It is fenced like the real path.** `select_spend_priority` withholds
    /// covenant-bound coins from the ORDER, but the Generator's fallback pool
    /// is the whole mature set, so a build can still draw one — which is why
    /// the real path checks the BUILT artifact with [`covenant_fence`] and why
    /// this must too (D-211: not-offering is not not-using). Without it the
    /// screen would price a send that Review is guaranteed to refuse.
    ///
    /// `None` means no transaction could be built — below the KIP-9 floor,
    /// above what the coins can cover, fenced, or an unparseable destination —
    /// and the caller renders **nothing**, never a guess.
    ///
    /// Signerless and read-only: it takes no key, no stash slot, and cannot
    /// disturb a concurrent real build (`generate_transaction` mutates only the
    /// Generator's own state; the UTXO context is touched in `try_submit`,
    /// which a preview never reaches).
    pub fn fee_preview(
        &self,
        destination: Address,
        change: Address,
        amount_sompi: u64,
        exclude: &[Address],
    ) -> Result<Option<u64>> {
        if amount_sompi == 0 {
            return Ok(None);
        }
        let context = self.context();
        let mature = mature_snapshot_sync(&context)?;
        let payment = || -> PaymentDestination {
            PaymentOutputs::from((destination.clone(), amount_sompi)).into()
        };
        let Ok(ridden) = price_chain(
            &context,
            spend_policy::select_spend_priority(&mature, &[], spend_policy::RIDER_LIMIT, exclude),
            &change,
            payment(),
            Fees::SenderPays(0),
            None,
        ) else {
            return Ok(None);
        };
        // The comparison shape is a QUESTION, never a gate — the same law the
        // real path applies to it.
        let comparison = price_chain(
            &context,
            spend_policy::select_spend_priority(&mature, &[], 0, exclude),
            &change,
            payment(),
            Fees::SenderPays(0),
            None,
        )
        .ok();
        let (pending, summary) = shipped_shape(ridden, comparison, || {
            let order = spend_policy::select_spend_priority(
                &mature,
                &[],
                spend_policy::RIDER_LIMIT,
                exclude,
            );
            let order = (!order.is_empty()).then_some(order);
            search_minimum(
                |amount| probe_context(&context, &change, amount, order.as_deref()),
                free_balance(&mature, exclude),
            )
            .ok()
            .flatten()
        });
        if covenant_fence(&pending).is_err() {
            return Ok(None);
        }
        Ok(Some(summary.aggregate_fees()))
    }

    /// The largest payment the pinned Generator will build from the CURRENT
    /// mature UTXO set — the mirror of [`Self::minimum_sendable`], for the
    /// other half of the same window. `None` when the wallet cannot send at
    /// all, or when no anchor could be proven (never a guess).
    ///
    /// **What it promises, exactly:** the returned amount was handed to the
    /// Generator and built. It is not "the most that could ever work" — the top
    /// boundary is not monotone (above it the CHANGE is dust, and only the
    /// single point where change vanishes into the fee builds again), so no
    /// probe can claim the supremum. It is the largest amount we have PROVEN,
    /// which is the only kind of number a refusal may offer a user.
    ///
    /// Cost: this runs [`search_minimum`] for its anchor and then climbs, so it
    /// is roughly twice a floor lookup. It belongs on the refusal path (where a
    /// user is already stopped and owed a number), not on the send path.
    pub fn maximum_sendable(
        &self,
        change: Address,
        pinned: &[UtxoEntryReference],
        exclude: &[Address],
    ) -> Result<Option<u64>> {
        let context = self.context();
        let mature = mature_snapshot_sync(&context)?;
        // The climb's upper bound counts the FREE coins only.
        //
        // The demote-never-withhold law says a user may spend into the reserved
        // tail when nothing else covers the payment; it does not say the wallet
        // should RECOMMEND it. This number is rendered as "the largest that
        // works right now", and the dead zone sits just under the sweep, so a
        // ceiling folded over the whole mature set would be an instruction to
        // drain every conversation binding — the D-148 harm, prescribed by us,
        // from addresses the app never shows (wallet-security audit, this
        // sitting).
        //
        // Honest residual: this bounds what is OFFERED, not what the Generator
        // draws. An amount just under the free total can still need one
        // reserved coin for its fee, and `finish_prepared_send`'s reserved-draw
        // line is what reports that if it happens.
        //
        let balance = free_balance(&mature, exclude);
        let order = spend_policy::select_spend_priority(
            &mature,
            pinned,
            spend_policy::RIDER_LIMIT,
            exclude,
        );
        let order = (!order.is_empty()).then_some(order);
        let mut probe = |amount| probe_context(&context, &change, amount, order.as_deref());
        // The floor is the one amount we know sits inside the buildable band,
        // so it is the anchor — re-probed inside `search_maximum`.
        let Some(anchor) = search_minimum(&mut probe, balance)? else {
            return Ok(None);
        };
        search_maximum(probe, anchor, balance)
    }
}

/// The value of the coins a send may draw on WITHOUT reaching into the reserved
/// tail — the upper bound [`WalletEngine::maximum_sendable`]'s climb is allowed
/// to point at.
///
/// Mirrors `select_spend_priority`'s own short-circuit: with no reservations
/// nothing is reserved, so the whole mature set counts — minus covenant-bound
/// coins, which are withheld from every plain spend (D-211): a bound that
/// counted them would advertise an amount the fenced real send refuses.
/// Saturating, because a wrapped total would hand the climb a nonsense bound
/// (a balance that overflows u64 is impossible on this network).
fn free_balance(mature: &[UtxoEntryReference], exclude: &[Address]) -> u64 {
    mature
        .iter()
        .filter(|entry| !spend_policy::is_covenant_bound(entry))
        .filter(|entry| exclude.is_empty() || !spend_policy::is_reserved(entry, exclude))
        .fold(0u64, |acc, entry| acc.saturating_add(entry.amount()))
}

/// A synchronous snapshot of the live context's mature set, in context order.
///
/// The pin's `UtxoContext::get_utxos` is async in signature only: its body
/// (context.rs:757-807 @ `cfafeb4`) takes a std mutex and contains no await
/// point, so its future is Ready on the first poll and polling it once with a
/// no-op waker is a complete execution, not a gamble. If a future pin bump
/// makes it genuinely asynchronous, this returns a typed error — never a hang,
/// never a spin — which is the tripwire forcing this sync call site
/// ([`WalletEngine::minimum_sendable`]) to be re-plumbed rather than silently
/// probing a stale or empty order.
fn mature_snapshot_sync(
    context: &kaspa_wallet_core::utxo::UtxoContext,
) -> Result<Vec<UtxoEntryReference>> {
    use std::future::Future;
    let fut = context.get_utxos(None, None);
    let mut fut = std::pin::pin!(fut);
    let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
    match fut.as_mut().poll(&mut cx) {
        std::task::Poll::Ready(entries) => Ok(entries?.into_iter().map(Into::into).collect()),
        std::task::Poll::Pending => {
            // LATCHED, and it has to be. This error is a pin tripwire, but both
            // of its consumers swallow it silently — the floor probe and the
            // live fee preview each catch and render nothing — so a pin bump
            // that made `get_utxos` genuinely async would present as a fee and
            // a minimum that quietly stopped appearing, with no red anywhere.
            // A signal with no reader is a silent failure by construction
            // (`wallet-security-auditor`, UX-4B), and the log line is the reader.
            //
            // Behind a `Once` because the preview calls this on a keystroke
            // debounce: unlatched it would flood logcat at several lines a
            // second and evict the diagnostics around it (L65).
            static TRIPPED: std::sync::Once = std::sync::Once::new();
            TRIPPED.call_once(|| {
                log::error!(
                    "send: UtxoContext::get_utxos is no longer ready-on-poll — the mature \
                     snapshot is now empty on every call; the KIP-9 floor and the live fee \
                     preview have gone silent. Re-plumb before trusting either."
                );
            });
            Err(ChainError::Message(
                "the pinned UtxoContext::get_utxos became genuinely asynchronous — \
                 re-plumb minimum_sendable's mature snapshot before trusting its floor"
                    .into(),
            ))
        }
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
        // Not a drain: an ordinary payment's change count is not this field's
        // business, and 0 is how it says so.
        resulting_coins: 0,
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
        // The Generator's post-build mass double-check (generator.rs:1108-1110)
        // surfaces the SAME dead zone as `StorageMassExceedsMaximumTransactionMass`
        // — `probe_error` already collapses the two for exactly this reason
        // (see its note) — but left un-mapped it reached the user as the raw
        // upstream Display text "Mass calculation error". One layer down, the
        // same collapse, so both halves of the dead zone earn the same honest
        // sentence. `storage_mass: 0` because this arm carries no measured mass;
        // no caller reads the number (the copy is driven by `minimum_sendable`).
        kaspa_wallet_core::error::Error::MassCalculationError => {
            ChainError::StorageMassExceeded { storage_mass: 0 }
        }
        other => ChainError::from(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_consensus_core::subnets::SUBNETWORK_ID_NATIVE;
    use kaspa_consensus_core::tx::TransactionOutput;
    use kaspa_txscript::pay_to_address_script;
    use kaspa_wallet_core::tx::generator::PendingTransaction as Pt;
    use kaspa_wallet_core::utils::kaspa_to_sompi;
    use kaspa_wallet_core::utxo::UtxoEntryReference;

    use crate::spend_policy::RIDER_LIMIT;
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

    /// A covenant-bound simulated coin — `covenant_id` stamped on the pin's
    /// own entry type, the shape `populate_genesis_covenants` produces when a
    /// covenant output pays one of our derived addresses.
    fn covenant_entry(kas: f64) -> UtxoEntryReference {
        let mut utxo = (*UtxoEntryReference::simulated(kaspa_to_sompi(kas)).utxo).clone();
        utxo.covenant_id = Some(kaspa_consensus_core::tx::TransactionId::from_bytes(
            [0xCC; 32],
        ));
        UtxoEntryReference::from(utxo)
    }

    /// The fence (D-211), end to end in the production shape: the policy
    /// order WITHHOLDS the covenant coin (`select_spend_priority`), the free
    /// coins cannot cover the send, the Generator draws the covenant coin
    /// from the context iterator BEHIND the priority order — the exact leak
    /// the policy layer cannot prevent — and the fence refuses the built
    /// chain with the typed error.
    #[test]
    fn covenant_fence_refuses_a_chain_that_drew_a_covenant_coin() {
        let pool = vec![
            covenant_entry(100.0),
            UtxoEntryReference::simulated(kaspa_to_sompi(0.2)),
        ];
        let order = crate::spend_policy::select_spend_priority(&pool, &[], 0, &[]);
        assert!(
            order.iter().all(|e| e.utxo.covenant_id.is_none()),
            "policy withholds the covenant coin from the order"
        );
        let generator = offline_generator_over(&pool, order, 50.0, addr(CHANGE));
        let pending = drain(&generator);
        assert!(!pending.is_empty(), "the Generator built a chain");
        match covenant_fence(&pending) {
            Err(ChainError::CovenantBoundInput { outpoint }) => {
                assert!(
                    outpoint.contains(':'),
                    "outpoint is txid:index, got {outpoint}"
                );
            }
            other => panic!("expected CovenantBoundInput, got {other:?}"),
        }
    }

    #[test]
    fn free_balance_never_counts_covenant_coins() {
        // Closure-audit F-4: the advertised bound and the fenced send must
        // agree — a maximum that counts covenant value is a number the real
        // send refuses.
        let entries = vec![
            UtxoEntryReference::simulated(kaspa_to_sompi(5.0)),
            covenant_entry(9.0),
        ];
        assert_eq!(free_balance(&entries, &[]), kaspa_to_sompi(5.0));
    }

    #[test]
    fn a_probe_chain_that_drew_a_covenant_coin_classifies_too_large() {
        // Closure-audit F-4: pin the probe arm. Same leak shape as the fence
        // test — priority covenant-free, free coins insufficient, the
        // covenant coin drawn from the iterator — and the probe must report
        // TooLarge, never Builds.
        let pool = vec![
            covenant_entry(100.0),
            UtxoEntryReference::simulated(kaspa_to_sompi(0.2)),
        ];
        let order = crate::spend_policy::select_spend_priority(&pool, &[], 0, &[]);
        let generator = offline_generator_over(&pool, order, 50.0, addr(CHANGE));
        let pending = drain(&generator);
        assert!(pending
            .iter()
            .any(|tx| matches!(probe_classify(tx), Some(ProbeOutcome::TooLarge))));
    }

    /// The complement: a clean chain passes the fence untouched.
    #[test]
    fn covenant_fence_passes_a_clean_chain() {
        let generator = offline_generator(&[100.0, 0.2], 50.0, addr(CHANGE));
        let pending = drain(&generator);
        assert!(!pending.is_empty());
        covenant_fence(&pending).expect("no covenant-bound inputs — the fence stays silent");
    }

    /// The liveness half of D-211 (consensus-audit CONCERNS-2, pinned): an
    /// EXIT over a pool containing a covenant coin still sweeps everything
    /// spendable in one built chain — the ReceiverPays arm's amount is the
    /// offered sum, so the Generator stops at the end of the priority list,
    /// the fence stays silent, and the covenant coin is untouched. INV-6 in
    /// spirit: the sweep is never blocked by coins that have their own
    /// contract exits.
    #[test]
    fn an_exit_sweeps_everything_spendable_and_leaves_the_covenant_coin() {
        let cov = covenant_entry(9.0);
        let pool = vec![
            UtxoEntryReference::simulated(kaspa_to_sompi(5.0)),
            UtxoEntryReference::simulated(kaspa_to_sompi(3.0)),
            cov.clone(),
        ];
        let (pending, _summary) = run_drain_offline(&pool, &[], &addr(DEST), &addr(CHANGE), true)
            .expect("the exit sweeps the spendable coins");
        covenant_fence(&pending).expect("fence silent — no covenant coin drawn");
        let consumed: Vec<UtxoEntryReference> = pending
            .iter()
            .flat_map(|tx| tx.utxo_entries().values().cloned().collect::<Vec<_>>())
            .collect();
        assert_eq!(consumed.len(), 2, "both free coins swept, nothing else");
        assert!(
            consumed.iter().all(|entry| {
                entry.utxo.outpoint.transaction_id() != cov.utxo.outpoint.transaction_id()
            }),
            "the covenant coin is untouched by the sweep"
        );
    }

    /// The silent-identity-change guard (wallet-security finding 1): an
    /// all-covenant pin REFUSES — it never proceeds with the wrong input[0] —
    /// and a mixed pin proceeds with only its spendable part.
    #[test]
    fn an_all_covenant_pin_is_refused_a_mixed_pin_loses_only_the_covenant_part() {
        let refusal = pinned_priority_or_refuse(vec![covenant_entry(7.0)]);
        assert!(
            matches!(refusal, Err(ChainError::Message(ref m)) if m.contains("no spendable UTXO to pin")),
            "an all-covenant pin hits the honest refusal, got {refusal:?}"
        );

        let free = UtxoEntryReference::simulated(kaspa_to_sompi(3.0));
        let kept = pinned_priority_or_refuse(vec![covenant_entry(7.0), free.clone()])
            .expect("a mixed pin proceeds");
        assert_eq!(kept.len(), 1);
        assert!(kept[0].utxo.covenant_id.is_none());
    }

    /// Drains withhold covenant coins even from a total sweep, counted apart
    /// from the conversation reservation so the refusal copy never mislabels
    /// a contract coin as a conversation's (D-211).
    #[test]
    fn drain_withholds_covenant_coins_even_from_a_sweep() {
        let entries = vec![
            UtxoEntryReference::simulated(kaspa_to_sompi(5.0)),
            covenant_entry(9.0),
        ];
        let (included, reserved, covenant) = drain_included(entries, &[]);
        assert_eq!((included.len(), reserved, covenant), (1, 0, 1));
        assert!(included.iter().all(|e| e.utxo.covenant_id.is_none()));
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

    /// The founder's measured fragmentation shape (2026-08-13): 12 x 0.5 +
    /// 6 x 2 + 3 x 10 + 1 x 200 KAS = 248 KAS across 22 coins. The spend-policy
    /// fence tests below assert the pinned Generator's EXACT numbers over it —
    /// reproduced from the original probe, never re-derived. A pin bump that
    /// moves any of them must fail here loudly.
    fn fragmented_fixture() -> Vec<f64> {
        std::iter::repeat_n(0.5, 12)
            .chain(std::iter::repeat_n(2.0, 6))
            .chain(std::iter::repeat_n(10.0, 3))
            .chain(std::iter::once(200.0))
            .collect()
    }

    /// A generator whose pool is `pool` (iterator order as given) and whose
    /// priority list is `order` — the production shape of the spend policy
    /// (`prepare_send_inner` hands the full policy order to the priority slot
    /// over the live context; the iterator path proves identical draw
    /// mechanics, as `offline_generator_pinned` already establishes).
    fn offline_generator_over(
        pool: &[UtxoEntryReference],
        order: Vec<UtxoEntryReference>,
        send_kas: f64,
        change: Address,
    ) -> Generator {
        let payment: PaymentDestination =
            PaymentOutputs::from((addr(DEST), kaspa_to_sompi(send_kas))).into();
        let settings = GeneratorSettings::try_new_with_iterator(
            mainnet(),
            // Owned, not borrowed: the settings box the Generator stores is
            // 'static, so a borrowing iterator cannot cross into it.
            #[allow(clippy::unnecessary_to_owned)]
            Box::new(pool.to_vec().into_iter()),
            (!order.is_empty()).then_some(order),
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

    /// THE SPEND-POLICY FENCE, part 1 — the starting reality (2026-08-13,
    /// reproduced): the pinned context's ASCENDING order (smallest-first, the
    /// pre-policy wallet) versus pure DESCENDING (largest-first, Kaspium's
    /// order), over the founder's measured wallet shape. The entire fee gap is
    /// input count at the identical relay floor: one extra input costs 1,118
    /// grams = 111,800 sompi here, and smallest-first drags in up to 22.
    #[test]
    fn spend_policy_table_reproduces_the_measured_orderings() {
        let mut asc = fragmented_fixture();
        asc.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let mut desc = fragmented_fixture();
        desc.sort_by(|a, b| b.partial_cmp(a).unwrap());

        // (send KAS, ascending inputs/fee, descending inputs/fee) — sompi-exact.
        let table = [
            (1.0, (3, 427_200), (2, 315_400)),
            (10.0, (15, 1_768_800), (1, 203_600)),
            (100.0, (22, 2_551_400), (1, 203_600)),
        ];
        for (send, (asc_inputs, asc_fee), (desc_inputs, desc_fee)) in table {
            let generator = offline_generator(&asc, send, addr(CHANGE));
            drain(&generator);
            let s = project_summary(&generator.summary(), DEST.to_string());
            assert_eq!(
                (s.utxo_count, s.fee_sompi, s.tx_count),
                (asc_inputs, asc_fee, 1),
                "ascending (pre-policy) order for a {send} KAS send"
            );

            let generator = offline_generator(&desc, send, addr(CHANGE));
            drain(&generator);
            let s = project_summary(&generator.summary(), DEST.to_string());
            assert_eq!(
                (s.utxo_count, s.fee_sompi, s.tx_count),
                (desc_inputs, desc_fee, 1),
                "descending (largest-first) order for a {send} KAS send"
            );
        }

        // The true 1-in-2-out floor: one fat coin, any ordinary amount.
        let generator = offline_generator(&[200.0], 10.0, addr(CHANGE));
        drain(&generator);
        let s = project_summary(&generator.summary(), DEST.to_string());
        assert_eq!(
            (s.utxo_count, s.fee_sompi),
            (1, 203_600),
            "the one-input floor"
        );
    }

    /// THE SPEND-POLICY FENCE, part 2 — the ending reality: the policy order
    /// (riders first, then largest-first) through the Generator's priority
    /// slot, exactly as production wires it. Every ordinary send from the
    /// fragmented wallet is 2 riders + 1 fat coin = 3 inputs at 427,200 sompi:
    /// the 10/100 KAS sends collapse 15->3 and 22->3, and the marginal cost of
    /// the riders is bounded by RIDER_LIMIT extra inputs over pure
    /// largest-first — asserted mechanically, not claimed.
    #[test]
    fn spend_policy_collapses_the_fragmented_send_within_the_rider_bound() {
        // Pure largest-first input counts from the table test above.
        let table = [(1.0, 2u32), (10.0, 1), (100.0, 1)];
        for (send, largest_first_inputs) in table {
            let entries: Vec<UtxoEntryReference> = fragmented_fixture()
                .iter()
                .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
                .collect();
            let order = crate::spend_policy::select_spend_priority(&entries, &[], RIDER_LIMIT, &[]);
            let generator = offline_generator_over(&entries, order.clone(), send, addr(CHANGE));
            let pending = drain(&generator);
            let s = project_summary(&generator.summary(), DEST.to_string());
            assert_eq!(
                (s.utxo_count, s.fee_sompi, s.tx_count),
                (3, 427_200, 1),
                "policy order for a {send} KAS send: 2 riders + 1 fat coin"
            );
            assert!(
                s.utxo_count <= largest_first_inputs + RIDER_LIMIT as u32,
                "rider law: at most RIDER_LIMIT inputs over pure largest-first"
            );

            // The Generator drew the policy list IN ORDER: the built inputs are
            // a prefix of it (riders lead, largest funds).
            let tx = pending
                .iter()
                .find(|pt| pt.is_final())
                .unwrap()
                .transaction();
            for (i, input) in tx.inputs.iter().enumerate() {
                assert_eq!(
                    input.previous_outpoint.transaction_id,
                    order[i].transaction_id(),
                    "input[{i}] must be policy order[{i}]"
                );
            }
        }
    }

    /// THE RIDER INVARIANT (spend-policy deliverable 3): over N successive
    /// sends from the fragmented wallet, the UTXO count STRICTLY decreases —
    /// largest-first alone would tread water (one coin out, one change back),
    /// so this is the riders provably draining the pile. Also proves the
    /// no-new-leg law the cheap way: every round builds exactly one
    /// transaction.
    /// How many riders the SHIPPED decision keeps for this pool and amount —
    /// `RIDER_LIMIT` or 0, decided by [`riderless_wins`] over both built
    /// shapes, exactly as `prepare_send_inner` decides it.
    fn shipped_riders(pool: &[UtxoEntryReference], send_kas: f64) -> usize {
        let (ridden, riderless) = both_shapes(pool, send_kas);
        let extra = extra_absorbed(&ridden, &riderless);
        let floor = if riderless_is_candidate(
            ridden.legs,
            riderless.legs,
            ridden.fee,
            riderless.fee,
            extra,
        ) && riderless.change != 0
        {
            offline_floor(pool)
        } else {
            None
        };
        if riderless_wins(
            ridden.legs,
            riderless.legs,
            ridden.fee,
            riderless.fee,
            riderless.change,
            extra,
            floor,
        ) {
            0
        } else {
            spend_policy::RIDER_LIMIT
        }
    }

    /// A batch builder over an offline coin set — the same two steps
    /// `try_batch` takes in production (fee-floor guard, then one
    /// `ReceiverPays` generation over exactly the offered coins), expressed
    /// with `try_new_with_iterator` because these tests have no live context.
    fn offline_batch_builder<'a>(
        entries: &'a [UtxoEntryReference],
        destination: &'a Address,
        change_home: &'a Address,
    ) -> impl FnMut(&[UtxoEntryReference]) -> Result<BatchFit> + 'a {
        move |coins| {
            let amount_sompi = coins
                .iter()
                .fold(0u64, |acc, entry| acc.saturating_add(entry.amount()));
            let fee_floor = receiver_pays_fee_floor(mainnet(), coins, destination)?;
            if amount_sompi <= fee_floor {
                return Ok(BatchFit::BelowFee);
            }
            let settings = GeneratorSettings::try_new_with_iterator(
                mainnet(),
                #[allow(clippy::unnecessary_to_owned)]
                Box::new(entries.to_vec().into_iter()),
                Some(coins.to_vec()),
                change_home.clone(),
                1,
                1,
                PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
                None,
                Fees::ReceiverPays(0),
                None,
                None,
            )?;
            let generator = Generator::try_new(settings, None, None)?;
            let mut pending = Vec::new();
            loop {
                match generator.generate_transaction() {
                    Ok(Some(tx)) => pending.push(tx),
                    Ok(None) => break,
                    Err(e) => return Err(map_generate_error(e)),
                }
            }
            Ok(BatchFit::Built(pending, generator.summary()))
        }
    }

    /// Every custody line a batched merge must hold, checked on the BUILT
    /// transactions rather than on intent: each pass is exactly one
    /// transaction with exactly one output paying our own address, the passes
    /// share no coin, and the coins consumed are exactly the ones offered.
    fn assert_batch_custody(pending: &[Pt], destination: &Address, offered: &[UtxoEntryReference]) {
        let offered_keys: std::collections::HashSet<_> = offered
            .iter()
            .map(|entry| {
                (
                    entry.utxo.outpoint.transaction_id(),
                    entry.utxo.outpoint.index(),
                )
            })
            .collect();
        let mut seen: std::collections::HashSet<(kaspa_consensus_core::tx::TransactionId, u32)> =
            std::collections::HashSet::new();
        for pt in pending {
            assert!(pt.is_final(), "every pass is a standalone transaction");
            let tx = pt.transaction();
            assert_eq!(tx.outputs.len(), 1, "one output per pass");
            assert!(pays_to(&tx, destination), "and it pays our own address");
            for input in &tx.inputs {
                let key = (
                    input.previous_outpoint.transaction_id,
                    input.previous_outpoint.index,
                );
                assert!(offered_keys.contains(&key), "a pass drew an unoffered coin");
                assert!(seen.insert(key), "two passes spent the same coin");
            }
        }
    }

    /// **D-166's conscious debt, repaid.** A pile too big for one transaction
    /// used to refuse with no path forward; it now merges in bounded passes.
    /// 200 coins at the pin's own single-transaction ceiling (88, found by the
    /// bisection, never hardcoded) is three passes with nothing left over.
    #[test]
    fn a_pile_too_big_for_one_transaction_merges_in_bounded_passes() {
        let home = addr(DEST);
        let change = addr(CHANGE);
        let entries: Vec<UtxoEntryReference> = (0..200)
            .map(|_| UtxoEntryReference::simulated_with_address(50_000_000, &home))
            .collect();
        let mut build = offline_batch_builder(&entries, &home, &change);
        let (pending, summary) = batched_merge(entries.clone(), &home, 0, &mut build).unwrap();

        assert_eq!(summary.tx_count, 3, "88 + 88 + 24");
        assert_eq!(pending.len(), 3, "one transaction per pass");
        assert_eq!(summary.utxo_count, 200, "every coin absorbed");
        assert_batch_custody(&pending, &home, &entries);
        // The whole point: 200 coins become 3, and a second tap merges those.
        assert!(
            (summary.tx_count as usize) < entries.len(),
            "the pile actually shrank"
        );
    }

    /// The bound is real and it is not silent: a pile past `MERGE_BATCH_LIMIT`
    /// passes merges what it can and leaves the rest, and the summary reports
    /// exactly what will be moved — the confirm renders those numbers, so the
    /// user is never told the wallet was emptied when it was not.
    #[test]
    fn the_pass_limit_holds_and_the_summary_reports_only_what_moves() {
        let home = addr(DEST);
        let change = addr(CHANGE);
        let entries: Vec<UtxoEntryReference> = (0..400)
            .map(|_| UtxoEntryReference::simulated_with_address(50_000_000, &home))
            .collect();
        let mut build = offline_batch_builder(&entries, &home, &change);
        let (pending, summary) = batched_merge(entries.clone(), &home, 0, &mut build).unwrap();

        assert_eq!(summary.tx_count as usize, MERGE_BATCH_LIMIT);
        assert_eq!(pending.len(), MERGE_BATCH_LIMIT);
        assert_eq!(summary.utxo_count, 352, "4 passes x 88 coins");
        assert!(
            (summary.utxo_count as usize) < entries.len(),
            "48 coins stay behind — and the summary says 352, not 400"
        );
        assert_batch_custody(&pending, &home, &entries);
    }

    /// Smallest first: the pile is cleared from the bottom, because that is
    /// where a fragment pile lives. (Mutation fence — reversing the sort reds
    /// this and nothing else.)
    #[test]
    fn batches_take_the_smallest_coins_first() {
        let home = addr(DEST);
        let change = addr(CHANGE);
        // 100 small coins and 5 fat ones: one pass of 88 must be all small.
        let mut entries: Vec<UtxoEntryReference> = (0..100)
            .map(|_| UtxoEntryReference::simulated_with_address(50_000_000, &home))
            .collect();
        entries
            .extend((0..5).map(|_| UtxoEntryReference::simulated_with_address(900_000_000, &home)));
        let mut build = offline_batch_builder(&entries, &home, &change);
        let (pending, _) = batched_merge(entries.clone(), &home, 0, &mut build).unwrap();
        let first = pending[0].transaction();
        let by_outpoint: std::collections::HashMap<_, _> = entries
            .iter()
            .map(|entry| {
                (
                    (
                        entry.utxo.outpoint.transaction_id(),
                        entry.utxo.outpoint.index(),
                    ),
                    entry.amount(),
                )
            })
            .collect();
        assert!(
            first.inputs.iter().all(|input| {
                by_outpoint[&(
                    input.previous_outpoint.transaction_id,
                    input.previous_outpoint.index,
                )] == 50_000_000
            }),
            "the first pass clears the small end"
        );
    }

    /// The ceiling may never RECOMMEND draining a conversation's coins: the
    /// climb's upper bound counts the free coins only. (Mutation fence —
    /// dropping the filter reds this and nothing else.)
    #[test]
    fn the_ceiling_bound_never_counts_the_reserved_tail() {
        let free = addr(DEST);
        let bound = addr(CHANGE);
        let mature = vec![
            UtxoEntryReference::simulated_with_address(400_000_000, &free),
            UtxoEntryReference::simulated_with_address(600_000_000, &bound),
        ];
        assert_eq!(
            free_balance(&mature, std::slice::from_ref(&bound)),
            400_000_000,
            "the reserved coin is not something to point a user at"
        );
        // With nothing reserved the whole balance is fair game — the same
        // short-circuit `select_spend_priority` takes.
        assert_eq!(free_balance(&mature, &[]), 1_000_000_000);
    }

    /// A pile whose every coin is worth less than the fee to move it refuses
    /// typed — and names the reserve, not a mystery. The batch search grows
    /// past a below-fee prefix, so reaching this means no batch of any size
    /// pays for itself.
    #[test]
    fn a_pile_worth_less_than_its_own_fee_refuses_typed() {
        let home = addr(DEST);
        let change = addr(CHANGE);
        let entries: Vec<UtxoEntryReference> = (0..3)
            .map(|_| UtxoEntryReference::simulated_with_address(1_000, &home))
            .collect();
        let mut build = offline_batch_builder(&entries, &home, &change);
        // Nothing was withheld, so the refusal may NOT blame a reserve.
        let err = batched_merge(entries.clone(), &home, 0, &mut build).unwrap_err();
        assert!(
            matches!(&err, ChainError::Message(m) if m.contains("worth less than the network fee")),
            "{err:?}"
        );
        assert!(
            !matches!(&err, ChainError::Message(m) if m.contains("conversations")),
            "an error may not name a cause the code never checked: {err:?}"
        );
        // With coins actually reserved, the reserve IS the honest cause.
        let reserved = batched_merge(entries.clone(), &home, 3, &mut build).unwrap_err();
        assert!(
            matches!(&reserved, ChainError::Message(m) if m.contains("conversations' reserves")),
            "{reserved:?}"
        );
    }

    /// One coin cannot merge with itself: a single-coin batch is a pure fee
    /// burn, so the search never offers one. (Mutation fence — lowering the
    /// batch floor from 2 to 1 reds this.)
    #[test]
    fn a_single_coin_is_never_a_batch() {
        let home = addr(DEST);
        let change = addr(CHANGE);
        let entries = vec![UtxoEntryReference::simulated_with_address(
            5_000_000_000,
            &home,
        )];
        let mut build = offline_batch_builder(&entries, &home, &change);
        assert!(largest_single_tx_batch(&entries, &mut build)
            .unwrap()
            .is_none());
    }

    /// One built shape's facts, read back from the Generator (never computed).
    struct Shape {
        legs: usize,
        inputs: u32,
        fee: u64,
        change: u64,
        consumed: std::collections::HashMap<(kaspa_consensus_core::tx::TransactionId, u32), u64>,
    }

    /// Build `send_kas` from `pool` twice — with riders and without — exactly
    /// as `prepare_send_inner` does, and read both shapes back off the built
    /// transactions.
    fn both_shapes(pool: &[UtxoEntryReference], send_kas: f64) -> (Shape, Shape) {
        let build = |riders: usize| {
            let order = spend_policy::select_spend_priority(pool, &[], riders, &[]);
            let generator = offline_generator_over(pool, order, send_kas, addr(CHANGE));
            let pending = drain(&generator);
            let summary = generator.summary();
            Shape {
                legs: pending.len(),
                inputs: summary.aggregated_utxos() as u32,
                fee: summary.aggregate_fees(),
                change: pending
                    .iter()
                    .find(|pt| pt.is_final())
                    .map_or(0, PendingTransaction::change_value),
                consumed: wallet_coins_consumed(&pending),
            }
        };
        (build(spend_policy::RIDER_LIMIT), build(0))
    }

    /// What the ridden shape absorbs and the cheap one leaves behind — the same
    /// read `prepare_send_inner` does over the two built chains.
    fn extra_absorbed(ridden: &Shape, riderless: &Shape) -> u64 {
        ridden
            .consumed
            .iter()
            .filter(|(outpoint, _)| !riderless.consumed.contains_key(*outpoint))
            .fold(0u64, |acc, (_, value)| acc.saturating_add(*value))
    }

    /// The wallet's own floor over an offline pool, in the send's order — the
    /// same number `minimum_sendable` computes over a live context.
    fn offline_floor(pool: &[UtxoEntryReference]) -> Option<u64> {
        let probe = |amount: u64| -> Result<ProbeOutcome> {
            let order =
                spend_policy::select_spend_priority(pool, &[], spend_policy::RIDER_LIMIT, &[]);
            let payment: PaymentDestination = PaymentOutputs::from((addr(CHANGE), amount)).into();
            let settings = match GeneratorSettings::try_new_with_iterator(
                mainnet(),
                // Owned, not borrowed: the settings box the Generator stores is
                // 'static, so a borrowing iterator cannot cross into it.
                #[allow(clippy::unnecessary_to_owned)]
                Box::new(pool.to_vec().into_iter()),
                Some(order),
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
        search_minimum(
            probe,
            pool.iter().fold(0u64, |a, e| a.saturating_add(e.amount())),
        )
        .unwrap()
    }

    /// **The measurement that refuted the count-threshold rider**, frozen as a
    /// fence. The founder's real wallet on 2026-08-23: 0.481524 + 1.0 + 100.0
    /// KAS, sending 100.90. Both shapes are reproduced to the sompi, and the
    /// rule must KEEP the more expensive ridden one — the cheap shape's change
    /// of 0.09684600 KAS is below this wallet's own floor, so saving 0.0011 KAS
    /// would have manufactured a coin that cannot be sent alone.
    #[test]
    fn the_cheap_shape_loses_when_it_would_leave_a_trap_coin() {
        let pool: Vec<UtxoEntryReference> = [48_152_400u64, 100_000_000, 10_000_000_000]
            .into_iter()
            .map(UtxoEntryReference::simulated)
            .collect();
        let (ridden, riderless) = both_shapes(&pool, 100.90);

        // The measured shapes, to the sompi (a pin bump that moves them reds
        // here — these numbers came off the real Generator, not a model).
        assert_eq!((ridden.legs, ridden.inputs, ridden.fee), (1, 3, 427_200));
        assert_eq!(ridden.change, 57_725_200);
        assert_eq!(
            (riderless.legs, riderless.inputs, riderless.fee),
            (1, 2, 315_400)
        );
        assert_eq!(riderless.change, 9_684_600);
        assert_eq!(ridden.fee - riderless.fee, 111_800, "what the rider cost");

        let floor = offline_floor(&pool).expect("this wallet can send");
        assert!(
            riderless.change < floor,
            "the cheap change {} is below this wallet's floor {floor} — that is \
             the whole point of the measurement",
            riderless.change
        );
        // Two independent reasons the ridden shape survives here, and the test
        // pins BOTH — the trap, and the fact that the riders paid for
        // themselves many times over.
        let extra = extra_absorbed(&ridden, &riderless);
        assert_eq!(extra, 48_152_400, "the trap coin the riders absorb");
        assert!(
            extra > ridden.fee - riderless.fee,
            "the riders are self-financing: {extra} absorbed for {} in fee",
            ridden.fee - riderless.fee
        );
        assert!(
            !riderless_wins(
                ridden.legs,
                riderless.legs,
                ridden.fee,
                riderless.fee,
                riderless.change,
                extra,
                Some(floor)
            ),
            "the ridden shape must survive: the cheap one manufactures a trap"
        );
    }

    /// **The comparison shape is a question, never a gate** — the consensus
    /// audit's BLOCK, frozen. The founder's measured wallet, 0.01 KAS higher
    /// than the fixture above: the riderless order stops one coin earlier and
    /// leaves change small enough that the pin's `calculate_mass`
    /// (generator.rs:970-972) errors BEFORE the storage-mass input-relief block
    /// at :849 can pull another input. The ridden shape builds in one
    /// transaction at the same amount, so the send must ship — a refusal here
    /// would be a wallet that will not send money it can plainly send.
    ///
    /// It fences two things and, said plainly, not a third. It pins the SHAPE
    /// FACT (this cliff is real, at this wallet, at this amount) and it drives
    /// the decision seam [`shipped_shape`] with the `None` the failure
    /// produces, asserting the ridden chain ships and that the floor lookup is
    /// never even reached. What no offline test can reach is
    /// `prepare_send_inner` itself — it needs a live `UtxoContext` — so that
    /// the production call site says `.ok()` and not `?` remains a one-line
    /// read, not a proof.
    #[test]
    fn a_refusing_comparison_shape_never_refuses_the_send() {
        let pool: Vec<UtxoEntryReference> = [48_152_400u64, 100_000_000, 10_000_000_000]
            .into_iter()
            .map(UtxoEntryReference::simulated)
            .collect();
        let build = |riders: usize| {
            let order = spend_policy::select_spend_priority(&pool, &[], riders, &[]);
            let generator = offline_generator_over(&pool, order, 100.91, addr(CHANGE));
            let mut pending = Vec::new();
            loop {
                match generator.generate_transaction() {
                    Ok(Some(tx)) => pending.push(tx),
                    Ok(None) => break,
                    Err(e) => return Err(map_generate_error(e)),
                }
            }
            Ok((pending, generator.summary()))
        };

        // The cheap shape dies of the CHANGE side's storage mass...
        let riderless = build(0);
        assert!(
            matches!(
                riderless,
                Err(ChainError::StorageMassExceeded { .. } | ChainError::Message(_))
            ),
            "the riderless shape must refuse at this amount, got {:?}",
            riderless.map(|(p, s)| (p.len(), s.aggregate_fees()))
        );
        // ...while the ridden shape builds cleanly, in ONE transaction.
        let (ridden, ridden_summary) = build(spend_policy::RIDER_LIMIT)
            .expect("the ridden shape builds — this is the send the wallet ships");
        assert_eq!(ridden.len(), 1);
        assert_eq!(ridden_summary.aggregated_utxos(), 3);
        // And the decision seam ships that chain when the comparison is the
        // `None` a refusal produces — without touching the floor at all.
        let (shipped, shipped_summary) = shipped_shape((ridden, ridden_summary), None, || {
            panic!("a shape that never built must not trigger a floor lookup")
        });
        assert_eq!(shipped.len(), 1, "the send ships the proven chain");
        assert_eq!(shipped_summary.aggregated_utxos(), 3);
    }

    /// The other side of the rule: a speck worth LESS than the fee to pick it
    /// up is left alone, and the user keeps the money. 0.001 KAS beside a 500
    /// KAS coin, sending 100 — the rider is a pure extra input, it costs more
    /// than the speck is worth, and the change it declines to grow is far above
    /// the floor either way.
    #[test]
    fn a_speck_that_costs_more_than_it_is_worth_is_left_alone() {
        let pool: Vec<UtxoEntryReference> = [100_000u64, 50_000_000_000]
            .into_iter()
            .map(UtxoEntryReference::simulated)
            .collect();
        let (ridden, riderless) = both_shapes(&pool, 100.0);

        assert_eq!(ridden.legs, riderless.legs, "same chain length");
        assert!(
            riderless.inputs < ridden.inputs,
            "the rider is a real extra input here: {} vs {}",
            riderless.inputs,
            ridden.inputs
        );
        assert!(riderless.fee < ridden.fee, "and it costs real sompi");

        let extra = extra_absorbed(&ridden, &riderless);
        assert_eq!(extra, 100_000, "the speck the rider would have absorbed");
        assert!(
            extra <= ridden.fee - riderless.fee,
            "and it is worth less than the {} sompi it costs to collect",
            ridden.fee - riderless.fee
        );

        let floor = offline_floor(&pool).expect("this wallet can send");
        assert!(
            riderless.change >= floor,
            "the change {} clears the floor {floor}",
            riderless.change
        );
        assert!(riderless_wins(
            ridden.legs,
            riderless.legs,
            ridden.fee,
            riderless.fee,
            riderless.change,
            extra,
            Some(floor)
        ));
    }

    /// **The counterfactual that justifies the self-financing clause**, frozen
    /// so the claim in [`riderless_wins`]'s doc is checkable rather than
    /// asserted. Run the canonical 22-coin fragmented wallet through the
    /// two-clause rule the backlog proposed (leg law + change shape, with no
    /// value bar): it drops the riders, because a fat wallet's riderless change
    /// is always healthy. That is D-165's hygiene half repealed in exactly the
    /// wallet the rider exists for.
    #[test]
    fn without_the_value_bar_the_fragmented_wallet_stops_draining() {
        let pool: Vec<UtxoEntryReference> = fragmented_fixture()
            .iter()
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
            .collect();
        let (ridden, riderless) = both_shapes(&pool, 1.0);
        let floor = offline_floor(&pool).expect("this wallet can send");

        // The two-clause rule: exactly the shipped one with the value bar
        // neutralised (nothing to absorb ⇒ nothing to weigh).
        assert!(
            riderless_wins(
                ridden.legs,
                riderless.legs,
                ridden.fee,
                riderless.fee,
                riderless.change,
                0,
                Some(floor)
            ),
            "the two-clause rule drops the riders here — the measurement"
        );
        // The shipped rule keeps them, because what they pick up is worth far
        // more than the pickup.
        let extra = extra_absorbed(&ridden, &riderless);
        assert!(
            extra > ridden.fee - riderless.fee,
            "{extra} absorbed for {} in fee",
            ridden.fee - riderless.fee
        );
        assert!(!riderless_wins(
            ridden.legs,
            riderless.legs,
            ridden.fee,
            riderless.fee,
            riderless.change,
            extra,
            Some(floor)
        ));
    }

    /// A fragment worth many times its pickup rides even though the cheap shape
    /// is cheaper AND leaves healthy change — the self-financing clause, which
    /// is the whole of D-165's hygiene half. (Mutation fence — deleting the
    /// `extra_absorbed <= saving` clause from `riderless_is_candidate` reds
    /// this and the fragmented-wallet drain test, and nothing else.)
    #[test]
    fn a_fragment_worth_more_than_its_pickup_still_rides() {
        let pool: Vec<UtxoEntryReference> = [50_000_000u64, 50_000_000_000]
            .into_iter()
            .map(UtxoEntryReference::simulated)
            .collect();
        let (ridden, riderless) = both_shapes(&pool, 100.0);
        let extra = extra_absorbed(&ridden, &riderless);
        assert_eq!(extra, 50_000_000, "half a KAS, absorbed by the rider");
        assert!(riderless.fee < ridden.fee, "the cheap shape IS cheaper");
        let floor = offline_floor(&pool).expect("this wallet can send");
        assert!(
            riderless.change >= floor,
            "and its change IS healthy — only the value bar stops it"
        );
        assert!(!riderless_wins(
            ridden.legs,
            riderless.legs,
            ridden.fee,
            riderless.fee,
            riderless.change,
            extra,
            Some(floor)
        ));
    }

    /// The leg law (D-165) still outranks everything: a shorter riderless chain
    /// wins whatever its change looks like, because an extra transaction costs
    /// a whole extra fee that no fragment absorption repays.
    #[test]
    fn a_shorter_chain_wins_regardless_of_the_change_it_leaves() {
        // Cheaper is false (the shorter chain costs MORE in aggregate) and the
        // change is a trap and the floor is unknown — every other clause says
        // no, and the leg law still says yes.
        assert!(riderless_wins(2, 1, 10_000, 90_000, 1, u64::MAX, None));
    }

    /// The change-shape clause ISOLATED — the one case where it alone decides.
    /// The riders are not self-financing (a 0.0005 KAS speck for 0.001 KAS of
    /// fee), so the value bar says drop them; the cheap shape's change would be
    /// below the floor, so the change clause overrules and they ride.
    /// (Mutation fence — deleting the change clause reds this and nothing
    /// else; the measured founder wallet does NOT isolate it, because there the
    /// value bar already keeps the riders.)
    #[test]
    fn a_worthless_rider_still_rides_when_dropping_it_would_leave_a_trap() {
        // saving 100_000; speck 50_000 (bar passes); change 0.05 KAS under a
        // 0.10 KAS floor.
        assert!(!riderless_wins(
            1,
            1,
            200_000,
            100_000,
            5_000_000,
            50_000,
            Some(10_000_000)
        ));
        // Same shape, healthy change: now the speck really is not worth
        // collecting and the user keeps the fee.
        assert!(riderless_wins(
            1,
            1,
            200_000,
            100_000,
            50_000_000,
            50_000,
            Some(10_000_000)
        ));
    }

    /// An unknown floor fails CLOSED onto the ridden shape: we decline to save
    /// a fee we cannot prove is safe to save. (Mutation fence — turning the
    /// `is_some_and` into an `is_none_or` reds this and nothing else.)
    #[test]
    fn an_unknown_floor_keeps_the_riders() {
        assert!(!riderless_wins(1, 1, 427_200, 315_400, 9_684_600, 0, None));
    }

    /// Change absorbed into the fee leaves no coin to strand, so the cheap
    /// shape wins without a floor lookup at all.
    #[test]
    fn a_shape_that_leaves_no_change_needs_no_floor() {
        assert!(riderless_wins(1, 1, 427_200, 315_400, 0, 0, None));
    }

    /// A tie is not a saving: equal fees keep the riders, which is what makes
    /// the rider free-when-the-Generator-needed-it-anyway case still absorb
    /// fragments. (Mutation fence — relaxing `<` to `<=` reds this.)
    #[test]
    fn an_equal_fee_keeps_the_riders() {
        assert!(!riderless_wins(
            1,
            1,
            427_200,
            427_200,
            50_000_000_000,
            0,
            Some(10_000_000)
        ));
    }

    #[test]
    fn riders_strictly_drain_a_fragmented_wallet() {
        let change = addr(CHANGE);
        let mut entries: Vec<UtxoEntryReference> = fragmented_fixture()
            .iter()
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
            .collect();

        for round in 0..8 {
            let before = entries.len();
            // The shape the wallet would actually SHIP, not just the ridden
            // order: since the change-shape law, a cheaper riderless shape can
            // win. Modelling only the ridden order would assert a drain
            // property the send path no longer promises.
            let riders = shipped_riders(&entries, 1.0);
            let order = crate::spend_policy::select_spend_priority(&entries, &[], riders, &[]);
            let generator = offline_generator_over(&entries, order, 1.0, change.clone());
            let pending = drain(&generator);
            assert_eq!(pending.len(), 1, "round {round}: riders never add a leg");
            let tx = pending[0].transaction();

            // Advance the simulated wallet: consumed inputs leave, the change
            // output returns (the payment output goes to DEST and is gone).
            let consumed: std::collections::HashSet<_> = tx
                .inputs
                .iter()
                .map(|input| input.previous_outpoint.transaction_id)
                .collect();
            entries.retain(|entry| !consumed.contains(&entry.transaction_id()));
            let change_value = tx
                .outputs
                .iter()
                .find(|output| {
                    extract_script_pub_key_address(&output.script_public_key, change.prefix)
                        .is_ok_and(|decoded| decoded == change)
                })
                .map(|output| output.value)
                .expect("an ordinary 1 KAS send from this wallet returns change");
            entries.push(UtxoEntryReference::simulated(change_value));

            assert!(
                entries.len() < before,
                "round {round}: UTXO count must strictly decrease ({before} -> {})",
                entries.len()
            );
        }

        // Six sends carry twelve riders: every 0.5 KAS fragment is gone (the
        // riders drain from the bottom).
        assert!(
            !entries
                .iter()
                .any(|entry| entry.amount() == kaspa_to_sompi(0.5)),
            "all twelve 0.5 KAS fragments must be absorbed within eight sends"
        );
        // Two regimes, both draining: while 0.5 KAS fragments last (rounds
        // 1-6) a send is 2 riders + 1 fat coin, net -2; once the smallest
        // coins are 2 KAS, the two riders alone cover a 1 KAS send, the
        // Generator stops at 2 inputs, and the net is -1. 22 - 6*2 - 2*1 = 8.
        assert_eq!(entries.len(), 8, "six -2 rounds, then two -1 rounds");
    }

    /// THE PIN COMPOSES WITH THE POLICY (D-067, the L47 scar): the pinned
    /// entry stays order[0] and lands at input[0] of the built transaction,
    /// with the riders and largest-first pool drawn behind it for the
    /// shortfall. The pin is deliberately MID-SIZED — bigger than the
    /// fragments, smaller than the pool's coins — so a policy that dropped it
    /// into the pool would bury it behind both the riders AND the larger
    /// coins (verified red under exactly that mutation; a smallest-coin pin
    /// would pass by accident through the rider slot). No test before this
    /// one would have caught a policy that silently overwrote the pin.
    #[test]
    fn pinned_entry_survives_the_policy_at_input_zero() {
        let bound = addr(CHANGE);
        let pin = UtxoEntryReference::simulated_with_address(kaspa_to_sompi(1.5), &bound);
        let pin_txid = pin.transaction_id();

        // The pinned entry lives in the mature set too (production always
        // does: mature_utxos_at reads the same context) — the policy must
        // de-duplicate it, not spend it twice.
        let mut mature: Vec<UtxoEntryReference> = fragmented_fixture()
            .iter()
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
            .collect();
        mature.push(pin.clone());

        let order = crate::spend_policy::select_spend_priority(
            &mature,
            std::slice::from_ref(&pin),
            RIDER_LIMIT,
            &[],
        );
        assert_eq!(
            order[0].transaction_id(),
            pin_txid,
            "the pin leads the order"
        );
        assert_eq!(order.len(), mature.len(), "the pin is not duplicated");

        // 1.5 KAS cannot cover a 5 KAS send: riders + pool are drawn behind
        // the pin, and the pin is STILL input[0].
        let generator = offline_generator_over(&mature, order.clone(), 5.0, bound);
        let pending = drain(&generator);
        let tx = pending
            .iter()
            .find(|pt| pt.is_final())
            .unwrap()
            .transaction();
        assert!(tx.inputs.len() >= 2, "the pool is drawn for the shortfall");
        assert_eq!(
            tx.inputs[0].previous_outpoint.transaction_id, pin_txid,
            "input[0] is the pinned entry even under the largest-first policy"
        );
        for (i, input) in tx.inputs.iter().enumerate() {
            assert_eq!(
                input.previous_outpoint.transaction_id,
                order[i].transaction_id(),
                "inputs follow the policy order exactly"
            );
        }
    }

    /// Offline analog of `prepare_drain`: same plan, same Generator modes,
    /// same `finish_drain` tail — the pool iterator plays the live context
    /// (INCLUDING excluded coins, exactly as production's context iterator
    /// would offer them).
    fn run_drain_offline(
        entries: &[UtxoEntryReference],
        exclude: &[Address],
        destination: &Address,
        change_home: &Address,
        is_exit: bool,
    ) -> Result<(Vec<Pt>, SendSummary)> {
        let (included, _, covenant_count) = drain_included(entries.to_vec(), exclude);
        // Mirrors production: covenant withholding arms the priority arm and
        // the verify input-set check exactly like an exclusion list (D-211).
        let has_withheld = !exclude.is_empty() || covenant_count > 0;
        let included_for_verify = has_withheld.then(|| included.clone());
        let arm = plan_drain(included, has_withheld)?;
        let chained_drain_allowed = !is_exit && matches!(arm, DrainArm::Drain);
        let (order, payment, fees): (Vec<UtxoEntryReference>, PaymentDestination, Fees) = match arm
        {
            DrainArm::ReceiverPays {
                amount_sompi,
                priority,
            } => {
                // Same guard as production: below the shape's own fee the
                // pin's finalizer would underflow (generator.rs:1071).
                let fee_floor = receiver_pays_fee_floor(mainnet(), &priority, destination)?;
                if amount_sompi <= fee_floor {
                    return Err(ChainError::Message(
                        "these coins are worth less than the network fee to move them".into(),
                    ));
                }
                (
                    priority,
                    PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
                    Fees::ReceiverPays(0),
                )
            }
            DrainArm::Drain => (Vec::new(), PaymentDestination::Change, Fees::None),
        };
        let change = match (&payment, &fees) {
            (PaymentDestination::Change, _) => destination.clone(),
            _ => change_home.clone(),
        };
        let settings = GeneratorSettings::try_new_with_iterator(
            mainnet(),
            #[allow(clippy::unnecessary_to_owned)]
            Box::new(entries.to_vec().into_iter()),
            (!order.is_empty()).then_some(order),
            change,
            1,
            1,
            payment,
            None,
            fees,
            None,
            None,
        )?;
        let generator = Generator::try_new(settings, None, None)?;
        let mut pending = Vec::new();
        loop {
            match generator.generate_transaction() {
                Ok(Some(tx)) => pending.push(tx),
                Ok(None) => break,
                Err(e) => return Err(map_generate_error(e)),
            }
        }
        let summary = finish_drain(
            &pending,
            &generator.summary(),
            destination,
            included_for_verify.as_deref(),
            chained_drain_allowed,
            is_exit,
        )?;
        Ok((pending, summary))
    }

    /// The discharge predicate, all four combinations. Each `false` row is a
    /// regression this rule prevents: dropping `is_exit` zeroes the `outgoing`
    /// bucket the "still settling" classifier reads (consensus finding 7), and
    /// widening past `ReceiverPays` discharges an arm whose accounting the pin
    /// already gets exactly right.
    #[test]
    fn only_a_receiver_pays_exit_discharges_its_outgoing_record() {
        let rp = DrainArm::ReceiverPays {
            amount_sompi: 48_152_400,
            priority: vec![UtxoEntryReference::simulated(48_152_400)],
        };
        assert!(
            discharges_outgoing(&rp, true),
            "a sweep: nothing comes home"
        );
        assert!(
            !discharges_outgoing(&rp, false),
            "a ReceiverPays MERGE self-heals when its coin returns to receive/0"
        );
        assert!(
            !discharges_outgoing(&DrainArm::Drain, true),
            "the Change arm's balance adjustment already nets to zero"
        );
        assert!(!discharges_outgoing(&DrainArm::Drain, false));
    }

    /// The residue the 2026-08-23 device sitting measured, pinned as an
    /// arithmetic signature on the BUILT transaction — the closest an offline
    /// fence can get, because the pin's `register_outgoing_transaction` is
    /// `pub(crate)` and only `try_submit` (which broadcasts) can reach it.
    ///
    /// `UtxoContext::calculate_balance` (context.rs:506-547) charges an
    /// unaccepted outgoing tx as `fees + payment_value` against a credit of
    /// `aggregate_input_value`. So `fees + payment_value > aggregate_input_value`
    /// IS the double-count, readable straight off the transaction, and the
    /// excess is exactly one fee. `PreparedSend::commit` discharges the record
    /// for the exit drain because of it. The `Change` arm must show the
    /// opposite: no payment value at all, hence the compound branch, which nets
    /// to zero and is deliberately left alone.
    ///
    /// Mutation check: the day a pin bump makes `ReceiverPays` report the
    /// post-deduction value as `payment_value`, the first assert flips and the
    /// discharge becomes wrong — which is precisely when we need to be told.
    #[test]
    fn the_receiver_pays_arm_carries_the_pins_fee_double_count() {
        // A one-coin wallet: the founder's measured trap, which only the
        // `ReceiverPays` arm can empty.
        let entries = vec![UtxoEntryReference::simulated(48_152_400)];
        let (pending, _) =
            run_drain_offline(&entries, &[], &addr(DEST), &addr(CHANGE), true).unwrap();
        let pt = pending.iter().find(|pt| pt.is_final()).unwrap();

        let payment = pt
            .payment_value()
            .expect("the ReceiverPays arm builds a PAYMENT, so it has a payment value");
        assert_eq!(
            payment, 48_152_400,
            "payment_value stays the REQUESTED full balance — the pin fixes it \
             before deducting the fee (generator.rs:432 vs :1067-1073)"
        );
        assert!(
            pt.aggregate_output_value() < payment,
            "the fee came OUT of the payment: built output {} vs requested {}",
            pt.aggregate_output_value(),
            payment
        );
        assert_eq!(
            pt.fees() + payment - pt.aggregate_input_value(),
            pt.fees(),
            "the balance adjustment overstates the outflow by exactly one fee"
        );

        // The Change arm: no payment value, so the compound branch applies and
        // `fees + outputs == inputs` exactly. Nothing to discharge.
        let merge_entries = vec![
            UtxoEntryReference::simulated(100_000_000),
            UtxoEntryReference::simulated(100_000_000),
        ];
        let (merge_pending, _) =
            run_drain_offline(&merge_entries, &[], &addr(CHANGE), &addr(CHANGE), false).unwrap();
        let mpt = merge_pending.iter().find(|pt| pt.is_final()).unwrap();
        assert!(
            mpt.payment_value().is_none(),
            "a Change-destination drain has no payment value (generator.rs:376-380)"
        );
        assert_eq!(
            mpt.fees() + mpt.aggregate_output_value(),
            mpt.aggregate_input_value(),
            "the compound branch nets to zero — the Change arm needs no discharge"
        );
    }

    /// THE EXIT, part 1 — the founder's trap, reproduced then freed. Measured
    /// 2026-08-22 on the dev wallet: ONE mature coin of 0.48152400 KAS and
    /// every send refused. Reproduced here at the pin: ordinary sends build
    /// only in a window near [0.107, 0.373] KAS — the top of the range dies
    /// of the change output's storage mass — so the wallet can never be
    /// EMPTIED by any amount a user could type. The sweep's ReceiverPays arm
    /// frees it in one 1-in-1-out transaction whose output + fee equal the
    /// balance to the sompi: the wallet ends at exactly zero.
    #[test]
    fn sweep_frees_the_one_coin_trap() {
        let balance = 48_152_400u64; // 0.481524 KAS
        let coin = [0.481524f64];
        let probe = |amount: u64| -> Result<ProbeOutcome> {
            let entries: Vec<UtxoEntryReference> = coin
                .iter()
                .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
                .collect();
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
        // The trap, pinned: a floor exists (the app honestly advertised one)…
        assert_eq!(
            search_minimum(probe, kaspa_to_sompi(0.481524)).unwrap(),
            Some(10_687_500)
        );
        // …but nothing near the balance builds: the wallet cannot be emptied
        // by an ordinary send at ANY amount.
        assert_eq!(probe(40_000_000).unwrap(), ProbeOutcome::TooSmall);
        assert_eq!(probe(48_000_000).unwrap(), ProbeOutcome::TooSmall);
        assert_eq!(probe(balance).unwrap(), ProbeOutcome::TooLarge);

        // The sweep frees it: one transaction, one input, one output.
        let entries = vec![UtxoEntryReference::simulated(kaspa_to_sompi(0.481524))];
        let (pending, summary) =
            run_drain_offline(&entries, &[], &addr(DEST), &addr(CHANGE), true).unwrap();
        assert_eq!(pending.len(), 1);
        let tx = pending[0].transaction();
        assert_eq!((tx.inputs.len(), tx.outputs.len()), (1, 1));
        assert_eq!(
            (summary.amount_sompi, summary.fee_sompi),
            (47_948_800, 203_600),
            "swept value and fee, sompi-exact at the pin"
        );
        assert_eq!(
            summary.amount_sompi + summary.fee_sompi,
            balance,
            "the wallet ends at exactly zero"
        );
        assert_eq!((summary.tx_count, summary.utxo_count), (1, 1));
    }

    /// THE EXIT, part 2 — the deeper trap the session prompt names as the
    /// acceptance fixture: a wallet whose `minimum_sendable` is `None` (NO
    /// ordinary amount builds at all) still sweeps to exactly zero.
    #[test]
    fn sweep_frees_the_wallet_that_cannot_send_at_all() {
        let coin = [0.15f64];
        let probe = |amount: u64| -> Result<ProbeOutcome> {
            let entries: Vec<UtxoEntryReference> = coin
                .iter()
                .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
                .collect();
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
        assert_eq!(
            search_minimum(probe, kaspa_to_sompi(0.15)).unwrap(),
            None,
            "the fixture state: no amount is sendable at all — and the F3 rescue \
             agrees: nothing straddling half of a 0.15 KAS coin builds either"
        );
        let entries = vec![UtxoEntryReference::simulated(kaspa_to_sompi(0.15))];
        let (_, summary) =
            run_drain_offline(&entries, &[], &addr(DEST), &addr(CHANGE), true).unwrap();
        assert_eq!(
            summary.amount_sompi + summary.fee_sompi,
            15_000_000,
            "swept + fee == balance: exactly zero remains"
        );
        assert_eq!(summary.fee_sompi, 203_600);
    }

    /// THE EXIT, part 3 — a multi-coin, multi-address wallet drains through
    /// the Generator's native sweep: every watched coin is consumed in ONE
    /// transaction and the arithmetic balances to the sompi.
    #[test]
    fn sweep_drains_every_watched_coin_in_one_tx() {
        let elsewhere = addr(CHANGE);
        let mut entries: Vec<UtxoEntryReference> = fragmented_fixture()
            .iter()
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
            .collect();
        // Three of the coins live at a DIFFERENT watched address — the sweep
        // must not care where a coin lives (the receive/0-stranding exit gap).
        for value in [0.7, 0.9, 1.1] {
            entries.push(UtxoEntryReference::simulated_with_address(
                kaspa_to_sompi(value),
                &elsewhere,
            ));
        }
        let total: u64 = entries.iter().map(|entry| entry.amount()).sum();
        let (pending, summary) =
            run_drain_offline(&entries, &[], &addr(DEST), &addr(CHANGE), true).unwrap();
        assert_eq!(pending.len(), 1, "25 coins fit one transaction");
        assert_eq!(summary.utxo_count, 25, "every coin, every address");
        assert_eq!(
            summary.amount_sompi + summary.fee_sompi,
            total,
            "swept + fee == the whole balance"
        );
    }

    /// An EXIT must be one transaction: a wallet too fragmented to sweep in
    /// one is refused TOWARD consolidation (the native sweep's intermediate
    /// legs pay the sweep target — unsignable by us when it is external).
    #[test]
    fn sweep_refuses_to_chain_and_names_the_way_out() {
        let entries: Vec<UtxoEntryReference> = std::iter::repeat_n(1.0, 400)
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(v)))
            .collect();
        let err = run_drain_offline(&entries, &[], &addr(DEST), &addr(CHANGE), true).unwrap_err();
        assert!(
            err.to_string().contains("merge your coins first"),
            "the refusal names the way out: {err}"
        );
    }

    /// CONSOLIDATION respects the exclusion line: conversation-bound coins
    /// are not offered, not drawn, and still in the wallet afterwards — and
    /// `verify_drain` enforces that on the BUILT transaction, red-proven by
    /// handing it a chain that DID consume an excluded coin.
    #[test]
    fn consolidation_respects_the_exclusion_line() {
        let home = addr(DEST); // receive/0 stand-in: destination AND change
        let bound = addr(CHANGE); // a conversation's bound address
        let mut entries: Vec<UtxoEntryReference> = [5.0, 0.5, 12.0, 0.5, 2.0]
            .iter()
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
            .collect();
        let conversation_coins: Vec<UtxoEntryReference> = [0.3, 0.4]
            .iter()
            .map(|v| UtxoEntryReference::simulated_with_address(kaspa_to_sompi(*v), &bound))
            .collect();
        entries.extend(conversation_coins.iter().cloned());
        let included_total: u64 = kaspa_to_sompi(5.0 + 0.5 + 12.0 + 0.5 + 2.0);

        let (pending, summary) =
            run_drain_offline(&entries, std::slice::from_ref(&bound), &home, &home, false).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(summary.utxo_count, 5, "absorbs exactly the offered coins");
        assert_eq!(
            summary.amount_sompi + summary.fee_sompi,
            included_total,
            "the conversation's 0.7 KAS is untouched"
        );
        let tx = pending[0].transaction();
        let consumed: std::collections::HashSet<_> = tx
            .inputs
            .iter()
            .map(|input| input.previous_outpoint.transaction_id)
            .collect();
        for coin in &conversation_coins {
            assert!(
                !consumed.contains(&coin.transaction_id()),
                "a bound coin must never ride out inside a consolidation"
            );
        }

        // The custody line, red-proven: a chain that consumed MORE than the
        // offered set must be refused by verify_drain itself.
        let offered: Vec<UtxoEntryReference> = entries
            .iter()
            .filter(|entry| entry.utxo.address.is_none())
            .take(3)
            .cloned()
            .collect();
        let settings = GeneratorSettings::try_new_with_iterator(
            mainnet(),
            Box::new(entries.clone().into_iter()),
            None,
            home.clone(),
            1,
            1,
            PaymentDestination::Change,
            None,
            Fees::None,
            None,
            None,
        )
        .unwrap();
        let generator = Generator::try_new(settings, None, None).unwrap();
        let all_pending = drain(&generator);
        let err = verify_drain(&all_pending, &generator.summary(), &home, Some(&offered));
        assert!(
            err.is_err()
                && err
                    .unwrap_err()
                    .to_string()
                    .contains("outside its offered set"),
            "verify_drain must refuse a chain that drew past the offered coins"
        );
    }

    /// The fail-closed corner of the exclusion filter: under an exclusion
    /// list, a coin with NO address on record is counted EXCLUDED — it cannot
    /// be matched against the list, so offering it would bypass the one
    /// custody check `verify_drain` enforces. (With no exclusions — a sweep —
    /// everything is offered.)
    #[test]
    fn an_addressless_coin_is_never_offered_under_exclusions() {
        let home = addr(DEST);
        let bound = addr(CHANGE);
        let with_addr: Vec<UtxoEntryReference> = [4.0, 6.0]
            .iter()
            .map(|v| UtxoEntryReference::simulated_with_address(kaspa_to_sompi(*v), &home))
            .collect();
        // `simulated` (no _with_address) still carries a random address at the
        // pin — build a genuinely address-less entry by clearing the field...
        // which the pin does not expose. So prove the rule at the filter
        // itself, over the pin's own Option: an entry whose address is None.
        let mut mystery = UtxoEntryReference::simulated(kaspa_to_sompi(9.0));
        {
            let utxo = std::sync::Arc::get_mut(&mut mystery.utxo)
                .expect("freshly built simulated entry has one owner");
            utxo.address = None;
        }
        let mut entries = with_addr.clone();
        entries.push(mystery.clone());

        // Under exclusions: the address-less coin is excluded (fails closed).
        let (included, excluded_count, _) =
            drain_included(entries.clone(), std::slice::from_ref(&bound));
        assert_eq!(included.len(), 2);
        assert_eq!(excluded_count, 1, "the None-address coin counts excluded");
        assert!(
            !included
                .iter()
                .any(|entry| entry.transaction_id() == mystery.transaction_id()),
            "a coin that cannot be matched to the exclusion list is not offered"
        );

        // With no exclusions (a sweep): everything spendable is offered.
        let (included, excluded_count, covenant_count) = drain_included(entries, &[]);
        assert_eq!((included.len(), excluded_count, covenant_count), (3, 0, 0));
    }

    /// A big consolidation to SELF chains through the Generator's canonical
    /// compound: every leg pays our own address, the whole pile lands as one
    /// coin, and the aggregate arithmetic still balances to the sompi.
    #[test]
    fn consolidation_chains_the_canonical_compound() {
        let home = addr(DEST);
        let entries: Vec<UtxoEntryReference> = std::iter::repeat_n(1.0, 400)
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(v)))
            .collect();
        let total: u64 = entries.iter().map(|entry| entry.amount()).sum();
        let (pending, summary) = run_drain_offline(&entries, &[], &home, &home, false).unwrap();
        assert!(pending.len() > 1, "400 coins must chain");
        assert_eq!(
            summary.utxo_count, 400,
            "absorbed counts wallet coins, not chain-internal edges"
        );
        assert_eq!(summary.tx_count as usize, pending.len());
        assert_eq!(
            summary.amount_sompi + summary.fee_sompi,
            total,
            "swept + aggregate fees == the whole pile"
        );
    }

    /// The ReceiverPays underflow guard, at its exact boundary (the pin's
    /// 1-in-1-out fee for this shape is 203,600 sompi — read from the
    /// Generator by `receiver_pays_fee_floor`, asserted here at fee−1 / fee /
    /// fee+1). Below or at the fee: refused typed BEFORE generation reaches
    /// the pin's unchecked `output.value -= transaction_fees`
    /// (generator.rs:1071 — a debug-build overflow panic; this test passing
    /// at all proves no panic fires). Just above: the 1-sompi output dies of
    /// KIP-9 storage — still typed, still no panic.
    #[test]
    fn a_below_fee_coin_refuses_at_the_exact_boundary() {
        let fee = 203_600u64;
        for (value, expect_worthless) in [(fee - 1, true), (fee, true), (fee + 1, false)] {
            let entries = vec![UtxoEntryReference::simulated(value)];
            let err =
                run_drain_offline(&entries, &[], &addr(DEST), &addr(CHANGE), true).unwrap_err();
            if expect_worthless {
                assert!(
                    err.to_string().contains("worth less than the network fee"),
                    "value {value}: expected the fee-floor refusal, got {err}"
                );
            } else {
                // One sompi of output: the guard lets it through and the
                // Generator's own mass check refuses it — TYPED (reaching
                // this assert at all proves no overflow panic fired; debug
                // builds carry overflow checks). It must not be the
                // fee-floor sentence: the guard's job ended at the fee.
                assert!(
                    !err.to_string().contains("worth less than the network fee"),
                    "value {value}: the guard must stop AT the fee, got {err}"
                );
            }
        }
    }

    /// The same guard on the multi-coin ReceiverPays arm (a consolidation
    /// forced onto it by exclusions, over coins beneath the fee).
    #[test]
    fn a_below_fee_exclusion_merge_refuses_typed() {
        let home = addr(DEST);
        let bound = addr(CHANGE);
        let mut entries: Vec<UtxoEntryReference> = std::iter::repeat_n(3_000u64, 10)
            .map(UtxoEntryReference::simulated)
            .collect();
        entries.push(UtxoEntryReference::simulated_with_address(
            kaspa_to_sompi(1.0),
            &bound,
        ));
        let err = run_drain_offline(&entries, std::slice::from_ref(&bound), &home, &home, false)
            .unwrap_err();
        assert!(
            err.to_string().contains("worth less than the network fee"),
            "expected the fee-floor refusal, got {err}"
        );
    }

    /// Coins collectively worth less than the fee to move them are refused
    /// typed — the network's own economics, said honestly, never a panic and
    /// never a transaction that pays more than it moves.
    #[test]
    fn draining_dust_beneath_the_fee_refuses_typed() {
        let entries: Vec<UtxoEntryReference> = std::iter::repeat_n(0.0001, 10)
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(v)))
            .collect();
        let err = run_drain_offline(&entries, &[], &addr(DEST), &addr(CHANGE), true).unwrap_err();
        assert!(
            matches!(
                err,
                ChainError::InsufficientFunds { .. } | ChainError::Message(_)
            ),
            "a dust pile beneath the fee refuses typed, got: {err}"
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
        let min = search_minimum(synthetic(floor, 5_000_000_000), 5_000_000_000)
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
        let min = search_minimum(synthetic(5_000_000, 8_000_000), 8_000_000)
            .unwrap()
            .unwrap();
        assert!(
            (5_000_000..=5_200_000).contains(&min),
            "min {min} in window"
        );
    }

    /// The ceiling's mirror of the floor test: every value the climb returns
    /// must be one the probe accepts. (Mutation fence — moving `lo = mid` onto
    /// the refusal arm reds this and nothing else.)
    #[test]
    fn the_climb_only_ever_returns_a_value_it_proved() {
        // Floor 0.05 KAS, ceiling 4.00 KAS, balance 5.00 KAS: the shape a real
        // wallet has (payment dust below, change dust above).
        let floor = 5_000_000;
        let ceiling = 400_000_000;
        let mut probe = move |v: u64| {
            Ok(if v < floor {
                ProbeOutcome::TooSmall
            } else if v <= ceiling {
                ProbeOutcome::Builds
            } else if v <= 500_000_000 {
                ProbeOutcome::TooSmall // the CHANGE is the dust up here
            } else {
                ProbeOutcome::TooLarge
            })
        };
        let max = search_maximum(&mut probe, floor, 500_000_000)
            .unwrap()
            .expect("the anchor builds, so a maximum exists");
        assert_eq!(
            probe(max).unwrap(),
            ProbeOutcome::Builds,
            "the reported maximum {max} must itself build"
        );
        assert!(max <= ceiling, "never above the real ceiling: {max}");
        assert!(
            ceiling - max <= PROBE_PRECISION_SOMPI,
            "within display precision of the real ceiling: {max}"
        );
    }

    /// An anchor that does not build is refused outright rather than returned.
    /// `search_minimum` can close on a `TooLarge` bound it never saw build, so
    /// the climb must not inherit that as a promise.
    #[test]
    fn an_unproven_anchor_yields_no_ceiling_at_all() {
        let probe = |_: u64| Ok(ProbeOutcome::TooLarge);
        assert_eq!(search_maximum(probe, 1_000_000, 5_000_000).unwrap(), None);
    }

    /// A wallet with no room above its floor reports NO ceiling — not the
    /// floor wearing the word "largest".
    ///
    /// The floor does build, so answering with it would be true; it would also
    /// be a superlative asserted over a space the climb never entered. Both
    /// edges are fenced: the bound equal to the anchor, and the bound BELOW it
    /// (which is reachable, because the climb's bound counts the free coins
    /// only while the anchor was probed over the whole order). (Mutation fence
    /// — deleting the `balance <= anchor` guard reds this and nothing else.)
    #[test]
    fn no_room_to_climb_means_no_ceiling_is_claimed() {
        assert_eq!(
            search_maximum(synthetic(5_000_000, 5_000_000), 5_000_000, 5_000_000).unwrap(),
            None,
            "the bound equals the anchor: nothing above it was searched"
        );
        assert_eq!(
            search_maximum(synthetic(5_000_000, 9_000_000), 5_000_000, 3_000_000).unwrap(),
            None,
            "the free coins do not even reach the floor"
        );
    }

    /// The reserved-draw trace must be silent on the healthy pinned path and
    /// loud on the harm it exists to report.
    ///
    /// A transport send PINS its conversation's own bound address (input[0]
    /// identity, D-067) — which `is_reserved` matches, and which is always
    /// consumed. Counting it would make every message from an off-identity
    /// conversation report a raided reserve, the opposite of the fact. (Mutation
    /// fence — dropping the `!own.contains` filter reds the first half and
    /// nothing else.)
    #[test]
    fn the_reserved_trace_ignores_a_send_s_own_pinned_binding() {
        let bound = addr(CHANGE);
        let other = addr(DEST);
        let mine = UtxoEntryReference::simulated_with_address(5_000_000_000, &bound);
        let neighbour = UtxoEntryReference::simulated_with_address(2_000_000_000, &other);
        let mature = vec![mine.clone(), neighbour.clone()];
        let exclude = [bound.clone(), other.clone()];
        let key = |entry: &UtxoEntryReference| {
            (
                entry.utxo.outpoint.transaction_id(),
                entry.utxo.outpoint.index(),
            )
        };

        // A pinned send that spends only its own binding: nothing to report.
        let consumed = std::collections::HashMap::from([(key(&mine), mine.amount())]);
        assert_eq!(
            reserved_coins_drawn(&mature, std::slice::from_ref(&mine), &consumed, &exclude),
            0
        );
        // The same send reaching into a NEIGHBOUR's reserve: reported.
        let consumed = std::collections::HashMap::from([
            (key(&mine), mine.amount()),
            (key(&neighbour), neighbour.amount()),
        ]);
        assert_eq!(
            reserved_coins_drawn(&mature, std::slice::from_ref(&mine), &consumed, &exclude),
            1
        );
        // A plain payment (nothing pinned) that draws a reserved coin: reported.
        assert_eq!(reserved_coins_drawn(&mature, &[], &consumed, &exclude), 2);
    }

    /// The founder's measured dead zone, priced by the REAL Generator: one
    /// 0.57725200 KAS coin, floor 0.10437500 on glass, 0.40 builds, 0.50
    /// refuses (device, 2026-08-23). The reported ceiling must land inside
    /// that measured window — and must itself build.
    #[test]
    fn the_measured_dead_zone_gets_a_real_ceiling() {
        let probe = |amount: u64| -> Result<ProbeOutcome> {
            let entries = vec![UtxoEntryReference::simulated(57_725_200)];
            let payment: PaymentDestination = PaymentOutputs::from((addr(CHANGE), amount)).into();
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
        let min = search_minimum(probe, 57_725_200)
            .unwrap()
            .expect("the measured coin can send something");
        let max = search_maximum(probe, min, 57_725_200)
            .unwrap()
            .expect("and it has a proven ceiling");
        assert_eq!(
            probe(max).unwrap(),
            ProbeOutcome::Builds,
            "the ceiling {max} must build — an unproven bound is worse than none"
        );
        assert!(
            max >= 40_000_000,
            "0.40 KAS built on glass, so the ceiling is at least that: {max}"
        );
        assert!(
            max < 50_000_000,
            "0.50 KAS refused on glass, so the ceiling is below it: {max}"
        );
        assert!(max > min, "the window has room: {min}..{max}");
        // The offline fixture reproduces the DEVICE number to the sompi: the
        // floor this coin rendered on glass was 0.10437500 KAS. A pin bump that
        // moves the KIP-9 floor reds here (the C5 tripwire family).
        assert_eq!(min, 10_437_500, "the glass floor, reproduced offline");
    }

    /// The §4 lifecycle-discipline tripwire for THIS file — the funds path's
    /// copy of the transport lane's `module_logs_are_lifecycle_only`.
    ///
    /// The drain lines added for diagnosis (arm, coin counts, refused-vs-built)
    /// sit in the one module that has every amount and every address in scope,
    /// so the mistake people actually make here is reaching for the variable
    /// that is already bound. Counts and state words only (INV-3).
    ///
    /// Prose is judged separately from data, exactly as the transport lane does
    /// it: "balance refresh failed" is a sentence, `{balance}` is a leak. What
    /// is checked is what gets EMITTED — inline captures in the format string,
    /// and the identifiers passed as arguments — and here the argument rule is
    /// STRICTER than transport's: a forbidden word may not appear in an
    /// argument identifier at all, not even measured. This lane logs lifecycle,
    /// never quantities, so there is nothing legitimate to measure.
    ///
    /// **What it is not:** a proof. It knows the identifier NAMES this module
    /// uses; a log line that copies an amount into a differently-named local
    /// and prints that still passes. It is a tripwire for the mistake people
    /// actually make, and the review is the authority — said plainly, because
    /// overclaiming a guard's reach is worse than not having it.
    #[test]
    fn send_logs_are_lifecycle_only() {
        let source = include_str!("send.rs");
        // Accumulate each `log::` call to its balanced closing paren, so a
        // wrapped macro is judged as one string.
        let mut calls: Vec<String> = Vec::new();
        let mut pending: Option<(String, i32)> = None;
        for raw in source.lines() {
            let line = raw.trim_start();
            if pending.is_none() && (!line.contains("log::") || line.starts_with("//")) {
                continue;
            }
            let (mut buf, mut depth) = pending.take().unwrap_or_default();
            buf.push(' ');
            buf.push_str(line);
            // Comment lines inside a call carry prose, not emitted text.
            if !line.starts_with("//") {
                depth += i32::try_from(line.matches('(').count()).unwrap_or(0);
                depth -= i32::try_from(line.matches(')').count()).unwrap_or(0);
            }
            if depth <= 0 {
                calls.push(buf);
            } else {
                pending = Some((buf, depth));
            }
        }
        assert!(
            calls.len() >= 5,
            "the scanner found only {} log calls — it has stopped matching",
            calls.len()
        );
        // Both halves of what may never reach logcat from a funds path: what a
        // coin is worth, and where it went.
        const FORBIDDEN: [&str; 8] = [
            "sompi",
            "amount",
            "balance",
            "value",
            "address",
            "destination",
            "txid",
            "outpoint",
        ];
        let is_ident = |c: char| c.is_alphanumeric() || c == '_';
        for call in calls {
            // Prose inside the format string is a sentence, and a lane that
            // cannot say in English what it did is a worse lane — so the
            // literal is judged by one rule and the arguments by another.
            // Split the format string off at ITS OWN closing quote, not at the
            // call's last quote. `rfind` swept every argument into the "format"
            // region the moment any later `"` appeared — a string default, a
            // `.unwrap_or("x")`, a trailing comment — and that region is only
            // checked for `{name}` captures, so
            // `log::info!("drain: {}", amount_sompi.to_string())` passed the
            // guard as written. Red-proved by the ffi-leak audit, this sitting.
            let close = call
                .find('"')
                .and_then(|a| call[a + 1..].find('"').map(|i| a + 1 + i));
            let (format, args) = match (call.find('"'), close) {
                (Some(a), Some(b)) if b > a => (&call[a..=b], &call[b + 1..]),
                _ => (call.as_str(), ""),
            };
            // Inline captures, by NAME — matched as a prefix-bearing whole
            // identifier so `{amount_sompi}` is caught, not just `{amount}`.
            for piece in format.split('{').skip(1) {
                let name: String = piece.chars().take_while(|c| is_ident(*c)).collect();
                for word in FORBIDDEN {
                    assert!(
                        !name.contains(word),
                        "a log FORMAT STRING captures `{name}` — the drain lane \
                         is counts and state words only (INV-3): {call}"
                    );
                }
            }
            // Argument identifiers, every token, strictly.
            let chars: Vec<char> = args.chars().collect();
            let mut at = 0;
            while at < chars.len() {
                if !is_ident(chars[at]) {
                    at += 1;
                    continue;
                }
                let start = at;
                while at < chars.len() && is_ident(chars[at]) {
                    at += 1;
                }
                let token: String = chars[start..at].iter().collect();
                for word in FORBIDDEN {
                    assert!(
                        !token.contains(word),
                        "a log ARGUMENT names `{token}` — the drain lane is \
                         counts and state words only (INV-3): {call}"
                    );
                }
            }
        }
    }

    /// A synthetic wallet with a REAL band: TooSmall below `floor` (the payment
    /// is dust), Builds in `[floor, ceiling]`, TooSmall again above `ceiling`
    /// (the CHANGE is dust), TooLarge above `balance`.
    ///
    /// The shape every real wallet has, and the one no `search_minimum` fixture
    /// had (F45): [`synthetic`] is monotone at the top, and the only double-sided
    /// probe in this module was passed exclusively to `search_maximum`. So the
    /// non-monotonicity F3 lives in could not be expressed, let alone caught.
    fn banded(floor: u64, ceiling: u64, balance: u64) -> impl FnMut(u64) -> Result<ProbeOutcome> {
        move |v| {
            Ok(if v < floor {
                ProbeOutcome::TooSmall
            } else if v <= ceiling {
                ProbeOutcome::Builds
            } else if v <= balance {
                ProbeOutcome::TooSmall // the CHANGE is the dust up here
            } else {
                ProbeOutcome::TooLarge
            })
        }
    }

    /// F3: a band narrower than the ladder gap beneath it. The doubling ladder
    /// steps 1M→2M→4M→8M→16M, every rung TooSmall, and 16M is CHANGE-side — so
    /// `lo` ends up pinned ABOVE the entire buildable range and the old search
    /// hunted `(16M, 32M)`, which is empty by construction.
    ///
    /// Numbers are the audit's real-Generator repro (one coin of 30,300,000
    /// sompi, band `[14_639_000, 15_457_000]`), used here as a pure fixture so
    /// the property is pinned without a Generator run.
    #[test]
    fn search_finds_a_band_the_ladder_steps_over() {
        let (floor, ceiling, balance) = (14_639_000u64, 15_457_000u64, 30_300_000u64);
        let mut probe = banded(floor, ceiling, balance);

        // The precondition that makes this test meaningful: every ladder rung
        // really is TooSmall, and the one just above the band is the change-side
        // refusal the search used to misread as "go higher".
        for rung in [1_000_000u64, 2_000_000, 4_000_000, 8_000_000, 16_000_000] {
            assert_eq!(
                probe(rung).unwrap(),
                ProbeOutcome::TooSmall,
                "rung {rung} must be TooSmall for this fixture to exercise F3"
            );
        }
        assert!(
            16_000_000 > ceiling,
            "the 16M rung must sit ABOVE the band — that is the whole defect"
        );

        let min = search_minimum(banded(floor, ceiling, balance), balance)
            .unwrap()
            .expect("a wallet with an 818-wide buildable band CAN send");
        assert_eq!(
            probe(min).unwrap(),
            ProbeOutcome::Builds,
            "the reported minimum {min} must itself build"
        );
        assert!(
            min - floor <= PROBE_PRECISION_SOMPI,
            "and it must be the BOTTOM of the band, within display precision: {min}"
        );
    }

    /// The same defect one rung lower, so the fix is not fitted to a single
    /// arithmetic coincidence: a band that opens just above the 4M rung.
    #[test]
    fn search_finds_a_band_above_a_lower_rung() {
        let (floor, ceiling, balance) = (4_100_000u64, 5_650_000u64, 9_800_000u64);
        let min = search_minimum(banded(floor, ceiling, balance), balance)
            .unwrap()
            .expect("this wallet can send");
        assert_eq!(
            banded(floor, ceiling, balance)(min).unwrap(),
            ProbeOutcome::Builds
        );
        assert!(
            min - floor <= PROBE_PRECISION_SOMPI,
            "bottom of the band: {min}"
        );
    }

    /// The same defect against the REAL pinned Generator, not a fixture — the
    /// counterexample the audit reproduced (F3). One coin of 30,300,000 sompi:
    /// the old search returned `None`, and `transport.rs` turned that into "your
    /// balance can't cover a message right now" while 818 distinct amounts built.
    ///
    /// Asserts the two things that matter and nothing about the exact value: a
    /// floor EXISTS, and the number handed to the user is one the Generator
    /// actually accepted (INV-9 — the pin decides, never this test's arithmetic).
    #[test]
    fn the_real_generator_band_the_ladder_steps_over() {
        let coin = 30_300_000u64;
        let probe = |amount: u64| -> Result<ProbeOutcome> {
            let entries = vec![UtxoEntryReference::simulated(coin)];
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

        // The preconditions, from the pin itself — these are what make the
        // fixture above a model of reality rather than a story about it.
        for rung in [1_000_000u64, 2_000_000, 4_000_000, 8_000_000, 16_000_000] {
            assert_eq!(
                probe(rung).unwrap(),
                ProbeOutcome::TooSmall,
                "every ladder rung is TooSmall on this coin — rung {rung}"
            );
        }

        let min = search_minimum(probe, coin)
            .unwrap()
            .expect("this coin has a buildable band — `None` is the F3 defect");
        assert_eq!(
            probe(min).unwrap(),
            ProbeOutcome::Builds,
            "the floor handed to the user, {min}, must be one the Generator built"
        );
    }

    /// The rescue must not invent sendability. A balance whose band is empty
    /// still reports `None` — otherwise the fix would trade a false "you cannot
    /// send" for a false "you can", which is the worse of the two.
    #[test]
    fn the_rescue_never_manufactures_a_floor() {
        // floor > ceiling ⇒ the band is empty at every amount.
        let mut probe = |v: u64| {
            Ok(if v <= 15_000_000 {
                ProbeOutcome::TooSmall
            } else {
                ProbeOutcome::TooLarge
            })
        };
        assert_eq!(search_minimum(&mut probe, 15_000_000).unwrap(), None);
    }

    #[test]
    fn search_reports_none_when_nothing_is_sendable() {
        // Floor above balance: a dust-only wallet cannot send at all.
        assert_eq!(
            search_minimum(synthetic(10_000_000, 4_000_000), 4_000_000).unwrap(),
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
        let min = search_minimum(probe, kaspa_to_sompi(100.0))
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

    /// The output half of [`WalletEngine::settling_at`]: a submitted-but-not-yet
    /// accepted transaction is recognised as "on its way to `address`" only when
    /// it actually pays that address. Getting this wrong in either direction is
    /// a live refusal or a pointless twenty-four-second wait.
    #[test]
    fn an_outgoing_transaction_is_matched_by_the_address_it_pays() {
        let change = addr(CHANGE);
        let dest = addr(DEST);
        let tx = |outputs: Vec<Address>| {
            Transaction::new(
                0,
                vec![],
                outputs
                    .iter()
                    .map(|a| TransactionOutput::new(20_000_000, pay_to_address_script(a)))
                    .collect(),
                0,
                SUBNETWORK_ID_NATIVE,
                0,
                vec![],
            )
        };
        // The transport shape: pay a stranger, change home to our bound address.
        let send = tx(vec![dest.clone(), change.clone()]);
        assert!(pays_to(&send, &change), "our own change output counts");
        assert!(pays_to(&send, &dest), "so does the payment output");

        // The false-wait case the wallet-global gate could not tell apart: a
        // transaction settling somewhere else entirely.
        let elsewhere = tx(vec![dest.clone()]);
        assert!(
            !pays_to(&elsewhere, &change),
            "a transaction that pays another address is not this address settling"
        );

        // No outputs at all must never read as "something is coming".
        assert!(!pays_to(&tx(vec![]), &change));
    }

    /// The premise behind the caller-ordering law in `prepare_transport_send`:
    /// an all-immature wallet has NO floor, so a floor computed before the
    /// maturity wait cannot return a number to wait with.
    ///
    /// This is the pin answering, not us: an empty spendable set makes the very
    /// first probe `InsufficientFunds` ⇒ `TooLarge`, the ladder never anchors,
    /// and the hunt closes on an empty window. A caller that reads that `None`
    /// as "your balance can't cover this (anti-dust floor)" blames the coin
    /// shape for what is only a clock — the L92 scar, one lane over.
    #[test]
    fn no_mature_coin_means_no_floor_at_all() {
        let probe = |amount: u64| -> Result<ProbeOutcome> {
            // Empty: every coin the wallet owns is still immature.
            let entries: Vec<UtxoEntryReference> = vec![];
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
        assert_eq!(
            probe(PROBE_LADDER_START_SOMPI).unwrap(),
            ProbeOutcome::TooLarge,
            "an empty spendable set is a shortfall at every amount"
        );
        assert_eq!(
            search_minimum(probe, 0).unwrap(),
            None,
            "no mature coin ⇒ no sendable minimum exists"
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
