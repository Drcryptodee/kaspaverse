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
//! P2.3 adds the encrypted lanes on the P2.1 spine: handshake initiate/accept
//! (bond + refund, §0.6), the comm compose, the inbound pipeline
//! (scan-match → store ciphertext → vault-gated decrypt-on-view →
//! conversation thread), and the FIRST decrypted-content DTO ever to cross
//! this bridge ([`ThreadMessageDto::text`] — user content post-decrypt,
//! INV-1 as amended D-056; the shape ffi-leak pre-cleared at P2.2). Plaintext
//! discipline (§4): decrypted text exists here only inside
//! [`transport_thread`]'s return value — never logged, never persisted, never
//! pushed into a Dart state manager (Dart PULLS threads to render and drops
//! them). Each encrypted kind is its own function taking sealed envelopes
//! only (chain's composers refuse plaintext-shaped bodies) — a DM can never
//! be routed through the plaintext `bcast` lane (§4 type-level separation).

use std::collections::HashSet;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use kaspaverse_chain::{
    compose_bcast, compose_comm_wire, compose_handshake_wire, decode_envelope_body, parse_payload,
    resolve_return_address, split_comm_body, Address, ChainError, ConversationRecord,
    ConversationStatus, KeyBranch, MessageDirection, MessageRecord, PreparedSend, SignerT,
    StoredKind, TransportEvent, TransportStore, HANDSHAKE_BOND_SOMPI,
};
use kaspaverse_core::handshake::{fresh_alias, fresh_conversation_id, HandshakePayload};
use kaspaverse_core::transport_crypto::{encrypt, Envelope};
use kaspaverse_core::{Branch, CoreError, KeySlot, TransportDecryptor};
use tokio::sync::broadcast::{self, error::RecvError};

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

/// A conversation row for the contacts surface. Every field is public-wire-
/// class data (addresses/txids on-chain, aliases on-wire, local ids/status).
#[derive(Clone, Debug)]
pub struct ConversationDto {
    pub conversation_id: String,
    /// Counterparty address — empty on an inbound-pending row until the
    /// accept flow resolves the sender via the node.
    pub contact_address: String,
    pub my_alias: String,
    pub their_alias: Option<String>,
    /// `pending_out` / `pending_in` / `active`.
    pub status: String,
    pub initiated_by_me: bool,
    pub created_unix_ms: u64,
    pub last_activity_unix_ms: u64,
}

/// One thread row — [`text`](Self::text) is THE first decrypted content to
/// cross this bridge (user content post-decrypt, D-056; ffi-leak pre-cleared
/// shape). Produced only by [`transport_thread`] (decrypt-on-view, §0.4):
/// Dart renders and drops it; nothing here is cached, logged, or persisted.
#[derive(Clone, Debug)]
pub struct ThreadMessageDto {
    pub txid: String,
    /// `handshake` (a system row — no body) or `comm`.
    pub kind: String,
    pub outbound: bool,
    pub unix_ms: u64,
    /// Decrypted message text for readable `comm` rows; empty otherwise.
    pub text: String,
    /// False when no watched key opens the envelope (kept honest, not hidden).
    pub readable: bool,
}

/// Single-slot stash for the built-but-unsigned transport send — SEPARATE from
/// the payment stash so a transport prepare can never clobber a payment
/// confirm in flight (both screens hold the B7 guarantee independently); the
/// shared nonce space keeps tokens unambiguous across both.
static PENDING_TRANSPORT: Mutex<Option<(u64, PreparedSend)>> = Mutex::new(None);

/// What to fold into the transport store when the stashed plan COMMITS
/// cleanly (same nonce as the stash). Sent plaintext is re-sealed to self at
/// PREPARE time, so only sealed bytes ever sit here (§0.4 — no plaintext in
/// any stash).
enum TransportIntent {
    /// Dev/broadcast lane — nothing to store.
    Bcast,
    /// Initiate: persist the pending-outbound conversation + its sent row.
    Handshake {
        conversation: ConversationRecord,
        reseal: Vec<u8>,
        timestamp_ms: u64,
    },
    /// Accept: flip the inbound-pending conversation active + its sent row.
    Accept {
        conversation_id: String,
        contact_address: String,
        my_alias: String,
        reseal: Vec<u8>,
        timestamp_ms: u64,
    },
    /// A comm message: its sent row.
    Comm {
        conversation_id: String,
        alias_on_wire: String,
        reseal: Vec<u8>,
        sealed_to: (KeyBranch, u32),
        timestamp_ms: u64,
    },
}

