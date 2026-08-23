//! Spend-selection policy — WHICH coins fund a send, and in what order.
//!
//! This module is wallet POLICY, not consensus: every fee, mass and validity
//! number still comes from the pinned Generator (INV-9, D-051). The only thing
//! decided here is the order in which the wallet's own mature UTXOs are offered
//! to it, expressed through the Generator's native priority-entry facility
//! (`generator.rs:588-614` @ `cfafeb4`: priority entries are consumed in list
//! order BEFORE the context iterator, and are de-duplicated out of that
//! iterator by outpoint identity — so a full ordering handed as priority is a
//! complete selection policy with the live `UtxoContext` bookkeeping intact).
//!
//! ## The policy, and why it replaces the pin's own order
//!
//! The pinned `UtxoContext` keeps its mature set sorted ASCENDING
//! (`utxo/context.rs:483`), so an unadorned send spends the wallet's smallest
//! coins first. That is a deliberate upstream dust-hygiene strategy — it grinds
//! the fragment pile down and keeps the UTXO set small — but it bills the user
//! up front: measured 2026-08-13 against the real Generator, a 100 KAS payment
//! from a fragmented wallet drew 22 inputs and paid ~12.5× the one-input floor,
//! while every extra input buys ~1,118 grams of compute mass at the relay
//! floor. (The permanent reproduction lives in `send.rs`'s
//! `spend_policy_table_*` tests — if a pin bump moves those numbers, the tests
//! say so; nothing here hardcodes them.)
//!
//! We choose the other point on the same trade-off, as recorded wallet policy:
//!
//! 1. **Largest-first funding.** The bulk of a payment is funded by the largest
//!    coins, so an ordinary send carries the fewest inputs the Generator needs
//!    — the same order Kaspium ships, and the reason its fees sit at the floor.
//! 2. **The dust rider — the debt we owe the hygiene goal.** Largest-first
//!    alone NEVER drains fragments; the pile only grows (every send's change,
//!    every small receive), and a wallet used for a year becomes permanently
//!    expensive. So every send also carries up to [`RIDER_LIMIT`] of the
//!    wallet's smallest coins, placed FIRST in the order so the Generator
//!    cannot skip them once it starts drawing. The rule:
//!
//!    - `RIDER_LIMIT = 2`, derived from the steady-state churn of a used
//!      wallet: one send emits one change output, and roughly one small receive
//!      lands between sends (chat/arcade traffic), so two absorptions per send
//!      hold the line at steady state and strictly drain any quieter wallet. A
//!      funded send consumes `base + riders ≥ 1 + riders` inputs and returns at
//!      most one change output, so the wallet's UTXO count strictly decreases
//!      while more than one coin remains — provable, and proved, in
//!      `send.rs::riders_strictly_drain_a_fragmented_wallet`, which models the
//!      shape the wallet actually SHIPS rather than this order alone.
//!    - **Marginal cost is bounded and stated:** at most `RIDER_LIMIT` extra
//!      inputs versus pure largest-first — ~1,118 grams ≈ 0.0011 KAS each at
//!      the pin's relay floor (measured, not hardcoded; the fee itself is
//!      always the Generator's). The rider can also SERVE as the extra input
//!      the Generator pulls on its own for KIP-9 storage-mass relief
//!      (`generator.rs:838-852`), in which case part of that margin is free.
//!    - **A rider never adds a transaction to the chain**, and **never costs
//!      more than the coin it collects** (`send.rs::riderless_wins`, D-171).
//!      Both are enforced by construction, not prediction: `send.rs` generates
//!      the send with riders and without, and the pinned Generator's own two
//!      answers decide. Where the cheap shape would leave change the wallet
//!      could not then send alone, or would decline a coin worth more than the
//!      fee it saves, the riders stay. No mass arithmetic of ours is involved
//!      (INV-9). This module chooses the ORDER; `send.rs` chooses between the
//!      two orders' built results.
//!
//! 3. **The pin composes.** A pinned send (D-067 source-address discipline, the
//!    L47 scar: the counterpart resolves our identity from input[0]'s
//!    prev-output) keeps its pinned block wholly FIRST — reordered
//!    largest-first among itself, so a covered conversation send stays
//!    one-input-cheap — followed by riders, then the rest descending. Riders on
//!    a pinned send are therefore opportunistic: they ride only when the pinned
//!    block cannot cover the send alone (input[0] identity outranks hygiene).
//!
//! **Privacy, recorded rather than sleepwalked into:** largest-first plus
//! riders consolidates coins and therefore linkage — inputs from unrelated
//! receives co-spend earlier and more often than under smallest-first. This
//! project has no privacy invariant that forbids that, and the pinned wallet's
//! own order already links freely; this line exists so the choice is on the
//! record (see DECISION_LOG).
//!
//! 4. **Reserved coins go last.** The bound address of every live conversation
//!    is DEMOTED to the tail of the order rather than withheld (D-169) — see
//!    [`select_spend_priority`]'s note for why a payment may never be refused
//!    to protect a chat binding, and why the same address set is a hard custody
//!    line for a drain but only a preference here.
//!
//! **What this deliberately does not do:** no fee estimation, no mass math, no
//! dust threshold of our own — a "fragment" is simply "currently smallest";
//! the Generator alone decides what a transaction costs and whether it builds.

