//! Send across the FFI (P1.6 · T3): a two-phase pipeline so the confirm screen
//! renders Rust's decode of the ACTUAL transactions being signed, never the
//! UI's echo of the user's intent (consensus B7).
//!
//! - [`send_prepare`] builds the whole tx chain (pinned Generator — INV-9) and
//!   STASHES the unsigned [`PreparedSend`], returning only a summary DTO.
//! - [`send_commit`] signs + broadcasts the SAME stashed txs (signing in Rust
//!   only — INV-1/2; only the txid leaves), advancing the change cursor on full
//!   success (D-041).
//! - [`send_abandon`] drops the stash (confirm dismissed / back).
//!
//! Nothing secret crosses: the signer is built inside `vault.rs` (the keychain
//! never leaves it) and held as an opaque `dyn SignerT`; only a summary + a txid
//! reach Dart. `*_sompi`/`mass` stay `u64` → Dart `BigInt` (L3).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use kaspaverse_chain::{Address, ChainError, PreparedSend, SendOutcome, SendSummary, SignerT};
use kaspaverse_core::{Branch, Prefix};

use crate::api::error::AppError;
use crate::api::{dag, vault, wallet};

/// Which send-like flow a signable summary describes — set by RUST from its
/// own flow knowledge, never caller-supplied (V5: the Dart `selfSend` bool
/// was the last un-Rust-vouched fact on the signing surface; the mode now
/// rides the same B7-decoded DTO as the numbers). Field-less by the FRB DTO
/// law (dag.rs note): per-kind facts ride [`SignableSummaryDto`]'s `Option`
/// fields — payment mode never sees frame fields.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignableKind {
    /// Plain payment: value to a counterparty, no payload.
    Payment,
    /// Outbound handshake: the 0.2 KAS bond to the counterparty + sealed
    /// payload (§0.6 — refunded in their acceptance).
    Bond,
    /// Accept: the bond REFUNDED to the sender + sealed payload. Value moves
    /// to the counterparty — deliberately NOT a self-send (D-069 keeps
    /// bonds unchanged).
    BondRefund,
    /// Comm/frame self-send (D-069): destination is our OWN bound address,
    /// value returns as change — the honest cost is the fee alone. The
    /// sheet leads with the fee and never states the value as spend.
    SelfSendFrame,
    /// The P4 challenge/stake seam: value at RISK into a covenant + game
    /// frame. No producer yet — reserved so P4 adds a producer, never a
    /// sixth confirm sheet (the V5 variant-coverage bar; render-pinned by
    /// the Dart B7 suite).
    Stake,
    /// Dev/broadcast lane: plaintext payload to an arbitrary address.
    Bcast,
    /// Sweep — send max, the wallet's EXIT: every spendable coin, from every
    /// watched address, to an external destination in ONE transaction whose
    /// output + fee equal the balance to the sompi. The amount is SOLVED by
    /// the Rust builder (it depends on the fee of the transaction spending
    /// it), never typed or computed in Dart.
    Sweep,
    /// Consolidate — the wallet's spendable coins merged into ONE coin at
    /// receive/0, so future sends pay the one-input floor. Coins at live
    /// conversations' bound addresses are excluded (`drain_exclusions`) and
    /// the chain layer refuses on the BUILT transaction if one is drawn.
    Consolidate,
}

/// Reserved fee-strategy discriminant (V5). One variant today — every flow
/// pays `Fees::SenderPays(priority)` at the pinned Generator
/// (`chain::send::prepare_send_inner`) with `priority_fee_sompi = 0`. The
/// seam for a later estimate/fee-choice (★ Send-UX pass, D-008/RBF-deferred);
/// fee ESTIMATION is deliberately not built here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FeeStrategyKind {
    SenderPays,
}