/// Intent stashed alongside [`PENDING_TRANSPORT`] under the same nonce.
static PENDING_INTENT: Mutex<Option<(u64, TransportIntent)>> = Mutex::new(None);

fn stash_intent(nonce: u64, intent: TransportIntent) {
    *PENDING_INTENT
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some((nonce, intent));
}

fn take_intent(nonce: u64) -> Option<TransportIntent> {
    let mut guard = PENDING_INTENT
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    match guard.take() {
        Some((stored, intent)) if stored == nonce => Some(intent),
        other => {
            *guard = other;
            None
        }
    }
}

// ── The transport hub (P2.3 inbound pipeline + stores) ────────────────────

/// Everything the inbound pipeline and the thread views share: the stores,
/// the vault-scoped decryptor (weak — dies on lock), and the PUBLIC watched
/// window (addresses for the handshake relevance filter; key slots for the
/// establishment scan).
struct TransportHub {
    store: Mutex<TransportStore>,
    decryptor: TransportDecryptor,
    watched: HashSet<String>,
    window: Vec<KeySlot>,
}

static HUB: Mutex<Option<Arc<TransportHub>>> = Mutex::new(None);
static HUB_TASK: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);
/// Sparse, content-free change pings (a conversation id) — Dart re-pulls.
static THREAD_PINGS: OnceLock<broadcast::Sender<String>> = OnceLock::new();

fn thread_pings() -> &'static broadcast::Sender<String> {
    THREAD_PINGS.get_or_init(|| broadcast::channel(64).0)
}

fn ping(conversation_id: &str) {
    let _ = thread_pings().send(conversation_id.to_string());
}

fn hub() -> Result<Arc<TransportHub>, AppError> {
    HUB.lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
        .ok_or_else(|| AppError::msg("messaging is still starting — try again in a moment"))
}

fn now_unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// core ↔ chain branch mapping (chain deliberately has no core dependency).
fn to_key_branch(branch: Branch) -> KeyBranch {
    match branch {
        Branch::Receive => KeyBranch::Receive,
        Branch::Change => KeyBranch::Change,
    }
}

fn to_core_branch(branch: KeyBranch) -> Branch {
    match branch {
        KeyBranch::Receive => Branch::Receive,
        KeyBranch::Change => Branch::Change,
    }
}

/// The 32-byte x-only pubkey of a Schnorr address — its payload. The one
/// address form the transport cipher can seal to; ECDSA (33-byte) addresses
/// are refused honestly.
fn x_only_of(address: &Address) -> Result<[u8; 32], AppError> {
    address.payload.as_ref().try_into().map_err(|_| {
        AppError::msg("this address type can't receive messages (Schnorr addresses only)")
    })
}

/// Start (or restart after a re-unlock) the transport hub: load the stores,
/// take a vault-scoped decryptor, derive the PUBLIC watched window, and
/// attach the inbound task to the live `ciph_msg:` scan. Idempotent while
/// the vault stays unlocked; called by Dart alongside the wallet start.
pub async fn transport_start() -> Result<(), AppError> {
    {
        let guard = HUB.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(existing) = guard.as_ref() {
            if existing.decryptor.is_live() {
                return Ok(()); // already running against the live vault
            }
        }
    }

    let store =
        TransportStore::load(vault::transport_store_dir()?.clone()).map_err(AppError::chain)?;
    let decryptor = vault::transport_decryptor()?;
    let (watched_addresses, _) =
        vault::derive_wallet_addresses(wallet::GAP_LIMIT, wallet::change_window())?;
    let watched: HashSet<String> = watched_addresses.iter().map(|a| a.to_string()).collect();
    // Receive slots first — the likelier establishment binding.
    let window: Vec<KeySlot> = (0..wallet::GAP_LIMIT)
        .map(|i| (Branch::Receive, i))
        .chain((0..wallet::change_window()).map(|i| (Branch::Change, i)))
        .collect();

    let hub = Arc::new(TransportHub {
        store: Mutex::new(store),
        decryptor,
        watched,
        window,
    });
    *HUB.lock().unwrap_or_else(PoisonError::into_inner) = Some(hub.clone());

    let monitor = dag::shared_monitor().await?;
    let mut events = monitor.subscribe_transport();
    let task = tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(event) => handle_inbound(&hub, event),
                // Sparse stream — lag is exotic; missed live events are the
                // live-only law's accepted cost (D-049), not silent data loss:
                // the store holds only what the wire delivered.
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });
    // Replace (and stop) any previous inbound task so a re-unlock never
    // leaves two tasks double-processing one stream.
    let old = HUB_TASK
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .replace(task);
    if let Some(old) = old {
        old.abort();
    }
    log::info!("transport-hub: started");
    Ok(())
}

