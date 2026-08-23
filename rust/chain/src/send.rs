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
    pub async fn prepare_send(
        &self,
        destination: Address,
        amount_sompi: u64,
        change: Address,
        signer: Arc<dyn SignerT>,
        rpc: Rpc,
        payload: Option<Vec<u8>>,
    ) -> Result<PreparedSend> {
        // A plain payment: no pinned block — the spend order is wholly the
        // wallet policy's (spend_policy.rs: riders first, then largest-first).
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
        let ridered =
            spend_policy::select_spend_priority(&mature, &pinned, spend_policy::RIDER_LIMIT);

        let (pending, summary) = {
            let (pending, summary) = generate_chain(
                &context,
                ridered,
                &change,
                PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
                Fees::SenderPays(0),
                payload.clone(),
                signer.clone(),
            )?;
            // The rider law's no-new-leg guarantee, enforced by construction:
            // a one-transaction chain cannot have gained a leg (one is the
            // floor), so only a chained result pays the comparison generation.
            // No mass arithmetic of ours decides this (INV-9) — the pinned
            // Generator is run both ways and the shorter chain wins.
            if pending.len() > 1 {
                let riderless = spend_policy::select_spend_priority(&mature, &pinned, 0);
                let (p, s) = generate_chain(
                    &context,
                    riderless,
                    &change,
                    PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
                    Fees::SenderPays(0),
                    payload.clone(),
                    signer.clone(),
                )?;
                if p.len() < pending.len() {
                    (p, s)
                } else {
                    (pending, summary)
                }
            } else {
                (pending, summary)
            }
        };

        let mut summary = project_summary(&summary, destination.to_string());
        // B7: the payload size the confirm shows is read back from the BUILT
        // final tx, never echoed from the caller's argument.
        summary.payload_len = final_payload_len(&pending);
        Ok(PreparedSend {
            pending,
            summary,
            rpc,
            // An ordinary payment's outgoing record is LOAD-BEARING while the
            // change is unconfirmed: the pin adds it back so the user sees
            // their money immediately. Never discharge it here.
            discharge_outgoing: None,
        })
    }
}

