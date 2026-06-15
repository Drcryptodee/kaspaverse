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

use kaspaverse_chain::{Address, ChainError, PreparedSend, SendOutcome, SignerT};
use kaspaverse_core::Prefix;

use crate::api::error::AppError;
use crate::api::{dag, vault, wallet};

/// The Rust-decoded summary the confirm screen renders (B7) — NOT the form echo.
/// `nonce` guards [`send_commit`] against a stale plan; `*_sompi`/`mass` cross as
/// Dart `BigInt` (L3).
#[derive(Clone, Debug)]
pub struct SendSummaryDto {
    /// Opaque token tying this summary to its stashed transactions.
    pub nonce: u64,
    /// The mainnet address Rust validated and built into the payment output.
    pub destination: String,
    pub amount_sompi: u64,
    /// The Generator's exact aggregate fee — never "≈ free" (KIP-9 storage mass).
    pub fee_sompi: u64,
    /// `amount + fee` (what leaves the wallet, excluding returned change).
    pub total_sompi: u64,
    pub mass: u64,
    /// 1 normally; >1 when the send chained past one tx's 100k-gram mass.
    pub tx_count: u32,
    pub utxo_count: u32,
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
/// live nonce.
static NONCE: AtomicU64 = AtomicU64::new(1);

/// Parse `s` as a mainnet Kaspa address, rejecting malformed input and a
/// wrong-network (e.g. testnet) address up front (DS-8) — the Generator's own
/// prefix check (generator.rs:389/418) is the backstop, not the only gate.
fn validate_mainnet_address(s: &str) -> Result<Address, AppError> {
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

/// Phase 1: validate, build the tx chain over the live UTXO context, and stash
/// the unsigned transactions. Returns the Rust-decoded summary for the confirm.
/// Errors honestly: malformed/wrong-network address, locked/unready wallet, or
/// a funds shortfall classified as "not yet spendable" vs "insufficient" using
/// the live balance.
pub async fn send_prepare(
    destination: String,
    amount_sompi: u64,
) -> Result<SendSummaryDto, AppError> {
    let dest = validate_mainnet_address(&destination)?;
    if amount_sompi == 0 {
        return Err(AppError::msg("enter an amount greater than zero"));
    }

    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;

    // The fresh change is change/cursor; the signer registers the SAME watched
    // window (receive + widened change) so it can resolve any selected input and
    // the fresh change (the two-consumer seam — vault.rs is the single source).
    let cursor = vault::change_cursor();
    let change = vault::change_address_at(cursor)?;
    let signer = vault::build_wallet_signer(wallet::GAP_LIMIT, wallet::change_window())?;
    let signer: Arc<dyn SignerT> = Arc::new(signer);

    let rpc = dag::shared_monitor().await?.rpc();

    let prepared = match engine
        .prepare_send(dest, amount_sompi, change, signer, rpc)
        .await
    {
        Ok(prepared) => prepared,
        Err(ChainError::InsufficientFunds { .. }) => {
            // Distinguish a true shortfall from "still maturing" using the live
            // balance (INV-8 honesty; the Generator spends only MATURE UTXOs).
            let pending = wallet::latest_snapshot()
                .and_then(|s| s.pending_sompi)
                .unwrap_or(0);
            return Err(AppError::msg(if pending > 0 {
                "not yet spendable — some funds are still confirming. Try again in a few seconds."
            } else {
                "insufficient funds — the amount plus the network fee is more than your spendable balance."
            }));
        }
        Err(ChainError::StorageMassExceeded { .. }) => {
            // KIP-9: a tiny output relative to the wallet's UTXOs is penalized
            // past the per-tx mass limit (INV-8 — surface it honestly, with the
            // way out, never a raw error).
            return Err(AppError::msg(
                "this amount is too small to send economically from your current balance — \
                 Kaspa's storage-mass rule penalises tiny outputs. Try sending a larger amount.",
            ));
        }
        Err(e) => return Err(AppError::chain(e)),
    };

    let nonce = NONCE.fetch_add(1, Ordering::Relaxed);
    let summary = prepared.summary().clone();
    *PENDING_SEND.lock().unwrap_or_else(PoisonError::into_inner) = Some((nonce, prepared));

    Ok(SendSummaryDto {
        nonce,
        destination: summary.destination,
        amount_sompi: summary.amount_sompi,
        fee_sompi: summary.fee_sompi,
        total_sompi: summary.total_sompi,
        mass: summary.mass,
        tx_count: summary.tx_count,
        utxo_count: summary.utxo_count,
    })
}

/// Phase 2: sign + broadcast the stashed plan identified by `nonce`. Refuses a
/// stale/mismatched nonce or an empty stash (the user re-confirms). Advances the
/// change cursor only on a fully-broadcast send.
pub async fn send_commit(nonce: u64) -> Result<SendOutcomeDto, AppError> {
    let prepared = {
        let mut guard = PENDING_SEND.lock().unwrap_or_else(PoisonError::into_inner);
        match guard.take() {
            Some((stored, prepared)) if stored == nonce => prepared,
            Some((stored, prepared)) => {
                // Mismatch: put it back and refuse (the confirmed plan changed).
                *guard = Some((stored, prepared));
                return Err(AppError::msg(
                    "this send is no longer current — please review and confirm again",
                ));
            }
            None => {
                return Err(AppError::msg(
                    "nothing to send — please start the send again",
                ))
            }
        }
    };

    // The change index this send used (cursor is advanced only on full success,
    // so it still reads as the index we prepared with).
    let used_cursor = vault::change_cursor();
    let outcome = prepared.commit().await;

    if fully_broadcast(&outcome) {
        // The change at `used_cursor` is now in use → next send uses the next.
        let _ = vault::set_change_cursor(used_cursor.saturating_add(1));
    }

    Ok(SendOutcomeDto {
        final_txid: outcome.final_txid,
        submitted: outcome.submitted,
        total: outcome.total,
        partial: outcome.partial,
        error: outcome.error,
    })
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
        }));
        // Degenerate zero-leg — never advances.
        assert!(!fully_broadcast(&SendOutcome {
            submitted: 0,
            total: 0,
            partial: false,
            error: None,
            final_txid: None,
        }));
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