/// One scan match → store/conversation fold. Content never reaches a log
/// line from here (§4: message plaintext is treated like key material for
/// logging; even sealed bodies are logged as shapes only).
fn handle_inbound(hub: &TransportHub, event: TransportEvent) {
    // The store law keys on txid (D-065); an id-less event (exotic — both the
    // node's verbose data AND the pinned recompute failed) cannot be stored.
    let Some(txid) = event.txid else { return };
    match event.kind.as_str() {
        "handshake" => handle_inbound_handshake(hub, &txid, &event.body, &event.addresses),
        "comm" => handle_inbound_comm(hub, &txid, &event.body),
        // `legacy` (VNone): parse-layer tolerance is fixture-pinned in chain;
        // conversation semantics for the unversioned generation are
        // consciously deferred (the population emits versioned forms since
        // 2025). `payment` memos: deferred (not a P2.3 deliverable). `bcast`:
        // plaintext dev/broadcast lane, rendered by the dev panel. Unknown
        // kinds: forward-compat opaque (§0.5) — visible on the dev wire view.
        _ => {}
    }
}

fn handle_inbound_handshake(hub: &TransportHub, txid: &str, body: &[u8], addresses: &[String]) {
    {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        // Dedup BEFORE any crypto: DAG re-delivery, and our own outbound
        // handshakes echoing back through the scan (stored at commit).
        if store.has_handshake_txid(txid) || store.has_message_txid(txid) {
            return;
        }
    }
    // Relevance without crypto: a real handshake bonds the recipient, so one
    // of OUR watched addresses must be among the outputs.
    if !addresses.iter().any(|a| hub.watched.contains(a)) {
        return;
    }
    let envelope_bytes = decode_envelope_body(body);
    let Ok(envelope) = Envelope::from_bytes(&envelope_bytes) else {
        return;
    };
    // Establishment scan: whichever watched key opens it becomes the §0.7
    // binding. Not ours / vault locked ⇒ skip (live-only law: an envelope
    // seen while locked is missed, same as one seen while offline).
    let Ok((slot, plaintext)) = hub
        .decryptor
        .decrypt_scanning(hub.window.iter().copied(), &envelope)
    else {
        return;
    };
    let Ok(payload) = HandshakePayload::from_plaintext(&plaintext) else {
        log::debug!("transport-hub: undecodable handshake payload skipped");
        return;
    };
    drop(plaintext); // Zeroizing — wiped here; the store keeps ciphertext only

    let now = now_unix_ms();
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);

    // An acceptance response completes a conversation we initiated: their
    // fresh alias arrives in `alias`, OUR alias echoes back in `their_alias`.
    if payload.is_acceptance() {
        let echoed = payload.their_alias.as_deref().unwrap_or_default();
        if let Some(existing) = store.conversation_awaiting_response(echoed) {
            let mut conversation = existing.clone();
            conversation.their_alias = Some(payload.alias.clone());
            conversation.status = ConversationStatus::Active;
            // REBIND to the slot that actually opened it — this is the key
            // the counterparty resolved for us and will keep sealing to.
            conversation.bound_branch = to_key_branch(slot.0);
            conversation.bound_index = slot.1;
            conversation.last_activity_unix_ms = now;
            let conversation_id = conversation.conversation_id.clone();
            let _ = store.upsert_conversation(conversation);
            let _ = store.record_message(MessageRecord {
                txid: txid.to_string(),
                conversation_id: conversation_id.clone(),
                direction: MessageDirection::Inbound,
                kind: StoredKind::Handshake,
                envelope: envelope_bytes,
                unix_ms: payload.timestamp,
                alias_on_wire: None,
                sealed_to: None,
            });
            drop(store);
            ping(&conversation_id);
            return;
        }
        // An acceptance we have no pending side for — fall through and treat
        // it as a fresh inbound handshake (the live app does the same).
    }

    // A new inbound handshake: pending until the user accepts (the accept
    // card resolves the sender + sends the §0.6 refund).
    let conversation_id = fresh_conversation_id();
    let conversation = ConversationRecord {
        conversation_id: conversation_id.clone(),
        contact_address: String::new(),
        my_alias: String::new(),
        their_alias: Some(payload.alias.clone()),
        status: ConversationStatus::PendingInbound,
        initiated_by_me: false,
        bound_branch: to_key_branch(slot.0),
        bound_index: slot.1,
        created_unix_ms: now,
        last_activity_unix_ms: now,
        handshake_txid: Some(txid.to_string()),
    };
    let _ = store.upsert_conversation(conversation);
    let _ = store.record_message(MessageRecord {
        txid: txid.to_string(),
        conversation_id: conversation_id.clone(),
        direction: MessageDirection::Inbound,
        kind: StoredKind::Handshake,
        envelope: envelope_bytes,
        unix_ms: payload.timestamp,
        alias_on_wire: None,
        sealed_to: None,
    });
    drop(store);
    ping(&conversation_id);
}

