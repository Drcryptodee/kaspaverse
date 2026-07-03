//! Payload transport across the FFI (P2.1 · T2): the send side reuses the
//! two-phase prepare/commit discipline of `api/send.rs` with payload bytes
//! threaded through the same pinned Generator; the receive side streams
//! `ciph_msg:` matches from the chain-layer BlockAdded scan.
//!
//! What crosses here is PUBLIC data only (INV-1/3): addresses, amounts, a
//! Rust-decoded summary of the built txs, and on-chain payload bytes (raw
//! ciphertext or plaintext `bcast` text — third-party or our own). No key
//! material, no vault types; the signer stays an opaque `dyn SignerT` built in
//! `vault.rs`, exactly as the payment path. Payload bodies are user/on-chain
//! content: DTO display is fine, logging is NOT (§4 plaintext discipline —
//! nothing in this module logs a body or a kind).
//!
//! P2.1 exposes exactly ONE compose kind: plaintext `bcast` (dev/broadcast
//! lane — wire-valid per Gate R, which is what makes the spine device-provable
//! before any cryptography exists). Encrypted kinds (`handshake`/`comm`/…)
//! arrive in P2.3 as their own functions; there is deliberately no
//! "send arbitrary payload" entry point, so a DM can never be routed through
//! the plaintext kind by accident (§4 type-level separation).

use std::sync::{Arc, Mutex, PoisonError};

use kaspaverse_chain::{compose_bcast, parse_payload, PreparedSend, SignerT, TransportEvent};
use tokio::sync::broadcast::error::RecvError;

use crate::api::error::AppError;
use crate::api::send::{
    commit_and_advance, next_nonce, take_stashed, validate_mainnet_address, SendOutcomeDto,
};
use crate::api::{dag, vault, wallet};
use crate::frb_generated::StreamSink;

/// The Rust-decoded summary the transport confirm renders (B7 — never the form
/// echo). Superset of the payment summary: `payload_len`/`payload_kind` are
/// decoded FROM THE BUILT final transaction, so the user confirms what will
/// actually be signed, payload included (anti-blind-signing parity with P1.6).
#[derive(Clone, Debug)]
pub struct TransportSendSummaryDto {
    /// Opaque token tying this summary to its stashed transactions.
    pub nonce: u64,
    /// The mainnet address Rust validated and built into the payment output.
    pub destination: String,
    pub amount_sompi: u64,
    /// The Generator's exact aggregate fee — payload mass is priced in here
    /// (KIP-9; the P2.1 fee-delta proof reads this field).
    pub fee_sompi: u64,
    /// `amount + fee` (what leaves the wallet, excluding returned change).
    pub total_sompi: u64,
    pub mass: u64,
    pub tx_count: u32,
    pub utxo_count: u32,
    /// Payload bytes on the built final tx (read back, not echoed).
    pub payload_len: u32,
    /// Wire kind decoded from the built payload (`bcast` here) — same parser
    /// the receive scan uses.
    pub payload_kind: String,
}

/// One `ciph_msg:` match from the live BlockAdded scan (P2.1 raw receive).
/// Raw by design: kind is the verbatim wire token, `body` the raw bytes after
/// it — semantics (decryption, conversations) arrive in P2.2/P2.3.
#[derive(Clone, Debug)]
pub struct TransportEventDto {
    /// Transaction id (hex), when resolvable — never fabricated.
    pub txid: Option<String>,
    /// Wire kind: `bcast` / `handshake` / `comm` / … / `legacy` / `unknown`.
    pub kind: String,
    /// Raw body bytes (ciphertext or plaintext; on-chain public data).
    pub body: Vec<u8>,
    /// Output addresses of the carrying tx (recipients incl. change).
    pub addresses: Vec<String>,
}

/// Single-slot stash for the built-but-unsigned transport send — SEPARATE from
/// the payment stash so a transport prepare can never clobber a payment
/// confirm in flight (both screens hold the B7 guarantee independently); the
/// shared nonce space keeps tokens unambiguous across both.
static PENDING_TRANSPORT: Mutex<Option<(u64, PreparedSend)>> = Mutex::new(None);

