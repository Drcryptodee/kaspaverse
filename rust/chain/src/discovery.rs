//! Address discovery — finding how deep a wallet's used address range goes.
//!
//! **Why this is balance-driven and not history-driven.** BIP44's classic gap
//! rule ("stop after N consecutive *unused* addresses") needs an oracle for *was
//! this address ever used*, which means transaction history. A Kaspa node is a
//! UTXO-state machine: it can answer *what does this address hold right now* and
//! nothing else. History lives in indexers, and INV-8 forbids trusting one.
//!
//! So we discover by **current balance**, which is the question that actually
//! matters here — we are hunting spendable funds, not doing archaeology. State
//! the bound honestly, because it is a real one: an address that was used and
//! then fully swept is invisible to this scan. The window therefore follows
//! where money **is**, never where money **was**.
//!
//! That distinction is not academic. It is exactly why the naive rule would have
//! failed the case this module was written for: a wallet whose change indices
//! 0..=76 had all been spent, with the only funded output at index 77. A
//! use-triggered rolling scan sees ~20 consecutive empty addresses and stops
//! around index 20, having walked straight past nothing — because there was
//! nothing to see. A depth-first balance probe finds index 77.
//!
//! INV-9: the probe is `get_balances_by_addresses` from the pinned crates
//! (`rpc/core/src/api/rpc.rs:351` at rev `cfafeb4`), never a re-implementation.

use std::future::Future;
use std::time::Duration;

use kaspa_addresses::Address;
use kaspa_rpc_core::RpcBalancesByAddressesEntry;
use kaspa_wallet_core::rpc::Rpc;

use crate::error::{ChainError, Result};

/// Addresses per `get_balances_by_addresses` round trip. The node accepts large
/// batches; this bounds a single request's size so one slow call cannot stall a
/// whole scan, and keeps the failure blast radius to one chunk.
pub const PROBE_BATCH: usize = 128;

/// Deadline for ONE probe round trip. The call is already pin-bounded — the
/// wrpc reaper errors overdue pending calls (`timeout_duration` 60 000 ms swept
/// every 5 000 ms, `wrpc client/mod.rs:151-152, 187-198`), so ≈65 s worst case
/// — but discovery sits on the unlock path, in front of the first balance, and
/// this codebase already ruled on that shape: a user-facing await gets an
/// explicit bound of ours (`LISTENER_UNREGISTER_TIMEOUT`, `PAGE_TIMEOUT`,
/// `SOFT_RESCAN_TIMEOUT`). 10 s is that tier; the caller retries on the next
/// `Connected` rather than living with the answer.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// Probe `addresses` for a non-zero balance and return the **position of the
/// highest funded entry**, or `None` when the whole range is empty.
///
/// The return is an index into the slice the caller passed, so a caller that
/// derives `0..depth` for one branch gets back that branch's high-water mark
/// directly.
pub async fn highest_funded_index(rpc: &Rpc, addresses: &[Address]) -> Result<Option<u32>> {
    scan_chunks(addresses, |chunk| async move {
        match tokio::time::timeout(
            PROBE_TIMEOUT,
            rpc.rpc_api().get_balances_by_addresses(chunk),
        )
        .await
        {
            Ok(Ok(entries)) => Ok(entries),
            Ok(Err(e)) => Err(ChainError::Message(format!(
                "address discovery probe failed: {e}"
            ))),
            Err(_) => Err(ChainError::Message(format!(
                "address discovery probe timed out ({} s)",
                PROBE_TIMEOUT.as_secs()
            ))),
        }
    })
    .await
}

/// The chunk walk, split from its transport so it can be tested (the
/// `history_fill::walk_pages` pattern — pure policy, injectable fetch). An empty
/// input never calls `probe` at all: `chunks()` yields nothing, so no round trip
/// is spent asking the node about no addresses.
async fn scan_chunks<F, Fut>(addresses: &[Address], mut probe: F) -> Result<Option<u32>>
where
    F: FnMut(Vec<Address>) -> Fut,
    Fut: Future<Output = Result<Vec<RpcBalancesByAddressesEntry>>>,
{
    let mut highest: Option<u32> = None;
    for (chunk_no, chunk) in addresses.chunks(PROBE_BATCH).enumerate() {
        let base = (chunk_no * PROBE_BATCH) as u32;
        let entries = probe(chunk.to_vec()).await?;
        if let Some(index) = highest_funded_in_chunk(base, chunk, &entries) {
            highest = Some(highest.map_or(index, |h: u32| h.max(index)));
        }
    }
    Ok(highest)
}