fn handle_inbound_comm(hub: &TransportHub, txid: &str, body: &[u8]) {
    {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        if store.has_message_txid(txid) {
            return; // DAG re-delivery, or our own sent row echoing back
        }
    }
    // The alias head sits OUTSIDE the envelope — split BEFORE any envelope
    // parse (P2.2 handover law).
    let Some((alias, sealed)) = split_comm_body(body) else {
        return;
    };
    // Relevance without crypto: the alias must belong to one of our
    // conversations (either side's — senders tag with their own).
    let (conversation_id, bound) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(conversation) = store.conversation_by_alias(&alias) else {
            return;
        };
        (
            conversation.conversation_id.clone(),
            (
                to_core_branch(conversation.bound_branch),
                conversation.bound_index,
            ),
        )
    };
    let envelope_bytes = decode_envelope_body(sealed);
    let Ok(envelope) = Envelope::from_bytes(&envelope_bytes) else {
        return;
    };
    // Validation decrypt: bound slot first (§0.7 fast path), then the window
    // (robustness against a counterparty that re-resolved our address). The
    // plaintext is DROPPED here — decrypt-on-view happens at thread pull.
    let sealed_to = match hub.decryptor.decrypt_at(bound, &envelope) {
        Ok(_) => None,
        Err(CoreError::TransportOpen) => {
            match hub
                .decryptor
                .decrypt_scanning(hub.window.iter().copied(), &envelope)
            {
                Ok((slot, _)) => Some((to_key_branch(slot.0), slot.1)),
                Err(_) => return, // alias matched but no key opens it — spoofed head
            }
        }
        Err(_) => return, // vault locked mid-stream — live-only law
    };

    let now = now_unix_ms();
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let recorded = store.record_message(MessageRecord {
        txid: txid.to_string(),
        conversation_id: conversation_id.clone(),
        direction: MessageDirection::Inbound,
        kind: StoredKind::Comm,
        envelope: envelope_bytes,
        unix_ms: now,
        alias_on_wire: Some(alias),
        sealed_to,
    });
    if let Ok(true) = recorded {
        if let Some(existing) = store.conversation(&conversation_id) {
            let mut conversation = existing.clone();
            conversation.last_activity_unix_ms = now;
            let _ = store.upsert_conversation(conversation);
        }
        drop(store);
        ping(&conversation_id);
    }
}

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
    stash_intent(nonce, TransportIntent::Bcast);
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