/// THE canonical Rust-decoded summary every signable flow renders (B7 — NOT
/// the form echo; V5 consolidation, one signing surface for P4 to extend).
/// `nonce` guards the commit against a stale plan; `*_sompi`/`mass` cross as
/// Dart `BigInt` (L3); `payload_*` are decoded from the BUILT final tx and
/// are `None` exactly when the flow carries no payload.
#[derive(Clone, Debug)]
pub struct SignableSummaryDto {
    /// Opaque token tying this summary to its stashed transactions.
    pub nonce: u64,
    /// The flow mode — Rust's knowledge, the sheet's render switch.
    pub kind: SignableKind,
    /// The mainnet address Rust validated and built into the payment output.
    pub destination: String,
    pub amount_sompi: u64,
    /// The Generator's exact aggregate fee — never "≈ free". The basis is the
    /// wallet's minimum-relay proxy: ≈ compute mass, with the payload
    /// component hardened for normalized transient bytes (so payload-bearing
    /// flows are priced in here); storage mass is EXCLUDED from the floor,
    /// which is why `mass` below never reconciles with this number.
    pub fee_sompi: u64,
    /// `amount + fee` (what leaves the wallet, excluding returned change).
    pub total_sompi: u64,
    pub mass: u64,
    /// 1 normally; >1 when the send chained past one tx's 100k-gram mass.
    pub tx_count: u32,
    pub utxo_count: u32,
    /// Payload bytes on the built final tx (read back, not echoed); `None`
    /// on a payload-less flow — payment mode never sees frame fields.
    pub payload_len: Option<u32>,
    /// Wire kind decoded from the built payload (same parser the receive
    /// scan uses); `None` on a payload-less flow.
    pub payload_kind: Option<String>,
    /// Reserved (V5): the strategy the stashed plan was built with.
    pub fee_strategy: FeeStrategyKind,
    /// Reserved (V5): the priority component — 0 today, everywhere.
    pub priority_fee_sompi: u64,
    /// Consolidate only (`None` on every other kind): the representative
    /// amount the savings comparison below was priced at — half the
    /// consolidated value, an ordinary mid-shape send.
    pub typical_amount_sompi: Option<u64>,
    /// Consolidate only: inputs that send draws from TODAY's coins.
    pub typical_now_utxos: Option<u32>,
    /// Consolidate only: its fee from today's coins.
    pub typical_now_fee_sompi: Option<u64>,
    /// Consolidate only: the same send's fee from the single consolidated
    /// coin. All four are the pinned Generator's own numbers over real
    /// shapes (probed in `chain::send::consolidation_savings`), never
    /// arithmetic done here or in Dart.
    pub typical_after_fee_sompi: Option<u64>,
}

/// The ONE stash-side projection every prepare path shares (V5 — replaces
/// three copy-pasted blocks). `payload_kind` presence drives BOTH payload
/// fields; the reserved fee-strategy constants live here, cross-referenced
/// to the Generator call (`chain::send::prepare_send_inner`,
/// `Fees::SenderPays(0)`) — a future fee-choice originates its real value in
/// chain, never here.
pub(crate) fn project_signable(
    nonce: u64,
    kind: SignableKind,
    summary: &SendSummary,
    payload_kind: Option<String>,
) -> SignableSummaryDto {
    debug_assert!(
        kind != SignableKind::Payment || payload_kind.is_none(),
        "payment mode never carries payload fields (B7 variant law)"
    );
    let payload_len = payload_kind.as_ref().map(|_| summary.payload_len);
    SignableSummaryDto {
        nonce,
        kind,
        destination: summary.destination.clone(),
        amount_sompi: summary.amount_sompi,
        fee_sompi: summary.fee_sompi,
        total_sompi: summary.total_sompi,
        mass: summary.mass,
        tx_count: summary.tx_count,
        utxo_count: summary.utxo_count,
        payload_len,
        payload_kind,
        fee_strategy: FeeStrategyKind::SenderPays,
        typical_amount_sompi: None,
        typical_now_utxos: None,
        typical_now_fee_sompi: None,
        typical_after_fee_sompi: None,
        priority_fee_sompi: 0,
    }
}

/// The outcome of broadcasting. `partial` (B6): some legs are already on-chain
/// (their UTXOs really spent) — surfaced, never hidden; the next sync reconciles.
#[derive(Clone, Debug)]
pub struct SendOutcomeDto {
    pub final_txid: Option<String>,
    pub submitted: u32,
    pub total: u32,
    pub partial: bool,
    pub error: Option<String>,
}