/// One full (unsigned) generation over the live context with an explicit spend
/// order. Pure plumbing shared by the ridered and riderless passes of
/// `prepare_send_inner`; generation never mutates the context (context
/// registration happens only in `try_submit`, pending.rs:214-219 @ `cfafeb4`),
/// so running it twice is side-effect-free and a discarded chain simply drops.
fn generate_chain(
    context: &kaspa_wallet_core::utxo::UtxoContext,
    order: Vec<UtxoEntryReference>,
    change: &Address,
    payment: PaymentDestination,
    fees: Fees,
    payload: Option<Vec<u8>>,
    signer: Arc<dyn SignerT>,
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
    let summary = generator.summary();
    Ok((pending, summary))
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

/// Split the mature snapshot into (offered, excluded_count) for a drain.
/// Address-matched, and under an exclusion list it FAILS CLOSED on the corner
/// the pin's types leave open: a coin whose `utxo.address` is `None` cannot be
/// matched to an exclusion, so offering it would bypass the one custody check
/// `verify_drain` enforces — it is counted excluded instead. (Unreachable for
/// coins this context scanned — they arrive via address registration — but
/// the type says Option, so the code refuses to guess.) With no exclusions
/// (a sweep — the total exit) everything is offered.
fn drain_included(
    mature: Vec<UtxoEntryReference>,
    exclude: &[Address],
) -> (Vec<UtxoEntryReference>, usize) {
    if exclude.is_empty() {
        return (mature, 0);
    }
    let total = mature.len();
    let included: Vec<UtxoEntryReference> = mature
        .into_iter()
        .filter(|entry| {
            entry
                .utxo
                .address
                .as_ref()
                .is_some_and(|address| !exclude.contains(address))
        })
        .collect();
    let excluded_count = total - included.len();
    (included, excluded_count)
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

    async fn prepare_drain(
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
        let has_exclusions = !exclude.is_empty();
        let (included, excluded_count) = drain_included(mature, exclude);
        let included_for_verify = has_exclusions.then(|| included.clone());

        if !is_exit && included.len() < 2 {
            // One coin in, one coin out is a pure fee burn — nothing merges.
            // Name the real cause when the exclusion line is what emptied the
            // offer (counts only, never an address).
            return Err(ChainError::Message(if excluded_count > 0 {
                format!(
                    "nothing to merge — {excluded_count} coin(s) stay reserved \
                     for your conversations, and the rest is already one coin"
                )
            } else {
                "nothing to merge — your spendable coins are already consolidated".into()
            }));
        }

        let arm = plan_drain(included, has_exclusions)?;
        let chained_drain_allowed = !is_exit && matches!(arm, DrainArm::Drain);
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
                generate_chain(
                    &context,
                    priority,
                    &change_home,
                    PaymentOutputs::from((destination.clone(), amount_sompi)).into(),
                    Fees::ReceiverPays(0),
                    None,
                    signer,
                )?
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
        Ok(PreparedSend {
            pending,
            summary,
            rpc,
            discharge_outgoing: discharge.then(|| context.clone()),
        })
    }
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
/// address). An EXIT must be one transaction — the native sweep's
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
        let order = spend_policy::select_spend_priority(&mature, &[], spend_policy::RIDER_LIMIT);
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
            Ok(Some(_)) => continue,
            Ok(None) => return Ok(ProbeOutcome::Builds),
            Err(e) => return probe_error(e),
        }
    }
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
    ) -> Result<Option<u64>> {
        let context = self.context();
        let mature = mature_snapshot_sync(&context)?;
        let order = spend_policy::select_spend_priority(&mature, pinned, spend_policy::RIDER_LIMIT);
        let order = (!order.is_empty()).then_some(order);
        search_minimum(|amount| probe_context(&context, &change, amount, order.as_deref()))
    }
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
        std::task::Poll::Pending => Err(ChainError::Message(
            "the pinned UtxoContext::get_utxos became genuinely asynchronous — \
             re-plumb minimum_sendable's mature snapshot before trusting its floor"
                .into(),
        )),
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
            let order = crate::spend_policy::select_spend_priority(&entries, &[], RIDER_LIMIT);
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
    #[test]
    fn riders_strictly_drain_a_fragmented_wallet() {
        let change = addr(CHANGE);
        let mut entries: Vec<UtxoEntryReference> = fragmented_fixture()
            .iter()
            .map(|v| UtxoEntryReference::simulated(kaspa_to_sompi(*v)))
            .collect();

        for round in 0..8 {
            let before = entries.len();
            let order = crate::spend_policy::select_spend_priority(&entries, &[], RIDER_LIMIT);
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
        let has_exclusions = !exclude.is_empty();
        let (included, _) = drain_included(entries.to_vec(), exclude);
        let included_for_verify = has_exclusions.then(|| included.clone());
        let arm = plan_drain(included, has_exclusions)?;
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
        assert_eq!(search_minimum(probe).unwrap(), Some(10_687_500));
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
            search_minimum(probe).unwrap(),
            None,
            "the fixture state: no amount is sendable at all"
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
        let (included, excluded_count) =
            drain_included(entries.clone(), std::slice::from_ref(&bound));
        assert_eq!(included.len(), 2);
        assert_eq!(excluded_count, 1, "the None-address coin counts excluded");
        assert!(
            !included
                .iter()
                .any(|entry| entry.transaction_id() == mystery.transaction_id()),
            "a coin that cannot be matched to the exclusion list is not offered"
        );

        // With no exclusions (a sweep): everything is offered.
        let (included, excluded_count) = drain_included(entries, &[]);
        assert_eq!((included.len(), excluded_count), (3, 0));
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
            search_minimum(probe).unwrap(),
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