/// Build + stash one encrypted-kind transport send over the shared two-phase
/// seam; returns the B7 summary (payload kind decoded from the BUILT tx).
async fn prepare_transport_send(
    dest: Address,
    amount_sompi: u64,
    wire: Vec<u8>,
    intent: TransportIntent,
) -> Result<TransportSendSummaryDto, AppError> {
    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;

    let cursor = vault::change_cursor();
    let change = vault::change_address_at(cursor)?;
    let signer = vault::build_wallet_signer(wallet::GAP_LIMIT, wallet::change_window())?;
    let signer: Arc<dyn SignerT> = Arc::new(signer);
    let rpc = dag::shared_monitor().await?.rpc();

    let prepared = engine
        .prepare_send(dest, amount_sompi, change, signer, rpc, Some(wire))
        .await
        .map_err(friendly_prepare_error)?;

    let built = prepared.final_payload();
    let payload_kind = parse_payload(&built)
        .map(|(kind, _)| kind)
        .unwrap_or_else(|| "none".to_string());

    let nonce = next_nonce();
    stash_intent(nonce, intent);
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

/// Honest friendly mapping of the Generator's typed errors for the compose
/// surfaces (the carried L-pattern from `StorageMassExceeded`, P2.1 note).
fn friendly_prepare_error(e: ChainError) -> AppError {
    match e {
        ChainError::TransactionTooHeavy => AppError::msg(
            "this message is too large for one transaction — shorten it and try again",
        ),
        ChainError::InsufficientFunds { .. } => AppError::msg(
            "insufficient funds — the message value plus the network fee is more than your \
             spendable balance",
        ),
        ChainError::StorageMassExceeded { .. } => AppError::msg(
            "this send is too small for your current coins (Kaspa's anti-dust rule) — \
             wait for pending funds or add to your balance",
        ),
        other => AppError::chain(other),
    }
}

/// Phase 1 (initiate a conversation): fresh alias + the live-shape handshake
/// JSON, sealed to the recipient's address key; 0.2 KAS bond (§0.6 — THE one
/// provenance-cited constant, refunded in their acceptance). The plaintext is
/// re-sealed to self HERE so the stash holds ciphertext only (§0.4).
pub async fn transport_prepare_handshake(
    destination: String,
) -> Result<TransportSendSummaryDto, AppError> {
    let dest = validate_mainnet_address(&destination)?;
    let recipient_x_only = x_only_of(&dest)?;
    hub()?; // the store must be live before we can promise persistence

    let my_alias = fresh_alias();
    let timestamp_ms = now_unix_ms();
    let payload = HandshakePayload::initial(&my_alias, timestamp_ms)
        .map_err(AppError::core)?
        .to_plaintext()
        .map_err(AppError::core)?;

    let envelope = encrypt(&recipient_x_only, &payload).map_err(AppError::core)?;
    let wire = compose_handshake_wire(&envelope.to_bytes()).map_err(AppError::chain)?;

    // Provisional §0.7 binding for an outbound conversation: receive/0. The
    // acceptance response rebinds to whichever of our keys the counterparty
    // actually resolved (handle_inbound_handshake).
    let bound: KeySlot = (Branch::Receive, 0);
    let own_address = vault::wallet_address_at(bound.0, bound.1)?;
    let reseal = encrypt(&x_only_of(&own_address)?, &payload)
        .map_err(AppError::core)?
        .to_bytes();

    let conversation = ConversationRecord {
        conversation_id: fresh_conversation_id(),
        contact_address: dest.to_string(),
        my_alias,
        their_alias: None,
        status: ConversationStatus::PendingOutbound,
        initiated_by_me: true,
        bound_branch: to_key_branch(bound.0),
        bound_index: bound.1,
        created_unix_ms: timestamp_ms,
        last_activity_unix_ms: timestamp_ms,
        handshake_txid: None, // set at commit from the broadcast txid
    };

    prepare_transport_send(
        dest,
        HANDSHAKE_BOND_SOMPI,
        wire,
        TransportIntent::Handshake {
            conversation,
            reseal,
            timestamp_ms,
        },
    )
    .await
}

/// Phase 1 (accept an inbound handshake): resolve the SENDER via the node's
/// own return-address lookup (consensus data, never payload content — §0.3:
/// this flow commits value), build the acceptance response, refund the 0.2
/// KAS bond (§0.6).
pub async fn transport_prepare_accept(
    conversation_id: String,
) -> Result<TransportSendSummaryDto, AppError> {
    let hub = hub()?;
    let (their_alias, handshake_txid, bound) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let conversation = store
            .conversation(&conversation_id)
            .ok_or_else(|| AppError::msg("conversation not found"))?;
        if conversation.status != ConversationStatus::PendingInbound {
            return Err(AppError::msg("this conversation isn't awaiting an accept"));
        }
        let their_alias = conversation
            .their_alias
            .clone()
            .ok_or_else(|| AppError::msg("handshake carried no alias"))?;
        let txid = conversation
            .handshake_txid
            .clone()
            .ok_or_else(|| AppError::msg("handshake transaction unknown"))?;
        (
            their_alias,
            txid,
            (
                to_core_branch(conversation.bound_branch),
                conversation.bound_index,
            ),
        )
    };

    // Sender resolution: the accepting-DAA score comes from the P1.5 record
    // of the bond that paid us; the address from the node (INV-8: same
    // untrusted node, same socket, no indexer).
    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;
    let daa = engine.activity_daa_score(&handshake_txid).ok_or_else(|| {
        AppError::msg("the handshake bond is still confirming — try again in a few seconds")
    })?;
    let rpc = dag::shared_monitor().await?.rpc();
    let sender = resolve_return_address(&rpc, &handshake_txid, daa)
        .await
        .map_err(AppError::chain)?;
    let dest = validate_mainnet_address(&sender)?;
    let recipient_x_only = x_only_of(&dest)?;

    let my_alias = fresh_alias();
    let timestamp_ms = now_unix_ms();
    let payload = HandshakePayload::response(&my_alias, &their_alias, timestamp_ms)
        .map_err(AppError::core)?
        .to_plaintext()
        .map_err(AppError::core)?;

    let envelope = encrypt(&recipient_x_only, &payload).map_err(AppError::core)?;
    let wire = compose_handshake_wire(&envelope.to_bytes()).map_err(AppError::chain)?;

    let own_address = vault::wallet_address_at(bound.0, bound.1)?;
    let reseal = encrypt(&x_only_of(&own_address)?, &payload)
        .map_err(AppError::core)?
        .to_bytes();

    prepare_transport_send(
        dest.clone(),
        HANDSHAKE_BOND_SOMPI, // the refund — the same provenance-cited norm
        wire,
        TransportIntent::Accept {
            conversation_id,
            contact_address: dest.to_string(),
            my_alias,
            reseal,
            timestamp_ms,
        },
    )
    .await
}