/// The single-slot stash of the built-but-unsigned send, between confirm and
/// the hold-to-sign commit. Each prepare overwrites; commit consumes; abandon
/// clears. Holding the SAME txs the summary describes is the B7 guarantee.
static PENDING_SEND: Mutex<Option<(u64, PreparedSend)>> = Mutex::new(None);

/// Monotonic nonce source (a unique token per prepare is all that's needed to
/// reject a stale commit — no randomness required). Starts at 1 so 0 is never a
/// live nonce. SHARED with the transport stash (api/transport.rs): one nonce
/// space, so a token can never name a plan in the wrong stash.
static NONCE: AtomicU64 = AtomicU64::new(1);

/// Next prepare nonce (shared across the payment and transport stashes).
pub(crate) fn next_nonce() -> u64 {
    NONCE.fetch_add(1, Ordering::Relaxed)
}

/// Parse `s` as a mainnet Kaspa address, rejecting malformed input and a
/// wrong-network (e.g. testnet) address up front (DS-8) — the Generator's own
/// prefix check (generator.rs:389/418) is the backstop, not the only gate.
pub(crate) fn validate_mainnet_address(s: &str) -> Result<Address, AppError> {
    let address = Address::try_from(s)
        .map_err(|_| AppError::msg("that doesn't look like a valid Kaspa address"))?;
    if address.prefix != Prefix::Mainnet {
        return Err(AppError::msg(
            "that's not a mainnet address — KaspaVerse is mainnet-only",
        ));
    }
    Ok(address)
}

/// Whether a [`SendOutcome`] is a clean, fully-broadcast send (every leg landed)
/// — the only case in which the change cursor advances (D-041). Pure; tested.
fn fully_broadcast(outcome: &SendOutcome) -> bool {
    !outcome.partial
        && outcome.error.is_none()
        && outcome.total > 0
        && outcome.submitted == outcome.total
}

/// Classify an `InsufficientFunds` refusal honestly against the live balance
/// buckets (the Generator spends only MATURE UTXOs). Change from our own
/// just-broadcast send rides the `outgoing` bucket until the network hands it
/// back — that is "still settling", never "insufficient" (V2, finding 7).
/// Incoming value still maturing rides `pending`. A "try again" is promised
/// ONLY when the amount fits inside everything the wallet could ever settle
/// (mature + pending + outgoing, all node-read) — an impossible amount is a
/// true shortfall however much is in flight (consensus-audit V2 finding 2;
/// the fee can still push a fitting retry over, and that retry then reads
/// the honest refusal). Shared with the transport prepare path (V5 — the
/// finding-7 fix must not fork per surface). Pure; tested.
pub(crate) fn shortfall_message(
    amount_sompi: u64,
    mature_sompi: u64,
    pending_sompi: u64,
    outgoing_sompi: u64,
) -> &'static str {
    let ever_settles = amount_sompi
        <= mature_sompi
            .saturating_add(pending_sompi)
            .saturating_add(outgoing_sompi);
    if ever_settles && outgoing_sompi > 0 {
        "still settling from your last send — your change is on its way back. \
         Try again in a few seconds."
    } else if ever_settles && pending_sompi > 0 {
        "not yet spendable — some funds are still confirming. Try again in a few seconds."
    } else {
        "insufficient funds — the amount plus the network fee is more than your spendable balance."
    }
}

/// Display a sompi amount as KAS with trailing zeros trimmed (display-only —
/// never consensus math). Pure; tested.
fn kas_display(sompi: u64) -> String {
    let kas = sompi / 100_000_000;
    let frac = sompi % 100_000_000;
    if frac == 0 {
        format!("{kas}")
    } else {
        let s = format!("{kas}.{frac:08}");
        s.trim_end_matches('0').to_string()
    }
}

