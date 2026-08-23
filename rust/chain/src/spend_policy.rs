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
//!      while more than one coin remains (the provable invariant —
//!      `send.rs::riders_strictly_drain_a_fragmented_wallet`).
//!    - **Marginal cost is bounded and stated:** at most `RIDER_LIMIT` extra
//!      inputs versus pure largest-first — ~1,118 grams ≈ 0.0011 KAS each at
//!      the pin's relay floor (measured, not hardcoded; the fee itself is
//!      always the Generator's). The rider can also SERVE as the extra input
//!      the Generator pulls on its own for KIP-9 storage-mass relief
//!      (`generator.rs:838-852`), in which case part of that margin is free.
//!    - **A rider never adds a transaction to the chain.** Enforced by
//!      construction, not prediction: `send.rs` generates with riders, and if
//!      the chain is longer than one transaction it regenerates without riders
//!      and keeps the shorter chain (`prepare_send_inner`). No mass arithmetic
//!      of ours is involved (INV-9).
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
//! **What this deliberately does not do:** no fee estimation, no mass math, no
//! dust threshold of our own — a "fragment" is simply "currently smallest";
//! the Generator alone decides what a transaction costs and whether it builds.

use std::collections::HashSet;

use kaspa_wallet_core::utxo::UtxoEntryReference;

/// How many of the wallet's smallest coins ride along on every send — see the
/// module doc for the derivation and the bounded, stated marginal cost.
pub(crate) const RIDER_LIMIT: usize = 2;

/// The complete spend order for one send, expressed as the Generator's
/// priority-entry list: `pinned` (largest-first among itself, wholly first —
/// input[0] identity, D-067) ++ up to `riders` smallest pool coins (smallest
/// first, so the fragment drain starts at the bottom) ++ the remaining pool
/// largest-first.
///
/// Pure and synchronous: `mature` is a snapshot of the live context's mature
/// set, `pinned` the caller's pinned entries (usually a subset of `mature`;
/// de-duplicated here by outpoint identity, the same identity the Generator's
/// own priority filter uses). A coin that matures AFTER the snapshot is not in
/// this list and simply flows through the context iterator behind it — still
/// spendable, merely last in line.
pub(crate) fn select_spend_priority(
    mature: &[UtxoEntryReference],
    pinned: &[UtxoEntryReference],
    riders: usize,
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

    let mut order: Vec<UtxoEntryReference> = pinned.to_vec();
    order.sort_by_key(|entry| std::cmp::Reverse(entry.amount()));

    // Riders: the pool's tail (its smallest), reversed so the very smallest
    // coin is drawn first.
    let rider_count = pool.len().min(riders);
    let keep = pool.len() - rider_count;
    order.extend(pool[keep..].iter().rev().cloned());
    pool.truncate(keep);

    order.extend(pool);
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
        let order = select_spend_priority(&mature, &[], RIDER_LIMIT);
        // Two smallest lead (smallest first), then the rest descending.
        assert_eq!(amounts(&order), kas(&[0.5, 2.0, 200.0, 10.0, 5.0]));
    }

    #[test]
    fn no_riders_is_pure_largest_first() {
        let mature: Vec<_> = [5.0, 0.5, 200.0, 2.0, 10.0].map(entry).into();
        let order = select_spend_priority(&mature, &[], 0);
        assert_eq!(amounts(&order), kas(&[200.0, 10.0, 5.0, 2.0, 0.5]));
    }

    #[test]
    fn pinned_block_stays_wholly_first_and_is_deduped_from_the_pool() {
        let pinned: Vec<_> = [0.3, 7.0].map(entry).into();
        let mut mature: Vec<_> = [5.0, 0.5, 200.0].map(entry).into();
        // The pinned entries are also in the mature snapshot (they always are
        // in production — mature_utxos_at reads the same context).
        mature.extend(pinned.iter().cloned());
        let order = select_spend_priority(&mature, &pinned, RIDER_LIMIT);
        // Pinned first (descending among itself: 7.0 then 0.3), then the two
        // smallest pool coins as riders, then the rest descending. The pinned
        // coins appear exactly once.
        assert_eq!(amounts(&order), kas(&[7.0, 0.3, 0.5, 5.0, 200.0]));
        assert_eq!(order.len(), 5, "pinned entries are not duplicated");
    }

    #[test]
    fn a_wallet_smaller_than_the_rider_limit_is_taken_whole() {
        let mature: Vec<_> = [3.0].map(entry).into();
        let order = select_spend_priority(&mature, &[], RIDER_LIMIT);
        assert_eq!(amounts(&order), kas(&[3.0]));
        assert!(select_spend_priority(&[], &[], RIDER_LIMIT).is_empty());
    }
}