/// Phase 1 (a message in an active conversation): seal to the contact's
/// address key, tag the wire with OUR alias (the live convention), and carry
/// the honest computed minimum value to the recipient (§0.6 — the D-054
/// floor machinery, never a hardcoded number).
pub async fn transport_prepare_comm(
    conversation_id: String,
    text: String,
) -> Result<TransportSendSummaryDto, AppError> {
    if text.trim().is_empty() {
        return Err(AppError::msg("enter a message"));
    }
    let hub = hub()?;
    let (contact_address, my_alias, bound) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let conversation = store
            .conversation(&conversation_id)
            .ok_or_else(|| AppError::msg("conversation not found"))?;
        if conversation.status != ConversationStatus::Active {
            return Err(AppError::msg(
                "this conversation isn't active yet — the handshake must complete first",
            ));
        }
        (
            conversation.contact_address.clone(),
            conversation.my_alias.clone(),
            (
                to_core_branch(conversation.bound_branch),
                conversation.bound_index,
            ),
        )
    };
    let dest = validate_mainnet_address(&contact_address)?;
    let recipient_x_only = x_only_of(&dest)?;

    // §0.6: every message carries value — the honest computed minimum for
    // THIS wallet's live coin shape (D-054), recomputed per send.
    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;
    let floor = engine
        .minimum_sendable(vault::change_address_at(vault::change_cursor())?)
        .map_err(AppError::chain)?
        .ok_or_else(|| {
            AppError::msg("your balance can't cover a message right now (anti-dust floor)")
        })?;

    let envelope = encrypt(&recipient_x_only, text.as_bytes()).map_err(AppError::core)?;
    let wire = compose_comm_wire(&my_alias, &envelope.to_bytes()).map_err(AppError::chain)?;

    let own_address = vault::wallet_address_at(bound.0, bound.1)?;
    let reseal = encrypt(&x_only_of(&own_address)?, text.as_bytes())
        .map_err(AppError::core)?
        .to_bytes();

    let timestamp_ms = now_unix_ms();
    prepare_transport_send(
        dest,
        floor,
        wire,
        TransportIntent::Comm {
            conversation_id,
            alias_on_wire: my_alias,
            reseal,
            sealed_to: (to_key_branch(bound.0), bound.1),
            timestamp_ms,
        },
    )
    .await
}

/// Phase 2: sign + broadcast the stashed transport plan identified by `nonce`.
/// Same stale-nonce refusal, partial-honesty (B6) and change-cursor discipline
/// as the payment path — one shared implementation. On a CLEAN broadcast the
/// stashed intent folds into the transport store (conversation + sent row).
pub async fn transport_commit(nonce: u64) -> Result<SendOutcomeDto, AppError> {
    let prepared = take_stashed(&PENDING_TRANSPORT, nonce)?;
    let intent = take_intent(nonce);
    let outcome = commit_and_advance(prepared).await;

    let clean = !outcome.partial && outcome.error.is_none();
    if let (true, Some(intent), Some(txid)) = (clean, intent, outcome.final_txid.clone()) {
        apply_intent(intent, &txid);
    }
    Ok(outcome)
}