/// WHERE A PAYMENT'S CHANGE GOES — `receive/0`, the same address everything
/// else in this wallet already is.
///
/// **The one-way valve this closes.** `receive/0` is three things at once: the
/// only address the wallet ever hands out (`vault_receive_address` derives
/// exactly this and never rotates), the §0.7 binding of every conversation, and
/// therefore the address every transport send must pin `input[0]` to (D2/L47,
/// D-067). Money arrives there. Sending change to a fresh `change/N` meant the
/// FIRST outgoing payment swept those coins away and put them somewhere the
/// messages lane may not spend from — so a wallet with a healthy balance had an
/// identity address holding zero UTXOs, and every message, handshake and backup
/// refused. Nothing ever refilled it, because nothing ever routed anything back.
/// Found on the founder's own device 2026-08-15: 14.19 KAS in the wallet,
/// 0 UTXOs at `receive/0`, one payment earlier.
///
/// **What it costs.** Change consolidates at one known address instead of a
/// fresh one. That buys less than it looks like it did: this wallet's receive
/// address never rotates and is published to every counterpart it messages, and
/// a payment's `input[0]` already links its change to it on chain. The lane
/// staying alive is worth more than hygiene that an observer defeats for free.
/// Reverting is this one function.
pub(crate) fn payment_change_address() -> Result<Address, AppError> {
    vault::wallet_address_at(Branch::Receive, 0)
}

/// The smallest amount currently sendable from this wallet's coins (the KIP-9
/// floor for the live UTXO shape, computed by probing the pinned Generator —
/// D-054), or `None` when the wallet cannot send at all / isn't ready. Public
/// data only; signerless; probes with the address the send will really use, so
/// the advertised floor is the floor of the transaction that gets built.
pub fn send_minimum() -> Result<Option<u64>, AppError> {
    let Some(engine) = wallet::engine_handle() else {
        return Ok(None); // engine not up yet — the UI simply shows no hint
    };
    engine
        .minimum_sendable(payment_change_address()?, &[])
        .map_err(AppError::chain)
}

/// Phase 1: validate, build the tx chain over the live UTXO context, and stash
/// the unsigned transactions. Returns the Rust-decoded summary for the confirm.
/// Errors honestly: malformed/wrong-network address, locked/unready wallet, or
/// a funds shortfall classified as "not yet spendable" vs "insufficient" using
/// the live balance.
pub async fn send_prepare(
    destination: String,
    amount_sompi: u64,
) -> Result<SignableSummaryDto, AppError> {
    let dest = validate_mainnet_address(&destination)?;
    if amount_sompi == 0 {
        return Err(AppError::msg("enter an amount greater than zero"));
    }

    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;

    // Change returns to `receive/0` — see `payment_change_address` for why. The
    // signer registers the whole watched window (receive + widened change)
    // anyway, so it still resolves inputs sitting at the change addresses
    // earlier builds created (the two-consumer seam — vault.rs is the single
    // source), and coins already parked there stay spendable.
    let change = payment_change_address()?;
    let signer = wallet::wallet_signer()?;
    let signer: Arc<dyn SignerT> = Arc::new(signer);

    let rpc = dag::shared_monitor().await?.rpc();

    let prepared = match engine
        .prepare_send(dest, amount_sompi, change, signer, rpc, None)
        .await
    {
        Ok(prepared) => prepared,
        Err(ChainError::InsufficientFunds { .. }) => {
            // Distinguish a true shortfall from funds in flight using the live
            // balance (INV-8 honesty) — both the maturing-incoming bucket and
            // our own settling change (finding 7: the classifier used to read
            // only `pending`, so a send minutes after a send said
            // "insufficient" at ample balance).
            let (mature, pending, outgoing) = wallet::latest_snapshot()
                .map(|s| {
                    (
                        s.mature_sompi.unwrap_or(0),
                        s.pending_sompi.unwrap_or(0),
                        s.outgoing_sompi.unwrap_or(0),
                    )
                })
                .unwrap_or((0, 0, 0));
            return Err(AppError::msg(shortfall_message(
                amount_sompi,
                mature,
                pending,
                outgoing,
            )));
        }
        Err(ChainError::StorageMassExceeded { .. }) => {
            // KIP-9: a tiny output relative to the wallet's UTXOs is penalized
            // past the Generator's per-tx mass ceiling (INV-8 — surface it
            // honestly, WITH the exact way out: the computed minimum for this
            // wallet's coin shape, not a mystery — D-054).
            // Two corrections, both carried from Wave A (SOURCE_OF_TRUTH §19).
            //
            // The address is `payment_change_address()`, not a fresh
            // `change/N` — the last derivation in this file that still
            // contradicted the rule stated ten lines above, and it would have
            // priced the hint against a coin shape the send itself never uses.
            //
            // And it is fallible-but-optional, so it may NOT use `?`. This is
            // the error arm: a failure to compute the hint used to propagate as
            // THE error, replacing "your amount is too small, here is the way
            // out" with a derivation failure that explains nothing. An optional
            // extra that can delete the explanation it decorates is worse than
            // no extra at all.
            let hint = payment_change_address()
                .ok()
                .and_then(|change| engine.minimum_sendable(change, &[]).ok().flatten())
                .map(|m| {
                    format!(
                        " The smallest sendable right now is about {} KAS.",
                        kas_display(m)
                    )
                })
                .unwrap_or_default();
            return Err(AppError::msg(format!(
                "this amount is too small to send from your current coins — Kaspa's \
                 anti-dust rule (storage mass) prices tiny outputs.{hint}"
            )));
        }
        Err(e) => return Err(AppError::chain(e)),
    };

    let nonce = next_nonce();
    let summary = prepared.summary().clone();
    *PENDING_SEND.lock().unwrap_or_else(PoisonError::into_inner) = Some((nonce, prepared));

    Ok(project_signable(
        nonce,
        SignableKind::Payment,
        &summary,
        None,
    ))
}