/// Phase 1 (dev/broadcast lane): compose `ciph_msg:1:bcast:<channel>:<text>`,
/// build the tx chain over the live UTXO context with the payload on the final
/// tx, and stash it unsigned. Returns the Rust-decoded summary (incl. the
/// payload the BUILT tx carries) for the confirm step.
pub async fn transport_prepare_bcast(
    destination: String,
    amount_sompi: u64,
    channel: String,
    message: String,
) -> Result<TransportSendSummaryDto, AppError> {
    let dest = validate_mainnet_address(&destination)?;
    if amount_sompi == 0 {
        // The Generator needs a real payment output; message value floors are
        // the D-054 machinery's job (send_minimum), never a hardcoded number.
        return Err(AppError::msg("enter an amount greater than zero"));
    }
    let payload = compose_bcast(&channel, &message).map_err(AppError::chain)?;

    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;

    // Same two-consumer change seam as the payment path (vault.rs is the
    // single source): fresh change registered + signer over the watched window.
    let cursor = vault::change_cursor();
    let change = vault::change_address_at(cursor)?;
    let signer = vault::build_wallet_signer(wallet::GAP_LIMIT, wallet::change_window())?;
    let signer: Arc<dyn SignerT> = Arc::new(signer);

    let rpc = dag::shared_monitor().await?.rpc();

    let prepared = engine
        .prepare_send(dest, amount_sompi, change, signer, rpc, Some(payload))
        .await
        .map_err(AppError::chain)?;

    // B7: decode the payload back OUT of the built final tx with the same
    // parser the receive scan uses — the confirm shows what will be signed.
    let built = prepared.final_payload();
    let payload_kind = parse_payload(&built)
        .map(|(kind, _)| kind)
        .unwrap_or_else(|| "none".to_string());

    let nonce = next_nonce();
    let summary = prepared.summary().clone();
    *PENDING_TRANSPORT
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some((nonce, prepared));

    Ok(TransportSendSummaryDto {
        nonce,
        destination: summary.destination,
        amount_sompi: summary.amount_sompi,
        fee_sompi: summary.fee_sompi,
        total_sompi: summary.total_sompi,
        mass: summary.mass,
        tx_count: summary.tx_count,
        utxo_count: summary.utxo_count,
        payload_len: summary.payload_len,
        payload_kind,
    })
}

/// Phase 2: sign + broadcast the stashed transport plan identified by `nonce`.
/// Same stale-nonce refusal, partial-honesty (B6) and change-cursor discipline
/// as the payment path — one shared implementation.
pub async fn transport_commit(nonce: u64) -> Result<SendOutcomeDto, AppError> {
    let prepared = take_stashed(&PENDING_TRANSPORT, nonce)?;
    Ok(commit_and_advance(prepared).await)
}

/// Drop any stashed transport send (confirm dismissed / back). Idempotent.
pub fn transport_abandon() {
    *PENDING_TRANSPORT
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = None;
}

/// Subscribe to live `ciph_msg:` matches from the BlockAdded scan. Discrete
/// deliveries, not snapshots: there is deliberately no cached-latest replay
/// (unlike `subscribe_dag_updates`) — history is the P2.3 message store's job;
/// this stream is the live wire. Foreground-only by construction: the scan
/// rides the shared socket's `dag_pause()`/`dag_resume()` posture (D-053).
pub async fn subscribe_transport_events(
    sink: StreamSink<TransportEventDto>,
) -> Result<(), AppError> {
    let monitor = dag::shared_monitor().await?;
    let mut events = monitor.subscribe_transport();
    // Runs on FRB's tokio runtime; exits when the Dart listener goes away
    // (sink.add fails) — e.g. on hot restart, leaving the connection up (L4).
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(event) => {
                    if sink.add(to_dto(event)).is_err() {
                        break;
                    }
                }
                // Lagged: the receiver fell behind the buffer. Transport events
                // are sparse (matches only), so this is exotic — skip ahead;
                // missed history is the store's concern (P2.3), not the wire's.
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

/// Chain event → FFI DTO (field-for-field; plain structs only, D-022d).
fn to_dto(event: TransportEvent) -> TransportEventDto {
    TransportEventDto {
        txid: event.txid,
        kind: event.kind,
        body: event.body,
        addresses: event.addresses,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn abandon_clears_the_transport_stash() {
        transport_abandon();
        assert!(PENDING_TRANSPORT
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_none());
    }

    #[test]
    fn event_maps_field_for_field() {
        let dto = to_dto(TransportEvent {
            txid: Some("ab".repeat(32)),
            kind: "bcast".into(),
            body: b"kv-dev:hi".to_vec(),
            addresses: vec!["kaspa:qz...".into()],
        });
        assert_eq!(dto.txid.as_deref(), Some("ab".repeat(32).as_str()));
        assert_eq!(dto.kind, "bcast");
        assert_eq!(dto.body, b"kv-dev:hi");
        assert_eq!(dto.addresses.len(), 1);
    }
}