/// Fold a committed send into the transport store. Failures here are store
/// I/O, not send failures — the tx is already broadcast; the wire re-delivers
/// what a torn store misses (inbound), and the user re-sees honest state.
fn apply_intent(intent: TransportIntent, txid: &str) {
    let Ok(hub) = hub() else { return };
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    match intent {
        TransportIntent::Bcast => {}
        TransportIntent::Handshake {
            mut conversation,
            reseal,
            timestamp_ms,
        } => {
            conversation.handshake_txid = Some(txid.to_string());
            let conversation_id = conversation.conversation_id.clone();
            let sealed_to = Some((conversation.bound_branch, conversation.bound_index));
            let _ = store.upsert_conversation(conversation);
            let _ = store.record_message(MessageRecord {
                txid: txid.to_string(),
                conversation_id: conversation_id.clone(),
                direction: MessageDirection::Outbound,
                kind: StoredKind::Handshake,
                envelope: reseal,
                unix_ms: timestamp_ms,
                alias_on_wire: None,
                sealed_to,
            });
            drop(store);
            ping(&conversation_id);
        }
        TransportIntent::Accept {
            conversation_id,
            contact_address,
            my_alias,
            reseal,
            timestamp_ms,
        } => {
            if let Some(existing) = store.conversation(&conversation_id) {
                let mut conversation = existing.clone();
                conversation.contact_address = contact_address;
                conversation.my_alias = my_alias;
                conversation.status = ConversationStatus::Active;
                conversation.last_activity_unix_ms = timestamp_ms;
                let sealed_to = Some((conversation.bound_branch, conversation.bound_index));
                let _ = store.upsert_conversation(conversation);
                let _ = store.record_message(MessageRecord {
                    txid: txid.to_string(),
                    conversation_id: conversation_id.clone(),
                    direction: MessageDirection::Outbound,
                    kind: StoredKind::Handshake,
                    envelope: reseal,
                    unix_ms: timestamp_ms,
                    alias_on_wire: None,
                    sealed_to,
                });
            }
            drop(store);
            ping(&conversation_id);
        }
        TransportIntent::Comm {
            conversation_id,
            alias_on_wire,
            reseal,
            sealed_to,
            timestamp_ms,
        } => {
            let _ = store.record_message(MessageRecord {
                txid: txid.to_string(),
                conversation_id: conversation_id.clone(),
                direction: MessageDirection::Outbound,
                kind: StoredKind::Comm,
                envelope: reseal,
                unix_ms: timestamp_ms,
                alias_on_wire: Some(alias_on_wire),
                sealed_to: Some(sealed_to),
            });
            if let Some(existing) = store.conversation(&conversation_id) {
                let mut conversation = existing.clone();
                conversation.last_activity_unix_ms = timestamp_ms;
                let _ = store.upsert_conversation(conversation);
            }
            drop(store);
            ping(&conversation_id);
        }
    }
}

/// Drop any stashed transport send (confirm dismissed / back). Idempotent.
pub fn transport_abandon() {
    *PENDING_TRANSPORT
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = None;
    *PENDING_INTENT
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = None;
}

// ── Pull surfaces (Dart renders and drops; nothing content-bearing streams) ─

/// All conversations, most recently active first.
pub fn transport_conversations() -> Result<Vec<ConversationDto>, AppError> {
    let hub = hub()?;
    let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    Ok(store
        .list_conversations()
        .into_iter()
        .map(|c| ConversationDto {
            conversation_id: c.conversation_id,
            contact_address: c.contact_address,
            my_alias: c.my_alias,
            their_alias: c.their_alias,
            status: match c.status {
                ConversationStatus::PendingOutbound => "pending_out".to_string(),
                ConversationStatus::PendingInbound => "pending_in".to_string(),
                ConversationStatus::Active => "active".to_string(),
            },
            initiated_by_me: c.initiated_by_me,
            created_unix_ms: c.created_unix_ms,
            last_activity_unix_ms: c.last_activity_unix_ms,
        })
        .collect())
}

/// A conversation's thread, oldest first — DECRYPT-ON-VIEW (§0.4): sealed
/// rows open here, per call, while the vault is unlocked; the plaintext
/// crosses once as the display DTO and Dart drops it with the widget. Vault
/// locked ⇒ this errs and the thread is unreadable (the P2.3 acceptance
/// observation). Handshake rows are system rows — no body crosses.
pub fn transport_thread(conversation_id: String) -> Result<Vec<ThreadMessageDto>, AppError> {
    let hub = hub()?;
    let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let conversation = store
        .conversation(&conversation_id)
        .ok_or_else(|| AppError::msg("conversation not found"))?;
    let bound: KeySlot = (
        to_core_branch(conversation.bound_branch),
        conversation.bound_index,
    );

    let mut thread = Vec::new();
    for record in store.messages_for(&conversation_id) {
        let outbound = record.direction == MessageDirection::Outbound;
        match record.kind {
            StoredKind::Handshake | StoredKind::Legacy => {
                thread.push(ThreadMessageDto {
                    txid: record.txid,
                    kind: "handshake".to_string(),
                    outbound,
                    unix_ms: record.unix_ms,
                    text: String::new(),
                    readable: true,
                });
            }
            StoredKind::Comm => {
                let (text, readable) = match Envelope::from_bytes(&record.envelope) {
                    Ok(envelope) => {
                        let slot = record
                            .sealed_to
                            .map(|(b, i)| (to_core_branch(b), i))
                            .unwrap_or(bound);
                        match open_with_fallback(&hub, slot, &envelope) {
                            Ok(plaintext) => {
                                (String::from_utf8_lossy(&plaintext).into_owned(), true)
                            }
                            Err(CoreError::VaultLocked) => {
                                return Err(AppError::msg(
                                    "wallet is locked — unlock to read messages",
                                ))
                            }
                            Err(_) => (String::new(), false),
                        }
                    }
                    Err(_) => (String::new(), false),
                };
                thread.push(ThreadMessageDto {
                    txid: record.txid,
                    kind: "comm".to_string(),
                    outbound,
                    unix_ms: record.unix_ms,
                    text,
                    readable,
                });
            }
        }
    }
    Ok(thread)
}