/// Phase 1 of the wallet's EXIT: build the sweep — every spendable coin, from
/// every watched address, to `destination` in one transaction — stash it, and
/// return the B7 summary. The swept amount is the BUILT transaction's single
/// output (the fee already deducted by the Generator), so the confirm renders
/// exactly what the destination receives and `amount + fee == balance` to the
/// sompi. Commit rides the ordinary [`send_commit`] path with the same nonce
/// guard, acceptance watch, and abandon affordance.
pub async fn sweep_prepare(destination: String) -> Result<SignableSummaryDto, AppError> {
    let dest = validate_mainnet_address(&destination)?;
    let change_home = payment_change_address()?;
    if dest == change_home {
        // Sweeping to our own identity address is a consolidation without the
        // conversation-address exclusions — the one shape that quietly
        // de-funds the chat lane. Route the intent to the action built for it.
        return Err(AppError::msg(
            "that is this wallet's own address — use \"Merge coins\" to tidy your \
             own wallet; Sweep moves everything to another wallet",
        ));
    }
    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;
    let signer: Arc<dyn SignerT> = Arc::new(wallet::wallet_signer()?);
    let rpc = dag::shared_monitor().await?.rpc();

    let prepared = engine
        .prepare_sweep(dest, change_home, signer, rpc)
        .await
        .map_err(map_drain_error)?;

    let nonce = next_nonce();
    let summary = prepared.summary().clone();
    *PENDING_SEND.lock().unwrap_or_else(PoisonError::into_inner) = Some((nonce, prepared));
    Ok(project_signable(nonce, SignableKind::Sweep, &summary, None))
}

/// Phase 1 of consolidation: merge the wallet's spendable coins into ONE coin
/// at receive/0, leaving live conversations' bound addresses untouched
/// (`transport::drain_exclusions` — fails closed if the transport store is
/// unavailable). The preview carries the honest savings pair when it can be
/// priced; a preview probe failing never fails the consolidation itself (an
/// optional extra that can delete the action it decorates is worse than no
/// extra — the send-hint scar, SOURCE_OF_TRUTH §19).
pub async fn consolidate_prepare() -> Result<SignableSummaryDto, AppError> {
    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;
    let destination = payment_change_address()?;
    let exclude = super::transport::drain_exclusions()?;
    let signer: Arc<dyn SignerT> = Arc::new(wallet::wallet_signer()?);
    let rpc = dag::shared_monitor().await?.rpc();

    let prepared = engine
        .prepare_consolidate(destination, &exclude, signer, rpc)
        .await
        .map_err(map_drain_error)?;

    let savings = engine.consolidation_savings(&prepared).ok().flatten();

    let nonce = next_nonce();
    let summary = prepared.summary().clone();
    *PENDING_SEND.lock().unwrap_or_else(PoisonError::into_inner) = Some((nonce, prepared));
    let mut dto = project_signable(nonce, SignableKind::Consolidate, &summary, None);
    if let Some(saving) = savings {
        dto.typical_amount_sompi = Some(saving.amount_sompi);
        dto.typical_now_utxos = Some(saving.now_utxos);
        dto.typical_now_fee_sompi = Some(saving.now_fee_sompi);
        dto.typical_after_fee_sompi = Some(saving.after_fee_sompi);
    }
    Ok(dto)
}

