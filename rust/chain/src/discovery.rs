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

use kaspa_addresses::Address;
use kaspa_wallet_core::rpc::Rpc;

use crate::error::{ChainError, Result};

/// Addresses per `get_balances_by_addresses` round trip. The node accepts large
/// batches; this bounds a single request's size so one slow call cannot stall a
/// whole scan, and keeps the failure blast radius to one chunk.
pub const PROBE_BATCH: usize = 128;

/// Probe `addresses` for a non-zero balance and return the **position of the
/// highest funded entry**, or `None` when the whole range is empty.
///
/// The return is an index into the slice the caller passed, so a caller that
/// derives `0..depth` for one branch gets back that branch's high-water mark
/// directly. Entries are matched **by address, not by response order** — the RPC
/// contract does not promise the node echoes the request order, and silently
/// trusting it would misattribute a balance to the wrong index, which on this
/// code path means deriving the wrong signing key.
pub async fn highest_funded_index(rpc: &Rpc, addresses: &[Address]) -> Result<Option<u32>> {
    if addresses.is_empty() {
        return Ok(None);
    }

    let mut highest: Option<u32> = None;

    for (chunk_no, chunk) in addresses.chunks(PROBE_BATCH).enumerate() {
        let base = (chunk_no * PROBE_BATCH) as u32;
        let entries = rpc
            .rpc_api()
            .get_balances_by_addresses(chunk.to_vec())
            .await
            .map_err(|e| ChainError::Message(format!("address discovery probe failed: {e}")))?;

        for entry in entries {
            // `balance: Option<u64>` — `None` means the node had no answer for
            // that address, which is NOT the same as zero. Treat only a positive
            // balance as evidence of funds; absence of evidence never widens the
            // window, and never narrows it either.
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
    }

    Ok(highest)
}