/// Bound slot first, watched window second (robust against rebinds without
/// ever hiding a readable message).
fn open_with_fallback(
    hub: &TransportHub,
    slot: KeySlot,
    envelope: &Envelope,
) -> Result<zeroize::Zeroizing<Vec<u8>>, CoreError> {
    match hub.decryptor.decrypt_at(slot, envelope) {
        Err(CoreError::TransportOpen) => hub
            .decryptor
            .decrypt_scanning(hub.window.iter().copied(), envelope)
            .map(|(_, plaintext)| plaintext),
        other => other,
    }
}

/// Sparse, content-free conversation-change pings (a conversation id) —
/// Dart re-pulls [`transport_conversations`] / [`transport_thread`] on each.
/// Nothing decrypted ever streams (§0.4: no Dart state manager holds content).
pub async fn subscribe_thread_pings(sink: StreamSink<String>) -> Result<(), AppError> {
    let mut pings = thread_pings().subscribe();
    tokio::spawn(async move {
        loop {
            match pings.recv().await {
                Ok(conversation_id) => {
                    if sink.add(conversation_id).is_err() {
                        break;
                    }
                }
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });
    Ok(())
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
    fn abandon_clears_the_transport_stash_and_intent() {
        stash_intent(99, TransportIntent::Bcast);
        transport_abandon();
        assert!(PENDING_TRANSPORT
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_none());
        assert!(PENDING_INTENT
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

    #[test]
    fn intent_stash_matches_only_its_own_nonce() {
        transport_abandon();
        stash_intent(7, TransportIntent::Bcast);
        // A wrong nonce leaves the intent in place…
        assert!(take_intent(8).is_none());
        // …the right one consumes it exactly once.
        assert!(take_intent(7).is_some());
        assert!(take_intent(7).is_none());
    }

    #[test]
    fn branch_mapping_round_trips() {
        for branch in [Branch::Receive, Branch::Change] {
            assert_eq!(to_core_branch(to_key_branch(branch)), branch);
        }
    }

    #[test]
    fn x_only_accepts_schnorr_and_refuses_ecdsa_addresses() {
        // Upstream gen1 mainnet vector — Schnorr, 32-byte x-only payload.
        let schnorr = Address::try_from(
            "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf",
        )
        .unwrap();
        assert_eq!(x_only_of(&schnorr).unwrap().len(), 32);

        // An ECDSA-version address carries a 33-byte payload — refused with
        // the honest reason (the cipher seals to x-only keys).
        let ecdsa = Address::new(
            kaspaverse_core::Prefix::Mainnet,
            kaspa_addresses_version_ecdsa(),
            &[2u8; 33],
        );
        let err = x_only_of(&ecdsa).unwrap_err();
        assert!(err.message.contains("Schnorr"));
    }

    /// Version enum access without a direct kaspa-addresses dependency.
    fn kaspa_addresses_version_ecdsa() -> kaspaverse_chain::AddressVersion {
        kaspaverse_chain::AddressVersion::PubKeyECDSA
    }

    /// The §4 plaintext-discipline grep-tripwire for THIS module: the only
    /// place decrypted text may exist is `transport_thread`'s return path.
    /// No `log::`/`tracing` call in this file may reference a plaintext,
    /// text, or body binding — reviewed by ffi-leak; this test pins the two
    /// log lines the module is allowed to have.
    #[test]
    fn module_logs_are_lifecycle_only() {
        let source = include_str!("transport.rs");
        for line in source
            .lines()
            .map(str::trim_start)
            .filter(|l| l.contains("log::") && !l.starts_with("//"))
        {
            assert!(
                !line.contains("text") && !line.contains("plaintext") && !line.contains("body"),
                "content-adjacent log line: {line}"
            );
        }
    }
}