/// Drain refusals arrive typed from the chain layer with their copy already
/// honest (each is a refusal, not a fault); the two families that need a
/// friendlier sentence than their Debug form are mapped here.
fn map_drain_error(e: ChainError) -> AppError {
    match e {
        ChainError::InsufficientFunds { .. } => {
            AppError::msg("these coins are worth less than the network fee to move them")
        }
        ChainError::Message(m) => AppError::msg(m),
        other => AppError::chain(other),
    }
}

/// Take the plan identified by `nonce` out of a stash. Refuses a
/// stale/mismatched nonce (putting the live plan back) or an empty stash —
/// the user re-confirms. Shared by the payment and transport commit paths.
pub(crate) fn take_stashed(
    stash: &Mutex<Option<(u64, PreparedSend)>>,
    nonce: u64,
) -> Result<PreparedSend, AppError> {
    let mut guard = stash.lock().unwrap_or_else(PoisonError::into_inner);
    match guard.take() {
        Some((stored, prepared)) if stored == nonce => Ok(prepared),
        Some((stored, prepared)) => {
            // Mismatch: put it back and refuse (the confirmed plan changed).
            *guard = Some((stored, prepared));
            Err(AppError::msg(
                "this send is no longer current — please review and confirm again",
            ))
        }
        None => Err(AppError::msg(
            "nothing to send — please start the send again",
        )),
    }
}

/// Sign + broadcast a taken plan, advancing the change cursor only on a
/// fully-broadcast outcome (D-041).
///
/// **The cursor is now vestigial and deliberately left alone.** Since
/// `payment_change_address` routes every send's change back to `receive/0`,
/// nothing consumes a `change/N` address — and this advance was already
/// meaningless for transport sends, which have always returned change to
/// `receive/0`. `wallet_window` floors the change window at `cursor + 1`, so
/// each such send widens the derived-and-registered window by one for nothing:
/// measured on the founder's device 2026-08-15, cursor **108** against a
/// handful of change addresses that ever held a coin. That is waste, not a
/// fault — it grows no faster than it did before and risks no funds — so it is
/// logged as follow-up rather than fixed inside a bug fix it does not belong
/// to (INV-12). Retiring it means retiring `set_change_cursor` and the
/// window floor together, under their own auditor pass.
pub(crate) async fn commit_and_advance(prepared: PreparedSend) -> SendOutcomeDto {
    // The change index this send used (neither input moves during a send —
    // the cursor advances only on full success, and the discovery mark that
    // floors it only ever grows — so this still reads as the index we prepared
    // with; a pass landing mid-send could only skip an index, never reuse one).
    let used_cursor = wallet::next_change_index();

    // V1 acceptance spine: resolve the tracker BEFORE committing so every
    // leg is watched the instant its submit is acked — a fast acceptance of
    // an early leg must not slip past the live VCC stream while later legs
    // are still broadcasting (consensus-audit finding 3). Partial-outcome
    // legs are covered by construction (the hook fired when they submitted).
    // One hook covers payments AND transport sends (both commit paths flow
    // through here); a tracker failure never fails the send.
    let tracker = match super::dag::shared_tracker().await {
        Ok(tracker) => Some(tracker),
        Err(e) => {
            log::warn!(
                "send: acceptance tracker unavailable ({}) — txids unwatched",
                e.message
            );
            None
        }
    };
    let mut hook = tracker.map(|tracker| {
        move |txid: &str, signed_tx: kaspaverse_chain::RpcTransaction| {
            tracker.watch(txid, kaspaverse_chain::WatchSource::Send);
            // V3 stall escalation: retain the signed wire form so a
            // stalled(T) can resubmit it via a fresh node (public broadcast
            // data only — INV-1/3 untouched; in-memory, TTL-pruned).
            let now_ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            // Submit-time endpoint captured WITH the tx: a later stall must
            // strike the node that took this submit, not whoever the socket
            // re-raced to since (consensus-audit finding).
            dag::retention().retain(txid, signed_tx, dag::current_endpoint_url(), now_ms);
        }
    });
    let outcome = prepared
        .commit(
            hook.as_mut()
                .map(|h| h as &mut (dyn FnMut(&str, kaspaverse_chain::RpcTransaction) + Send)),
        )
        .await;

    if fully_broadcast(&outcome) {
        // The change at `used_cursor` is now in use → next send uses the next.
        let _ = vault::set_change_cursor(used_cursor.saturating_add(1));
    }

    SendOutcomeDto {
        final_txid: outcome.final_txid,
        submitted: outcome.submitted,
        total: outcome.total,
        partial: outcome.partial,
        error: outcome.error,
    }
}