/// Reduce one chunk's response to the highest funded index within it, where
/// `base` is the index the chunk starts at in the caller's full slice.
///
/// Entries are matched **by address, not by response order** — the RPC contract
/// does not promise the node echoes the request order, and silently trusting it
/// would misattribute a balance to the wrong index, which on this code path
/// means deriving the wrong signing key. (At this rev the server does echo
/// order, building one entry per requested address in sequence —
/// `rpc/service/src/service.rs:840-847` — so this is stricter than the pin
/// requires. That is the correct direction to be wrong in.)
fn highest_funded_in_chunk(
    base: u32,
    chunk: &[Address],
    entries: &[RpcBalancesByAddressesEntry],
) -> Option<u32> {
    let mut highest: Option<u32> = None;
    for entry in entries {
        // `balance: Option<u64>` — at the pin the server builds one entry per
        // REQUESTED address with `balance = entry_map.get(&script).copied()`
        // (`rpc/service/src/service.rs:840-847`), so `None` means the address
        // has no indexed UTXOs: exactly zero, not "no answer". Either way the
        // treatment is the same — only a positive balance widens the window.
        if entry.balance.unwrap_or(0) == 0 {
            continue;
        }
        let Some(offset) = chunk.iter().position(|a| *a == entry.address) else {
            // An address we did not ask about. Refuse to guess its index.
            continue;
        };
        let index = base + offset as u32;
        highest = Some(highest.map_or(index, |h: u32| h.max(index)));
    }
    highest
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_addresses::{Prefix, Version};

    /// A distinct, valid mainnet address per index — the reduction only ever
    /// compares addresses for equality, so the payload just has to be unique.
    fn addr(i: u32) -> Address {
        let mut payload = [0u8; 32];
        payload[..4].copy_from_slice(&i.to_le_bytes());
        Address::new(Prefix::Mainnet, Version::PubKey, &payload)
    }

    fn addrs(n: u32) -> Vec<Address> {
        (0..n).map(addr).collect()
    }

    fn entry(address: Address, balance: Option<u64>) -> RpcBalancesByAddressesEntry {
        RpcBalancesByAddressesEntry { address, balance }
    }

    /// The node's honest answer: one entry per requested address, in order.
    fn all_empty(chunk: &[Address]) -> Vec<RpcBalancesByAddressesEntry> {
        chunk.iter().map(|a| entry(a.clone(), Some(0))).collect()
    }

    /// Run a scan against a scripted node. Returns `(result, chunk_sizes_asked)`.
    async fn scan(
        addresses: &[Address],
        mut respond: impl FnMut(&[Address]) -> Result<Vec<RpcBalancesByAddressesEntry>>,
    ) -> (Result<Option<u32>>, Vec<usize>) {
        let mut asked: Vec<usize> = Vec::new();
        let result = scan_chunks(addresses, |chunk| {
            asked.push(chunk.len());
            let answer = respond(&chunk);
            async move { answer }
        })
        .await;
        (result, asked)
    }

    #[tokio::test]
    async fn an_empty_range_costs_no_round_trip() {
        let (found, asked) = scan(&[], |_| panic!("probed an empty address list")).await;
        assert_eq!(found.unwrap(), None);
        assert!(asked.is_empty(), "an empty scan must not ask the node");
    }

    #[tokio::test]
    async fn funded_at_index_zero_is_found_and_is_not_nothing() {
        let all = addrs(10);
        let (found, _) = scan(&all, |chunk| {
            let mut entries = all_empty(chunk);
            entries[0] = entry(chunk[0].clone(), Some(1));
            Ok(entries)
        })
        .await;
        assert_eq!(found.unwrap(), Some(0));
    }

    #[tokio::test]
    async fn a_wholly_empty_range_reports_nothing_found() {
        let all = addrs(10);
        let (found, _) = scan(&all, |chunk| Ok(all_empty(chunk))).await;
        assert_eq!(found.unwrap(), None);
    }

    #[tokio::test]
    async fn funded_in_the_second_chunk_carries_the_chunk_offset() {
        // The `base = chunk_no * PROBE_BATCH` arithmetic, on the DEFAULT path:
        // a 256-deep pass is two chunks, so index 129 is offset 1 of chunk 1.
        // Get `base` wrong and this reports 1 — the founder's funds all over
        // again, one window narrower than the truth.
        let all = addrs(256);
        let target = addr(129);
        let (found, asked) = scan(&all, |chunk| {
            let mut entries = all_empty(chunk);
            if let Some(pos) = chunk.iter().position(|a| *a == target) {
                entries[pos] = entry(target.clone(), Some(42));
            }
            Ok(entries)
        })
        .await;
        assert_eq!(found.unwrap(), Some(129));
        assert_eq!(asked, vec![PROBE_BATCH, PROBE_BATCH], "two chunks of 128");
    }

    #[tokio::test]
    async fn the_highest_hit_wins_across_chunks() {
        let all = addrs(256);
        let (found, _) = scan(&all, |chunk| {
            let mut entries = all_empty(chunk);
            for (pos, a) in chunk.iter().enumerate() {
                if *a == addr(3) || *a == addr(200) {
                    entries[pos] = entry(a.clone(), Some(7));
                }
            }
            Ok(entries)
        })
        .await;
        assert_eq!(found.unwrap(), Some(200));
    }

    #[tokio::test]
    async fn an_out_of_order_response_is_attributed_by_address_not_position() {
        // The whole reason we match by address. Position 0 of the response
        // carries the balance for index 5; trusting order would report 0 and
        // leave index 5's coins outside the window.
        let all = addrs(10);
        let (found, _) = scan(&all, |chunk| {
            let mut entries: Vec<_> = all_empty(chunk);
            entries.reverse();
            let pos = entries
                .iter()
                .position(|e| e.address == addr(5))
                .expect("address 5 in the response");
            entries[pos] = entry(addr(5), Some(9));
            Ok(entries)
        })
        .await;
        assert_eq!(found.unwrap(), Some(5));
    }

    #[tokio::test]
    async fn an_unrequested_address_is_refused_never_guessed() {
        // A node that answers about something we did not ask about must not be
        // able to move our signing window — not even by one index.
        let all = addrs(4);
        let (found, _) = scan(&all, |chunk| {
            let mut entries = all_empty(chunk);
            entries.push(entry(addr(9_999), Some(1_000_000)));
            Ok(entries)
        })
        .await;
        assert_eq!(found.unwrap(), None);
    }

    #[tokio::test]
    async fn a_none_balance_is_zero_at_the_pin_and_never_widens_the_window() {
        // `None` = no indexed UTXOs for that address (service.rs:840-847).
        let all = addrs(4);
        let (found, _) = scan(&all, |chunk| {
            Ok(chunk.iter().map(|a| entry(a.clone(), None)).collect())
        })
        .await;
        assert_eq!(found.unwrap(), None);
    }

    #[tokio::test]
    async fn a_failed_chunk_fails_the_scan_rather_than_reporting_a_short_answer() {
        // Half a scan is a NARROWER window than the truth, and the caller's
        // marks are monotonic — a short answer would look like a valid, smaller
        // discovery. It must surface as an error so the caller keeps its last
        // known-good window and retries.
        let all = addrs(256);
        let (found, asked) = scan(&all, |chunk| {
            if chunk.iter().any(|a| *a == addr(0)) {
                Ok(all_empty(chunk))
            } else {
                Err(ChainError::Message("socket down".into()))
            }
        })
        .await;
        assert!(found.is_err());
        assert_eq!(asked.len(), 2, "stops at the failing chunk");
    }
}