use std::collections::HashSet;

use kaspa_wallet_core::prelude::Address;
use kaspa_wallet_core::utxo::UtxoEntryReference;

/// How many of the wallet's smallest coins ride along on every send — see the
/// module doc for the derivation and the bounded, stated marginal cost.
pub(crate) const RIDER_LIMIT: usize = 2;

/// Is this coin RESERVED for a conversation — or unprovably free?
///
/// The one definition of the reservation test, so the ordering policy and the
/// observability that reports on it can never disagree. Fails CLOSED: an
/// address-less coin is reserved (see the note on [`select_spend_priority`]).
pub(crate) fn is_reserved(entry: &UtxoEntryReference, exclude: &[Address]) -> bool {
    // Reads exactly as the rule states: no address to match, OR a match.
    entry
        .utxo
        .address
        .as_ref()
        .is_none_or(|address| exclude.contains(address))
}

/// The complete spend order for one send, expressed as the Generator's
/// priority-entry list: `pinned` (largest-first among itself, wholly first —
/// input[0] identity, D-067) ++ up to `riders` smallest FREE coins (smallest
/// first, so the fragment drain starts at the bottom) ++ the remaining free
/// coins largest-first ++ the RESERVED coins, largest-first, dead last.
///
/// Pure and synchronous: `mature` is a snapshot of the live context's mature
/// set, `pinned` the caller's pinned entries (usually a subset of `mature`;
/// de-duplicated here by outpoint identity, the same identity the Generator's
/// own priority filter uses). A coin that matures AFTER the snapshot is not in
/// this list and simply flows through the context iterator behind it — still
/// spendable, merely last in line.
///
/// ## `exclude` — reserved coins, demoted rather than withheld
///
/// The bound own-address of every live conversation (`drain_exclusions`).
/// Since D-148 nothing refills a non-identity bound address, so an ordinary
/// payment that drew one could strand a conversation with no way to send until
/// it is hand-refilled — the open item at `await_spendable_at`, narrowed by the
/// rider law (riders draw strictly fewer small coins than the pin's ascending
/// order) but not closed by it.
///
/// Reserved coins sort **dead last**; they are not removed. That is the whole
/// design, and it is what makes the "what if everything else is excluded"
/// question have no answer to give: there is no shortfall path, because a
/// payment the free coins cannot fund simply keeps drawing into the reserved
/// tail. **A payment is the wallet's core function and may never be refused to
/// protect a chat binding** — a stranded conversation is recoverable, a wallet
/// that will not send is not (INV-6 in spirit). For a DRAIN the same set is a
/// custody line, enforced on the built transaction (`verify_drain`); here it is
/// a preference. Same addresses, deliberately different force.
///
/// Riders are drawn from the FREE coins only: a rider is a deliberate
/// absorption, and absorbing a conversation's coin is exactly the harm.
///
/// Fails CLOSED on the corner the pin's types leave open, the same way
/// `drain_included` does: a coin whose `utxo.address` is `None` cannot be
/// matched against the reserved set, so it is treated as reserved. Unreachable
/// for coins this context scanned (they arrive via address registration), but
/// the type says `Option` and the code refuses to guess.
pub(crate) fn select_spend_priority(
    mature: &[UtxoEntryReference],
    pinned: &[UtxoEntryReference],
    riders: usize,
    exclude: &[Address],
) -> Vec<UtxoEntryReference> {
    let pinned_outpoints: HashSet<&UtxoEntryReference> = pinned.iter().collect();
    // A duplicated outpoint inside `pinned` would ride the Generator's priority
    // queue twice and build a transaction the node rejects (liveness, not fund
    // loss). Both current callers are duplicate-free by construction; keep any
    // future one loud in debug builds.
    debug_assert_eq!(
        pinned_outpoints.len(),
        pinned.len(),
        "pinned entries must be unique by outpoint"
    );
    let mut pool: Vec<UtxoEntryReference> = mature
        .iter()
        .filter(|entry| !pinned_outpoints.contains(entry))
        .cloned()
        .collect();
    // Descending; ties keep snapshot order (stable sort ⇒ deterministic).
    pool.sort_by_key(|entry| std::cmp::Reverse(entry.amount()));

    // Reserved coins split off the bottom of the order. `partition` keeps the
    // relative order inside both halves, so both stay descending.
    let (mut pool, reserved): (Vec<UtxoEntryReference>, Vec<UtxoEntryReference>) =
        if exclude.is_empty() {
            (pool, Vec::new())
        } else {
            pool.into_iter()
                .partition(|entry| !is_reserved(entry, exclude))
        };

    let mut order: Vec<UtxoEntryReference> = pinned.to_vec();
    order.sort_by_key(|entry| std::cmp::Reverse(entry.amount()));

    // Riders: the FREE pool's tail (its smallest), reversed so the very
    // smallest coin is drawn first.
    let rider_count = pool.len().min(riders);
    let keep = pool.len() - rider_count;
    order.extend(pool[keep..].iter().rev().cloned());
    pool.truncate(keep);

    order.extend(pool);
    order.extend(reserved);
    order
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_wallet_core::utils::kaspa_to_sompi;

    fn entry(kas: f64) -> UtxoEntryReference {
        UtxoEntryReference::simulated(kaspa_to_sompi(kas))
    }

    fn amounts(order: &[UtxoEntryReference]) -> Vec<u64> {
        order.iter().map(|e| e.amount()).collect()
    }

    fn kas(values: &[f64]) -> Vec<u64> {
        values.iter().map(|v| kaspa_to_sompi(*v)).collect()
    }

    #[test]
    fn unpinned_order_is_riders_then_largest_first() {
        let mature: Vec<_> = [5.0, 0.5, 200.0, 2.0, 10.0].map(entry).into();
        let order = select_spend_priority(&mature, &[], RIDER_LIMIT, &[]);
        // Two smallest lead (smallest first), then the rest descending.
        assert_eq!(amounts(&order), kas(&[0.5, 2.0, 200.0, 10.0, 5.0]));
    }

    #[test]
    fn no_riders_is_pure_largest_first() {
        let mature: Vec<_> = [5.0, 0.5, 200.0, 2.0, 10.0].map(entry).into();
        let order = select_spend_priority(&mature, &[], 0, &[]);
        assert_eq!(amounts(&order), kas(&[200.0, 10.0, 5.0, 2.0, 0.5]));
    }

    #[test]
    fn pinned_block_stays_wholly_first_and_is_deduped_from_the_pool() {
        let pinned: Vec<_> = [0.3, 7.0].map(entry).into();
        let mut mature: Vec<_> = [5.0, 0.5, 200.0].map(entry).into();
        // The pinned entries are also in the mature snapshot (they always are
        // in production — mature_utxos_at reads the same context).
        mature.extend(pinned.iter().cloned());
        let order = select_spend_priority(&mature, &pinned, RIDER_LIMIT, &[]);
        // Pinned first (descending among itself: 7.0 then 0.3), then the two
        // smallest pool coins as riders, then the rest descending. The pinned
        // coins appear exactly once.
        assert_eq!(amounts(&order), kas(&[7.0, 0.3, 0.5, 5.0, 200.0]));
        assert_eq!(order.len(), 5, "pinned entries are not duplicated");
    }

    fn addr(s: &str) -> Address {
        Address::try_from(s).unwrap()
    }

    /// Two real mainnet addresses; only the script SHAPE matters here.
    const FREE: &str = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf";
    const BOUND: &str = "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692";

    fn at(kas: f64, address: &str) -> UtxoEntryReference {
        UtxoEntryReference::simulated_with_address(kaspa_to_sompi(kas), &addr(address))
    }

    /// A conversation's coins sort DEAD LAST — behind every free coin, and
    /// behind the riders, which are drawn only from the free pool. The
    /// Generator therefore reaches them only when nothing else covers the send.
    #[test]
    fn reserved_coins_sort_behind_everything_including_the_riders() {
        let mature = vec![
            at(3.0, BOUND),
            at(0.4, FREE),
            at(50.0, FREE),
            at(0.2, BOUND),
            at(1.0, FREE),
        ];
        let order = select_spend_priority(&mature, &[], RIDER_LIMIT, &[addr(BOUND)]);
        // Free riders (0.4 then 1.0 — smallest first), free rest (50.0), then
        // the reserved pair descending.
        assert_eq!(amounts(&order), kas(&[0.4, 1.0, 50.0, 3.0, 0.2]));
        assert_eq!(order.len(), mature.len(), "demoted, never withheld");
    }

    /// The liveness half, stated as a test: a payment the free coins cannot
    /// cover still has every reserved coin available behind them. There is no
    /// shortfall path to get wrong because there is no withholding.
    #[test]
    fn a_wallet_whose_free_coins_are_all_reserved_still_offers_everything() {
        let mature = vec![at(2.0, BOUND), at(5.0, BOUND)];
        let order = select_spend_priority(&mature, &[], RIDER_LIMIT, &[addr(BOUND)]);
        assert_eq!(
            amounts(&order),
            kas(&[5.0, 2.0]),
            "all of it, largest-first"
        );
    }

    /// Fails CLOSED on the corner the pin's types leave open: a coin with no
    /// address cannot be matched against the reserved set, so it is treated as
    /// reserved. (Mutation fence — flipping `is_reserved`'s `is_none_or` to
    /// `is_some_and` reds this and nothing else.)
    #[test]
    fn an_addressless_coin_is_reserved_not_assumed_free() {
        // `simulated` still carries a random address at the pin, and the pin
        // exposes no way to build one without — so clear the field the same way
        // `send.rs::an_addressless_coin_is_never_offered_under_exclusions`
        // does, over the pin's own `Option`.
        let mut nameless = UtxoEntryReference::simulated(kaspa_to_sompi(9.0));
        {
            let utxo = std::sync::Arc::get_mut(&mut nameless.utxo)
                .expect("freshly built simulated entry has one owner");
            utxo.address = None;
        }
        let mature = vec![nameless, at(1.0, FREE)];
        let order = select_spend_priority(&mature, &[], 0, &[addr(BOUND)]);
        assert_eq!(
            amounts(&order),
            kas(&[1.0, 9.0]),
            "the address-less coin sorts last despite being the largest"
        );
        assert!(is_reserved(&order[1], &[addr(BOUND)]));
    }

    /// The pinned block outranks the reservation: a conversation spending from
    /// its OWN binding is exactly what the reservation protects, so pinned
    /// entries leave the pool before any demotion and stay at input[0].
    #[test]
    fn the_pinned_block_is_never_demoted_by_its_own_reservation() {
        let pinned = vec![at(0.3, BOUND)];
        let mut mature = vec![at(7.0, FREE), at(4.0, BOUND)];
        // The pinned entries are also in the mature snapshot, as they always
        // are in production (`mature_utxos_at` reads the same context).
        mature.extend(pinned.iter().cloned());
        let order = select_spend_priority(&mature, &pinned, RIDER_LIMIT, &[addr(BOUND)]);
        assert_eq!(amounts(&order), kas(&[0.3, 7.0, 4.0]));
    }

    /// No reservations ⇒ the pre-D-169 order: riders then largest-first, with
    /// the bound coin treated like any other. The SAME coin set with the
    /// reservation applied sorts differently — which is what makes the first
    /// assertion an observation rather than a tautology.
    #[test]
    fn an_empty_reservation_set_changes_nothing() {
        let mature = vec![at(3.0, BOUND), at(0.4, FREE), at(50.0, FREE)];
        assert_eq!(
            amounts(&select_spend_priority(&mature, &[], RIDER_LIMIT, &[])),
            kas(&[0.4, 3.0, 50.0]),
            "no reservations: 3.0 rides as an ordinary small coin"
        );
        assert_eq!(
            amounts(&select_spend_priority(
                &mature,
                &[],
                RIDER_LIMIT,
                &[addr(BOUND)]
            )),
            kas(&[0.4, 50.0, 3.0]),
            "reserved: it leaves the rider slot and sorts last"
        );
    }

    #[test]
    fn a_wallet_smaller_than_the_rider_limit_is_taken_whole() {
        let mature: Vec<_> = [3.0].map(entry).into();
        let order = select_spend_priority(&mature, &[], RIDER_LIMIT, &[]);
        assert_eq!(amounts(&order), kas(&[3.0]));
        assert!(select_spend_priority(&[], &[], RIDER_LIMIT, &[]).is_empty());
    }
}