/// Phase 2: sign + broadcast the stashed plan identified by `nonce`. Refuses a
/// stale/mismatched nonce or an empty stash (the user re-confirms). Advances the
/// change cursor only on a fully-broadcast send.
pub async fn send_commit(nonce: u64) -> Result<SendOutcomeDto, AppError> {
    let prepared = take_stashed(&PENDING_SEND, nonce)?;
    Ok(commit_and_advance(prepared).await)
}

/// Drop any stashed send (confirm dismissed / back-gesture). Idempotent.
pub fn send_abandon() {
    *PENDING_SEND.lock().unwrap_or_else(PoisonError::into_inner) = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    // An upstream gen1 mainnet vector (keychain.rs / hd.rs) — valid checksum.
    const MAINNET: &str = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf";

    fn summary_fixture() -> SendSummary {
        SendSummary {
            destination: MAINNET.to_string(),
            amount_sompi: 20_000_000,
            fee_sompi: 31_000,
            total_sompi: 20_031_000,
            mass: 2_000,
            tx_count: 1,
            utxo_count: 1,
            payload_len: 154,
        }
    }

    /// V5: the reserved fee-strategy seam holds the ONE live strategy —
    /// `SenderPays` with zero priority (the Generator's `Fees::SenderPays(0)`)
    /// — on every projection, regardless of kind.
    #[test]
    fn project_signable_defaults_the_reserved_fee_strategy() {
        let dto = project_signable(
            7,
            SignableKind::SelfSendFrame,
            &summary_fixture(),
            Some("comm".to_string()),
        );
        assert_eq!(dto.fee_strategy, FeeStrategyKind::SenderPays);
        assert_eq!(dto.priority_fee_sompi, 0);
        assert_eq!(dto.nonce, 7);
        assert_eq!(dto.kind, SignableKind::SelfSendFrame);
        // Payload facts ride together, decoded from the built tx.
        assert_eq!(dto.payload_len, Some(154));
        assert_eq!(dto.payload_kind.as_deref(), Some("comm"));
    }

    /// V5 variant law: payment mode NEVER carries payload fields — the sheet
    /// can trust `None` structurally, not by caller convention.
    #[test]
    fn payment_kind_never_carries_payload_fields() {
        let dto = project_signable(1, SignableKind::Payment, &summary_fixture(), None);
        assert_eq!(dto.payload_len, None);
        assert_eq!(dto.payload_kind, None);
        // The numbers are the chain summary's, untouched (B7).
        assert_eq!(dto.amount_sompi, 20_000_000);
        assert_eq!(dto.fee_sompi, 31_000);
        assert_eq!(dto.total_sompi, 20_031_000);
    }

    #[test]
    fn validate_accepts_a_mainnet_address() {
        let address = validate_mainnet_address(MAINNET).unwrap();
        assert_eq!(address.prefix, Prefix::Mainnet);
    }

    #[test]
    fn validate_rejects_malformed_input() {
        assert!(validate_mainnet_address("not-an-address").is_err());
        assert!(validate_mainnet_address("").is_err());
        // A valid-looking but wrong checksum payload is rejected by the parser.
        assert!(validate_mainnet_address("kaspa:qqqqqqqq").is_err());
    }

    #[test]
    fn validate_rejects_a_wrong_network_address() {
        // Re-prefix the valid mainnet payload as testnet → a well-formed string
        // that must STILL be rejected on the network gate, not the parser.
        let main = Address::try_from(MAINNET).unwrap();
        let testnet =
            Address::new(Prefix::Testnet, main.version, main.payload.as_ref()).to_string();
        assert!(
            testnet.starts_with("kaspatest:"),
            "fabricated a testnet address"
        );
        let err = validate_mainnet_address(&testnet).unwrap_err();
        assert!(
            err.message.contains("mainnet"),
            "rejected for the right reason: {}",
            err.message
        );
    }

    #[test]
    fn cursor_advances_only_on_a_clean_full_broadcast() {
        let clean = SendOutcome {
            final_txid: Some("a".repeat(64)),
            submitted: 2,
            total: 2,
            partial: false,
            error: None,
            submitted_txids: vec!["b".repeat(64), "a".repeat(64)],
        };
        assert!(fully_broadcast(&clean));

        // Partial (a mid-chain failure) — must NOT advance.
        assert!(!fully_broadcast(&SendOutcome {
            partial: true,
            submitted: 1,
            ..clean.clone()
        }));
        // An error on the first leg — nothing broadcast, must NOT advance.
        assert!(!fully_broadcast(&SendOutcome {
            submitted: 0,
            total: 2,
            partial: false,
            error: Some("boom".into()),
            final_txid: None,
            submitted_txids: Vec::new(),
        }));
        // Degenerate zero-leg — never advances.
        assert!(!fully_broadcast(&SendOutcome {
            submitted: 0,
            total: 0,
            partial: false,
            error: None,
            final_txid: None,
            submitted_txids: Vec::new(),
        }));
    }

    #[test]
    fn shortfall_classifier_reads_both_in_flight_buckets() {
        // Our own settling change (outgoing bucket) — never "insufficient",
        // and outgoing wins even while incoming value is also maturing
        // (finding 7: the observed refusal minutes after a send).
        assert!(shortfall_message(1, 0, 0, 1).contains("still settling from your last send"));
        assert!(shortfall_message(10, 5, 5, 5).contains("still settling from your last send"));
        // Incoming value maturing — "not yet spendable".
        assert!(shortfall_message(1, 0, 1, 0).contains("not yet spendable"));
        // A true shortfall stays a true shortfall.
        assert!(shortfall_message(1, 0, 0, 0).contains("insufficient funds"));
        // An amount NOTHING in flight could ever cover is a true shortfall,
        // never a "try again in a few seconds" (consensus-audit V2 finding 2).
        assert!(shortfall_message(100, 10, 20, 30).contains("insufficient funds"));
        assert!(shortfall_message(100, 0, 0, 99).contains("insufficient funds"));
        // At the exact boundary the funds could settle — the transient
        // message stands (the fee may still refuse the retry, honestly).
        assert!(shortfall_message(60, 10, 20, 30).contains("still settling"));
    }

    #[test]
    fn kas_display_trims_honestly() {
        assert_eq!(kas_display(100_000_000), "1");
        assert_eq!(kas_display(10_000_000), "0.1");
        assert_eq!(kas_display(12_345_678), "0.12345678");
        assert_eq!(kas_display(23_000_000), "0.23");
        assert_eq!(kas_display(0), "0");
    }

    #[test]
    fn abandon_clears_the_stash() {
        // Synchronous safety: abandon is a no-op on an empty stash and leaves it
        // empty (the real fill path needs an engine; covered on-device).
        send_abandon();
        assert!(PENDING_SEND
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_none());
    }
}
