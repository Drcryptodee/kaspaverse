//! Payload transport across the FFI (P2.1 · T2): the send side reuses the
//! two-phase prepare/commit discipline of `api/send.rs` with payload bytes
//! threaded through the same pinned Generator; the receive side folds the
//! `ciph_msg:`/`kchat:` matches of the chain layer's message walk: ACCEPTED
//! transactions, not the full-block stream it replaced (LINK-Q3, D-344).
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
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use kaspaverse_chain::prefs::MessagePrefs;
use kaspaverse_chain::{
    compose_bcast, compose_comm_wire_in, compose_handshake_wire, compose_self_stash_wire,
    decode_envelope_body, parse_payload, resolve_return_address, split_comm_body, AcceptanceEvent,
    Address, BlockList, ChainError, ConversationRecord, ConversationStatus, KeyBranch,
    MessageDirection, MessageRecord, PreparedSend, ReadMarks, RowSource, SignerT, StoredKind,
    TransportEvent, TransportStore, UtxoEntryReference, WalletEngine, WatchSource, WireNamespace,
    HANDSHAKE_BOND_SOMPI, STASH_SCOPE_SAVED_HANDSHAKE,
};
use kaspaverse_core::attachment::Attachment;
use kaspaverse_core::frames::{
    self, build_accept, build_challenge, build_taunt, fresh_challenge_id, GAME_ATTACK_DEFEND,
};
use kaspaverse_core::handshake::{
    attach_stash_tag, fresh_alias, fresh_conversation_id, split_stash_tag, HandshakePayload,
    SavedHandshakePayload, SavedHandshakeSnapshot, BOUND_BRANCH_CHANGE, BOUND_BRANCH_RECEIVE,
};
use kaspaverse_core::transport_crypto::{encrypt, Envelope};
use kaspaverse_core::{Branch, CoreError, KeySlot, TransportDecryptor};
use tokio::sync::broadcast::{self, error::RecvError};

use crate::api::error::AppError;
use crate::api::send::{
    commit_and_advance, next_nonce, project_signable, shortfall_message, take_stashed,
    validate_mainnet_address, SendOutcomeDto, SignableKind, SignableSummaryDto,
};
use crate::api::{dag, vault, wallet};
use crate::frb_generated::StreamSink;

/// One `ciph_msg:`/`kchat:` match in an ACCEPTED transaction, from the message
/// walk (P2.1 raw receive; LINK-Q3 moved its source off the full-block stream).
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

/// A conversation row for the contacts surface.
///
/// **Two fields are NOT public-wire-class, and the rest are.** Addresses,
/// txids, aliases, ids and status are all on-chain or on-wire; `preview` is
/// decrypted message text (D-303) and `contact_name` is a label the user typed
/// about a real person. That is why this type has a hand-written [`Debug`]
/// instead of a derived one — see it for the reasoning — and why SOT §11's row
/// for `transport_conversations` was amended in the same commit that added the
/// preview rather than left claiming what it claimed before.
#[derive(Clone)]
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
    /// A `pending_in` invitation whose bond tx is past the node's pruning
    /// horizon (V5, finding 15): the accept can NEVER resolve — the bond
    /// UTXO is spent/pruned and the return-address RPC is gone with it. The
    /// card renders the honest terminal copy + a Dismiss exit instead of the
    /// transient promise. Computed in Rust from the pin-read horizon
    /// (INV-9); only this bool crosses the FFI. Always `false` for other
    /// statuses.
    pub invite_expired: bool,
    /// The local name the user gave this address, when they gave one. Device
    /// only — never on the wire, never in a backup.
    pub contact_name: Option<String>,
    /// **The last thing said in this thread, as one bounded line** — `M1`'s
    /// second row (founder ruling, 2026-09-08 / D-303).
    ///
    /// **This is decrypted user content, and it is the only field on this DTO
    /// that is.** Everything else here is public-wire-class; this one opens
    /// the newest envelope per conversation under the same vault gate
    /// [`transport_thread`] opens a thread with, and it exists outside a
    /// thread's lifetime, which is why `wallet-security-auditor` is mandatory
    /// on the change that introduced it and why SOT §11's clause on this
    /// function was amended in the same commit.
    ///
    /// **Bounded in Rust, ellipsised by the widget.** The cap here
    /// ([`PREVIEW_CHARS`]) is a CUSTODY bound — how much plaintext may leave
    /// the vault per row — not a visual one; the row still applies its own
    /// `TextOverflow.ellipsis`, because every frame this app supports is
    /// narrower than the cap and `M1` draws the `…`.
    ///
    /// `None` in three honest cases, and the row then falls back to the state
    /// line it drew before this field existed: the vault is locked, the thread
    /// holds no message rows at all, or the newest row is a handshake (whose
    /// news IS the row's state — *Wants to connect*, *Awaiting their accept*).
    pub preview: Option<String>,
    /// Inbound messages in this thread past the device's read mark — `M1`'s
    /// figure under the time. `0` draws nothing at all, never an empty badge.
    ///
    /// Derived per pull from the rows and the mark, never stored, so it cannot
    /// disagree with the thread it counts.
    pub unread: u32,
    /// The counterparty's address is on the user's block list (D-308). True
    /// only on a request from someone the user refused — the request still
    /// surfaces, because a handshake is the one door a blocked person may
    /// still knock on, and accepting it lifts the block. A blocked address
    /// never holds an Active row: blocking destroyed it.
    pub blocked: bool,
    /// **This thread can be read but not answered until a new handshake goes
    /// out** (D-307). The row was minted by THEIR message after a wipe took
    /// the alias they know us by, and no client re-announces one: the thread
    /// says so and offers the handshake. Derived from the row (`Active` with
    /// no alias of ours), never stored.
    pub reply_needs_handshake: bool,
}

/// **Counts and shapes, never content** — the same posture `TransportStore`
/// carries one crate over, for the same reason.
///
/// A derived `Debug` would put a stranger's message text and a real person's
/// name into any `{:?}` that ever reaches this type: a log line, a panic
/// message, or a container printed whole. None exists today, which is exactly
/// when it is cheap to make impossible (`wallet-security-auditor`, this
/// sitting; §4's plaintext-logging discipline).
impl std::fmt::Debug for ConversationDto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConversationDto")
            .field("conversation_id", &self.conversation_id)
            .field("contact_address", &self.contact_address)
            .field("my_alias", &self.my_alias)
            .field("their_alias", &self.their_alias)
            .field("status", &self.status)
            .field("initiated_by_me", &self.initiated_by_me)
            .field("created_unix_ms", &self.created_unix_ms)
            .field("last_activity_unix_ms", &self.last_activity_unix_ms)
            .field("invite_expired", &self.invite_expired)
            // Both redacted: how many characters, never which.
            .field("contact_name", &self.contact_name.as_ref().map(|n| n.len()))
            .field("preview", &self.preview.as_ref().map(|p| p.chars().count()))
            .field("unread", &self.unread)
            .field("blocked", &self.blocked)
            .field("reply_needs_handshake", &self.reply_needs_handshake)
            .finish()
    }
}

/// A file a counterparty sent. Every field here is OURS: the name is scrubbed
/// to a base name, the size is what we decoded (never what they claimed), and
/// `kind` is our own classification, never their `mimeType`.
#[derive(Clone, Debug)]
pub struct AttachmentDto {
    pub name: String,
    pub size_bytes: u64,
    /// `text` / `image` / `other` — a coarse, allowlisted bucket. Markup types
    /// deliberately land in `other` and stay opaque.
    pub kind: String,
    /// The decoded text, for `text` attachments only. `None` for everything
    /// else: bytes we will not interpret never cross the bridge as content.
    pub text: Option<String>,
    /// True when the body claimed to be a file and could not be decoded — the
    /// row says so instead of falling back to rendering its raw JSON.
    pub broken: bool,
    /// The media type to hand the SYSTEM when opening this file, derived from
    /// the extension we scrubbed — never from the sender's `mimeType`. Markup
    /// types resolve to the neutral type so no browser is ever routed to.
    pub view_mime: String,
}

/// One thread row — [`text`](Self::text) is THE first decrypted content to
/// cross this bridge (user content post-decrypt, D-056; ffi-leak pre-cleared
/// shape). Produced only by [`transport_thread`] (decrypt-on-view, §0.4):
/// Dart renders and drops it; nothing here is cached, logged, or persisted.
#[derive(Clone)]
pub struct ThreadMessageDto {
    pub txid: String,
    /// `handshake` (a system row — no body) or `comm`.
    pub kind: String,
    pub outbound: bool,
    pub unix_ms: u64,
    /// Decrypted message text for readable `comm` rows; empty otherwise. When
    /// [`frame`](Self::frame) is set this is the frame's readable line (what a
    /// Kasia user sees; the KaspaVerse card fallback), not the machine tail.
    pub text: String,
    /// False when no watched key opens the envelope (kept honest, not hidden).
    pub readable: bool,
    /// Set when the decrypted body carried a RECOGNIZED `kv:1:` game frame —
    /// the tappable arcade half. `None` for a plain message OR an unknown /
    /// forward-version tail (which render as an ordinary bubble from `text`,
    /// P5). Display-only: a frame binds no value (§0.3).
    pub frame: Option<FrameDto>,
    /// A file the counterparty sent, when this message is one. Set instead of
    /// [`text`](Self::text) — a file body IS the whole plaintext.
    pub attachment: Option<AttachmentDto>,
    /// V1 reorg honesty: true when this message's accepting block was
    /// displaced and not re-accepted within the observed window — the row is
    /// a ghost (styled affordance lands in V2; the flag is the truth surface).
    pub tombstoned: bool,
    /// Where this row came from: `node` (our node's own scan — chain truth),
    /// `archive` (a history-fill row from an indexer, D-074 — an unverifiable
    /// txid and timestamp), `own` (self-authored at commit), `unknown`
    /// (written before V5 recorded provenance).
    ///
    /// The store has recorded this since V5; it did not cross the bridge, so an
    /// archive-supplied row rendered byte-identically to node truth and the
    /// fill's disclosure promised a guarantee the wire cannot make
    /// (product-audit run 1, F3). A `String` rather than the chain crate's
    /// `RowSource`, matching [`kind`](Self::kind): the enum is a store-layer
    /// type with Borsh positional law on it, and widening its blast radius to
    /// the FFI buys nothing the label does not.
    pub provenance: String,
}

/// **Counts and shapes, never content** — the same posture `ConversationDto`
/// and `TransportStore` carry, and for the same reason: a derived `Debug` puts
/// a decrypted message into any `{:?}` that ever reaches this type, and the
/// module's own log tripwire matches identifier NAMES, so `log::info!("row
/// {row:?}")` walks straight past it (`ffi-leak-auditor`, this sitting —
/// hardening one of three DTOs created the asymmetry this closes).
impl std::fmt::Debug for ThreadMessageDto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ThreadMessageDto")
            .field("txid", &self.txid)
            .field("kind", &self.kind)
            .field("outbound", &self.outbound)
            .field("unix_ms", &self.unix_ms)
            .field("text", &self.text.chars().count())
            .field("readable", &self.readable)
            .field("frame", &self.frame.is_some())
            .field("attachment", &self.attachment.is_some())
            .field("tombstoned", &self.tombstoned)
            .field("provenance", &self.provenance)
            .finish()
    }
}

/// The five acceptance states a chip can wear (V2). Field-less — FRB 2.12
/// maps an enum-with-fields to a freezed class (the dag.rs DTO note); the
/// per-state numbers ride [`TxStatusDto`]'s optional fields instead.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TxStatusKind {
    Submitted,
    Accepted,
    Confirmed,
    Displaced,
    Stalled,
}

/// The acceptance tracker's answer for one txid, mirrored for display (V2
/// status chips). A RENDERING of the chain crate's `TxStatus` — depth is
/// node-read there (INV-9); nothing is recomputed here.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TxStatusDto {
    pub kind: TxStatusKind,
    /// Node-read blue depth for `Accepted`/`Confirmed` (the V6
    /// observe-before-tuning surface); `None` otherwise.
    pub blue_depth: Option<u64>,
    /// How long a `Stalled` submit has waited; `None` otherwise.
    pub waited_ms: Option<u64>,
    /// **The accepting block's own header timestamp**, unix ms, for
    /// `Accepted`/`Confirmed`; `None` otherwise, including when the accepting
    /// block could not be fetched.
    ///
    /// It crosses because a receipt that prints an acceptance time must print
    /// the CHAIN's moment. `DateTime.now()` at the instant a poll noticed is a
    /// wallet claim wearing a chain's clothes; so, as `ffi-leak-auditor` found
    /// in the first cut of this field, is the wallet's fold time recorded in
    /// Rust — it is the same observation moved one layer down, wrong by the
    /// poll latency on a live link and by hours on a catch-up replay (UX-4B).
    pub accepted_unix_ms: Option<u64>,
}

/// Per-txid display status for EVERY message in a conversation — the cheap
/// (no-decrypt) half of [`transport_thread_since`]. Rows already on the glass
/// apply these in place: a tombstone flip or an acceptance transition of a row
/// BEHIND the cursor would otherwise be invisible to an incremental pull (the
/// V2-design resolution of the cursor edge-case research hook).
#[derive(Clone, Debug)]
pub struct MessageStatusDto {
    pub txid: String,
    /// V1 reorg honesty (reversible ghost flag).
    pub tombstoned: bool,
    /// `None` = unwatched or horizon-pruned — store/wallet truth stands alone.
    pub acceptance: Option<TxStatusDto>,
}

/// One incremental thread pull: the decrypted NEW tail plus the status of
/// every row in the conversation.
#[derive(Clone, Debug)]
pub struct ThreadDeltaDto {
    /// Rows strictly after the cursor in the store's `(unix_ms, txid)` order,
    /// decrypted on view (§0.4). The FULL thread when the cursor is absent or
    /// unknown — the caller keys rows by txid, so a full merge is idempotent.
    pub messages: Vec<ThreadMessageDto>,
    /// Status for every message txid in the conversation, cursor-independent.
    pub statuses: Vec<MessageStatusDto>,
}

/// A parsed `kv:1:` game frame (P2.4 §0.5). Fields come from the frame JSON, so
/// a tampered readable line can't misstate the card. Nothing here binds value —
/// the `stake` is a DISPLAY number; the real wager binds at the P3 covenant.
#[derive(Clone, Debug)]
pub struct FrameDto {
    /// `challenge` | `accept` | `result` | `taunt`.
    pub kind: String,
    /// `challenge`: the game slug (P2.4: `attack_defend`); empty otherwise.
    pub game: String,
    /// `challenge`: the DISPLAY stake in KAS; empty ⇒ a friendly, no-stake duel.
    pub stake: String,
    /// The challenge id this frame concerns (a `challenge`'s own id, or the id
    /// an `accept`/`result` references) — enables card pairing; empty otherwise.
    pub id: String,
    /// `result`: the reported outcome (a claim). `taunt`: the text. Else empty.
    pub detail: String,
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
        /// The namespace the comm was composed in (§K11), recorded on its
        /// row so the thread's own history says which dialect each message
        /// went out in.
        wire: WireNamespace,
    },
    /// The D-138 conversation backup. Records what the snapshot covered and
    /// touches NOTHING else — no conversation, no message row.
    ///
    /// That emptiness is the design. Kasia's stash is emitted from inside their
    /// handshake flow, *after* the handshake is already on the wire, so a stash
    /// failure throws over a broadcast transaction. Ours is its own user
    /// action, which makes that class of failure unreachable rather than
    /// handled.
    SelfStash {
        covered: Vec<String>,
        timestamp_ms: u64,
    },
}

/// How input[0] gets chosen inside [`prepare_transport_send`].
///
/// **This exists because of how the live indexer attributes ownership**, which
/// is not what any of our notes assumed. Reading its source
/// (`idx_block_processor.rs`): the `owner` it files a self-stash under is NOT
/// input[0]'s address. It is `inputs[0].previous_outpoint`, **required to be at
/// index 0**, looked up among transactions that were themselves `ciph_msg:`
/// operations, resolving to THAT transaction's output[0] address. Miss either
/// condition and the row is parked for later resolution from the node's
/// return-address RPC — which can quietly never happen during a historical
/// gap-fill, leaving a stash that exists on chain and is invisible to the only
/// query that could restore it.
///
/// So a backup asks for its funding to be ordered to hit that fast path. It is
/// a hint, not a guarantee: we take the best input[0] available and the
/// deferred resolution remains the fallback.
#[derive(Clone, Copy, PartialEq, Eq)]
enum PinPolicy {
    /// Spend the source's UTXOs in whatever order the wallet supplies.
    Default,
    /// Order input[0] so the indexer can attribute the row to us, and refuse
    /// rather than spend beyond the source address.
    OwnerAttributable,
}

/// Intent stashed alongside [`PENDING_TRANSPORT`] under the same nonce.
static PENDING_INTENT: Mutex<Option<(u64, TransportIntent)>> = Mutex::new(None);

fn stash_intent(nonce: u64, intent: TransportIntent) {
    *PENDING_INTENT
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some((nonce, intent));
}

/// The invitation a stashed Accept would refund, if the stash under `nonce` is
/// one. Read without consuming — the commit's pre-broadcast guard.
fn pending_accept_target(nonce: u64) -> Option<String> {
    let guard = PENDING_INTENT
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    match guard.as_ref() {
        Some((
            stored,
            TransportIntent::Accept {
                conversation_id, ..
            },
        )) if *stored == nonce => Some(conversation_id.clone()),
        _ => None,
    }
}

/// Is the invitation an Accept was prepared against no longer there to accept?
/// True when the row is gone (folded into another conversation, or erased) or
/// is no longer awaiting an accept. Pure over the store; tested.
fn accept_target_missing(store: &TransportStore, conversation_id: &str) -> bool {
    !store
        .conversation(conversation_id)
        .is_some_and(|c| c.status == ConversationStatus::PendingInbound)
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
    /// The process's one message store, shared by every hub generation
    /// ([`hub_stores`], PRE3-LOG).
    store: Arc<Mutex<TransportStore>>,
    decryptor: TransportDecryptor,
    /// The addresses an inbound envelope must touch to be ours, and the key
    /// slots we try to open it with.
    ///
    /// ONE lock over BOTH, because address discovery can widen the wallet's
    /// window after the hub is built and the two must move together: a watched
    /// address whose key slot is missing is a message we can never decrypt, and
    /// a key slot whose address is unwatched is never reached at all. Two
    /// mutexes would let a reader take its two snapshots either side of a
    /// widening and see exactly that split — nanoseconds wide, and free to
    /// close. See [`widen_key_window`].
    keys: Mutex<Arc<KeyWindow>>,
    /// The user's refusals (D-308), loaded once with the store and written
    /// through to `block.list` on every change. In memory because the comm
    /// lane consults it for every unroutable comm on a public chain, and a
    /// file read per stranger's message is a cost with no reason.
    ///
    /// **Lock order: `store` before `block_list`, never the reverse.** Every
    /// site that holds both takes them in that order; a site that needs only
    /// this one takes it alone.
    ///
    /// One per process, like the store ([`hub_stores`]): it saves whole, so a
    /// second instance's save would undo the first's change.
    block_list: Arc<Mutex<BlockList>>,
}

/// The hub's watched set and key slots as one replaceable value.
struct KeyWindow {
    watched: HashSet<String>,
    /// Receive slots first — the likelier establishment binding.
    slots: Vec<KeySlot>,
}

impl KeyWindow {
    fn build(receive: u32, change: u32, addresses: &[Address]) -> Self {
        Self {
            watched: addresses.iter().map(|a| a.to_string()).collect(),
            slots: (0..receive)
                .map(|i| (Branch::Receive, i))
                .chain((0..change).map(|i| (Branch::Change, i)))
                .collect(),
        }
    }

    /// The slots a HANDSHAKE may have been sealed to: **the whole window**.
    ///
    /// This looked like the obvious place to halve an attacker-triggerable scan
    /// — a handshake bonds an address we hand out, and we hand out receive
    /// addresses. `fill_walks` sweeps the receive branch alone for exactly that
    /// reason. It is wrong here, and the difference is where the counterparty
    /// gets the address from.
    ///
    /// `fill_walks` asks an indexer about addresses WE published. A sender
    /// resolves our return address from the chain: `get_utxo_return_address`
    /// answers with the address behind **input[0]** of a transaction we
    /// broadcast (pin `rpc/core/src/api/rpc.rs:455`; it is the primitive the
    /// live population uses, Kasia's own service included). Our inputs are
    /// whatever the Generator selected, and on a wallet that has sent before,
    /// that is overwhelmingly returning change. So a counterparty can, and
    /// routinely will, seal a handshake to one of our CHANGE slots.
    ///
    /// Scanning the receive prefix only would have dropped those at a bare
    /// `return false`, with no log line and no way to establish the
    /// conversation — a silent interop hole against exactly the clients this
    /// protocol has to talk to. The window is receive-first, so the common case
    /// still exits early; the cost is paid on the miss, which is the honest
    /// price of being reachable.
    fn handshake_slots(&self) -> &[KeySlot] {
        &self.slots
    }
}

impl TransportHub {
    /// A snapshot of the watched set and key slots — one `Arc` bump, so a reader
    /// can never see the two halves from different windows, and no lock is held
    /// across a decrypt.
    fn keys(&self) -> Arc<KeyWindow> {
        self.keys
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

/// Widen the hub's watched set and key window to `(receive, change)` after a
/// late discovery pass found the wallet reaches deeper than the window this
/// session started on.
///
/// Never narrows: a smaller window than the one already armed is ignored, so a
/// caller cannot cost us a conversation by passing a stale read. A no-op when
/// no hub is running or the vault is locked (the next `transport_start()`
/// derives from the widened marks anyway).
pub(crate) fn widen_key_window(window: (u32, u32)) {
    let Some(hub) = HUB.lock().unwrap_or_else(PoisonError::into_inner).clone() else {
        return;
    };
    let (receive, change) = window;
    let armed = hub.keys().slots.len();
    if (receive as usize + change as usize) <= armed {
        return;
    }
    let addresses = match vault::derive_wallet_addresses(receive, change) {
        Ok((addresses, _)) => addresses,
        Err(e) => {
            log::warn!(
                "transport-hub: key window not widened ({}) — vault locked",
                e.message
            );
            return;
        }
    };
    // One publish, so no reader can observe a half-widened hub.
    *hub.keys.lock().unwrap_or_else(PoisonError::into_inner) =
        Arc::new(KeyWindow::build(receive, change, &addresses));
    log::info!(
        "transport-hub: key window widened to receive={receive} change={change} after discovery"
    );
}

static HUB: Mutex<Option<Arc<TransportHub>>> = Mutex::new(None);
/// V1 consumer #2 (reorg tombstones) — replaced on re-unlock so one stream
/// never feeds two folders.
static ACCEPTANCE_TASK: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);
/// F5's sweep lane — replaced on re-unlock like the tombstone task. (It carried
/// F4's reconnect replay too until LINK-Q3's walk made every gap a replay.)
static SWEEP_TASK: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);

/// **The message hub as the walk's committing consumer** (LINK-Q3, D-344).
/// Each page's matches fold here in chain order, and the walk commits its
/// cursor only when every one of them folded — Kafka's commit-after-processing,
/// made safe to replay by the store's dedupe by txid. A vault that locks under
/// the fold holds the page: the fold stops at the first `Locked` drop (what came
/// before it in the page is stored, and the replay dedupes it), and the
/// unlock's arm replays the page. This replaced a broadcast receiver, which
/// could lag and drop live messages outright (the 14-day capture's 8,153
/// `fold lagged` lines, 2026-09-05..07); a sink is backpressure, it cannot lag.
struct HubSink {
    hub: Arc<TransportHub>,
}

impl kaspaverse_chain::MessageSink for HubSink {
    fn skipped(&self, from: kaspaverse_chain::Hash, to: kaspaverse_chain::Hash) {
        let Some(monitor) = crate::api::dag::monitor() else {
            return;
        };
        tokio::spawn(async move {
            resolve_skipped_gap(&monitor, from, to).await;
        });
    }

    fn fold(&self, matches: Vec<TransportEvent>) -> kaspaverse_chain::VerdictFuture<'_> {
        Box::pin(async move {
            for event in matches {
                if handle_inbound(&self.hub, event, EventOrigin::Node).await == FoldOutcome::Locked
                {
                    return kaspaverse_chain::Verdict::Held;
                }
            }
            kaspaverse_chain::Verdict::Folded
        })
    }
}

/// Sparse, content-free change pings (a conversation id) — Dart re-pulls.
static THREAD_PINGS: OnceLock<broadcast::Sender<String>> = OnceLock::new();

/// The V1 gap-age signal (deliverable 6): computed once per open from the
/// persisted scan cursor's block time; V2b's fill + honest notice consume it.
/// `None` = first run (no prior cursor) or not yet resolved this open.
static GAP_AGE: Mutex<Option<GapAgeDto>> = Mutex::new(None);

/// "How much history did this open skip?" — the honest number behind V2b's
/// gap notice. All node-read data (INV-9): cursor block timestamp vs now.
#[derive(Clone, Debug, Default)]
pub struct GapAgeDto {
    /// Minutes between the last-scanned block and now, when knowable.
    pub gap_minutes: Option<u64>,
    /// True when the node no longer knows the cursor block: the gap is at
    /// least the pruning horizon (read from the pinned params — see
    /// `kaspaverse_chain::pruning_horizon_ms`), and history before it is
    /// unrecoverable from any normal node.
    pub beyond_horizon: bool,
    /// True when the message walk SKIPPED part of the history this session
    /// (LINK-Q4): a spent catch-up budget, a cursor the node did not know, or
    /// a page it could not serve three times. The node will not replay what
    /// was skipped, so the notice speaks whatever the gap's length, on a line
    /// of its own. `gap_minutes` is then the longer of the open's gap and any
    /// skip's span, which the skip line does not print.
    pub skipped: bool,
}

/// The gap-age computed at this open (`None` until resolved / first run).
/// Pull surface for V2b's notice; also logged + span-marked when resolved.
pub fn transport_gap_age() -> Option<GapAgeDto> {
    GAP_AGE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

// ── V2b history fill (D-074 — the indexer as a verifiable hint) ────────────

/// The user's fill posture, for the settings surface. `default_endpoint`
/// rides along so the UI can offer "reset to default" without hardcoding it.
#[derive(Clone, Debug)]
pub struct FillConfigDto {
    /// Defaults OFF — the §0 lock (founder-ruled 2026-07-10): node-only out
    /// of the box; enabling is an explicit opt-in beside the disclosure.
    pub enabled: bool,
    pub endpoint: String,
    pub default_endpoint: String,
}

/// One fill run's outcome — row counts and shape only, never content. The
/// honest-notice logic reads this: `!ran || !complete` keeps the "history
/// before X may be incomplete" notice up (never silence — D-074).
#[derive(Clone, Debug)]
pub struct FillReportDto {
    /// False when the fill is disabled or another run was already in flight.
    pub ran: bool,
    /// Every walk drained within budget and without a network error.
    pub complete: bool,
    pub pages: u32,
    /// New rows folded into the store (post verify-by-decrypt + txid dedup).
    pub new_rows: u32,
    /// First network/HTTP error text, when any walk failed.
    pub error: Option<String>,
    pub at_unix_ms: u64,
}

/// Generation counter for "the user destroyed content", bumped by
/// [`transport_wipe_all`] AND [`transport_clear_messages`].
///
/// A history fill is spawned on every unlock and walks for as long as the
/// indexer takes. It loads the cursors once at entry and blind-writes the
/// whole struct at exit, so a wipe landing mid-walk was undone twice over: the
/// rows folded after the erase went straight into the emptied store, and the
/// final save wrote the PRE-wipe cursors back over the floor
/// (`consensus-auditor` BLOCK, 2026-08-17). `floor_persisted` was true when it
/// was written and false a minute later.
///
/// Same shape as the vault's `LOCK_EPOCH` (D-158) and for the same reason: a
/// long operation must not commit state a user action has since invalidated.
/// Read once at walk entry — BEFORE the cursors it guards — and compared
/// before every fold and every save.
///
/// A per-conversation clear bumps it too, and that is not over-caution: the
/// clear floors one comm cursor while an in-flight walk holds a pre-clear copy
/// of the whole struct and blind-writes it back at the end, which would both
/// clobber the floor and re-fold every historical inbound comm into the thread
/// the user just emptied. The cost of the bump is one fill run that resumes at
/// the next open.
static ERASE_EPOCH: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// The generation in force right now.
fn erase_epoch() -> u64 {
    ERASE_EPOCH.load(std::sync::atomic::Ordering::SeqCst)
}

/// Serialises an erasure's {floor, bump} against a fill's {epoch read, cursor
/// load} and {epoch check, cursor save}.
///
/// **Ordering alone was not enough, and the reason is worth keeping.** Reading
/// the epoch before the cursors closed the "fill already running" case. It did
/// not close "fill about to start": the erase bumped first and stamped the
/// floor afterwards, so a walk beginning inside that window read the NEW epoch
/// and the PRE-floor cursors, matched every guard it later met, folded our own
/// on-chain backup into the emptied store and saved floor-0 cursors over the
/// top. The window is the whole erase body — two fsync+rename pairs plus file
/// I/O — and it is reachable without an adversary: the fill auto-runs on every
/// unlock and the settings sheet has a "check now" (`consensus-auditor` BLOCK,
/// 2026-08-17, round 4).
///
/// A plain `Mutex<()>`, held across no `.await` at any of its four sites (L7).
///
/// **Stated residual: one row per lane can still land.** The fold guards sit
/// immediately before an `.await` on `handle_inbound`, so an erase committing
/// inside that await folds one row into the emptied store before the next
/// iteration abandons. Widening the gate to cover it would hold a plain mutex
/// across an await, which this project forbids for better reasons than this one
/// is worth; the real close is an erase check inside the fold's own store-lock
/// scope. Bounded to one row per lane, and said out loud rather than left for a
/// reader to discover.
static ERASE_GATE: Mutex<()> = Mutex::new(());

/// The walk's own read of {generation, cursors}, taken atomically against
/// [`seal_erasure`] under [`ERASE_GATE`].
///
/// Extracted so the property can be TESTED through the same door the walk uses.
/// The pair is what matters — an epoch and the cursors that belong to it — and
/// asserting it any other way pins a lookalike rather than the thing that
/// protects the walk.
fn gated_walk_start(dir: &std::path::Path) -> (u64, kaspaverse_chain::history_fill::FillCursors) {
    let _gate = ERASE_GATE.lock().unwrap_or_else(PoisonError::into_inner);
    (
        erase_epoch(),
        kaspaverse_chain::history_fill::FillCursors::load(dir),
    )
}

/// Stamp the fill's erase floor, then bump the generation — both under
/// [`ERASE_GATE`], floor FIRST.
///
/// **The gate and the ordering buy different things, and both are load-bearing.**
/// Measured, not argued — each was removed in turn and the tests watched:
///
/// - **Floor-before-bump** gives "sees generation N ⟹ generation N's floor is
///   already on disk". It holds even with an ungated reader, because the save
///   happens-before the bump. Remove it (bump between `mutate` and `save`) with
///   the reader ungated and `a_walk_can_never_see_a_generation_without_its_floor`
///   goes red on the first iteration.
/// - **The gate** gives atomicity to the two read-modify-write pairs the
///   ordering cannot reach: the walk's `{epoch read, cursors load}` and its
///   `{epoch check, cursors save}`. Without it the final check is a TOCTOU and
///   the walk writes its stale cursor map over a floor stamped microseconds
///   earlier — the round-4 BLOCK.
///
/// So neither subsumes the other, and an earlier version of this comment
/// claiming the gate made the ordering merely defensive was wrong.
///
/// Returns whether the floor is durable. `false` is a real outcome the caller
/// must surface, not an error to swallow: the content is already destroyed by
/// the time it matters, and the honest report is "erased, but the catch-up
/// could still bring it back".
fn seal_erasure(mutate: impl FnOnce(&mut kaspaverse_chain::history_fill::FillCursors)) -> bool {
    let _gate = ERASE_GATE.lock().unwrap_or_else(PoisonError::into_inner);
    let persisted = match vault::transport_store_dir() {
        Ok(dir) => {
            // The parent is created by the write itself (`write_json*`), which
            // is where it belongs: the sibling `transport_set_fill_config` had
            // the identical missing-parent shape and no guard, so a wallet with
            // no conversations errored on saving a setting. Found by the
            // ordering test failing on a fresh harness dir, not by reasoning
            // about it.
            let mut cursors = kaspaverse_chain::history_fill::FillCursors::load(&dir);
            mutate(&mut cursors);
            match cursors.save(&dir) {
                Ok(()) => true,
                // Loud: a silent failure here means the next catch-up rebuilds
                // what the user just destroyed, and the caller renders a
                // different sentence for it.
                Err(e) => {
                    log::warn!("transport-erase: the fill floor did NOT persist: {e}");
                    false
                }
            }
        }
        Err(e) => {
            // Shape only — an `AppError` here names the vault state, not a
            // path, but it is not `Display` and this lane logs no content.
            log::warn!(
                "transport-erase: no store dir, so no fill floor: {}",
                e.message
            );
            false
        }
    };
    ERASE_EPOCH.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    persisted
}

/// Last run's report (per process; the notice re-derives on each open).
static LAST_FILL: Mutex<Option<FillReportDto>> = Mutex::new(None);

/// Skips the walk has reported this process (LINK-Q4): a fill run reads it
/// before and after its walk, and a skip in between keeps it from reading
/// complete.
static WALK_SKIPS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
/// One fill at a time — an open-time auto-run and a settings-sheet "check
/// now" must not double-walk (txid dedup would make it correct; the guard
/// makes it cheap).
static FILL_RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Current fill config (file-backed; defaults OFF + the hosted default).
pub fn transport_fill_config() -> Result<FillConfigDto, AppError> {
    let dir = vault::transport_store_dir()?;
    let config = kaspaverse_chain::history_fill::FillConfig::load(&dir);
    Ok(FillConfigDto {
        enabled: config.enabled,
        endpoint: config.endpoint,
        default_endpoint: kaspaverse_chain::history_fill::DEFAULT_INDEXER.to_string(),
    })
}

/// Persist the fill posture. The endpoint is validated (http/https) here —
/// a rejected save leaves the previous config untouched.
pub fn transport_set_fill_config(enabled: bool, endpoint: String) -> Result<(), AppError> {
    let dir = vault::transport_store_dir()?;
    let endpoint = endpoint.trim().to_string();
    let endpoint = if endpoint.is_empty() {
        kaspaverse_chain::history_fill::DEFAULT_INDEXER.to_string()
    } else {
        endpoint
    };
    let config = kaspaverse_chain::history_fill::FillConfig { enabled, endpoint };
    config.save(&dir).map_err(AppError::chain)?;
    log::info!(
        "history-fill: config saved (enabled={}, endpoint set)",
        enabled
    );
    Ok(())
}

/// The last fill run's report (`None` = no run this process).
pub fn transport_fill_status() -> Option<FillReportDto> {
    LAST_FILL
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
}

/// Run the fill immediately (the settings sheet's "check now"; the open-time
/// auto-run uses the same path). Returns the report it also stores.
pub async fn transport_fill_now() -> Result<FillReportDto, AppError> {
    let hub = hub()?;
    Ok(run_fill(&hub).await)
}

/// The fill itself: page-walk the configured indexer per Gate K §K7 —
/// handshakes by receiver (each receive-branch address; recovers NEW inbound
/// contacts), comms by (contact address, THEIR alias) per active conversation
/// — and feed every row through the EXISTING inbound pipeline
/// ([`handle_inbound`]): verify-by-decrypt, txid dedup, ciphertext-at-rest
/// §0.4 — the fill has no decrypt surface of its own. Our own sent comms are
/// deliberately not queried (sealed to the counterparty; unrecoverable by
/// design — the K8 restore posture).
async fn run_fill(hub: &Arc<TransportHub>) -> FillReportDto {
    use kaspaverse_chain::history_fill::FillConfig;
    use std::sync::atomic::Ordering;

    let idle = FillReportDto {
        ran: false,
        complete: false,
        pages: 0,
        new_rows: 0,
        error: None,
        at_unix_ms: now_unix_ms(),
    };
    let Ok(dir) = vault::transport_store_dir() else {
        return idle;
    };
    let config = FillConfig::load(&dir);
    if !config.enabled {
        return idle;
    }
    // Verify-by-decrypt needs a LIVE vault: with it locked, every genuine
    // envelope would fail decryption locally and the cursor would advance
    // past recoverable history while reporting complete (consensus-audit
    // finding, V2b). Refuse honestly instead.
    if !hub.decryptor.is_live() {
        let mut report = idle;
        report.ran = true;
        report.error = Some("wallet is locked — unlock and check again".to_string());
        *LAST_FILL.lock().unwrap_or_else(PoisonError::into_inner) = Some(report.clone());
        return report;
    }
    if FILL_RUNNING
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        log::info!("history-fill: a run is already in flight — skipped");
        return idle;
    }
    // Everything below must release the guard — one exit point at the end.
    let report = counted_fill(fill_walks(hub, &dir, &config)).await;
    FILL_RUNNING.store(false, Ordering::SeqCst);
    log::info!(
        "history-fill: run finished (complete={}, pages={}, new_rows={}, error={})",
        report.complete,
        report.pages,
        report.new_rows,
        report.error.is_some(),
    );
    kaspaverse_chain::spans::mark_with("fill_rows", &report.new_rows.to_string());
    ping_notice_inputs();
    report
}

/// The walk half of [`run_fill`] (guard-free; caller owns the run lock).
async fn fill_walks(
    hub: &Arc<TransportHub>,
    dir: &std::path::Path,
    config: &kaspaverse_chain::history_fill::FillConfig,
) -> FillReportDto {
    use kaspaverse_chain::history_fill::{encode_hex, walk_pages, IndexerClient};

    let mut report = FillReportDto {
        ran: true,
        complete: true,
        pages: 0,
        new_rows: 0,
        error: None,
        at_unix_ms: now_unix_ms(),
    };
    let client = match IndexerClient::new(&config.endpoint) {
        Ok(client) => client,
        Err(e) => {
            report.complete = false;
            report.error = Some(e.to_string());
            return report;
        }
    };
    // BEFORE the cursors, and the order is the guarantee. Read after, and an
    // erase landing in between is invisible: we would hold PRE-erase cursors
    // under a POST-erase epoch, the comparison would match forever, every fold
    // would land in the emptied store and the save would write the old resume
    // positions back over the floor — the very race this guard exists for,
    // through a microsecond window. Reading first can only fail the safe way:
    // post-erase cursors under a pre-erase epoch abort the walk.
    //
    // (The vault's `LOCK_EPOCH` reads its generation under the `VAULT` guard,
    // which is what makes its two outcomes both correct. There is no such
    // serialisation here, so the ordering has to do that work — hence this
    // comment rather than a citation.)
    let (epoch, mut cursors) = gated_walk_start(dir);

    // Backup sweep (D-138): the conversations we parked on chain ourselves.
    //
    // **FIRST, and that ordering is load-bearing — proven on the device.**
    // When this ran last, a restore rebuilt one conversation out of three: the
    // handshake sweep went first, replayed eight old handshakes into fresh
    // INVITATIONS (no alias of ours, a bond needed to accept), and the backup's
    // proper rows — carrying both aliases and the bound slot — were then refused
    // as colliding with them. The weaker recovery path beat the authenticated
    // one by fourteen seconds.
    //
    // A backup is the only source that knows OUR alias for a conversation; the
    // handshake sweep can only ever produce a half-conversation. So the
    // authenticated record lands first and the weaker lane yields to it.
    //
    // ONE address — `receive/0` — for three reasons, in order of weight: it is
    // the only owner our own writer ever produces; it is the only address a
    // restore can derive before any store exists; and one query hands the
    // operator one address instead of a correlatable sweep of the whole
    // receive prefix for history that, by construction, only we wrote.
    //
    // This is the half of restore the handshake sweep structurally cannot do.
    // `handshakes/by-receiver` finds invitations addressed TO us and can never
    // find one we SENT, which is exactly why a restore used to come back with
    // every inbound conversation and not one outbound one.
    if hub.decryptor.is_live() {
        match vault::wallet_address_at(Branch::Receive, 0) {
            Ok(owner_address) => {
                let owner = owner_address.to_string();
                let start = cursors.start_at(&cursors.stash, &owner);
                let outcome = walk_pages(
                    |cursor| {
                        client.self_stash_by_owner(&owner, STASH_SCOPE_SAVED_HANDSHAKE, cursor)
                    },
                    start,
                    now_unix_ms(),
                )
                .await;
                report.pages += outcome.pages;

                let mut held = HeldFloor::new();
                // The NEWEST snapshot alone, not a merge across snapshots.
                //
                // A snapshot is a complete statement of the conversation list at
                // the moment it was written, not a delta — so an older one adds
                // nothing except the rows the user has since HIDDEN. Merging
                // would resurrect exactly what hiding means, and after a wipe
                // there is no tombstone left to refuse them: the suppression
                // record lived on the device being replaced. Keeping only the
                // newest makes the newest backup a revocation by construction.
                let mut newest: Option<(u64, String, SavedHandshakeSnapshot)> = None;
                for row in &outcome.items {
                    let Some(sealed) =
                        kaspaverse_chain::history_fill::decode_hex(&row.stashed_data)
                    else {
                        continue; // malformed hint row — omitted, never an error
                    };
                    let Ok(envelope) = Envelope::from_bytes(&sealed) else {
                        dropped(
                            SELF_STASH,
                            &row.tx_id,
                            DropReason::MalformedEnvelope,
                            EventOrigin::Fill,
                        );
                        continue;
                    };
                    let plaintext = match open_with_fallback(hub, (Branch::Receive, 0), &envelope) {
                        Ok(plaintext) => plaintext,
                        Err(error) => {
                            let reason = decrypt_drop(&error);
                            if dropped(SELF_STASH, &row.tx_id, reason, EventOrigin::Fill).holds() {
                                held.hold(row.block_time);
                            }
                            continue;
                        }
                    };
                    // AUTHORSHIP, not merely readability. Opening the envelope
                    // proves nothing about who wrote it: the seal is to our own
                    // PUBLIC key, so the archive answering this very query can
                    // mint a row our key opens. Since a restore CREATES
                    // conversations, an unauthenticated row would become a live
                    // thread carrying an attacker's address, and everything the
                    // user typed into it would be sealed to them. Only a tag
                    // keyed by the seed passes here.
                    //
                    // A vault lock landing here is NOT a forgery, and the two
                    // must not collapse into one answer. `stash_tag` is a vault
                    // operation, so an idle-lock between the decrypt above and
                    // this line returns `VaultLocked` — our own transient
                    // condition, which has to HOLD the cursor. Reporting it as
                    // "not ours" would settle the row, let the cursor step past
                    // our newest backup, and print a security-shaped line about
                    // a transaction we wrote ourselves.
                    let authentic = match split_stash_tag(&plaintext) {
                        Some((untagged, tag)) => {
                            match hub.decryptor.verify_stash_tag(&untagged, &tag) {
                                Ok(verified) => verified,
                                Err(error) => {
                                    let reason = decrypt_drop(&error);
                                    if dropped(SELF_STASH, &row.tx_id, reason, EventOrigin::Fill)
                                        .holds()
                                    {
                                        held.hold(row.block_time);
                                    }
                                    continue;
                                }
                            }
                        }
                        // No tag at all: a stash from a client that does not
                        // write one. Settled — it will never authenticate, so
                        // holding for it would wedge the walk forever.
                        None => false,
                    };
                    if !authentic {
                        dropped(
                            SELF_STASH,
                            &row.tx_id,
                            DropReason::StashNotOurs,
                            EventOrigin::Fill,
                        );
                        continue;
                    }
                    match SavedHandshakeSnapshot::from_plaintext(&plaintext) {
                        Ok(snapshot) => {
                            let supersedes = stash_supersedes(
                                (snapshot.stashed_at, row.block_time, &row.tx_id),
                                newest
                                    .as_ref()
                                    .map(|(t, id, s)| (s.stashed_at, *t, id.as_str())),
                            );
                            if supersedes {
                                newest = Some((row.block_time, row.tx_id.clone(), snapshot));
                            }
                        }
                        Err(_) => {
                            dropped(
                                SELF_STASH,
                                &row.tx_id,
                                DropReason::UndecodablePayload,
                                EventOrigin::Fill,
                            );
                        }
                    }
                }

                // The admissible slot window comes from the wallet's ONE source,
                // never a formula re-derived here — a narrower one would silently
                // rebind a conversation to an address the counterparty does not
                // know us by (D-067).
                let windows = wallet::wallet_window();
                let mut created = 0usize;
                // ONLY fold a walk that actually drained.
                //
                // The newest-snapshot rule is only sound over the whole set. A
                // walk cut short by the page budget or a network error may have
                // seen nothing but an OLD backup — and folding that one creates
                // conversations which `stash_row_is_free` then refuses the
                // correct snapshot against, forever. A restore is not urgent;
                // being right is. The cursor holds and the next run sees more.
                if !outcome.complete && newest.is_some() {
                    held.hold(start);
                    log::info!(
                        "history-fill: backup walk incomplete — not restoring from a partial view"
                    );
                }
                if let (true, Some((_, tx_id, snapshot))) = (outcome.complete, &newest) {
                    // THE LANE THE ERASE MOST NEEDS DEFENDING. This fold
                    // rebuilds conversations from our own on-chain backup, and
                    // `stash_row_is_free` passes trivially against an empty
                    // store — so a walk that was already in the network when
                    // the user tapped Delete would restore everything into the
                    // store that was just emptied, and the later guards would
                    // then dutifully decline to save the cursors for a store
                    // that is already repopulated.
                    if erase_epoch() != epoch {
                        return abandon_wiped_walk(report);
                    }
                    for payload in snapshot.rows() {
                        if erase_epoch() != epoch {
                            return abandon_wiped_walk(report);
                        }
                        match fold_stash_row(hub, tx_id, payload, &mut created, windows) {
                            FoldOutcome::Recorded => report.new_rows += 1,
                            FoldOutcome::Settled => {}
                            FoldOutcome::Held | FoldOutcome::Locked => held.hold(0),
                        }
                    }
                }

                // COVERAGE BECOMES PROVEN, not merely claimed. Until a walk has
                // actually read our last backup back, all we know is that we
                // broadcast one — and the indexer's attribution can fail
                // quietly, leaving a transaction that is on chain, valid, and
                // invisible to the only query that restores it.
                //
                // The proof is a row that DECRYPTED AND AUTHENTICATED, never a
                // txid match. Our txid is public chain data, so an archive
                // could echo it back over junk and flip the wallet from an
                // honest "not confirmed readable" to "all backed up" — taking
                // the one assurance the user acts on from an untrusted claim,
                // which is the shape INV-8 exists to refuse.
                // Writes the side file the erase deleted, so it is a commit
                // point too: re-asserting "coverage proven" about a backup for
                // conversations that no longer exist.
                if erase_epoch() != epoch {
                    return abandon_wiped_walk(report);
                }
                if let Some((_, proven_txid, _)) = &newest {
                    // Under the gate, like the cursor save — this WRITES the
                    // side file `transport_wipe_all` deletes, so a bare epoch
                    // check leaves a window in which a committing wipe has its
                    // `stash.state` re-created underneath it, re-asserting
                    // "coverage proven" about a backup of conversations that no
                    // longer exist.
                    let _gate = ERASE_GATE.lock().unwrap_or_else(PoisonError::into_inner);
                    if erase_epoch() != epoch {
                        return abandon_wiped_walk(report);
                    }
                    let mut state = kaspaverse_chain::history_fill::StashState::load(dir);
                    if !state.confirmed_readable
                        && !state.last_txid.is_empty()
                        && *proven_txid == state.last_txid
                    {
                        state.confirmed_readable = true;
                        if let Err(e) = state.save(dir) {
                            log::warn!("self-stash: coverage confirmation not saved: {e}");
                        } else {
                            log::info!("self-stash: the last backup reads back — coverage proven");
                        }
                    }
                }

                let resume = held.resume_from(outcome.cursor);
                if !outcome.items.is_empty() {
                    log::info!(
                        "history-fill: backup walk rows={} restored={created} cursor {start}->{resume}{}",
                        outcome.items.len(),
                        if held.any() { " (HELD)" } else { "" },
                    );
                }
                if resume > start {
                    cursors.stash.insert(owner, resume);
                }
                if !outcome.complete || held.any() {
                    report.complete = false;
                    if report.error.is_none() {
                        report.error = outcome.error.or_else(|| held.notice());
                    }
                }
            }
            Err(e) => {
                report.complete = false;
                if report.error.is_none() {
                    report.error = Some(e.message);
                }
            }
        }
    } else {
        // The same law the two sweeps above carry, and it was missing here.
        // A lane that is skipped while the run still reports `complete` is a
        // silent gap — and this is the one lane that matters on exactly the
        // path the feature exists for: a fresh restore, where the walk is long
        // and the vault's idle grace is short.
        report.complete = false;
        if report.error.is_none() {
            report.error =
                Some("the wallet locked while catching up — unlock and check again".to_string());
        }
        log::info!("history-fill: vault locked before the backup walk — nothing restored");
    }

    // Handshake sweep: the receive branch only.
    //
    // The reason this file used to give — "the change branch is internal and
    // never receives one" — is FALSE, and this branch is what disproved it: a
    // sender resolves our return address with `get_utxo_return_address`, which
    // answers with the address behind input[0] of a transaction we broadcast,
    // routinely one of our change addresses (see `KeyWindow::handshake_slots`).
    // The LIVE path handles those; this history sweep does not, so a
    // change-established conversation is unrecoverable from history. That is
    // omission, which is D-074's accepted failure mode and stays behind the
    // honest notice — but it is a real gap, logged to IDEAS_BACKLOG with its
    // trigger rather than left behind a comment that says it cannot happen.
    //
    // The real reason the sweep stays narrow is the one below: each address is a
    // separate paginated walk against an untrusted indexer, and the change
    // branch would roughly double a correlatable burst for history we can
    // usually re-derive from the live lane.
    //
    // Capped at the FUNDED receive prefix, not the whole watch window. Each
    // address here is a separate paginated walk against an untrusted indexer, so
    // sweeping the full discovered window would multiply both the run duration
    // and — worse — the slice of this wallet's address graph handed to one
    // server in one correlatable burst. The gap addresses past the last funded
    // one have no history to fill by construction.
    let sweep_depth = wallet::GAP_LIMIT.max(vault::scan_high_water().0);
    let receive_addresses = match vault::derive_wallet_addresses(sweep_depth, 0) {
        Ok((receive, _)) => receive,
        Err(e) => {
            report.complete = false;
            report.error = Some(e.message);
            return report;
        }
    };
    for address in &receive_addresses {
        // Liveness is re-checked per address, not once per run.
        //
        // `run_fill` gates the whole walk on one `is_live()` at the top, and
        // that gate is only true at the instant it is read: this sweep is one
        // paginated HTTP walk PER ADDRESS, so a full run outlives the vault's
        // 30-second idle grace easily. A vault that locks mid-walk used to
        // turn every remaining row into a silent `decrypt_scanning` failure
        // while the cursor advanced over all of them — history destroyed by a
        // guard that had already passed. Stop honestly instead; the held
        // cursors mean the next run resumes exactly here.
        if !hub.decryptor.is_live() {
            report.complete = false;
            if report.error.is_none() {
                report.error = Some(
                    "the wallet locked while catching up — unlock and check again".to_string(),
                );
            }
            log::info!("history-fill: vault locked mid-walk — stopping with cursors held");
            break;
        }
        let address = address.to_string();
        let start = cursors.start_at(&cursors.handshakes, &address);
        let outcome = walk_pages(
            |cursor| client.handshakes_by_receiver(&address, cursor),
            start,
            now_unix_ms(),
        )
        .await;
        report.pages += outcome.pages;
        let mut held = HeldFloor::new();
        for row in &outcome.items {
            let Some(body) = kaspaverse_chain::history_fill::decode_hex(&row.message_payload)
            else {
                continue; // malformed hint row — omitted data, never an error
            };
            let event = TransportEvent {
                txid: Some(row.tx_id.clone()),
                kind: "handshake".to_string(),
                // The Kasia indexer serves `ciph_msg` rows only (§K7 addendum).
                namespace: WireNamespace::CiphMsg,
                body,
                // The address WE swept, not the indexer's `receiver` claim.
                // The relevance gate exists to prove a row is ours; feeding
                // it a value the untrusted server chose lets that server
                // decide the answer — and with the cursor now holding on a
                // relevance miss, a forged `receiver` would pin this walk
                // forever. We asked by-receiver for this address, so this
                // address is the only honest relevance input.
                addresses: vec![address.clone()],
                block_time_ms: Some(row.block_time),
                // An indexer row has no carrying block we trust (D-139).
                block_hash: None,
                // The handshake lane takes no identity from an archive row
                // (D-139): a fill invitation stays address-less until our own
                // node reaches its txid.
                sender: None,
            };
            if erase_epoch() != epoch {
                return abandon_wiped_walk(report);
            }
            match handle_inbound(hub, event, EventOrigin::Fill).await {
                FoldOutcome::Recorded => report.new_rows += 1,
                FoldOutcome::Settled => {}
                FoldOutcome::Held | FoldOutcome::Locked => held.hold(row.block_time),
            }
        }
        let resume = held.resume_from(outcome.cursor);
        // Public routing data only (our own address, row counts, block times):
        // enough to tell "the indexer served nothing" apart from "it served a
        // row and the fold refused it" — the two the 2026-08-13 sitting could
        // not distinguish.
        if !outcome.items.is_empty() {
            log::info!(
                "history-fill: handshake walk rows={} cursor {start}->{resume}{}",
                outcome.items.len(),
                if held.any() { " (HELD)" } else { "" },
            );
        }
        if resume > start {
            cursors.handshakes.insert(address, resume);
        }
        if !outcome.complete || held.any() {
            report.complete = false;
            if report.error.is_none() {
                report.error = outcome.error.or_else(|| held.notice());
            }
        }
    }

    // Comm sweep: per ACTIVE conversation, by (contact address, THEIR alias)
    // ── see the handshake sweep above for the cursor-hold law.
    // — the sender tags comms with their own alias (§K7 partition key).
    let conversations: Vec<(String, String, String)> = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store
            .list_conversations()
            .into_iter()
            .filter(|c| c.status == ConversationStatus::Active)
            // Don't spend indexer round trips refilling a thread the user hid.
            .filter(|c| !store.is_conversation_tombstoned(&c.conversation_id))
            .filter_map(|c| {
                let their_alias = c.their_alias.clone()?;
                if c.contact_address.is_empty() || their_alias.is_empty() {
                    return None;
                }
                Some((
                    c.conversation_id.clone(),
                    c.contact_address.clone(),
                    their_alias,
                ))
            })
            .collect()
    };
    for (conversation_id, contact_address, their_alias) in conversations {
        // Same law as the handshake sweep above — see the note there.
        if !hub.decryptor.is_live() {
            report.complete = false;
            if report.error.is_none() {
                report.error = Some(
                    "the wallet locked while catching up — unlock and check again".to_string(),
                );
            }
            log::info!("history-fill: vault locked mid-walk — stopping with cursors held");
            break;
        }
        let alias_hex = encode_hex(their_alias.as_bytes());
        let start = cursors.start_at(&cursors.comms, &conversation_id);
        let outcome = walk_pages(
            |cursor| client.comms_by_sender(&contact_address, &alias_hex, cursor),
            start,
            now_unix_ms(),
        )
        .await;
        report.pages += outcome.pages;
        let mut held = HeldFloor::new();
        for row in &outcome.items {
            let Some(sealed) = kaspaverse_chain::history_fill::decode_hex(&row.message_payload)
            else {
                continue;
            };
            // Reassemble the wire body the live scan would have seen:
            // `<alias>:<sealed>` — the alias head sits OUTSIDE the envelope.
            let mut body = their_alias.clone().into_bytes();
            body.push(b':');
            body.extend_from_slice(&sealed);
            let event = TransportEvent {
                txid: Some(row.tx_id.clone()),
                kind: "comm".to_string(),
                namespace: WireNamespace::CiphMsg,
                body,
                addresses: Vec::new(),
                block_time_ms: Some(row.block_time),
                // An indexer row has no carrying block we trust (D-139).
                block_hash: None,
                // The archive's CLAIM about who sent it, parsed and ignored
                // until PRE3-SENDER. The comm lane folds the row only when the
                // claim names this conversation's contact (§0.10), and never for
                // a txid our own walk refused this session; the row keeps its
                // `archive` provenance on the glass. When our walk reaches the
                // txid after the fill, it replaces the row, or removes it when it
                // names another sender. An invented txid our walk never reaches
                // stays an archive row (the declared residual).
                sender: Some(row.sender.clone()),
            };
            if erase_epoch() != epoch {
                return abandon_wiped_walk(report);
            }
            match handle_inbound(hub, event, EventOrigin::Fill).await {
                FoldOutcome::Recorded => report.new_rows += 1,
                FoldOutcome::Settled => {}
                FoldOutcome::Held | FoldOutcome::Locked => held.hold(row.block_time),
            }
        }
        let resume = held.resume_from(outcome.cursor);
        if resume > start {
            cursors.comms.insert(conversation_id, resume);
        }
        if !outcome.complete || held.any() {
            report.complete = false;
            if report.error.is_none() {
                report.error = outcome.error.or_else(|| held.notice());
            }
        }
    }

    // The last commit point. `cursors` was loaded before the erase, so saving
    // it now would restore every pre-wipe resume position — including over the
    // floor that makes the erase durable.
    {
        let _gate = ERASE_GATE.lock().unwrap_or_else(PoisonError::into_inner);
        if erase_epoch() != epoch {
            return abandon_wiped_walk(report);
        }
        if let Err(e) = cursors.save(dir) {
            log::warn!("history-fill: cursor save failed: {e}");
        }
    }
    report
}

/// Stop a walk whose store was erased under it, writing NOTHING.
///
/// Reported as incomplete rather than as a clean run, because it is: the
/// honest-notice logic keys on `!complete` and the user should be told history
/// catch-up did not finish, not shown a tick over a walk that was abandoned.
fn abandon_wiped_walk(mut report: FillReportDto) -> FillReportDto {
    log::info!("history-fill: abandoned — messages were erased mid-walk; no rows, no cursors");
    report.complete = false;
    report.error = Some("history was erased while catching up".to_string());
    report
}

/// Order a funding set so input[0] is one the live indexer can attribute back
/// to us — the D-138 backup's whole read path depends on it.
///
/// **The rule this satisfies is not the one anyone assumed.** Both our audit
/// plan and the first cut of this design said the indexer keys a self-stash's
/// `owner` on input[0]'s address. It does not. Reading its source
/// (`idx_block_processor.rs`, 2026-08-14): take `inputs[0].previous_outpoint`,
/// **require its index to be 0**, look that funding transaction up among
/// transactions that were themselves `ciph_msg:` operations, and the owner is
/// THAT transaction's output[0] address. Miss either condition and the row is
/// parked for deferred resolution from the node's return-address RPC — which
/// usually succeeds live and can quietly never happen during a historical
/// gap-fill.
///
/// The failure that avoids is silent and total: a backup sitting on chain,
/// perfectly valid, invisible to the only query that could ever restore it.
///
/// So this SORTS and never filters — refusing to spend a badly-shaped coin
/// would refuse honest backups on a wallet that has only ever received — and
/// the sort is stable, so the wallet's own ordering survives within a tier.
///
/// Generic over the entry type purely so the rule is testable without
/// constructing consensus UTXOs (which would cost a new dependency for a test).
fn order_priority_for_owner<T>(
    entries: Vec<T>,
    outpoint_of: impl Fn(&T) -> (u32, String),
    is_own_protocol_tx: impl Fn(&str) -> bool,
) -> Vec<T> {
    let mut ordered = entries;
    ordered.sort_by_key(|entry| {
        let (index, txid) = outpoint_of(entry);
        match (index == 0, is_own_protocol_tx(&txid)) {
            // Index 0 of a transaction the indexer already parsed as a protocol
            // operation: the fast path, attributed the moment it is accepted.
            (true, true) => 0u8,
            // Index 0 of something else: half the condition, and still better
            // than nothing — the funder may be a protocol tx we never stored.
            (true, false) => 1,
            // Anything else can only reach `owner` by deferred resolution.
            _ => 2,
        }
    });
    ordered
}

/// How long to wait for our own change to become spendable before giving up,
/// and how often to look.
///
/// The budget covers BOTH legs of [`WalletEngine::settling_at`], and the second
/// is what binds it:
///
/// - For our own change the clock is ACCEPTANCE, not maturity — the pin
///   force-matures a UTXO belonging to one of our outgoing transactions the
///   moment its `UtxosChanged` notification arrives (context.rs:590 → 299-300),
///   so submit → notification is the whole wait, normally about a second.
/// - For anything that lands in the pending set instead — a third-party payment
///   to the bound address, or our own change re-inserted by a rescan through
///   `extend_from_scan` — the clock IS the 100-DAA hold (settings.rs:49), about
///   ten seconds at mainnet's ten blocks per second.
///
/// So 24 s is sized against the ten-second leg with room for a slow link and a
/// DAA clock that does not advance on a metronome — **not** against the
/// one-second leg. Tightening it to "a second, loosely" would break the case
/// this constant actually exists for. See [`await_spendable_at`].
const MATURITY_WAIT: std::time::Duration = std::time::Duration::from_secs(24);
const MATURITY_POLL: std::time::Duration = std::time::Duration::from_millis(400);

/// Does the candidate backup supersede the one we are holding?
///
/// **The newest snapshot alone speaks for the wallet.** A snapshot is a
/// complete statement of the conversation list at the moment it was written,
/// not a delta, so an older one can only add rows the user has since HIDDEN —
/// and after a wipe there is no tombstone left to refuse them, because the
/// suppression record lived on the device being replaced. Keeping only the
/// newest makes each backup a revocation of the one before it.
///
/// The txid tiebreak is not decoration: two backups can share a block time, and
/// a restore that depended on page order would rebuild differently on different
/// devices.
/// `stashed_at` is the snapshot's OWN build time, which rides inside the
/// authenticated body; `block_time`/`tx_id` are the archive's metadata and only
/// break ties. Ordering primarily on the signed field is what stops an archive
/// replaying a stale-but-genuine backup of ours under a fresh block time and
/// resurrecting conversations the user hid — with the untrusted field alone,
/// "the newest backup revokes the older one" was a claim about what the archive
/// chose to show us, not a property (INV-8).
fn stash_supersedes(
    candidate: (Option<u64>, u64, &str),
    current: Option<(Option<u64>, u64, &str)>,
) -> bool {
    let Some(current) = current else { return true };
    match (candidate.0, current.0) {
        (Some(a), Some(b)) if a != b => a > b,
        // A snapshot that states its build time outranks one that does not —
        // ours always states it, so an older foreign row cannot displace us.
        (Some(_), None) => true,
        (None, Some(_)) => false,
        _ => candidate.1 > current.1 || (candidate.1 == current.1 && candidate.2 < current.2),
    }
}

/// Turn a decrypted stash row into the conversation it describes, or `None` if
/// it describes one we could not use.
///
/// Pure over its inputs so the rules below are testable without a store.
fn restored_conversation(
    payload: &SavedHandshakePayload,
    receive_window: u32,
    change_window: u32,
) -> Option<ConversationRecord> {
    // The counterparty address decides where every future message is sealed, so
    // it has to be an address on OUR network — not merely a non-empty string.
    // Stored in the pin's canonical form, never as the archive spelled it: the
    // decoder drops non-zero padding bits (`bech32.rs` `conv5to8`), so a string
    // can validate and still differ from its address's own form, and the comm
    // lane compares senders as canonical strings (PRE3-SENDER,
    // `consensus-auditor`).
    let partner_address = validate_mainnet_address(&payload.partner_address)
        .ok()?
        .to_string();

    // The bound slot, clamped to the window we actually derive keys for. An
    // out-of-window index is not a reason to refuse the conversation; it is a
    // reason to fall back to the identity address and let the counterparty's
    // own traffic re-teach us the binding.
    let bound = match payload.bound_slot() {
        Some((BOUND_BRANCH_RECEIVE, index)) if index < receive_window => {
            (KeyBranch::Receive, index)
        }
        Some((BOUND_BRANCH_CHANGE, index)) if index < change_window => (KeyBranch::Change, index),
        // No slot at all is the KASIA case, and receive/0 is right for it for a
        // specific reason rather than as a default: their wallet is
        // single-address, and that address is BIP44 `m/44'/111111'/0'/0/0` —
        // our receive/0. A stash from a client that binds elsewhere and says
        // nothing would land here wrongly, which is why we always write ours.
        _ => (KeyBranch::Receive, 0),
    };

    Some(ConversationRecord {
        conversation_id: payload
            .conversation_id
            .clone()
            .unwrap_or_else(fresh_conversation_id),
        contact_address: partner_address,
        my_alias: payload.alias.clone(),
        their_alias: payload.their_alias.clone(),
        // Never `PendingInbound`. That is the ONE status carrying an Accept
        // affordance, and Accept spends 0.2 KAS to an address resolved from a
        // handshake transaction. A row reconstructed from an archive must not
        // be able to put a bond-spending button in front of the user.
        status: if payload.their_alias.is_some() {
            ConversationStatus::Active
        } else {
            ConversationStatus::PendingOutbound
        },
        // Their hydrate hardcodes `initiatedByMe: true` even for a row their own
        // writer flagged `isResponse` — a free correction, so take it.
        initiated_by_me: !payload.is_response.unwrap_or(false),
        bound_branch: bound.0,
        bound_index: bound.1,
        created_unix_ms: payload.timestamp,
        last_activity_unix_ms: payload.timestamp,
        // The establishing handshake tx is NOT this stash's txid. Leaving it
        // empty is honest; filling it with the stash would point the accept
        // flow's sender resolution at a transaction that paid nobody.
        handshake_txid: None,
    })
}

/// May this restored row be created, given what the store already holds?
///
/// **CREATE-ONLY IS NOT ENOUGH ON ITS OWN, and that is the whole point of this
/// function.** A restored row carries the ORIGINAL handshake's timestamp, so it
/// is older than any live row by construction — and `conversation_by_alias`
/// breaks ties in favour of the older establishment (deliberately: the squatter
/// arrives later). A plain create that merely avoided touching existing rows
/// would therefore silently capture a live conversation's alias, and every
/// message that contact sent would file into an invisible twin. That is D-141's
/// symptom arriving through a door we opened ourselves.
///
/// So all four: not the same conversation id, not the same counterparty, and
/// neither alias already spoken for.
/// **A hidden row blocks its OWN conversation and nothing else.** The two rules
/// pull in opposite directions and the device showed why the distinction
/// matters:
///
/// - Clause 1 counts tombstoned rows *deliberately*. Hiding a conversation is
///   the user's suppression record, so a backup must not hand that exact
///   conversation back.
/// - Clauses 2–4 must IGNORE them. On the restore sitting, the handshake sweep
///   minted junk invitations, the founder dismissed them — which tombstones but
///   KEEPS the row — and those dead rows then held the aliases and addresses of
///   two real conversations, refusing their authenticated backups **forever**.
///   Dismissing spam permanently destroyed the recovery of unrelated threads.
///
/// The principle: the alias clauses defend a LIVE conversation from having its
/// routing captured. A tombstoned row routes nothing, so it has nothing to
/// defend and no standing to refuse.
///
/// **A revived row has no standing either** (D-307). It is live and Active,
/// but it holds no alias of ours: their message minted it after a wipe, and
/// the backup is exactly what gives it back the alias they know us by. So a
/// row with an empty `my_alias` blocks nothing here, and [`fold_stash_row`]
/// merges the two through the store's own `merge_contact` — the backup row
/// becomes the host (it outranks on the alias it holds) and the revived
/// messages are re-homed onto it.
fn stash_row_is_free(store: &TransportStore, record: &ConversationRecord) -> bool {
    // Only the REVIVED shape lacks standing — an Active row with no alias of
    // ours. A live invitation also has no alias of ours yet and keeps its
    // standing, exactly as before: it is a bond-carrying card the user has
    // not answered, and a backup must not fold it away.
    let revived =
        |c: &ConversationRecord| c.status == ConversationStatus::Active && c.my_alias.is_empty();
    let standing = |c: &ConversationRecord| {
        !store.is_conversation_tombstoned(&c.conversation_id) && !revived(c)
    };
    // EVERY row that answers to the alias, not the one `conversation_by_alias`
    // ranks first: a revived row can outrank a standing one that shares the
    // alias, and the standing one is the one with something to defend.
    let rows = store.list_conversations();
    let alias_is_free = |alias: &str| {
        rows.iter()
            .filter(|c| c.my_alias == alias || c.their_alias.as_deref() == Some(alias))
            .all(|c| !standing(c))
    };
    store.conversation(&record.conversation_id).is_none()
        && store
            .conversations_for_contact_address(&record.contact_address)
            .iter()
            .all(|c| !standing(c))
        && alias_is_free(&record.my_alias)
        && record.their_alias.as_deref().is_none_or(alias_is_free)
}

/// Fold one restored stash row into the store. Creates or refuses — never
/// merges, never mutates.
fn fold_stash_row(
    hub: &TransportHub,
    tx_id: &str,
    payload: &SavedHandshakePayload,
    created: &mut usize,
    windows: (u32, u32),
) -> FoldOutcome {
    if *created >= STASH_CREATE_CAP {
        return dropped(
            SELF_STASH,
            tx_id,
            DropReason::StashRefusedCollision,
            EventOrigin::Fill,
        );
    }
    let Some(record) = restored_conversation(payload, windows.0, windows.1) else {
        return dropped(
            SELF_STASH,
            tx_id,
            DropReason::UndecodablePayload,
            EventOrigin::Fill,
        );
    };
    let mut conversation_id = record.conversation_id.clone();
    let address = record.contact_address.clone();
    {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        // THE BLOCK LIST, on the restore lane (`consensus-auditor` +
        // `wallet-security-auditor`, MSG-BLOCK). A block purges the rows and
        // leaves no tombstone, so a backup taken before it describes a
        // contact the store now knows nothing about — and a walk from zero
        // would rebuild them, Active, both aliases, which is exactly the way
        // back in the surviving block exists to deny. `store` before
        // `block_list`, the hub's lock order.
        if hub
            .block_list
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_blocked(&address)
        {
            drop(store);
            return dropped(
                SELF_STASH,
                tx_id,
                DropReason::BlockedContact,
                EventOrigin::Fill,
            );
        }
        if !stash_row_is_free(&store, &record) {
            drop(store);
            return dropped(
                SELF_STASH,
                tx_id,
                DropReason::StashRefusedCollision,
                EventOrigin::Fill,
            );
        }
        if store.upsert_conversation(record).is_err() {
            drop(store);
            return dropped(
                SELF_STASH,
                tx_id,
                DropReason::StoreFailed,
                EventOrigin::Fill,
            );
        }
        // A revived row for the same contact (D-307) folds into the restored
        // one here: the backup's alias is the voice the revived thread was
        // missing, and its messages come along.
        match store.merge_contact(&address) {
            Ok(Some((host, report))) => {
                log::info!(
                    "history-fill: a restored backup row folded a revived conversation ({} \
                     row(s), {} message(s) re-homed; D-307)",
                    report.rows_folded,
                    report.messages_rehomed
                );
                if host != conversation_id {
                    ping(&conversation_id);
                    conversation_id = host;
                }
            }
            Ok(None) => {}
            Err(e) => log::warn!("history-fill: contact merge after a restore failed: {e}"),
        }
    }
    *created += 1;
    log::info!("history-fill: a conversation was restored from a backup");
    ping(&conversation_id);
    FoldOutcome::Recorded
}

fn thread_pings() -> &'static broadcast::Sender<String> {
    THREAD_PINGS.get_or_init(|| broadcast::channel(64).0)
}

fn ping(conversation_id: &str) {
    // Three-lights producer log (V3, L55 extension): a frozen ping lane would
    // silently kill thread refresh exactly like the wallet lane's item 10.
    // Counts + a sentinel flag only — never the id's owner or content (INV-3).
    let receivers = thread_pings().receiver_count();
    log::info!(
        "transport: ping emit sentinel={} receivers={receivers}",
        conversation_id.is_empty()
    );
    let _ = thread_pings().send(conversation_id.to_string());
}

/// The V2b notice sentinel: an EMPTY ping (content-free like every ping)
/// telling Dart the notice INPUTS changed — the gap-age resolved or a fill
/// run reported. Event-driven so the honest notice can never stay dark on a
/// quiet wire (consensus-audit finding; a Dart-side timer poll would leak
/// into widget-test fake time — the L48 async-seam family).
fn ping_notice_inputs() {
    ping("");
}

/// The process's one message store and one block list ([`hub_stores`]).
type HubStores = (Arc<Mutex<TransportStore>>, Arc<Mutex<BlockList>>);

/// **One message store and one block list per directory per process**
/// (PRE3-LOG), handed to every hub generation.
///
/// A re-unlock used to load both afresh over the same files, while a lane
/// still holding the previous hub could write after a network wait
/// (`wallet-security-auditor` + `consensus-auditor`, PRE3-LOG). Under the old
/// append mode that was harmless; once the logs write at a remembered end, a
/// second instance's write would cut or overwrite the first's frames (the log
/// now refuses instead, loudly), and a second block list would undo the
/// first's change on its next whole-file save. Two first starts can also
/// overlap (the Dart start has no in-flight guard), so this lock is held
/// across the load: the second start waits, then takes the first's.
fn hub_stores(dir: &Path) -> Result<HubStores, AppError> {
    static STORES: Mutex<std::collections::BTreeMap<PathBuf, HubStores>> =
        Mutex::new(std::collections::BTreeMap::new());
    let mut stores = STORES.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some((store, list)) = stores.get(dir) {
        return Ok((store.clone(), list.clone()));
    }
    let store = TransportStore::load(dir.to_path_buf()).map_err(AppError::chain)?;
    // A PRESENT but unreadable `block.list` is quarantined, never read as
    // empty and then overwritten by the next block (`wallet-security-auditor`,
    // MSG-BLOCK): the bytes are kept beside it for a repair, and the log says
    // so. An absent file is the ordinary case and reads as nobody blocked.
    quarantine_unreadable_block_list(dir);
    let pair: HubStores = (
        Arc::new(Mutex::new(store)),
        Arc::new(Mutex::new(BlockList::load(dir))),
    );
    stores.insert(dir.to_path_buf(), pair.clone());
    Ok(pair)
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
/// take a vault-scoped decryptor, derive the PUBLIC watched window, and arm
/// the message walk with this hub as the consumer that folds each page of
/// accepted transactions (LINK-Q3). Idempotent while the vault stays unlocked;
/// called by Dart alongside the wallet start.
pub async fn transport_start() -> Result<(), AppError> {
    {
        let guard = HUB.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(existing) = guard.as_ref() {
            if existing.decryptor.is_live() {
                return Ok(()); // already running against the live vault
            }
        }
    }

    // **One writer from here on** (LINK-Q3). The previous hub may still be
    // folding a page through the message walk — it is the walk's consumer now,
    // not a task this function could abort — so hold the walk and wait out any
    // fold in flight BEFORE the store is loaded: from this line no page folds
    // until the arm below hands the walk this start's hub.
    let monitor = dag::shared_monitor().await?;
    monitor.quiesce_intake("the message hub restarts").await;

    let transport_dir = vault::transport_store_dir()?;
    let (store, block_list) = hub_stores(&transport_dir)?;
    let cursor_path = transport_dir.join("scan.cursor");
    // The walk's committed cursor as this start finds it, read only for the
    // gap-age line below (the walk itself resumes from it). None on the first
    // ever run.
    let catch_up_from = kaspaverse_chain::DagMonitor::read_transport_cursor(&cursor_path);
    let decryptor = vault::transport_decryptor()?;
    // One window read, used for BOTH the watched set and the key slots below:
    // reading it twice would let the two disagree if a discovery pass landed in
    // between, and a key slot without its watched address is a message we can
    // never decrypt.
    //
    // Taken through the SAME discovery gate the wallet's sync engine waits on
    // (main.dart fires both starts unawaited, and this path reaches the window
    // after only local store work — it used to win that race and freeze the
    // pre-discovery window every time).
    let (window_receive, window_change) = wallet::window_after_discovery().await;
    let (watched_addresses, _) = vault::derive_wallet_addresses(window_receive, window_change)?;

    let hub = Arc::new(TransportHub {
        store,
        decryptor,
        block_list,
        keys: Mutex::new(Arc::new(KeyWindow::build(
            window_receive,
            window_change,
            &watched_addresses,
        ))),
    });
    *HUB.lock().unwrap_or_else(PoisonError::into_inner) = Some(hub.clone());

    // ONE ROW PER CONTACT (D-141), for rows the old fold lane already minted —
    // see `backfill_invitation_sender` for the lane and the store's
    // `merge_duplicate_contacts` for the rule. Idempotent and cheap (one pass
    // over the conversation set). Runs HERE — after the hub swap and after the
    // previous inbound task is aborted — so the log has one writer while it
    // runs: before the swap, a re-unlock's old hub was still reachable through
    // `hub()` and its fold task, and either could have appended a frame to a
    // conversation this pass had just removed, orphaning that row for good
    // (`wallet-security-auditor`, 2026-09-07). Since LINK-Q3 there is no fold
    // task to abort: the walk was held and quiesced at the top of this
    // function, and folds again only once the arm below hands it this hub.
    // Counts only in the log: a report
    // about folding user threads carries none of their content.
    {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        match store.merge_duplicate_contacts() {
            Ok(report) if report.contacts > 0 => log::info!(
                "transport-hub: {} contact(s) held more than one conversation — {} row(s) \
                 folded, {} message(s) re-homed (D-141)",
                report.contacts,
                report.rows_folded,
                report.messages_rehomed
            ),
            Ok(_) => {}
            Err(e) => log::warn!("transport-hub: contact merge failed at start: {e}"),
        }
    }

    // **No thread for a blocked address survives a start** (D-308;
    // `wallet-security-auditor`, MSG-BLOCK). A block purges its rows at the
    // time, but a purge can fail half-way, and a row for the address can
    // arrive through a lane that consults the list late. The sweep is the
    // invariant `ConversationDto.blocked` states — *a blocked address never
    // holds an Active row* — asserted at the one moment every lane is quiet.
    // A LIVE request they knocked with afterwards is kept: it is their one
    // door, and the bond they paid for it must stay Accept-able.
    {
        let addresses: Vec<String> = hub
            .block_list
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .blocked
            .keys()
            .cloned()
            .collect();
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        start_store_step(&mut store, &addresses);
    }

    // **A request whose sender never resolved gets another go.** In the
    // BACKGROUND: each retry is a bounded node lookup, and unlock must not
    // wait on the network for a label (see `resweep_invitation_senders`).
    tokio::spawn(resweep_invitation_senders());

    // **Arm the message walk** (LINK-Q3, D-344): from here every page of
    // accepted transactions folds through this hub, and the walk commits its
    // cursor only once the page's matches are folded. It resumes from the
    // committed cursor, so the closed-app gap (D-067's catch-up), a reconnect's
    // (F4's replay) and a lock's (deliverable 4) are all the same replay. The
    // old unlock catch-up and the F4 replay task are gone with the stream.
    let epoch = monitor.arm_intake(cursor_path, Arc::new(HubSink { hub: hub.clone() }));
    let fill_monitor = monitor.clone();
    let fill_hub = hub.clone();
    tokio::spawn(async move {
        // V2b auto-fill (D-074) — SEQUENCED after the walk settles (its first
        // run, or the runs a budget landing chains, D-344) so node truth folds
        // first: a fill row's txid is an indexer CLAIM (we hold
        // only its payload, so the pinned recompute cannot check it); folding
        // node rows first means a mislabeled hint cannot suppress a message the
        // node was about to deliver (consensus-audit finding, V2b). Config-gated
        // inside (defaults OFF, the §0 lock); a first-ever run (no cursor) still
        // fills — that IS the restore-from-seed case the V0 casualty lived.
        // Deliberately unconditional on gap size: the walk covers a gap's
        // oldest hour and everything after the arm's mark (what it skips, its
        // log names), the indexer the rest, and txid dedup makes the overlap
        // free.
        if !fill_monitor
            .intake_settled(epoch, kaspaverse_chain::INTAKE_SETTLE_WAIT)
            .await
        {
            log::info!(
                "transport-hub: the walk under this unlock has not settled in {} s (its runs \
                 had not reached the tip) — the fill runs anyway",
                kaspaverse_chain::INTAKE_SETTLE_WAIT.as_secs()
            );
        }
        run_fill(&fill_hub).await;
    });

    // ── F5's completion lane, on the chain's pulse ─────────────────────────
    //
    // This task also carried F4's reconnect replay until LINK-Q3; the walk now
    // replays every gap by construction (its cursor never passes anything
    // unfolded), so what remains is the sweep. It rides here because this is
    // the one task in the hub that wakes at the block rate without being on
    // the fold's critical path: single-flight, spawned rather than awaited, and
    // skipped entirely when nothing is parked — the overwhelmingly common case.
    // THROTTLED, not merely single-flight. Single-flight caps concurrency at
    // one; it does not cap RATE, and this loop wakes at roughly 20 events/s. An
    // entry whose lookup fails FAST — a node that answers
    // `get_utxo_return_address` with an immediate error — would otherwise be
    // retried as fast as the previous attempt returned: a spin against our own
    // node, and being rate-limited or dropped by it produces a `Disconnected`.
    // Resolution latency is dominated by the activity record landing, never by
    // how often we ask, so a slow cadence costs nothing real. Connectivity is
    // asked of the MONITOR, never remembered from an event this task saw: a lag
    // can hide the `Connected` as easily as a drop.
    let sweep_monitor = monitor.clone();
    let mut dag_rx = monitor.subscribe();
    let sweep = tokio::spawn(async move {
        let sweeping = Arc::new(AtomicBool::new(false));
        // Sweep immediately the first time, then at most every `SWEEP_INTERVAL`.
        let mut last_sweep = tokio::time::Instant::now() - SWEEP_INTERVAL;
        loop {
            match dag_rx.recv().await {
                Ok(_) | Err(RecvError::Lagged(_)) => {}
                Err(RecvError::Closed) => break,
            }
            if sweep_monitor.is_connected()
                && last_sweep.elapsed() >= SWEEP_INTERVAL
                && !sweeping.load(Ordering::SeqCst)
                && !PENDING_ACCEPTANCE
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .is_empty()
            {
                last_sweep = tokio::time::Instant::now();
                sweeping.store(true, Ordering::SeqCst);
                let done = sweeping.clone();
                tokio::spawn(async move {
                    sweep_parked_acceptances().await;
                    done.store(false, Ordering::SeqCst);
                });
            }
        }
    });
    if let Some(old) = SWEEP_TASK
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .replace(sweep)
    {
        old.abort();
    }

    // V1 gap-age signal (deliverable 6): resolve the pre-catch-up cursor's
    // block time in the background (the socket may still be dialing) and
    // expose "history gap ≈ N min". First run (no cursor) = no gap concept.
    *GAP_AGE.lock().unwrap_or_else(PoisonError::into_inner) = None;
    if let Some(cursor) = catch_up_from {
        let gap_monitor = monitor.clone();
        tokio::spawn(async move {
            resolve_gap_age(&gap_monitor, cursor).await;
        });
    }

    // V1 consumer #2: reorg tombstones. The tracker signals a displaced-
    // past-window txid (`DisplacedElapsed`) → ghost-flag the stored row;
    // a later re-acceptance (`Accepted`) reverses the ghost. Soft
    // dependency: tracker bootstrap failure degrades to pre-V1 behavior.
    match dag::shared_tracker().await {
        Ok(tracker) => {
            let mut acceptance_rx = tracker.subscribe();
            let task = tokio::spawn(async move {
                loop {
                    let event = match acceptance_rx.recv().await {
                        Ok(event) => event,
                        Err(RecvError::Lagged(_)) => continue,
                        Err(RecvError::Closed) => break,
                    };
                    // The alias re-learn lane, handled before the status
                    // lanes because it is about a message we have NOT stored.
                    if let AcceptanceEvent::SenderResolvable {
                        txid,
                        accepting_daa_score,
                    } = &event
                    {
                        adopt_alias_from_sender(txid, *accepting_daa_score).await;
                        backfill_invitation_sender(txid, *accepting_daa_score).await;
                        // F5: the acceptance leg's sender check. Same event,
                        // same reason as the two above — the return-address
                        // lookup needs the accepting block's DAA score, which
                        // is exactly what has just landed.
                        complete_acceptance_from_sender(txid, *accepting_daa_score).await;
                        continue;
                    }
                    let txid = match &event {
                        AcceptanceEvent::Accepted { txid }
                        | AcceptanceEvent::Confirmed { txid, .. }
                        | AcceptanceEvent::Displaced { txid }
                        | AcceptanceEvent::DisplacedElapsed { txid }
                        | AcceptanceEvent::Stalled { txid, .. } => txid.clone(),
                        // Handled above.
                        AcceptanceEvent::SenderResolvable { txid, .. } => txid.clone(),
                    };
                    // `self::` — the enclosing scope's `hub` binding (the
                    // Arc) shadows the accessor fn in this task.
                    let Ok(hub) = self::hub() else { continue };
                    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
                    // V1 tombstone lane: flag flips log their own line.
                    match &event {
                        AcceptanceEvent::DisplacedElapsed { .. } => {
                            if let Ok(true) = store.tombstone_message(&txid) {
                                log::info!(
                                    "transport-hub: {txid} tombstoned (displaced past window)"
                                );
                            }
                        }
                        AcceptanceEvent::Accepted { .. } => {
                            if let Ok(true) = store.untombstone_message(&txid) {
                                log::info!("transport-hub: {txid} ghost reversed (re-accepted)");
                            }
                        }
                        _ => {}
                    }
                    // V2 chip lane (sitting find 2026-07-10): EVERY acceptance
                    // transition of a stored message pings its conversation —
                    // an OPEN thread otherwise never refreshes its status map
                    // and the chip sticks on Pending until re-entry. Events
                    // are one-shot per transition in the tracker, so pings
                    // stay sparse; the re-pull is the cheap incremental one.
                    let conversation = store.message_conversation(&txid);
                    drop(store);
                    if let Some(id) = conversation {
                        ping(&id);
                    }
                }
            });
            let old = ACCEPTANCE_TASK
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .replace(task);
            if let Some(old) = old {
                old.abort();
            }
        }
        Err(e) => log::warn!(
            "transport-hub: acceptance tracker unavailable ({}) — tombstone lane off",
            e.message
        ),
    }

    log::info!("transport-hub: started");
    Ok(())
}

/// A block as the node reports it — its own time and DAA score — or that the
/// node no longer has it (pruned), or that no answer came.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BlockTime {
    /// (timestamp in unix ms, DAA score).
    Known(u64, u64),
    Pruned,
    Unknown,
}

/// Read a block's own time with a connect-tolerant retry budget: a socket
/// still dialing is waited for; a node that is CONNECTED yet three times
/// cannot answer for the block has pruned it (an honest "≥ the horizon",
/// never a guess). Each call is bounded at our boundary (LINK-Q4: the open's
/// reader had no deadline of its own). Shared by the open's gap and the
/// walk's skips, so both judge a block the same way (`consensus-auditor`,
/// LINK-Q4 round 1: the skip's reader used to call ONE error "pruned").
async fn block_time(
    monitor: &kaspaverse_chain::DagMonitor,
    hash: kaspaverse_chain::Hash,
) -> BlockTime {
    const ATTEMPTS: u32 = 15;
    const CALL: std::time::Duration = std::time::Duration::from_secs(10);
    let rpc = monitor.rpc().rpc_api().clone();
    let mut connected_failures = 0u32;
    for _attempt in 0..ATTEMPTS {
        match tokio::time::timeout(CALL, rpc.get_block(hash, false)).await {
            Ok(Ok(block)) => {
                return BlockTime::Known(block.header.timestamp, block.header.daa_score)
            }
            Ok(Err(_)) if monitor.is_connected() => {
                // Connected but unanswered — tolerate transient node errors
                // before concluding the block is pruned.
                connected_failures += 1;
                if connected_failures >= 3 {
                    return BlockTime::Pruned;
                }
            }
            // Still dialing, or no answer in time: wait for the socket.
            _ => {}
        }
        tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
    }
    BlockTime::Unknown
}

/// Resolve the gap-age (cursor block time vs now), then store + log +
/// span-mark it.
async fn resolve_gap_age(monitor: &kaspaverse_chain::DagMonitor, cursor: kaspaverse_chain::Hash) {
    match block_time(monitor, cursor).await {
        BlockTime::Known(timestamp, _) => {
            let minutes = now_unix_ms().saturating_sub(timestamp) / 60_000;
            merge_gap_age(GapAgeDto {
                gap_minutes: Some(minutes),
                beyond_horizon: false,
                skipped: false,
            });
            kaspaverse_chain::spans::mark_with("open_gap_min", &minutes.to_string());
            log::info!("transport-hub: history gap ≈ {minutes} min at open");
            ping_notice_inputs();
        }
        BlockTime::Pruned => {
            let horizon_min = kaspaverse_chain::pruning_horizon_ms() / 60_000;
            merge_gap_age(GapAgeDto {
                gap_minutes: None,
                beyond_horizon: true,
                skipped: false,
            });
            kaspaverse_chain::spans::mark_with("open_gap_min", "beyond_horizon");
            log::info!(
                "transport-hub: cursor block pruned — history gap ≥ {horizon_min} min \
                 (pruning horizon)"
            );
            ping_notice_inputs();
        }
        BlockTime::Unknown => {
            log::info!("transport-hub: gap-age unresolved this open (node unreachable)");
        }
    }
}

/// Fold a gap reading into this open's (LINK-Q4): the open's own age and any
/// skip the walk reports later all speak through one notice, so a later
/// reading widens it and never narrows it — the longer span, a pruned cursor
/// anywhere, a skip anywhere.
fn merge_gap_age(reading: GapAgeDto) {
    let mut gap = GAP_AGE.lock().unwrap_or_else(PoisonError::into_inner);
    *gap = Some(merged_gap(gap.take(), reading));
}

/// [`merge_gap_age`]'s rule, pure.
fn merged_gap(held: Option<GapAgeDto>, reading: GapAgeDto) -> GapAgeDto {
    match held {
        None => reading,
        Some(held) => GapAgeDto {
            gap_minutes: match (held.gap_minutes, reading.gap_minutes) {
                (Some(a), Some(b)) => Some(a.max(b)),
                (a, b) => a.or(b),
            },
            beyond_horizon: held.beyond_horizon || reading.beyond_horizon,
            skipped: held.skipped || reading.skipped,
        },
    }
}

/// **What a skip from block `from` to block `to` puts on the notice**
/// (LINK-Q4): the span between the two blocks' own times, a pruned start as
/// "beyond the horizon", an unknown length as unknown — and NOTHING when the
/// landing is not ahead of the cursor (a re-walk from a mark behind it, a
/// lagging node): that skip skipped nothing (`consensus-auditor`, round 1 —
/// the walk calls `on_gap` for it all the same, because a matcher's state must
/// hear every move). A mark the chain reorganised away can read either way;
/// reading it as a skip is the safe error (round 3). "Ahead" is read by DAA
/// SCORE, never by time: at the pin a
/// block may be stamped up to 132 s in the future
/// (`TIMESTAMP_DEVIATION_TOLERANCE`, `pre_ghostdag_validation.rs:40`) and a
/// later block need only beat the past median time
/// (`post_pow_validation.rs:23`), so a short real skip can land on an EARLIER
/// timestamp (`consensus-auditor`, round 2). The minutes are the times'
/// difference, saturating. The device clock never decides.
fn skip_reading(from: BlockTime, to: BlockTime) -> Option<GapAgeDto> {
    let (minutes, beyond_horizon) = match (from, to) {
        (BlockTime::Known(_, from_daa), BlockTime::Known(_, to_daa)) if to_daa <= from_daa => {
            return None
        }
        (BlockTime::Known(from, _), BlockTime::Known(to, _)) => {
            (Some(to.saturating_sub(from) / 60_000), false)
        }
        (BlockTime::Pruned, _) => (None, true),
        _ => (None, false),
    };
    Some(GapAgeDto {
        gap_minutes: minutes,
        beyond_horizon,
        skipped: true,
    })
}

/// **The walk skipped** (LINK-Q4, [`kaspaverse_chain::MessageSink::skipped`]):
/// read the two blocks' own times and fold the span into the notice as a
/// skip. A history fill that completed before this skip did not cover it, so
/// its report stops reading complete: the notice says the check is incomplete
/// rather than calling a skipped span healed (`wallet-security-auditor`,
/// round 1 note). The fill itself is not re-run here — the next unlock runs it
/// after the walk settles, keeping D-074's node-first order.
async fn resolve_skipped_gap(
    monitor: &kaspaverse_chain::DagMonitor,
    from: kaspaverse_chain::Hash,
    to: kaspaverse_chain::Hash,
) {
    let (from_time, to_time) = tokio::join!(block_time(monitor, from), block_time(monitor, to));
    let Some(reading) = skip_reading(from_time, to_time) else {
        log::info!(
            "transport-hub: the walk re-walked from a mark behind its cursor — nothing skipped"
        );
        return;
    };
    log::info!(
        "transport-hub: the walk skipped {} — the history notice speaks for it",
        match reading.gap_minutes {
            Some(minutes) => format!("≈ {minutes} min"),
            None if reading.beyond_horizon => "past the pruning horizon".to_string(),
            None => "a span of unknown length".to_string(),
        }
    );
    fold_skip(reading);
    ping_notice_inputs();
}

/// Has the walk reported a skip since the count read `before`?
fn walk_skipped_since(before: u64) -> bool {
    WALK_SKIPS.load(std::sync::atomic::Ordering::SeqCst) != before
}

/// **A fill run's walk, counted** (LINK-Q4, `wallet-security-auditor` rounds
/// 2–3): the skip count is read before the walk is first polled and checked
/// when it has finished, so a skip that lands while the run walks — which the
/// run does not cover — keeps its report from reading complete.
async fn counted_fill(walk: impl std::future::Future<Output = FillReportDto>) -> FillReportDto {
    let skips_before = WALK_SKIPS.load(std::sync::atomic::Ordering::SeqCst);
    store_fill_report(walk.await, skips_before)
}

/// **A finished run's report, stored** (LINK-Q4): a skip that landed after the
/// run read the count at `skips_before` is not covered by it, so the report
/// stops reading complete. The check and the store share `LAST_FILL`'s lock,
/// and [`fold_skip`] counts under it too — a skip lands wholly before this or
/// wholly after it, never between the check and the store
/// (`wallet-security-auditor`, round 3).
fn store_fill_report(mut report: FillReportDto, skips_before: u64) -> FillReportDto {
    let mut last = LAST_FILL.lock().unwrap_or_else(PoisonError::into_inner);
    if walk_skipped_since(skips_before) {
        report.complete = false;
    }
    *last = Some(report.clone());
    report
}

/// A skip's reading into the notice's inputs: the gap widens, and a fill that
/// had completed no longer covers everything (see [`resolve_skipped_gap`]).
fn fold_skip(reading: GapAgeDto) {
    merge_gap_age(reading);
    let mut last = LAST_FILL.lock().unwrap_or_else(PoisonError::into_inner);
    WALK_SKIPS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    if let Some(report) = last.as_mut() {
        report.complete = false;
    }
}

/// A store fold must never be silently lossy (consensus-audit in-run finding
/// at P2.3): a lost SENT row cannot be re-derived from the wire — its
/// envelope is sealed to the counterparty — so append failures are warned
/// (I/O error text only, never content; the wallet-sync store has the same
/// posture).
fn warn_store<T>(result: kaspaverse_chain::Result<T>) {
    if let Err(e) = result {
        log::warn!("transport-hub: store append failed: {e}");
    }
}

/// Only rows this fresh register acceptance watches. The tracker's VCC
/// catch-up resolves acceptances within roughly this window; a watch for an
/// OLDER txid (a fill row from hours/days back) can never resolve — it would
/// sit `Submitted`, dress settled history in a breathing Pending chip
/// (DS-1), and a first-enable fill would flood the 512-entry watch cap,
/// evicting genuine in-flight Send watches (consensus-audit finding, V2b).
const WATCH_FRESH_MS: u64 = 60 * 60 * 1000;

/// V1: put a stored message's txid on the acceptance watch-set. Inbound rows
/// register as `Transport` (never stall-signalled — the watch may start
/// after acceptance already passed); outbound rows were already registered
/// as `Send` by the commit path, and the tracker's first-source-wins
/// idempotence keeps that. No-op until the tracker bootstraps (its connect
/// catch-up covers the sliver). `block_time_ms` gates stale rows out
/// entirely: unwatched settled history renders quiet (`chipStateOfAcceptance
/// (null)` = none), which is exactly the honest state.
fn watch_acceptance(txid: &str, block_time_ms: Option<u64>) {
    if let Some(t) = block_time_ms {
        if now_unix_ms().saturating_sub(t) > WATCH_FRESH_MS {
            return;
        }
    }
    if let Some(tracker) = dag::tracker_handle() {
        tracker.watch(txid, WatchSource::Transport);
    }
}

/// Where an inbound event came from — the fold's provenance input (V5,
/// finding 14). Everything the message walk folds through `HubSink` (live and
/// catch-up alike, LINK-Q3) is node truth; only the fill's direct calls are
/// indexer claims. A parameter, not a `TransportEvent`
/// field: the event type (and its dev wire view) stays untouched.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EventOrigin {
    Node,
    Fill,
}

impl EventOrigin {
    fn row_source(self) -> RowSource {
        match self {
            EventOrigin::Node => RowSource::NodeScanned,
            EventOrigin::Fill => RowSource::FillSourced,
        }
    }
}

/// Why an inbound event never became a stored row.
///
/// Every early return in the two intake folds names one of these. The reason
/// this type exists at all: the most consequential gate in the pipeline — "no
/// key opened this envelope" — used to be a bare `return false` with no log
/// line, and that silence cost a real diagnosis. A genuine handshake
/// acceptance was dropped on the founder's device on 2026-08-13 and the
/// capture could not say WHICH gate fired, because the gate produced nothing
/// (sitting §5). A pipeline whose rejections are invisible cannot be debugged
/// from the field, only guessed at.
///
/// Content-free by construction (§4): each label is a fixed string, and the
/// only values that ride alongside are the txid — public chain data — and
/// byte counts. No alias, no envelope bytes, never a decrypted value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DropReason {
    /// Neither the node's verbose data nor the pinned recompute produced an id.
    NoTxid,
    /// Already stored: DAG re-delivery, our own outbound echoing back, or a
    /// fill row the live scan already caught.
    AlreadyStored,
    /// No output paid an address we watch — not ours.
    NotAddressedToUs,
    /// A `comm` whose `<alias>:` head is missing or not UTF-8.
    MalformedCommHead,
    /// The envelope failed structural parse (length/tag).
    MalformedEnvelope,
    /// **The vault was locked when this arrived.** Distinguishing this from
    /// `NoKeyOpensIt` is the whole point of the enum: one means "we were shut
    /// when the postman called", the other means "not addressed to us".
    VaultLocked,
    /// Structurally sound, but no key in the window opened it.
    NoKeyOpensIt,
    /// Opened, but the plaintext was not a handshake payload we can decode.
    UndecodablePayload,
    /// Traffic for an invitation the user dismissed. Correct and expected —
    /// NOT the D-139 symptom, and it must not pollute the one diagnostic that
    /// found D-139.
    DismissedInvitation,
    /// A `comm` tagged with an alias none of our conversations answers to.
    ///
    /// This is the visible end of the D-139 cascade: a conversation stuck at
    /// `PendingOutbound` has `their_alias = None`, so every message the
    /// counterparty sends lands here and dies. Loud on purpose — it is the
    /// symptom a user reports as "my messages never arrive".
    NoConversationForAlias,
    /// A racing writer settled the row first (override mode).
    StoreRace,
    /// The append itself failed.
    StoreFailed,
    /// A restored self-stash row that would have collided with a conversation
    /// we already hold — or that came past this run's creation cap.
    ///
    /// Settled, not held: re-serving it next run changes nothing, because the
    /// thing in its way is a live conversation and that is the correct winner.
    StashRefusedCollision,
    /// A handshake for a conversation we already hold — its alias is one we
    /// already answer to. Not a new request, so not an invitation.
    ConversationAlreadyKnown,
    /// An acceptance that echoes our alias but whose sender the node has not
    /// named yet (F5). Held, not lost: the claim is parked and the acceptance
    /// event completes it once the return-address lookup can run. On the fill
    /// lane it is simply refused — an indexer's txid label cannot authenticate
    /// the payload it is paired with.
    ///
    /// **Settled, not Held**, and deliberately so ([`DropReason::outcome`]):
    /// this is the most attacker-mintable row in the pipeline — our alias
    /// rides the wire in cleartext and the envelope seals to a published
    /// address — so a cursor that held here could be pinned forever by one
    /// forged acceptance, which is the denial-of-service that rule exists to
    /// prevent. The cost is D-139's, restated: an acceptance recoverable only
    /// from the archive no longer completes a conversation. It is not folded
    /// into an invitation either, because we know exactly what it is and
    /// minting a stranger's card for a contact we already hold is the worse
    /// error. The counterparty's next comm re-learns their alias through
    /// [`adopt_alias_from_sender`], on the same sender proof.
    AcceptanceUnverified,
    /// A self-stash row our own key opened but could not AUTHENTICATE.
    ///
    /// The seal is to our published key, so opening it proves only that someone
    /// knew a public address. Without our keyed tag the row is a stranger's
    /// claim about who our contacts are — and the restore creates conversations
    /// from these, so the claim would become a live thread.
    StashNotOurs,
    /// Traffic from an address the user BLOCKED (D-308): a comm routed to a
    /// request they knocked with, a backup row that would rebuild them, or a
    /// parked comm whose sender resolved to them. Keyed on the address —
    /// the node's own sender resolution — never on an alias.
    BlockedContact,
    /// An unroutable comm that sealed to us and is parked until the chain
    /// names its sender (D-142; widened at D-307 to mint the conversation when
    /// none exists). **Held in memory for this run only**: the parked set is
    /// bounded (256 entries, 1 MiB) and not durable, so an eviction or a
    /// restart loses it, and the walk has committed past it (a register row,
    /// PRE3-SENDER). Settled for the cursor: the node lane
    /// owns it and a fill row never parks. Since PRE3-SENDER also a ROUTED
    /// comm whose page named no sender, parked the same way; over an archive
    /// row the node could neither confirm nor refute, nothing is parked and
    /// the archive row stays as it stands.
    SenderPending,
    /// The revival lane's per-minute decrypt budget is spent
    /// ([`REVIVAL_ATTEMPTS_PER_MINUTE`]). Every stranger's comm on a public
    /// chain reaches the unroutable branch, so the full-window decrypt behind
    /// it is bounded; a real contact's next message tries again.
    RevivalBudgetSpent,
    /// A comm under an alias one of our conversations answers to, whose sender
    /// is not that conversation's contact (F2, PRE3-SENDER, §0.10): a stranger
    /// posting as the contact, the contact's own old envelope replayed from
    /// another address, our own alias used by anyone, or an archive row whose
    /// claimed sender disagrees. Also a row with no contact address to compare
    /// (an invitation whose sender has not resolved): an unprovable sender is
    /// refused, never assumed (the rule `acceptance_verdict` keeps).
    ///
    /// Settled: the cursor passes it. It names the attempt, never the address
    /// (INV-3): the txid is the forensic handle, and the chain holds the rest.
    /// Logged at `info` on both lanes, like `NoKeyOpensIt`: it takes a known
    /// alias to raise it, so it is a targeted event, not the chain's
    /// background noise.
    SenderNotContact,
}

/// What one fold attempt did.
///
/// The fill needs more than a bool. A row it could not fold must HOLD its
/// cursor; a row that was merely already stored must not. Conflating the two
/// either loses history forever or wedges the walk permanently — and the
/// first of those is exactly what happened on 2026-08-13.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FoldOutcome {
    /// A new row was recorded.
    Recorded,
    /// Nothing to do and nothing lost: already stored, structurally junk, or
    /// verifiably not ours. A cursor may pass it.
    Settled,
    /// We could not fold a row that may well be ours. A cursor must not
    /// advance past it.
    Held,
    /// [`FoldOutcome::Held`] because the vault was locked — the one hold the
    /// message walk acts on (LINK-Q3). On the node lane `NotAddressedToUs` is
    /// every stranger's handshake (holding for it would let one pin the walk)
    /// and `StoreRace` was settled by the other writer. `StoreFailed` is our
    /// own write failing on a message that decrypted, and the walk commits
    /// past it: parity with the old stream, whose cursor moved on regardless,
    /// not an improvement (`consensus-auditor`, `wallet-security-auditor`).
    /// The fill treats `Locked` exactly as `Held`.
    Locked,
}

impl FoldOutcome {
    /// Does a fill cursor hold at this row? (`Locked` is a `Held`.)
    fn holds(self) -> bool {
        matches!(self, FoldOutcome::Held | FoldOutcome::Locked)
    }
}

impl DropReason {
    /// Whether a fill cursor may advance past a row that dropped for this
    /// reason.
    ///
    /// The discriminator is **who can cause it**. A locked vault, a failed
    /// append, or our own watched window disagreeing with an address we
    /// swept are OUR transient conditions: the row is probably ours and will
    /// fold on a later run, so the cursor holds and the row is re-served (the
    /// indexer's range start is inclusive).
    ///
    /// Everything else is settled or **attacker-mintable**, and that is the
    /// load-bearing half. A cursor that holds on attacker-mintable input is a
    /// denial of service on our own history: one unopenable envelope sent to
    /// a published receive address would pin the walk at that block time
    /// forever, and every later message would stop arriving. So a row no key
    /// opens is passed over, loudly logged, and left to the node lane — a row
    /// no key of ours opens was not sealed to us, so it is not ours (D-074).
    /// The converse proves less than D-074 first wrote: an archive can seal a
    /// row to our published key too (F68), which is why an archive comm must
    /// also name the contact as its sender (`comm_sender_verdict`).
    fn outcome(self) -> FoldOutcome {
        match self {
            DropReason::VaultLocked => FoldOutcome::Locked,
            DropReason::StoreRace | DropReason::StoreFailed | DropReason::NotAddressedToUs => {
                FoldOutcome::Held
            }
            _ => FoldOutcome::Settled,
        }
    }
}

/// The lowest block time in a walk whose row we could not fold.
///
/// A fill cursor is a promise: *everything at or below this block time is
/// dealt with.* The walker's own cursor is only "the highest block time I
/// fetched", and persisting that made the promise false — on 2026-08-13 a
/// genuine handshake acceptance was fetched, dropped by the fold, and stepped
/// over by the cursor. The wallet then held a conversation waiting forever on
/// a response that was, by then, unreachable.
///
/// Holding at the lowest unfolded row re-serves that row and everything after
/// it on the next run (the indexer's range start is inclusive), so a
/// transient failure costs a little re-work instead of the message.
/// NOT `#[derive(Default)]`: FRB's whole-crate scan exports a derived
/// `Default` impl as a bridge function, which put this purely internal cursor
/// helper on the FFI surface (caught by the gate's codegen-drift check). A
/// private constructor keeps it ignored, like `KeyWindow` and `TransportHub`.
struct HeldFloor(Option<u64>);

impl HeldFloor {
    const fn new() -> Self {
        Self(None)
    }

    fn hold(&mut self, block_time: u64) {
        self.0 = Some(self.0.map_or(block_time, |f| f.min(block_time)));
    }

    fn any(&self) -> bool {
        self.0.is_some()
    }

    /// The resume point: never past the lowest held row.
    fn resume_from(&self, walk_cursor: u64) -> u64 {
        match self.0 {
            Some(floor) => walk_cursor.min(floor),
            None => walk_cursor,
        }
    }

    /// Why the walk is reported incomplete — the honest notice stays up
    /// rather than a silent "drained" (D-074).
    fn notice(&self) -> Option<String> {
        self.0.map(|_| {
            "some history could not be folded this run and will be retried \
             (the cursor is held, not advanced)"
                .to_string()
        })
    }
}

/// Wire-kind labels for the drop log — the same tokens that ride the wire,
/// so a capture line greps straight back to the payload kind.
const HANDSHAKE: &str = "handshake";
const COMM: &str = "comm";
const SELF_STASH: &str = "self_stash";

/// Log one intake drop and classify it — so every rejection in the folds
/// below reads `return dropped(...)` and none can go silent again.
fn dropped(kind: &str, txid: &str, reason: DropReason, origin: EventOrigin) -> FoldOutcome {
    // Two reasons are the ordinary outcome for most chain traffic on the NODE
    // lane and pure noise in a device capture. On the FILL lane, "not
    // addressed to us" is never routine: the indexer was asked by-receiver
    // for an address we swept ourselves, so a miss means our own watched
    // window disagrees with our own sweep.
    // `NoConversationForAlias` is the same class on the NODE lane: every comm
    // any stranger sends on a public chain reaches this scan and matches
    // nothing. Measured 2026-08-14 — a third party's comm tripped it three
    // times in one minute, which would drown a capture. On the FILL lane it
    // stays loud: there a comm was fetched FOR one of our own conversations
    // and still did not match, which is an anomaly worth a line.
    // `MalformedCommHead` joins them: it fires BEFORE the alias gate, so on
    // the node lane any stranger can raise an `info` line on every device on
    // the network for the price of one dust transaction carrying
    // `ciph_msg:1:comm:` with no `<alias>:` head — evicting the very forensic
    // record this change exists to create.
    let routine = matches!(reason, DropReason::AlreadyStored)
        || (origin == EventOrigin::Node
            && matches!(
                reason,
                DropReason::NotAddressedToUs
                    | DropReason::NoConversationForAlias
                    | DropReason::MalformedCommHead
                    | DropReason::MalformedEnvelope
                    // A blocked spammer and a flood over the revival budget
                    // are both attacker-driven at chain rate — a line each
                    // would be the eviction weapon this list exists to deny.
                    | DropReason::BlockedContact
                    | DropReason::RevivalBudgetSpent
                    // The DAG delivers one transaction in several blocks:
                    // on glass (2026-09-10) the reviving message was seen
                    // six times in 1.3 s, and five of those were the
                    // already-parked refusal. The park itself says so once,
                    // at info, in `revive_or_drop`.
                    | DropReason::SenderPending
            ))
        || reason == DropReason::DismissedInvitation;
    if routine {
        log::debug!("transport-intake: skipped {kind} tx={txid} reason={reason:?}");
    } else {
        // `info` is the device sink's max level — a `debug!` here is
        // invisible on the phone, which is how the one drop log that did
        // exist came to prove nothing.
        log::info!("transport-intake: dropped {kind} tx={txid} reason={reason:?} via={origin:?}");
    }
    reason.outcome()
}

/// Resolve who sent a handshake, via the node's own return-address lookup
/// (INV-8: same untrusted node, same socket, no indexer).
///
/// `None` when the bond has not reached our activity record yet. The caller
/// then falls back to the alias-only path, so a slow resolution costs a
/// duplicate conversation at worst, never a lost message.
/// **Bounded**, because the NODE lane awaits this inline in the walk's fold.
/// Since LINK-Q3 a slow fold can no longer drop a message (the walk waits for
/// it, where the old broadcast receiver lagged and dropped), but it holds back
/// every message behind it, and the walk's next page with them. The lookup is
/// a best-effort enrichment; the fold works without it, so it must never be
/// able to cost more than it can give.
const SENDER_LOOKUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// Floor on how often [`sweep_parked_acceptances`] may run. Its driver wakes at
/// roughly the block rate, and what the sweep waits for — the wallet's own
/// activity record — lands on its own schedule, so asking oftener buys nothing
/// and a fast-failing lookup would otherwise spin against our own node.
const SWEEP_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);

async fn resolve_handshake_sender(txid: &str) -> Option<String> {
    let engine = wallet::engine_handle()?;
    // The bond's own activity record — absent until the tx is accepted, which
    // is the common case on the live lane. Checked FIRST because it is free
    // and skips the RPC entirely.
    let daa = engine.activity_daa_score(txid)?;
    let rpc = dag::shared_monitor().await.ok()?.rpc();
    match tokio::time::timeout(
        SENDER_LOOKUP_TIMEOUT,
        resolve_return_address(&rpc, txid, daa),
    )
    .await
    {
        Ok(Ok(address)) => Some(address),
        Ok(Err(e)) => {
            // Node-controlled text: every other sink in `chain` sanitizes it,
            // and this diff hardened the shape line against the same class.
            log::info!(
                "transport-intake: sender lookup failed for tx={txid}: {}",
                kaspaverse_chain::sanitize_node_text(&e.to_string())
            );
            None
        }
        Err(_) => {
            log::info!("transport-intake: sender lookup timed out for tx={txid}");
            None
        }
    }
}

/// Map a decrypt failure onto the reason it happened. `VaultLocked` is a
/// genuinely different event from "not for us" and the two must never again
/// be collapsed into one silent `return false`.
fn decrypt_drop(error: &CoreError) -> DropReason {
    match error {
        CoreError::VaultLocked => DropReason::VaultLocked,
        _ => DropReason::NoKeyOpensIt,
    }
}

/// An unroutable comm that opened under one of our keys, parked until the
/// chain names its sender (D-142; widened at D-307 to mint the conversation it
/// belongs to when none exists).
///
/// **Carries the SEALED body** — ciphertext at rest, exactly as
/// `MessageRecord.envelope` holds it — so the message that reveals a contact
/// is the first row of the thread it revives, not a row the fill may or may
/// not recover later. The alias lane used to park `(txid, alias)` alone and
/// the message itself was lost unless History & backup was on; the sibling
/// acceptance lane ([`ParkedAcceptance`]) had already fixed that defect for
/// its own row, for the same reason.
#[derive(Clone)]
struct ParkedComm {
    alias: String,
    /// The slot that opened it — a revived row's binding (§0.7).
    slot: KeySlot,
    envelope: Vec<u8>,
    block_time_ms: Option<u64>,
    wire: WireNamespace,
    /// The sender the walk's page named, when it named one (PRE3-SENDER). The
    /// row's own completion still asks the return-address lookup (the revival
    /// lane keeps its path); this is what lets a SIBLING folded on the alias be
    /// judged by its own sender rather than by the alias it shares.
    sender: Option<String>,
}

/// The parked comms, keyed by txid, oldest first.
///
/// Bounded and in-memory, like the tracker's own interest set: these txids are
/// attacker-mintable — our receive addresses are published, so anyone can seal
/// an envelope we open — so nothing here may be durable or unbounded. Two
/// bounds, because a comm can carry an attachment and 256 of those is a
/// different order of memory from 256 lines of text. An evicted entry costs
/// THAT message until the row exists and the fill re-walks the thread; never
/// the contact, whose next message parks again.
///
/// NOT `#[derive(Default)]`: FRB's whole-crate scan exports a derived
/// `Default` as a bridge function and would put this private set on the FFI
/// surface (the `HeldFloor` lesson, caught by the codegen-drift lane).
struct ParkedComms {
    entries: Vec<(String, ParkedComm)>,
}

/// Cap on parked comms — the same order as the tracker's interest set.
const PENDING_COMMS_CAPACITY: usize = 256;
/// Cap on the sealed bytes the parked set may hold, all entries together.
const PENDING_COMMS_BYTES: usize = 1 << 20;

impl ParkedComms {
    const fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    fn contains(&self, txid: &str) -> bool {
        self.entries.iter().any(|(t, _)| t == txid)
    }

    fn bytes(&self) -> usize {
        self.entries.iter().map(|(_, p)| p.envelope.len()).sum()
    }

    /// Park, evicting the oldest until both bounds hold. A second park of the
    /// same txid is a no-op: the first claim stands.
    fn park(&mut self, txid: &str, parked: ParkedComm) {
        if self.contains(txid) {
            return;
        }
        self.entries.push((txid.to_string(), parked));
        while self.entries.len() > PENDING_COMMS_CAPACITY
            || (self.entries.len() > 1 && self.bytes() > PENDING_COMMS_BYTES)
        {
            self.entries.remove(0);
        }
    }

    /// One shot per txid.
    fn take(&mut self, txid: &str) -> Option<ParkedComm> {
        let pos = self.entries.iter().position(|(t, _)| t == txid)?;
        Some(self.entries.remove(pos).1)
    }

    /// Every entry parked under `alias` that the page says `sender` sent — the
    /// siblings that arrived in the same catch-up as the one whose sender just
    /// resolved, folded into that row with it.
    ///
    /// **The alias alone never folds a sibling** (PRE3-SENDER). It used to: the
    /// routed lane took any comm whose envelope opened under our key, so this
    /// took any comm parked under the alias, and a stranger's comm parked
    /// beside the contact's rode the contact's proof into the thread. A
    /// sibling whose page named someone else is a stranger's and is dropped
    /// here; one whose page named no sender stays parked, for its own
    /// resolution. Returns `(folded, refused txids)`.
    fn take_siblings(
        &mut self,
        alias: &str,
        sender: &str,
    ) -> (Vec<(String, ParkedComm)>, Vec<String>) {
        let mut refused = Vec::new();
        let mut folded = Vec::new();
        let mut kept = Vec::new();
        for (txid, parked) in std::mem::take(&mut self.entries) {
            if parked.alias != alias {
                kept.push((txid, parked));
                continue;
            }
            match parked.sender.as_deref() {
                Some(named) if named == sender => folded.push((txid, parked)),
                Some(_) => refused.push(txid),
                None => kept.push((txid, parked)),
            }
        }
        self.entries = kept;
        (folded, refused)
    }

    /// Forget what `sender`'s page put under `alias`, and nothing else.
    /// Returns the txids that went.
    fn forget_from(&mut self, alias: &str, sender: &str) -> Vec<String> {
        let (gone, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.entries)
            .into_iter()
            .partition(|(_, p)| p.alias == alias && p.sender.as_deref() == Some(sender));
        self.entries = kept;
        gone.into_iter().map(|(txid, _)| txid).collect()
    }

    /// Forget everything parked under `alias` — a block's in-memory half.
    fn forget_alias(&mut self, alias: &str) {
        self.entries.retain(|(_, p)| p.alias != alias);
    }

    fn clear(&mut self) {
        self.entries.clear();
    }
}

static PENDING_COMMS: Mutex<ParkedComms> = Mutex::new(ParkedComms::new());

/// Whether this txid is already awaiting resolution.
///
/// Checked BEFORE the decrypt, not after: the DAG delivers one transaction in
/// several blocks, and on the founder's device a single message hit this path
/// twelve times — twelve full key-window scans, and twelve identical log
/// lines, for one message.
fn comm_already_parked(txid: &str) -> bool {
    PENDING_COMMS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .contains(txid)
}

fn park_comm(txid: &str, parked: ParkedComm) {
    PENDING_COMMS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .park(txid, parked);
}

fn take_parked_comm(txid: &str) -> Option<ParkedComm> {
    PENDING_COMMS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take(txid)
}

/// Drop what `sender` left parked under `alias` (and nothing else), returning
/// the txids — for a refusal of that sender, which refuses its siblings too.
fn forget_parked_from(alias: &str, sender: &str) -> Vec<String> {
    PENDING_COMMS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .forget_from(alias, sender)
}

fn take_parked_siblings(alias: &str, sender: &str) -> (Vec<(String, ParkedComm)>, Vec<String>) {
    PENDING_COMMS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take_siblings(alias, sender)
}

/// **Release what an invitation held while it did not know its sender**
/// (PRE3-SENDER, `wallet-security-auditor`). A comm that routes to a row with
/// no contact address is parked with its page's sender instead of refused (a
/// settled refusal could never be judged again once the address lands). Every
/// writer of an invitation's address calls this after the write and after any
/// merge, with the store lock released, naming the row that now holds the
/// sender: a merge can keep the other row's alias, and the held alias would
/// then route nowhere. The comms `sender` wrote under `alias` land in that row
/// when its contact is `sender`; the rest under the alias are refused and
/// remembered against the archive.
fn release_held_comms(hub: &TransportHub, conversation_id: &str, alias: &str, sender: &str) {
    let (rows, refused) = take_parked_siblings(alias, sender);
    for txid in &refused {
        note_refuted(txid);
    }
    if !refused.is_empty() {
        log::info!(
            "transport-intake: {} held comm(s) under a named invitation's alias came from another \
             sender — refused (PRE3-SENDER)",
            refused.len()
        );
    }
    if rows.is_empty() {
        return;
    }
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(row) = store.conversation(conversation_id).cloned() else {
        drop(store);
        log::info!(
            "transport-intake: {} held comm(s) had no row left to land in — dropped",
            rows.len()
        );
        return;
    };
    let blocked = hub
        .block_list
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .is_blocked(sender);
    if blocked
        || comm_sender_verdict(EventOrigin::Node, Some(sender), &row.contact_address)
            != CommSenderVerdict::Contact
        || comm_is_dismissed(
            row.status,
            store.is_conversation_tombstoned(conversation_id),
        )
    {
        drop(store);
        log::info!(
            "transport-intake: {} held comm(s) refused at release (blocked, dismissed, or not \
             this row's contact)",
            rows.len()
        );
        return;
    }
    unhide_on_inbound(&mut store, conversation_id);
    let n = rows.len();
    record_parked_rows(
        &mut store,
        conversation_id,
        (row.bound_branch, row.bound_index),
        rows,
        now_unix_ms(),
    );
    drop(store);
    log::info!("transport-intake: {n} held comm(s) released into the named conversation");
    ping(conversation_id);
}

/// Txids our own walk refused as not the contact's, and those whose archive
/// row it disproved (PRE3-SENDER, `wallet-security-auditor`). The fill runs
/// after the walk settles, so in the ordinary order the walk refuses a
/// stranger's comm first and writes nothing; without a trace, the fill would
/// then file a hostile archive's "the contact sent it" for the same txid, and
/// nothing would revisit it. Bounded and in memory, like the parked set: a
/// refusal is attacker-mintable, so an evicted entry costs only what an
/// archive's invented txid already could (the declared residual, bounded by
/// the `archive` label).
struct RefutedTxids {
    order: std::collections::VecDeque<String>,
}

/// Cap on remembered refutations: four walk catch-ups' worth of comms at
/// today's measured rate is well under it.
const REFUTED_CAPACITY: usize = 1024;

impl RefutedTxids {
    const fn new() -> Self {
        Self {
            order: std::collections::VecDeque::new(),
        }
    }

    fn note(&mut self, txid: &str) {
        if self.order.iter().any(|t| t == txid) {
            return;
        }
        if self.order.len() >= REFUTED_CAPACITY {
            self.order.pop_front();
        }
        self.order.push_back(txid.to_string());
    }

    fn contains(&self, txid: &str) -> bool {
        self.order.iter().any(|t| t == txid)
    }
}

static REFUTED: Mutex<RefutedTxids> = Mutex::new(RefutedTxids::new());

fn note_refuted(txid: &str) {
    REFUTED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .note(txid);
}

fn is_refuted(txid: &str) -> bool {
    REFUTED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .contains(txid)
}

/// A fixed-window rate limit: at most `limit` takes per `window_ms`. Pure over
/// the clock it is handed, so the tests drive it.
struct RateWindow {
    started_ms: u64,
    taken: u32,
}

impl RateWindow {
    const fn new() -> Self {
        Self {
            started_ms: 0,
            taken: 0,
        }
    }

    fn try_take(&mut self, now_ms: u64, limit: u32, window_ms: u64) -> bool {
        if now_ms.saturating_sub(self.started_ms) >= window_ms {
            self.started_ms = now_ms;
            self.taken = 0;
        }
        if self.taken >= limit {
            return false;
        }
        self.taken += 1;
        true
    }
}

const MINUTE_MS: u64 = 60_000;

/// **The bound on the revival path's decrypt** (D-307). Every comm any
/// stranger posts on a public chain reaches the unroutable branch, and the
/// thing that tells ours from theirs is a scan over the whole key window —
/// one ECDH per slot. Thirty a minute is far above any human conversation
/// rate and far below what a flood would cost unbounded; a real contact's
/// message refused by a spent budget is retried by their next one, and the
/// fill re-walks the thread once the row exists.
const REVIVAL_ATTEMPTS_PER_MINUTE: u32 = 30;
static REVIVAL_WINDOW: Mutex<RateWindow> = Mutex::new(RateWindow::new());

/// The bound on targeted sender locates ([`schedule_sender_locate`]): each is
/// one virtual-chain page — up to `mergeset_size_limit × 10` chain blocks
/// with their accepted txids — and one `get_block`.
const LOCATE_PAGES_PER_MINUTE: u32 = 6;
static LOCATE_WINDOW: Mutex<RateWindow> = Mutex::new(RateWindow::new());
/// How long the live VCC lane gets to name the sender before a locate is
/// spent on it: a comm from a fresh block resolves through
/// `note_sender_interest` within a block or two, and the locate exists for
/// the OLD block that lane can no longer see.
const LOCATE_GRACE: std::time::Duration = std::time::Duration::from_secs(5);
const LOCATE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
/// Aliases with a locate in flight — one per alias, because a catch-up folds
/// a contact's whole backlog in one second and every row of it would
/// otherwise buy its own page for the same answer.
static LOCATING: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Why an unroutable comm may not even be TRIED for revival — `None` means
/// try. The order is the cost order: the free checks refuse before the budget
/// is charged, so a re-delivery or a fill row never spends a decrypt. A
/// blocked address is refused AFTER its sender resolves, on the address —
/// there is no alias shortcut, by the `consensus-auditor`'s pricing (see
/// `BlockedContact` in the chain crate); the budget is the bound on what a
/// blocked spammer can cost.
fn revival_refusal(
    origin: EventOrigin,
    already_parked: bool,
    take_budget: impl FnOnce() -> bool,
) -> Option<DropReason> {
    if origin != EventOrigin::Node {
        // A fill row's identity is an indexer claim; it never revives
        // anything (D-139) — the node lane will see the same tx.
        return Some(DropReason::NoConversationForAlias);
    }
    if already_parked {
        return Some(DropReason::SenderPending);
    }
    if !take_budget() {
        return Some(DropReason::RevivalBudgetSpent);
    }
    None
}

/// **The revival branch of the comm lane** (D-307): no conversation answers to
/// this alias, but the envelope may still be sealed to us — a contact whose
/// row a wipe destroyed keeps writing to an alias pair this device has
/// forgotten, and their client never re-announces itself. Open it under the
/// whole key window; if it opens, park it with its body until the chain names
/// the sender, who then either completes a row that was missing their alias
/// or gets the conversation minted.
///
/// The gate is WIDENED, not removed: it used to fire only while some row was
/// awaiting an alias, which a wiped store never is. Now it fires on the node
/// lane, within [`REVIVAL_ATTEMPTS_PER_MINUTE`], once per txid — and what it
/// parks is completed only for an address this wallet has paid before
/// (`adopt_alias_from_sender`), which is the founder's own condition.
#[allow(clippy::too_many_arguments)]
fn revive_or_drop(
    hub: &TransportHub,
    txid: &str,
    alias: String,
    sealed: &[u8],
    block_time_ms: Option<u64>,
    block_hash: Option<&str>,
    sender: Option<&str>,
    origin: EventOrigin,
    wire: WireNamespace,
) -> FoldOutcome {
    if let Some(reason) = revival_refusal(origin, comm_already_parked(txid), || {
        REVIVAL_WINDOW
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .try_take(now_unix_ms(), REVIVAL_ATTEMPTS_PER_MINUTE, MINUTE_MS)
    }) {
        return dropped(COMM, txid, reason, origin);
    }
    let envelope_bytes = decode_envelope_body(sealed);
    let Ok(envelope) = Envelope::from_bytes(&envelope_bytes) else {
        return dropped(COMM, txid, DropReason::MalformedEnvelope, origin);
    };
    // Whichever slot opens it is the binding a revived row takes. The
    // plaintext is dropped here (Zeroizing) — decrypt-on-view is the thread's.
    let slot = match hub
        .decryptor
        .decrypt_scanning(hub.keys().slots.iter().copied(), &envelope)
    {
        Ok((slot, _)) => slot,
        Err(CoreError::VaultLocked) => return dropped(COMM, txid, DropReason::VaultLocked, origin),
        // Not ours — the routine end of nearly every stranger's comm.
        Err(_) => return dropped(COMM, txid, DropReason::NoConversationForAlias, origin),
    };
    // It opened under one of our keys, so it was sealed to us. That is not
    // proof of authorship — the sender check is — but it is worth resolving.
    park_comm(
        txid,
        ParkedComm {
            alias: alias.clone(),
            slot,
            envelope: envelope_bytes,
            block_time_ms,
            wire,
            sender: sender.map(str::to_string),
        },
    );
    if let Some(tracker) = dag::tracker_handle() {
        tracker.note_sender_interest(txid);
    }
    // One locate per alias AND page sender: the siblings it folds are exactly
    // those (`take_siblings`). A comm whose page named no one takes its own.
    let seat = match sender {
        Some(sender) => format!("{alias}|{sender}"),
        None => txid.to_string(),
    };
    schedule_sender_locate(txid.to_string(), seat, block_hash.map(str::to_string));
    // Once, here — the re-deliveries the DAG will send next are refused
    // before the decrypt and stay quiet.
    log::info!("transport-intake: unroutable comm tx={txid} sealed to us — parked, awaiting sender (D-307)");
    dropped(COMM, txid, DropReason::SenderPending, origin)
}

/// **Name the sender of a parked comm whose VCC batch the tracker has already
/// walked** — the message that landed while the app was closed.
///
/// `note_sender_interest` resolves inside the tracker's `fold_batch`, so it
/// can only answer for a batch that arrives AFTER the interest is noted; a
/// comm the transport lane folds out of its own catch-up sits in a block the
/// tracker's cold-open walk has usually passed already, and its interest
/// would wait forever. The old alias lane accepted that (D-142); the revival
/// path cannot, because a user who reopens the app after a day is exactly who
/// D-307 is for.
///
/// So after a grace period — long enough for the live lane to win when the
/// block is fresh — if the comm is still parked, spend one bounded, read-only
/// virtual-chain page from its carrying block
/// (`AcceptanceTracker::locate_accepting_daa_score`) and complete through the
/// same [`adopt_alias_from_sender`] the live lane uses, on the same sender
/// proof. One in flight per `seat`; [`LOCATE_PAGES_PER_MINUTE`] overall.
///
/// **The seat is what one locate can fold** (PRE3-SENDER,
/// `wallet-security-auditor`): the alias and the page's sender on the revival
/// lane, because the holder folds exactly the siblings that sender wrote under
/// the alias; the txid for a comm whose page named no sender (the routed
/// fallback, or a revival off the pin), because no other row's proof ever
/// folds it. A shared seat would skip a comm's own locate and lose it.
fn schedule_sender_locate(txid: String, seat: String, block_hash: Option<String>) {
    let Some(block_hash) = block_hash else {
        return; // no carrying block — the live lane is the only path
    };
    tokio::spawn(async move {
        tokio::time::sleep(LOCATE_GRACE).await;
        if !comm_already_parked(&txid) {
            return; // resolved (or evicted) while we waited
        }
        let Some(_guard) = LocatingGuard::take(seat) else {
            return; // the seat's holder folds this one with its siblings
        };
        locate_and_adopt(&txid, &block_hash).await;
    });
}

/// One alias's seat in [`LOCATING`], released on drop — so a panic or a
/// cancelled task inside the locate cannot pin the alias for the life of the
/// process (`consensus-auditor`, MSG-BLOCK).
struct LocatingGuard(String);

impl LocatingGuard {
    fn take(alias: String) -> Option<Self> {
        let mut locating = LOCATING.lock().unwrap_or_else(PoisonError::into_inner);
        if locating.contains(&alias) {
            return None;
        }
        locating.push(alias.clone());
        Some(Self(alias))
    }
}

impl Drop for LocatingGuard {
    fn drop(&mut self) {
        LOCATING
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|a| *a != self.0);
    }
}

async fn locate_and_adopt(txid: &str, block_hash: &str) {
    let allowed = LOCATE_WINDOW
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .try_take(now_unix_ms(), LOCATE_PAGES_PER_MINUTE, MINUTE_MS);
    if !allowed {
        log::info!(
            "transport-intake: sender locate budget spent — tx={txid} waits for the live lane"
        );
        return;
    }
    let Some(tracker) = dag::tracker_handle() else {
        return;
    };
    let Ok(monitor) = dag::shared_monitor().await else {
        return;
    };
    let Ok(carrying) = block_hash.parse::<kaspaverse_chain::Hash>() else {
        return;
    };
    match tokio::time::timeout(
        LOCATE_TIMEOUT,
        tracker.locate_accepting_daa_score(&monitor.rpc(), txid, carrying),
    )
    .await
    {
        Ok(Some(daa)) => adopt_alias_from_sender(txid, daa).await,
        Ok(None) => log::info!("transport-intake: no accepting block located for tx={txid}"),
        Err(_) => log::info!("transport-intake: sender locate timed out for tx={txid}"),
    }
}

/// The row a known contact's message mints when no row holds them (D-307).
///
/// **`my_alias` is EMPTY, deliberately.** The alias they know us by went with
/// the row a wipe destroyed, and nothing on this device or the chain can give
/// it back: their client never re-announces it, and our own handshake to them
/// is sealed to THEIR key. An `Active` row with no alias of ours is the
/// store's own shape for *we have not announced ourselves* — `comm_sendable`
/// refuses to send into it, so a reply cannot silently go out under an alias
/// nobody listens on (the D-162 sink) — and the thread offers the one repair
/// the protocol has: a fresh handshake, which every measured client answers by
/// refreshing the alias it holds for us in place (kasia_messaging §K4; KaChat
/// 4.0 proven on glass at D-305). `transport_prepare_handshake` reuses this
/// row for exactly that.
fn revived_conversation(
    sender: &str,
    their_alias: &str,
    slot: KeySlot,
    now_unix_ms: u64,
) -> ConversationRecord {
    ConversationRecord {
        conversation_id: fresh_conversation_id(),
        contact_address: sender.to_string(),
        my_alias: String::new(),
        their_alias: Some(their_alias.to_string()),
        status: ConversationStatus::Active,
        initiated_by_me: false,
        bound_branch: to_key_branch(slot.0),
        bound_index: slot.1,
        created_unix_ms: now_unix_ms,
        last_activity_unix_ms: now_unix_ms,
        handshake_txid: None,
    }
}

/// The identity an acceptance wants to write, held until the chain names who
/// sent it (F5). Everything here came out of an envelope **anyone can mint** —
/// it is a claim, never applied on its own authority.
#[derive(Clone)]
struct ParkedAcceptance {
    conversation_id: String,
    their_alias: String,
    bound_branch: KeyBranch,
    bound_index: u32,
    /// The sealed envelope, carried so the deferred completion can store the
    /// same `Handshake` row the immediate one does. Without it the two lanes
    /// persisted different state for the same event — and the deferred lane is
    /// the COMMON live case, so the thread would usually lose the row.
    /// Ciphertext at rest (§0.4), exactly as `MessageRecord.envelope` holds it.
    envelope: Vec<u8>,
    /// The payload's own timestamp, so a deferred row sorts where the
    /// immediate one would have.
    unix_ms: u64,
    /// The namespace the acceptance rode under, for its row (§K11).
    wire: WireNamespace,
}

/// Acceptances awaiting their sender, keyed by txid.
///
/// Bounded and in-memory for the same reason as [`PENDING_COMMS`]: these txids
/// are attacker-mintable, so nothing here may be durable or unbounded. Losing
/// an entry costs the conversation nothing permanent — it stays
/// `PendingOutbound`, and the counterparty's next comm re-learns their alias
/// through [`adopt_alias_from_sender`], which applies the same sender check.
static PENDING_ACCEPTANCE: Mutex<Vec<(String, ParkedAcceptance)>> = Mutex::new(Vec::new());

/// Whether this txid's acceptance is already awaiting its sender. Checked
/// before the work, like [`comm_already_parked`]: the DAG delivers one
/// transaction in several blocks.
fn acceptance_already_parked(txid: &str) -> bool {
    PENDING_ACCEPTANCE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .any(|(t, _)| t == txid)
}

/// Remember what an acceptance claims while we wait to learn who sent it.
fn park_acceptance(txid: &str, claim: ParkedAcceptance) {
    let mut parked = PENDING_ACCEPTANCE
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if parked.iter().any(|(t, _)| t == txid) {
        return;
    }
    if parked.len() >= PENDING_COMMS_CAPACITY {
        parked.remove(0);
    }
    parked.push((txid.to_string(), claim));
}

fn take_parked_acceptance(txid: &str) -> Option<ParkedAcceptance> {
    let mut parked = PENDING_ACCEPTANCE
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    let pos = parked.iter().position(|(t, _)| t == txid)?;
    Some(parked.remove(pos).1)
}

/// What may be done with an acceptance that echoes one of our aliases (F5).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AcceptanceVerdict {
    /// Our node named the sender and it is this conversation's contact.
    /// Complete now — nobody else could have sent it.
    Complete,
    /// A sender is known and it is NOT our contact. Not an answer to this
    /// conversation; let the address lane treat it as whatever it really is.
    NotOurContact,
    /// No sender yet, on the node lane. Park the claim and ask the chain.
    AwaitSender,
    /// No sender, and none is obtainable — the fill lane's txid is an indexer
    /// label, so resolving against it would authenticate the label rather than
    /// the payload (D-139/D-074).
    Refuse,
}

/// The whole F5 gate, as a pure decision — kept out of the fold so it can be
/// driven exhaustively without a hub, a socket or a node.
///
/// `origin == Node` is re-asserted here rather than inherited from the fact
/// that the caller only resolves senders on the node lane. That coupling is
/// real today and invisible tomorrow; the rule this branch enforces is
/// D-139's, so it states its own premise.
fn acceptance_verdict(
    origin: EventOrigin,
    resolved_sender: Option<&str>,
    contact_address: &str,
) -> AcceptanceVerdict {
    // Node truth or nothing — stated ONCE, at the top, rather than repeated as
    // a condition on each arm. Said per-arm it drifted: a fill row with a
    // matching sender fell to `NotOurContact` and thence to the address lane,
    // which cannot match a fill row either, so it minted an invitation —
    // contradicting `AcceptanceUnverified`'s own promise that it is never
    // folded into one. Refusing here says the law where it belongs and leaves
    // no arm whose behaviour differs from its documentation.
    if origin != EventOrigin::Node {
        return AcceptanceVerdict::Refuse;
    }
    match resolved_sender {
        Some(sender)
            // An address-less row can never match: it would otherwise answer
            // to a sender that resolved to nothing.
            if !contact_address.is_empty() && sender == contact_address =>
        {
            AcceptanceVerdict::Complete
        }
        Some(_) => AcceptanceVerdict::NotOurContact,
        None => AcceptanceVerdict::AwaitSender,
    }
}

/// Learn a contact's alias from a message we could not route.
///
/// **This is what makes an alias re-learnable, and the class of failure that
/// destroyed a live conversation survivable.** A counterparty who already
/// knows us never re-announces themselves, so if we lose their alias — by
/// hiding the thread, by reinstalling, by never having received their
/// handshake — every message they send afterwards matches nothing. Their
/// alias is nevertheless in cleartext on every single comm they send. The
/// only thing missing was proof that the comm is theirs.
///
/// That proof is the sender address, from the node's own return-address
/// lookup at the accepting block's DAA score (INV-8: our node, our socket, no
/// indexer). We compare it against the contact address WE chose when we
/// opened the conversation — so only the real counterparty can bind an alias,
/// and a stranger sealing a comm to our published key matches nothing.
///
/// It is also PRE3-SENDER's fallback: a routed comm whose page named no sender
/// is parked here, and [`fold_parked_comm`] holds it to the routed lane's rule.
///
/// Node lane only, by construction: the DAA score comes from the VCC stream
/// our own node emits, never from a fill row.
async fn adopt_alias_from_sender(txid: &str, accepting_daa_score: u64) {
    let Some(parked) = take_parked_comm(txid) else {
        return;
    };
    let Ok(hub) = hub() else { return };
    let Ok(monitor) = dag::shared_monitor().await else {
        return;
    };
    // Bounded like every other lookup on this loop. `resolve_return_address`
    // carries no deadline of its own, and all three sender lanes are awaited
    // INLINE on the acceptance-event receiver — so an unbounded one ahead of
    // the others stalls the whole loop, which costs tombstones, status chips
    // and the lanes behind it. (Pre-existing gap, taken here because the wave's own comment three functions down claims the property this loop did not have.)
    let sender = match tokio::time::timeout(
        SENDER_LOOKUP_TIMEOUT,
        resolve_return_address(&monitor.rpc(), txid, accepting_daa_score),
    )
    .await
    {
        Ok(Ok(sender)) => sender,
        Ok(Err(e)) => {
            log::info!(
                "transport-intake: sender lookup failed for tx={txid}: {}",
                kaspaverse_chain::sanitize_node_text(&e.to_string())
            );
            return;
        }
        Err(_) => {
            log::info!("transport-intake: sender lookup timed out for tx={txid}");
            return;
        }
    };
    fold_parked_comm(&hub, txid, parked, &sender);
}

/// Fold a parked comm once the chain has named its `sender`: the decision half
/// of [`adopt_alias_from_sender`], kept apart from the lookup so it is driven
/// without a node.
///
/// **An alias a conversation answers to is that conversation's, and only its
/// contact writes under it** (PRE3-SENDER): the routed lane's rule,
/// [`comm_sender_verdict`], applied to the address the chain named. This is
/// what the routed lane's fallback parks for, and it holds a comm the revival
/// lane parked whose alias a row has learned since: such a comm is recorded
/// into that row only when its sender is the row's contact, and it never
/// teaches another row the alias. Only an alias NO row answers to reaches the
/// re-learn and revival branch (D-142, D-307), unchanged.
fn fold_parked_comm(hub: &TransportHub, txid: &str, parked: ParkedComm, sender: &str) {
    // An address we cannot seal to is worse than none: a row built on it
    // would answer address lookups while unable to hold a conversation.
    if validate_mainnet_address(sender).is_err() {
        log::info!("transport-intake: tx={txid} resolved to an address we cannot seal to");
        return;
    }
    let now = parked.block_time_ms.unwrap_or_else(now_unix_ms);
    let alias = parked.alias.clone();

    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    // THE BLOCK LIST, before anything is adopted or minted (D-308). The alias
    // check at the fold is the cheap refusal; this is the one that holds,
    // because the address is the identity and the alias is a stranger's
    // choice of twelve hex characters.
    if hub
        .block_list
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .is_blocked(sender)
    {
        drop(store);
        // Everything else THAT ADDRESS left parked under this alias goes too: a
        // blocked knock keeps its handshake row and nothing else, so its held
        // comms must not wait for a later accept to fold them
        // (`wallet-security-auditor`). Only its own: a blocked address owns no
        // alias, and a contact's comm parked beside it under that public alias
        // keeps its own lookup (`consensus-auditor`).
        let dropped_too = forget_parked_from(&alias, sender);
        // Remembered against the archive, like every node-lane refusal.
        note_refuted(txid);
        for gone in &dropped_too {
            note_refuted(gone);
        }
        log::info!(
            "transport-intake: a message from a blocked address was refused before it could \
             revive anything (tx={txid}; {} more from it under the alias dropped)",
            dropped_too.len()
        );
        return;
    }
    let routed = store.conversation_by_alias(&alias).map(|c| {
        (
            c.conversation_id.clone(),
            c.contact_address.clone(),
            c.status,
            (c.bound_branch, c.bound_index),
        )
    });
    let (conversation_id, bound) = match routed {
        // The routed lane's rule, on the chain's answer. No identity is
        // rewritten here: the row already answers to this alias.
        Some((conversation_id, contact_address, status, bound)) => {
            match comm_sender_verdict(EventOrigin::Node, Some(sender), &contact_address) {
                CommSenderVerdict::Contact => {}
                // The row does not know its sender yet: hold the comm under
                // the address the chain just named, for the writer of the
                // row's address to release (`release_held_comms`).
                // Parked BEFORE the store lock is released: a writer that names
                // the row takes that lock first, so it cannot release between
                // this verdict and the park (`consensus-auditor`, L73).
                CommSenderVerdict::AwaitContact => {
                    park_comm(
                        txid,
                        ParkedComm {
                            sender: Some(sender.to_string()),
                            ..parked
                        },
                    );
                    drop(store);
                    log::info!(
                        "transport-intake: comm tx={txid} held until its invitation names a \
                         sender (PRE3-SENDER)"
                    );
                    return;
                }
                CommSenderVerdict::NotContact | CommSenderVerdict::AwaitSender => {
                    drop(store);
                    note_refuted(txid);
                    // The siblings that sender left under the alias fall with
                    // it, remembered against the archive; other senders' keep
                    // their own lookups.
                    for sibling in forget_parked_from(&alias, sender) {
                        note_refuted(&sibling);
                    }
                    dropped(COMM, txid, DropReason::SenderNotContact, EventOrigin::Node);
                    return;
                }
            }
            if comm_is_dismissed(status, store.is_conversation_tombstoned(&conversation_id)) {
                drop(store);
                note_refuted(txid);
                for sibling in forget_parked_from(&alias, sender) {
                    note_refuted(&sibling);
                }
                dropped(
                    COMM,
                    txid,
                    DropReason::DismissedInvitation,
                    EventOrigin::Node,
                );
                return;
            }
            unhide_on_inbound(&mut store, &conversation_id);
            (conversation_id, bound)
        }
        None => match store.conversation_by_contact_address(sender) {
            Some(existing) => {
                // Never overwrite an alias we already hold: this path exists to
                // fill a gap, not to let the newest message redefine who a
                // contact is. (A dismissed invitation lands here too — it holds
                // their alias — and stays dismissed.)
                if existing
                    .their_alias
                    .as_deref()
                    .is_some_and(|held| held != alias)
                {
                    drop(store);
                    log::info!(
                        "transport-intake: tx={txid} sender matches a conversation that already \
                         holds a different alias for them — not adopting"
                    );
                    return;
                }
                let mut conversation = existing.clone();
                let conversation_id = conversation.conversation_id.clone();
                conversation.their_alias = Some(alias.clone());
                // Their message proves the handshake completed on their side,
                // whatever our own side was still waiting for.
                if conversation.status == ConversationStatus::PendingOutbound {
                    conversation.status = ConversationStatus::Active;
                }
                let bound = (conversation.bound_branch, conversation.bound_index);
                unhide_on_inbound(&mut store, &conversation_id);
                warn_store(store.upsert_conversation(conversation));
                log::info!(
                    "transport-intake: learned a contact's alias from their message (tx={txid}) — \
                     conversation active"
                );
                (conversation_id, bound)
            }
            None => {
                // D-307: no row holds them, the message opened under our key and
                // came from an address our own node named. **And this wallet has
                // paid that address before** — a handshake bond, an acceptance
                // refund or a payment, witnessed by our own signature in the
                // wallet's activity record, which a message wipe does not touch.
                // That is the founder's condition (*as long as there is already
                // a handshake*) made checkable after the rows are gone, and it is
                // what keeps this door from being a bond-free way into Chats: a
                // comm is a self-send costing a fee, and without this fence any
                // stranger could seal one to our published key and appear as an
                // Active thread (`consensus-auditor`, MSG-BLOCK). A stranger's
                // door is still the handshake, at the bond.
                let paid = wallet::engine_handle().is_some_and(|engine| engine.has_paid(sender));
                if !paid {
                    drop(store);
                    log::info!(
                        "transport-intake: tx={txid} sealed to us from an address this wallet \
                         never paid — not a contact, not revived (a handshake is the door)"
                    );
                    return;
                }
                let conversation = revived_conversation(sender, &alias, parked.slot, now);
                let conversation_id = conversation.conversation_id.clone();
                let bound = (conversation.bound_branch, conversation.bound_index);
                warn_store(store.upsert_conversation(conversation));
                log::info!(
                    "transport-intake: a message from a contact this device no longer held \
                     revived their conversation (tx={txid}, D-307)"
                );
                (conversation_id, bound)
            }
        },
    };
    // The message that revealed them is the thread's first row, and every
    // sibling parked under the same alias BY THE SAME SENDER follows it — a
    // catch-up folds a contact's whole backlog in one second, and only one of
    // those rows needed the lookup. A sibling the page says someone else sent
    // is refused, never carried in on this row's proof.
    let (siblings, refused) = take_parked_siblings(&alias, sender);
    if !refused.is_empty() {
        log::info!(
            "transport-intake: {} comm(s) parked beside tx={txid} under its alias named another \
             sender — refused (PRE3-SENDER)",
            refused.len()
        );
    }
    for refused in &refused {
        note_refuted(refused);
    }
    let mut rows = vec![(txid.to_string(), parked)];
    rows.extend(siblings);
    record_parked_rows(&mut store, &conversation_id, bound, rows, now);
    drop(store);
    ping(&conversation_id);
}

/// Record parked comms the chain has proven into `conversation_id`, as node
/// rows, and lift its activity clock. Store lock held by the caller.
fn record_parked_rows(
    store: &mut TransportStore,
    conversation_id: &str,
    bound: (KeyBranch, u32),
    rows: Vec<(String, ParkedComm)>,
    now: u64,
) {
    let mut newest = 0u64;
    for (row_txid, row) in rows {
        let opened_at = (to_key_branch(row.slot.0), row.slot.1);
        let unix_ms = row.block_time_ms.unwrap_or(now);
        newest = newest.max(unix_ms);
        warn_store(store.record_message(MessageRecord {
            txid: row_txid.clone(),
            conversation_id: conversation_id.to_string(),
            direction: MessageDirection::Inbound,
            kind: StoredKind::Comm,
            envelope: row.envelope,
            unix_ms,
            alias_on_wire: Some(row.alias),
            sealed_to: (opened_at != bound).then_some(opened_at),
            provenance: RowSource::NodeScanned,
            wire: row.wire,
        }));
        watch_acceptance(&row_txid, row.block_time_ms);
    }
    if let Some(existing) = store.conversation(conversation_id) {
        let mut conversation = existing.clone();
        // Max, never assignment: a filled old row must not re-sort the
        // conversation above genuinely newer traffic.
        conversation.last_activity_unix_ms = conversation.last_activity_unix_ms.max(newest);
        warn_store(store.upsert_conversation(conversation));
    }
}

/// Complete a handshake acceptance once the chain names its sender (F5).
///
/// **The acceptance leg used to complete on a decryptable payload alone.** Its
/// whole gate was "the envelope opened, and it echoes an alias one of our
/// `PendingOutbound` conversations answers to" — no origin check, no sender
/// check, no bond check. Neither half is a secret: `prepare_comm_plaintext`
/// writes `comm:<alias>:` **outside** the envelope in cleartext, and D-142
/// item 3 deliberately permits sending while `PendingOutbound`, so the very
/// state that leaks our alias is the one that never expires; and the envelope
/// is sealed to OUR public key, which is a published receive address, so
/// anyone may mint one (this file says so twice already). A party who read one
/// pre-acceptance message could therefore flip that conversation `Active` with
/// their own alias and a key slot of their choosing, for the price of one dust
/// transaction — unrouting the real contact and landing inside a thread the
/// user trusts.
///
/// The proof that fixes it is the one [`adopt_alias_from_sender`] already
/// uses, and its reasoning transfers verbatim: the sender address from our own
/// node's return-address lookup at the accepting block's DAA score (INV-8),
/// compared against the contact address WE chose when we opened the
/// conversation. Only the real counterparty can complete a handshake; a
/// stranger sealing an acceptance to our published key matches nothing.
///
/// Why this is deferred rather than checked at the fold: the lookup needs the
/// bond's own activity record, which does not exist yet when the acceptance is
/// first folded, so the live lane almost always resolves nothing there. This
/// is the primary path — the same relationship [`backfill_invitation_sender`]
/// has to its own fold — not a fallback.
///
/// Node lane only, by construction: the DAA score comes from the VCC stream
/// our own node emits, never from a fill row.
async fn complete_acceptance_from_sender(txid: &str, accepting_daa_score: u64) {
    if !acceptance_already_parked(txid) {
        return; // nothing held for this txid — don't pay for an RPC
    }
    let Ok(monitor) = dag::shared_monitor().await else {
        return;
    };
    // Bounded, like `resolve_handshake_sender` three functions down.
    // `resolve_return_address` carries no deadline of its own, and this is
    // awaited inline on the acceptance-event loop — whose receiver drops
    // events when it lags, costing tombstones and status chips. A dependency's
    // default timeout posture is never the one we rely on.
    match tokio::time::timeout(
        SENDER_LOOKUP_TIMEOUT,
        resolve_return_address(&monitor.rpc(), txid, accepting_daa_score),
    )
    .await
    {
        Ok(Ok(sender)) => apply_parked_acceptance(txid, &sender),
        Ok(Err(e)) => log::info!(
            "transport-intake: acceptance sender lookup failed for tx={txid}: {}",
            kaspaverse_chain::sanitize_node_text(&e.to_string())
        ),
        Err(_) => log::info!("transport-intake: acceptance sender lookup timed out for tx={txid}"),
    }
}

/// The same completion, for a txid whose accepting score nobody handed us
/// (F5's second trigger — see the acceptance-event loop). Resolves the score
/// itself from the bond's activity record, which is how an acceptance
/// recovered by the catch-up or the F4 replay gets completed at all: its block
/// was folded before the claim was ever parked, so no future batch will name
/// it. A no-op when the record has not landed yet; the sweep runs again.
async fn complete_parked_acceptance(txid: &str) {
    if !acceptance_already_parked(txid) {
        return;
    }
    let Some(sender) = resolve_handshake_sender(txid).await else {
        return;
    };
    apply_parked_acceptance(txid, &sender);
}

/// Try every parked acceptance whose sender the wallet can now name.
///
/// **This is what makes a replayed acceptance completable at all**, and the
/// reason it exists is worth stating plainly, because the obvious alternative
/// does not work. Both event-driven triggers ultimately need a *future* VCC
/// batch to name the txid: `SenderResolvable` comes from `fold_batch`'s filter
/// over `batch.accepted`, and `AcceptanceTracker::watch` installs a record at
/// `Submitted`, which only `on_added` — also driven by `batch.accepted` — ever
/// promotes to `Accepted`. An acceptance recovered by the unlock catch-up or
/// the F4 replay sits in an OLD block: the tracker's own forward-only cursor
/// walked past it on the very same `Connected`, and does strictly less work
/// than the transport walk, so by the time the claim is parked no batch will
/// ever name that txid again. A watch registered there is inert, not slow.
///
/// This lane asks a different oracle. `resolve_handshake_sender`'s only real
/// precondition is `engine.activity_daa_score(txid)` — the WALLET-SYNC activity
/// record, which fills independently of the tracker's cursor — so a sweep costs
/// one free map lookup per parked claim until that record lands, and one
/// bounded RPC after. Driven from the replay task, which already wakes at
/// roughly the block rate.
async fn sweep_parked_acceptances() {
    let parked: Vec<String> = PENDING_ACCEPTANCE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .map(|(txid, _)| txid.clone())
        .collect();
    for txid in parked {
        complete_parked_acceptance(&txid).await;
    }
}

/// Take the parked claim and apply it **iff** `sender` is the contact we chose.
/// The gate itself; both triggers land here so there is exactly one place that
/// can rewrite a conversation's identity from an acceptance.
fn apply_parked_acceptance(txid: &str, sender: &str) {
    // Everything that can fail WITHOUT a decision happens before the claim is
    // taken. `take_parked_acceptance` is one-shot, so taking first and then
    // discovering the hub is gone would destroy a legitimate claim on a
    // condition that is nothing to do with it — and this now runs on a detached
    // sweep task that can outlive a vault lock, which is exactly when `hub()`
    // fails. Held means held.
    let Ok(hub) = hub() else { return };
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(claim) = take_parked_acceptance(txid) else {
        return;
    };
    let Some(existing) = store.conversation(&claim.conversation_id) else {
        // The row was folded into another (D-305) or erased while the claim
        // waited. Not silent: the claim was parked WITHOUT a row (the
        // `AwaitSender` arm stores nothing), so what recovers the alias is
        // D-142's adoption from their next comm, not this lane — and a one-shot
        // claim consumed with no effect is exactly the event that must say so.
        log::info!(
            "transport-intake: acceptance tx={txid} names a conversation that no longer exists — \
             claim dropped"
        );
        return;
    };
    // THE GATE — the same function the fold's Complete arm calls, not a second
    // hand-rolled copy of the rule. The copy is how the `origin != Node`
    // condition drifted per-arm earlier in this very wave and ended up minting
    // an invitation; and since this deferred lane is the COMMON live case, a
    // divergence here would be the one that actually shipped. Routing both
    // writers through `acceptance_verdict` also means the five tests that
    // range over it cover this lane too.
    //
    // Re-read under the write lock rather than trusting the fold-time
    // snapshot: the user may have accepted, hidden or otherwise moved this
    // conversation while we were on the network.
    if existing.status != ConversationStatus::PendingOutbound
        || acceptance_verdict(EventOrigin::Node, Some(sender), &existing.contact_address)
            != AcceptanceVerdict::Complete
    {
        log::info!(
            "transport-intake: acceptance tx={txid} was not sent by this conversation's \
             contact — refused"
        );
        return;
    }

    let mut conversation = existing.clone();
    let conversation_id = conversation.conversation_id.clone();
    conversation.their_alias = Some(claim.their_alias);
    conversation.status = ConversationStatus::Active;
    // REBIND to the slot that actually opened it — the key the counterparty
    // resolved for us and will keep sealing to. Safe only now: this rewrites
    // who the conversation talks to, on evidence the node produced.
    conversation.bound_branch = claim.bound_branch;
    conversation.bound_index = claim.bound_index;
    conversation.last_activity_unix_ms = conversation.last_activity_unix_ms.max(now_unix_ms());
    unhide_on_inbound(&mut store, &conversation_id);
    warn_store(store.upsert_conversation(conversation));
    // The same row the immediate lane records. Withheld at fold time because
    // the claim was unauthenticated; stored now, on the far side of the gate,
    // so the two lanes leave the thread in the same state. `NodeScanned` is
    // exact: this path is unreachable except from the node lane.
    warn_store(store.record_message(MessageRecord {
        txid: txid.to_string(),
        conversation_id: conversation_id.clone(),
        direction: MessageDirection::Inbound,
        kind: StoredKind::Handshake,
        envelope: claim.envelope,
        unix_ms: claim.unix_ms,
        alias_on_wire: None,
        sealed_to: None,
        provenance: RowSource::NodeScanned,
        wire: claim.wire,
    }));
    drop(store);
    log::info!("transport-intake: acceptance tx={txid} confirmed by sender — conversation active");
    ping(&conversation_id);
}

/// May inbound traffic reopen this hidden conversation?
///
/// A conversation you already have: yes — hide is a mute. An invitation you
/// turned down: never. That card spends the bond refund, so a stranger must
/// not be able to re-arm it by writing again (INV-6: no exit that the
/// counterparty can revoke).
/// Fill in the sender of an invitation whose bond has now been accepted.
///
/// **This is the primary path, not a fallback.** `resolve_handshake_sender`
/// needs the bond's own activity record, which does not exist yet when the
/// handshake is first folded — so the live lane almost always resolves nothing,
/// and without this an invitation would keep saying "Unknown sender" until the
/// user paid to accept it. The acceptance event fires precisely when the
/// missing record lands.
///
/// Node truth throughout: the address comes from our own node's return-address
/// lookup, never from payload content or an indexer (INV-8).
/// **Re-try every invitation whose sender never resolved.**
///
/// [`backfill_invitation_sender`] gets ONE attempt, on the acceptance event for
/// the bond's own transaction, bounded by [`SENDER_LOOKUP_TIMEOUT`]. A node
/// that was slow, unreachable or still catching up at that exact moment leaves
/// the row with an empty `contact_address` **forever** — and the glass then
/// says *Sender not yet known* permanently, which is the false permanence that
/// wording was written to avoid. The founder asked for exactly this after
/// seeing it (2026-09-08: *"i hope the node resolve works so make sure it
/// probably will"*).
///
/// So the lookup gets a second life on every hub start: reopening the app
/// heals a request whose sender was missed. Cheap and bounded — it runs only
/// for rows that are still address-less, and each one is the same timed
/// lookup, so a wallet with none pays a store read and nothing else.
///
/// **A resolved sender is a merge trigger** (L186's own lesson, which this
/// lane taught): writing the address without re-running the rules keyed on it
/// is half a backfill, so each success folds through `merge_contact` exactly
/// as the live path does.
async fn resweep_invitation_senders() {
    let Ok(hub) = hub() else { return };
    let pending: Vec<(String, String)> = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store
            .list_conversations()
            .into_iter()
            .filter(|c| nameable_invitation(&store, c))
            .filter_map(|c| c.handshake_txid.map(|txid| (c.conversation_id, txid)))
            .collect()
    };
    if pending.is_empty() {
        return;
    }
    log::info!(
        "transport-intake: re-trying {} unresolved invitation sender(s) at start",
        pending.len()
    );
    let mut healed = 0usize;
    for (conversation_id, txid) in pending {
        let Some(sender) = resolve_handshake_sender(&txid).await else {
            continue;
        };
        let held_under = {
            let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
            let Some(mut row) = store.conversation(&conversation_id).cloned() else {
                continue;
            };
            // Someone else resolved it while we were on the RPC — leave it.
            if !row.contact_address.is_empty() {
                continue;
            }
            let held_under = row.their_alias.clone();
            row.contact_address = sender.clone();
            warn_store(store.upsert_conversation(row));
            refuse_blocked_knock_comms(&hub, &mut store, &conversation_id, &sender);
            let host = match store.merge_contact(&sender) {
                Ok(Some((host, _))) => host,
                Ok(None) => conversation_id.clone(),
                Err(e) => {
                    log::warn!("transport-hub: contact merge failed: {e}");
                    conversation_id.clone()
                }
            };
            held_under.map(|alias| (host, alias))
        };
        // Every writer of an invitation's address releases what it held, into
        // the row that holds the sender after the merge.
        if let Some((host, alias)) = held_under {
            release_held_comms(&hub, &host, &alias, &sender);
        }
        healed += 1;
        ping(&conversation_id);
    }
    if healed > 0 {
        log::info!("transport-intake: {healed} invitation sender(s) resolved on the re-try");
    }
}

/// **An invitation the sender lookup may name**: still waiting for its sender,
/// and its handshake row is our node's own (`accept_provenance_ok`). An
/// archive's invitation carries the archive's txid label, and the lookup
/// answers for any txid in our wallet's activity record, so naming it from
/// that label would let an archive pair its own handshake with a real
/// payment's txid and steer a real contact's alias and key slot through the
/// merge (D-139, `wallet-security-auditor`). An archive's invitation is named
/// only when our node folds the handshake itself (the override branch of
/// `handle_inbound_handshake`).
fn nameable_invitation(store: &TransportStore, c: &ConversationRecord) -> bool {
    c.status == ConversationStatus::PendingInbound
        && c.contact_address.is_empty()
        && c.handshake_txid.as_deref().is_some_and(|txid| {
            // A HANDSHAKE row our node scanned: the provenance gate alone does
            // not look at the kind, and a node comm row under the label's txid
            // would otherwise pass for the invitation's handshake.
            accept_provenance_ok(store, txid)
                && store
                    .message(txid)
                    .is_some_and(|m| m.kind == StoredKind::Handshake)
        })
}

async fn backfill_invitation_sender(txid: &str, accepting_daa_score: u64) {
    let Ok(hub) = hub() else { return };
    // Cheap first: is there even an address-less invitation for this txid?
    let needs_backfill = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store
            .list_conversations()
            .into_iter()
            .any(|c| nameable_invitation(&store, &c) && c.handshake_txid.as_deref() == Some(txid))
    };
    if !needs_backfill {
        return;
    }
    let Ok(monitor) = dag::shared_monitor().await else {
        return;
    };
    // Bounded like every other lookup on this loop. `resolve_return_address`
    // carries no deadline of its own, and all three sender lanes are awaited
    // INLINE on the acceptance-event receiver — so an unbounded one ahead of
    // the others stalls the whole loop, which costs tombstones, status chips
    // and the lanes behind it. (Same gap, same loop.)
    let sender = match tokio::time::timeout(
        SENDER_LOOKUP_TIMEOUT,
        resolve_return_address(&monitor.rpc(), txid, accepting_daa_score),
    )
    .await
    {
        Ok(Ok(sender)) => sender,
        Ok(Err(e)) => {
            log::info!(
                "transport-intake: invitation sender lookup failed for tx={txid}: {}",
                kaspaverse_chain::sanitize_node_text(&e.to_string())
            );
            return;
        }
        Err(_) => {
            log::info!("transport-intake: invitation sender lookup timed out for tx={txid}");
            return;
        }
    };
    // An address we cannot seal to is worse than none: it would make the row
    // answer address lookups while still being unable to hold a conversation.
    if validate_mainnet_address(&sender).is_err() {
        return;
    }

    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(existing) = store
        .list_conversations()
        .into_iter()
        .find(|c| nameable_invitation(&store, c) && c.handshake_txid.as_deref() == Some(txid))
    else {
        return; // accepted or changed while we were on the network
    };
    let conversation_id = existing.conversation_id.clone();
    let held_under = existing.their_alias.clone();
    let conversation = ConversationRecord {
        contact_address: sender.clone(),
        ..existing
    };
    warn_store(store.upsert_conversation(conversation));
    refuse_blocked_knock_comms(&hub, &mut store, &conversation_id, &sender);
    // ONE ROW PER CONTACT (D-141), on the lane the rule was missing from.
    //
    // The fold applies the address-keyed rule only when the node can name the
    // sender AT fold time. Until PRE3-SENDER the live lane almost never could —
    // the return-address lookup needs the bond's own activity record, which
    // lands later; the walk's page now names it, so this lane is for a page
    // that named no sender. So a handshake from a contact we already hold minted a second row beside
    // the first, and that pair is what the derived `superseded_by` rule and
    // the "Start over" gesture were built to paper over — both since removed,
    // because this merge is what makes them unnecessary (D-305). Measured on the founder's device 2026-09-07: our
    // request of 08-23 and the counterparty's handshake back of 08-24, held
    // as two rows for a fortnight. Now that the sender IS known, the merge
    // runs here: the invitation folds into the conversation it answers (or
    // the one it refreshes), with the population's own semantics — no accept
    // card, no second bond, the newest alias wins.
    let folded = match store.merge_contact(&sender) {
        Ok(folded) => folded,
        Err(e) => {
            log::warn!("transport-hub: contact merge failed: {e}");
            None
        }
    };
    drop(store);
    log::info!("transport-intake: recorded the sender of an invitation (tx={txid})");
    // Every writer of an invitation's address releases what it held, into the
    // row that holds the sender after the merge.
    if let Some(alias) = held_under {
        let host = folded
            .as_ref()
            .map_or(conversation_id.as_str(), |(h, _)| h.as_str());
        release_held_comms(&hub, host, &alias, &sender);
    }
    match folded {
        Some((host, report)) => {
            log::info!(
                "transport-intake: that invitation is from a contact we already hold — folded \
                 into their conversation ({} row(s), {} message(s) re-homed; D-141)",
                report.rows_folded,
                report.messages_rehomed
            );
            ping(&host);
            if host != conversation_id {
                ping(&conversation_id);
            }
        }
        None => ping(&conversation_id),
    }
}

/// **A blocked address's knock keeps its handshake row and nothing else**
/// (`wallet-security-auditor`, MSG-BLOCK). A request minted address-less is
/// named later: one our node folded without a page sender by the sender
/// lookup, an archive's only when our node folds its handshake (the override;
/// never from the archive's txid label, `nameable_invitation`). Since
/// PRE3-SENDER the comms its sender writes meanwhile are HELD,
/// not stored, and released only after this purge runs; what it still removes
/// is any comm row an older build stored before the name landed. So the
/// moment the name lands, if it is blocked, the comms go: the handshake row
/// stays because the accept gate reads it, and the card stays Accept-able,
/// which is the door D-308 keeps open. Store lock held by the caller; the
/// block list is taken after it, the hub's order.
fn refuse_blocked_knock_comms(
    hub: &TransportHub,
    store: &mut TransportStore,
    conversation_id: &str,
    sender: &str,
) {
    let blocked = hub
        .block_list
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .is_blocked(sender);
    if !blocked {
        return;
    }
    match purge_comms_keeping_handshake(store, conversation_id) {
        Ok(0) => {}
        Ok(n) => log::info!(
            "transport-block: {n} message row(s) from a blocked address's request removed at \
             sender resolution"
        ),
        Err(e) => log::warn!("transport-block: purge at sender resolution failed: {e}"),
    }
}

/// Remove every `Comm` row of a conversation, keeping its handshake rows.
/// Pure over the store, so it is tested without a hub.
fn purge_comms_keeping_handshake(
    store: &mut TransportStore,
    conversation_id: &str,
) -> kaspaverse_chain::Result<usize> {
    let txids: Vec<String> = store
        .messages_for(conversation_id)
        .into_iter()
        .filter(|m| m.kind == StoredKind::Comm)
        .map(|m| m.txid)
        .collect();
    let mut removed = 0usize;
    for txid in txids {
        store.remove_message(&txid)?;
        removed += 1;
    }
    Ok(removed)
}

fn may_unhide(status: ConversationStatus, tombstoned: bool) -> bool {
    tombstoned && status != ConversationStatus::PendingInbound
}

/// Is this inbound comm addressed to an invitation the user dismissed?
///
/// Checked at BOTH the alias resolution and again after the decrypt re-takes
/// the store lock: the decrypt runs unlocked, and `transport_hide_conversation`
/// runs concurrently on an FRB worker, so a dismissal can land in between.
fn comm_is_dismissed(status: ConversationStatus, tombstoned: bool) -> bool {
    tombstoned && status == ConversationStatus::PendingInbound
}

/// Bring a hidden conversation back the moment its counterparty writes.
///
/// Without this, hiding is not a mute but a **silent sink**: the row still
/// matches by alias, so their messages are stored and `last_activity` is
/// bumped, but the list filters the row out forever and no affordance exists
/// to restore it. That is strictly worse than the hard delete it replaced —
/// a state with no unilateral exit (INV-6) — and it would make the hide
/// sheet's promise that they can still write to you a lie, because the
/// writing would arrive somewhere no user can look.
///
/// Un-hiding needs inbound traffic on a row that is already a **contact**.
///
/// Since PRE3-SENDER that traffic is the contact's: a comm reaches here only
/// when its sender is the row's contact (`comm_sender_verdict`) — chain truth
/// on the node lane, the archive's claim on the fill lane. Before it, a comm
/// proved only that the envelope opened under one of our keys, so any wire
/// observer could undo the hide of a contact for one dust transaction (the
/// residual backlog #5 named). The fill cannot reach a hidden contact at all:
/// its comm sweep skips hidden rows, so a hostile archive's claim does not
/// reopen one (`wallet-security-auditor`). The invitation case is still NOT
/// treated the same way.
///
/// A dismissed `PendingInbound` invitation is never resurrected: the guard at
/// the top of this function refuses it under the write lock,
/// `handle_inbound_comm` drops its traffic outright, and
/// `conversation_by_contact_address` cannot reach one at all because an
/// invitation carries no contact address until its accept.
///
/// So `hide` has an honest two-sided meaning: on a conversation you already
/// have, it is "mute until they write"; on an invitation you never took up,
/// it is "no".
///
/// (Do NOT re-derive that guarantee from status filtering in
/// `conversation_by_alias` — status there RANKS, it does not filter. An
/// earlier version of this comment claimed the filter as its safety argument
/// and was falsified by the same change set that removed it.)
fn unhide_on_inbound(store: &mut TransportStore, conversation_id: &str) {
    // Re-check status HERE, under the write lock, not only at the earlier
    // alias-resolution guard: the decrypt between them runs with the lock
    // released, and `transport_hide_conversation` runs concurrently on an FRB
    // worker. A dismissal landing inside that window must still win, or the
    // user's exit from a money-spending invitation is revocable by whoever
    // they dismissed — for the cost of streaming dust comms to widen the race.
    let tombstoned = store.is_conversation_tombstoned(conversation_id);
    let Some(status) = store.conversation(conversation_id).map(|c| c.status) else {
        return;
    };
    if !may_unhide(status, tombstoned) {
        return;
    }
    {
        match store.untombstone_conversation(conversation_id) {
            // "the contact wrote" by chain truth on the node lane, by the
            // archive's claim on the fill lane (PRE3-SENDER).
            Ok(true) => {
                log::info!("transport-intake: hidden conversation reopened by inbound traffic")
            }
            Ok(false) => {}
            Err(e) => log::warn!("transport-hub: unhide failed: {e}"),
        }
    }
}

/// One scan match → store/conversation fold. Content never reaches a log
/// line from here (§4: message plaintext is treated like key material for
/// logging; even sealed bodies are logged as shapes only). Returns what the
/// fold did — the live scan ignores it; the V2b fill counts `Recorded` rows
/// and holds its cursor on `Held` ones (its report is row-counts, never
/// content).
async fn handle_inbound(
    hub: &TransportHub,
    event: TransportEvent,
    origin: EventOrigin,
) -> FoldOutcome {
    // The store law keys on txid (D-065); an id-less event (exotic — both the
    // node's verbose data AND the pinned recompute failed) cannot be stored.
    let Some(txid) = event.txid else {
        // A fixed token, never `event.kind`: the kind is `from_utf8_lossy`
        // over arbitrary wire bytes, i.e. a stranger's choice of characters
        // going straight into a log line.
        return dropped("?", "?", DropReason::NoTxid, origin);
    };
    match event.kind.as_str() {
        "handshake" => {
            handle_inbound_handshake(
                hub,
                &txid,
                &event.body,
                &event.addresses,
                event.block_time_ms,
                event.sender.as_deref(),
                origin,
                event.namespace,
            )
            .await
        }
        "comm" => handle_inbound_comm(
            hub,
            &txid,
            &event.body,
            event.block_time_ms,
            event.block_hash.as_deref(),
            event.sender.as_deref(),
            origin,
            event.namespace,
        ),
        // `self_stash` (D-138) is FILL-ONLY, deliberately — this arm is where
        // it lands and where it must keep landing. Our own backups reach here
        // the moment our node accepts them (they self-send to a watched
        // address), and doing nothing is correct:
        //
        // - Folding them would run `decrypt_scanning` over the whole key window
        //   for every stash-shaped transaction any stranger cares to post, at
        //   the price of dust, on every device.
        // - It would add an attacker-mintable drop reason to the node lane's
        //   log — the one diagnostic that found D-139 — and `info!` is the
        //   device sink's ceiling, so the useful lines would be the ones evicted.
        // - It would decide identity from a lane with no authorship check at
        //   all. The restore path proves a stash is ours with a keyed tag
        //   (`stash_tag`) precisely because sealing does not — the envelope
        //   goes to our PUBLISHED key, so anyone can make one we can open.
        //
        // `legacy` (VNone): parse-layer tolerance is fixture-pinned in chain;
        // conversation semantics for the unversioned generation are
        // consciously deferred (the population emits versioned forms since
        // 2025). `payment` memos: deferred (not a P2.3 deliverable). `bcast`:
        // plaintext dev/broadcast lane, rendered by the dev panel. Unknown
        // kinds: forward-compat opaque (§0.5) — visible on the dev wire view.
        _ => FoldOutcome::Settled,
    }
}

#[allow(clippy::too_many_arguments)]
async fn handle_inbound_handshake(
    hub: &TransportHub,
    txid: &str,
    body: &[u8],
    addresses: &[String],
    block_time_ms: Option<u64>,
    page_sender: Option<&str>,
    origin: EventOrigin,
    wire: WireNamespace,
) -> FoldOutcome {
    // Dedup BEFORE any crypto: DAG re-delivery, our own outbound handshakes
    // echoing back through the scan (stored at commit — Own/Outbound rows
    // keep the cheap pre-crypto skip), and fill rows the live scan already
    // caught. ONE exception (V5, finding 14): a NODE event whose stored row
    // is an indexer claim (`FillSourced`) or pre-V5 (`Unknown`) proceeds in
    // OVERRIDE mode — node truth replaces the claim after the full
    // verify-by-decrypt below.
    let override_row = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        if store.has_handshake_txid(txid) || store.has_message_txid(txid) {
            let overridable = origin == EventOrigin::Node
                && store.message(txid).is_some_and(|m| {
                    m.direction == MessageDirection::Inbound
                        && matches!(m.provenance, RowSource::FillSourced | RowSource::Unknown)
                });
            if !overridable {
                return dropped(HANDSHAKE, txid, DropReason::AlreadyStored, origin);
            }
            store.message(txid).cloned()
        } else {
            None
        }
    };
    // Relevance without crypto: a real handshake bonds the recipient, so one
    // of OUR watched addresses must be among the outputs.
    // One snapshot for both halves of the check below — see `TransportHub::keys`.
    let keys = hub.keys();
    if !addresses.iter().any(|a| keys.watched.contains(a)) {
        return dropped(HANDSHAKE, txid, DropReason::NotAddressedToUs, origin);
    }
    let envelope_bytes = decode_envelope_body(body);
    let Ok(envelope) = Envelope::from_bytes(&envelope_bytes) else {
        return dropped(HANDSHAKE, txid, DropReason::MalformedEnvelope, origin);
    };
    // Establishment scan: whichever watched key opens it becomes the §0.7
    // binding. Not ours ⇒ skip. Vault locked ⇒ `Locked`: on the node lane the
    // walk holds the page and replays it at the unlock (LINK-Q3, deliverable
    // 4); it used to be missed, like one seen while offline. This decrypt
    // also filters the fill: an indexer row no watched key opens is dropped
    // here. One that opens is still only a claim, since anyone can seal to our
    // published key (F68): a fill handshake sets no identity (below), and it
    // folds as an invitation with its `archive` provenance.
    let (slot, plaintext) = match hub
        .decryptor
        .decrypt_scanning(keys.handshake_slots().iter().copied(), &envelope)
    {
        Ok(opened) => opened,
        // THE gate the 2026-08-13 sitting could not see through. A locked
        // vault and an envelope addressed to someone else are completely
        // different events and are now reported as such.
        Err(e) => return dropped(HANDSHAKE, txid, decrypt_drop(&e), origin),
    };
    let payload = match HandshakePayload::from_plaintext(&plaintext) {
        Ok(payload) => payload,
        Err(e) => {
            // The envelope AEAD-authenticated, so these bytes are genuinely
            // ours and genuinely the counterparty's — a rejection here is an
            // INTEROP defect in our parser, not a hostile input. Say which of
            // the four checks refused it, and how long the decoded value was
            // (a shape, never its content — §4).
            log::info!(
                "transport-intake: handshake payload rejected by our parser: {e} (len={})",
                plaintext.len()
            );
            // SHAPE, not content — field names and JSON types only. This is
            // how an interop divergence gets named instead of guessed at.
            log::info!(
                "transport-intake: rejected handshake shape: {}",
                kaspaverse_core::handshake::describe_shape(&plaintext)
            );
            return dropped(HANDSHAKE, txid, DropReason::UndecodablePayload, origin);
        }
    };
    drop(plaintext); // Zeroizing — wiped here; the store keeps ciphertext only

    // Conversation clocks ride the block time when the source knows it (the
    // fill; the scans since V2b) so filled history lands in true order.
    let now = block_time_ms.unwrap_or_else(now_unix_ms);

    // Both branches below run under the store lock, and the address-keyed
    // step after them AWAITS — so the guard lives in a block that ends before
    // it, never across it.
    {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);

        // OVERRIDE mode (V5, finding 14): node truth replaces the stored claim's
        // row in place — never a second conversation. The owning conversation is
        // refreshed only while it is still PendingInbound (node block time
        // hardens the expiry discriminator; the alias is the node-decrypted
        // truth); an Active conversation is NEVER touched — the user already
        // accepted, and regressing status or rebinding is worse than the
        // documented open-thread residual.
        if let Some(old) = override_row {
            let record = MessageRecord {
                txid: txid.to_string(),
                conversation_id: old.conversation_id.clone(),
                direction: MessageDirection::Inbound,
                kind: StoredKind::Handshake,
                envelope: envelope_bytes,
                unix_ms: payload.timestamp,
                alias_on_wire: None,
                sealed_to: None,
                provenance: RowSource::NodeScanned,
                wire,
            };
            match store.override_message(record) {
                Ok(Some(_)) => {}
                Ok(None) => return dropped(HANDSHAKE, txid, DropReason::StoreRace, origin),
                Err(e) => {
                    log::warn!("transport-hub: store append failed: {e}");
                    return dropped(HANDSHAKE, txid, DropReason::StoreFailed, origin);
                }
            }
            let mut named: Option<String> = None;
            let mut release: Option<(String, String)> = None;
            if let Some(existing) = store.conversation(&old.conversation_id) {
                if existing.status == ConversationStatus::PendingInbound {
                    let mut conversation = existing.clone();
                    conversation.created_unix_ms = now;
                    conversation.their_alias = Some(payload.alias.clone());
                    // Rebind to the slot that opened the NODE envelope (same as
                    // the fresh-inbound fold): a mislabeled fill could have bound
                    // a different slot, and a later accept would pin input[0] to
                    // an address the counterpart doesn't know (the D-067
                    // identity-fragmentation class). Safe while PendingInbound —
                    // nothing was accepted against the stale binding.
                    conversation.bound_branch = to_key_branch(slot.0);
                    conversation.bound_index = slot.1;
                    // NAME IT FROM THE PAGE (PRE3-SENDER, `wallet-security-
                    // auditor`). A fill invitation is minted address-less (an
                    // archive sets no identity, D-139). Our node has now folded
                    // the handshake itself, and its page names the sender: node
                    // truth for this very transaction. Unnamed, the row would
                    // hold every comm its sender writes until the next start.
                    // Only the invitation whose own handshake this is: the row
                    // was found by where the archive filed the txid, and an
                    // older store can hold an archive comm inside another
                    // invitation (`consensus-auditor`).
                    if conversation.contact_address.is_empty()
                        && conversation.handshake_txid.as_deref() == Some(txid)
                    {
                        if let Some(sender) =
                            page_sender.filter(|s| validate_mainnet_address(s).is_ok())
                        {
                            conversation.contact_address = sender.to_string();
                            named = Some(sender.to_string());
                        }
                    }
                    warn_store(store.upsert_conversation(conversation));
                    // The rules keyed on a resolved sender run with it (L186),
                    // as in `backfill_invitation_sender`.
                    if let Some(sender) = named.take() {
                        refuse_blocked_knock_comms(hub, &mut store, &old.conversation_id, &sender);
                        let host = match store.merge_contact(&sender) {
                            Ok(Some((host, _))) => host,
                            Ok(None) => old.conversation_id.clone(),
                            Err(e) => {
                                log::warn!("transport-hub: contact merge failed: {e}");
                                old.conversation_id.clone()
                            }
                        };
                        release = Some((host, sender));
                    }
                }
            }
            drop(store);
            if let Some((host, sender)) = release {
                log::info!("transport-intake: an archive invitation named by our node (tx={txid})");
                release_held_comms(hub, &host, &payload.alias, &sender);
                // The merge may have folded this row away: the host is the
                // thread that changed.
                if host != old.conversation_id {
                    ping(&host);
                }
            }
            watch_acceptance(txid, block_time_ms);
            ping(&old.conversation_id);
            return FoldOutcome::Recorded;
        }

        // The acceptance leg used to live HERE, completing a conversation on
        // nothing but a decryptable payload and an echoed alias — both of them
        // public. It now runs below, after the node has named the sender
        // (F5); this scope keeps only the override lane, which was already
        // node-gated.
    }

    // ── D-139: the counterparty's ADDRESS is the conversation key ──────────
    //
    // The live population looks a handshake up "strictly by sender address
    // only" and treats a repeat from a known contact as idempotent: it
    // refreshes their alias, activates a conversation it had initiated, and
    // **emits no response** (`conversation-manager-service.ts:181-213` @
    // `acd3cf65`). Ours waited for an acceptance that, against such a
    // counterparty, is never sent — so the conversation hung at
    // `PendingOutbound` with `their_alias = None`, and because inbound comms
    // are matched by alias, every message they sent afterwards was dropped
    // too. Both directions dead from one missing field. Measured on the
    // founder's device 2026-08-14 and proven on chain: he handshaked an
    // address that had handshaked him five weeks earlier, and that address
    // has no reply on chain at all, because their client correctly sent none.
    //
    // So we match their semantics. The sender is the node's own answer —
    // consensus data, never payload content (§0.3): the walk's page names it
    // (input 0's previous output, PRE3-SENDER), and the return-address lookup,
    // which needs the bond's P1.5 activity record, is the fallback.
    //
    // **No response is emitted and no accept card is armed**, which is also
    // what keeps the bond arithmetic honest: a re-handshake carries a fresh
    // 0.2 KAS, and creating a second invitation here would let the user spend
    // a second refund on a conversation that is already paid for.
    // **NODE TRUTH ONLY** (consensus-auditor BLOCK, 2026-08-14).
    //
    // This branch rewrites an EXISTING conversation's identity — their alias
    // and the key slot we seal to. It may therefore only run on evidence the
    // node itself produced.
    //
    // On the fill lane the txid is an indexer CLAIM, and the decrypt proves
    // only that the PAYLOAD opens for us — nothing binds that payload to that
    // txid. A hostile endpoint could serve one row pairing an attacker-authored
    // handshake envelope (anyone may seal one to a published receive address —
    // that is the protocol) with the txid of a real payment we received from a
    // contact. The sender would then resolve to that contact's address, and we
    // would rebind their conversation to the attacker's alias and slot: their
    // genuine messages would stop matching, and the attacker's would arrive
    // inside a thread the user trusts. There is no way to bind an
    // indexer-supplied payload to an indexer-supplied txid without our own node
    // seeing the transaction, so the rule is simply that identity comes from
    // the node (D-074, as F68 corrected it: an archive can omit a row and can
    // forge one, so nothing it serves may set identity — the same reason
    // `transport_prepare_accept` refuses a `FillSourced` invitation).
    //
    // Cost, stated plainly: a handshake recoverable only from the archive can
    // no longer complete a conversation by address. It still folds as an
    // invitation, and the node-override lane upgrades it if our own scan ever
    // reaches that txid.
    //
    // **Resolve on the node lane whether or not a MATCH is possible**, and the
    // split matters. The pre-check below asks whether any conversation holds a
    // counterparty address; on the very first invitation a wallet ever receives
    // that is false — so gating the RESOLVE on it meant the sender was never
    // looked up in exactly the case where recording it matters most, and the
    // row was stored as "Unknown sender" forever.
    //
    // The cheap pre-check still guards the MATCH, which is all it was ever
    // reasoning about.
    //
    // **The page names it first (PRE3-SENDER, `consensus-auditor`).** The walk's
    // page carries input 0's previous-output address, the very definition
    // `get_utxo_return_address` answers with, from the same node: so the sender
    // is known at fold time, with no call and no wait for the bond's activity
    // record. Without it an invitation was minted address-less on the live lane
    // and named seconds later, and the comm its sender wrote in the same page
    // met a row with no contact to compare: since the comm lane admits only the
    // contact, that message would have been refused for good. The lookup stays
    // as the fallback for a page that named no sender (a node off the pin).
    let resolved_sender = if origin == EventOrigin::Node {
        match page_sender {
            Some(sender) => Some(sender.to_string()),
            None => resolve_handshake_sender(txid).await,
        }
    } else {
        // A fill row's sender is an indexer claim; identity never comes from
        // one (D-139/D-074). Such a row stays address-less until our own node
        // reaches its txid.
        None
    };
    // ── F5: the acceptance leg, on NODE TRUTH ONLY ─────────────────────────
    //
    // An acceptance response completes a conversation we initiated: their
    // fresh alias arrives in `alias`, OUR alias echoes back in `their_alias`.
    //
    // It sits here, after the resolve and before the D-139 match, for two
    // reasons. It needs `resolved_sender`, which is only available past the
    // await; and it must keep its precedence over the address lane, which
    // would otherwise claim the same conversation by a different key and log
    // it as something it is not.
    //
    // The rule is D-139's, applied to the lane that was missed: this branch
    // rewrites an EXISTING conversation's identity — their alias and the key
    // slot we seal to — so it may only run on evidence the node itself
    // produced. The old gate ("the envelope opened, and it echoes an alias we
    // answer to") authenticated nobody: the alias rides the wire in cleartext
    // outside the envelope, and the envelope is sealed to a published receive
    // address, so both halves are available to any observer for the price of
    // one dust transaction.
    if payload.is_acceptance() {
        let echoed = payload.their_alias.as_deref().unwrap_or_default();
        let pending = {
            let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
            store.conversation_awaiting_response(echoed).cloned()
        };
        if let Some(existing) = pending {
            match acceptance_verdict(
                origin,
                resolved_sender.as_deref(),
                &existing.contact_address,
            ) {
                // The node named the sender, and it is the contact WE chose
                // when we opened this conversation. Only they could have sent
                // it; complete now.
                AcceptanceVerdict::Complete => {
                    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
                    // RE-READ under the write lock. The row above was cloned
                    // under a *different* acquisition, and writing that
                    // snapshot back would clobber anything a concurrent FRB
                    // worker settled in between — the check and the state it
                    // protects must be one critical section (L73). The
                    // deferred sibling re-reads for the same reason; before
                    // this the two lanes disagreed about their own rule.
                    let Some(current) = store.conversation(&existing.conversation_id) else {
                        return dropped(HANDSHAKE, txid, DropReason::StoreRace, origin);
                    };
                    // Re-run the WHOLE verdict against the re-read row, not
                    // just its status. Checking only `status` inside the lock
                    // while the address half still rested on the pre-lock
                    // snapshot would leave the rule half-enforced — and the
                    // address is the load-bearing half of this gate.
                    if current.status != ConversationStatus::PendingOutbound
                        || acceptance_verdict(
                            origin,
                            resolved_sender.as_deref(),
                            &current.contact_address,
                        ) != AcceptanceVerdict::Complete
                    {
                        return dropped(HANDSHAKE, txid, DropReason::StoreRace, origin);
                    }
                    let mut conversation = current.clone();
                    conversation.their_alias = Some(payload.alias.clone());
                    conversation.status = ConversationStatus::Active;
                    // REBIND to the slot that actually opened it — this is the
                    // key the counterparty resolved for us and will keep
                    // sealing to.
                    conversation.bound_branch = to_key_branch(slot.0);
                    conversation.bound_index = slot.1;
                    // Never regress the activity clock: a FILLED old acceptance
                    // must not re-sort the conversation above newer traffic.
                    conversation.last_activity_unix_ms =
                        conversation.last_activity_unix_ms.max(now);
                    let conversation_id = conversation.conversation_id.clone();
                    unhide_on_inbound(&mut store, &conversation_id);
                    warn_store(store.upsert_conversation(conversation));
                    warn_store(store.record_message(MessageRecord {
                        txid: txid.to_string(),
                        conversation_id: conversation_id.clone(),
                        direction: MessageDirection::Inbound,
                        kind: StoredKind::Handshake,
                        envelope: envelope_bytes,
                        unix_ms: payload.timestamp,
                        alias_on_wire: None,
                        sealed_to: None,
                        provenance: origin.row_source(),
                        wire,
                    }));
                    drop(store);
                    watch_acceptance(txid, block_time_ms);
                    ping(&conversation_id);
                    return FoldOutcome::Recorded;
                }
                // The node named a DIFFERENT sender. Whatever this is, it is
                // not this conversation's counterparty answering — fall
                // through and let the address lane treat it as what it is: a
                // handshake from whoever actually sent it.
                AcceptanceVerdict::NotOurContact => {
                    log::info!(
                        "transport-intake: acceptance tx={txid} echoes our alias but was sent \
                         by someone else — not completing"
                    );
                }
                // No sender yet. This is the COMMON live case, not an error:
                // the return-address lookup needs the bond's own activity
                // record, which does not exist when the acceptance is first
                // folded. Park the claim and ask the chain who sent it. Nothing
                // is written to the conversation and no row is stored yet — an
                // unauthenticated claim earns neither, exactly as an unroutable
                // comm earns none; both land once the sender is proven.
                AcceptanceVerdict::AwaitSender => {
                    if !acceptance_already_parked(txid) {
                        park_acceptance(
                            txid,
                            ParkedAcceptance {
                                conversation_id: existing.conversation_id.clone(),
                                their_alias: payload.alias.clone(),
                                bound_branch: to_key_branch(slot.0),
                                bound_index: slot.1,
                                envelope: envelope_bytes,
                                unix_ms: payload.timestamp,
                                wire,
                            },
                        );
                        if let Some(tracker) = dag::tracker_handle() {
                            tracker.note_sender_interest(txid);
                        }
                        // `note_sender_interest` is the fast path, not the only
                        // one: it fires only for a txid named by a FUTURE VCC
                        // batch, so an acceptance folded out of the unlock
                        // catch-up or the F4 replay — an OLD block, whose batch
                        // the tracker walked past on the same `Connected` —
                        // would never be signalled by it. That is precisely the
                        // traffic F4 exists to recover, so the claim is ALSO
                        // swept by [`sweep_parked_acceptances`], which asks the
                        // wallet's own activity record and does not depend on a
                        // batch arriving at all.
                        log::info!("transport-intake: acceptance tx={txid} held — awaiting sender");
                    }
                    return dropped(HANDSHAKE, txid, DropReason::AcceptanceUnverified, origin);
                }
                // A FILL row never parks: its txid is an indexer claim, so
                // resolving a sender for it would authenticate the label, not
                // the payload (D-139/D-074).
                AcceptanceVerdict::Refuse => {
                    return dropped(HANDSHAKE, txid, DropReason::AcceptanceUnverified, origin);
                }
            }
        }
        // An acceptance we have no pending side for — fall through and treat
        // it as a fresh inbound handshake (the live app does the same).
    }

    let can_match_by_address = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store.conversations_have_any_contact_address()
    };
    if can_match_by_address {
        if let Some(sender) = resolved_sender.clone() {
            let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(existing) = store.conversation_by_contact_address(&sender) {
                let mut conversation = existing.clone();
                let conversation_id = conversation.conversation_id.clone();
                unhide_on_inbound(&mut store, &conversation_id);
                let was = conversation.status;
                conversation.their_alias = Some(payload.alias.clone());
                // Their handshake is the authority on which of our keys they seal
                // to — the same rebinding the acceptance leg does, and what keeps
                // our input[0] on the address they know us by (D2).
                conversation.bound_branch = to_key_branch(slot.0);
                conversation.bound_index = slot.1;
                // Only a conversation WE initiated may auto-activate. One they
                // initiated still needs our accept — that is where the bond is
                // refunded, and skipping it would take their money silently.
                if conversation.initiated_by_me && conversation.status != ConversationStatus::Active
                {
                    conversation.status = ConversationStatus::Active;
                }
                conversation.last_activity_unix_ms = conversation.last_activity_unix_ms.max(now);
                warn_store(store.upsert_conversation(conversation));
                warn_store(store.record_message(MessageRecord {
                    txid: txid.to_string(),
                    conversation_id: conversation_id.clone(),
                    direction: MessageDirection::Inbound,
                    kind: StoredKind::Handshake,
                    envelope: envelope_bytes,
                    unix_ms: payload.timestamp,
                    alias_on_wire: None,
                    sealed_to: None,
                    provenance: origin.row_source(),
                    wire,
                }));
                drop(store);
                log::info!(
                    "transport-intake: handshake matched an existing contact by address \
                 (status {was:?} -> active check) — no response emitted, per D-139"
                );
                watch_acceptance(txid, block_time_ms);
                ping(&conversation_id);
                return FoldOutcome::Recorded;
            }
        }
    }

    // A new inbound handshake: pending until the user accepts (the accept
    // card resolves the sender + sends the §0.6 refund).
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);

    // …unless we already hold the conversation this handshake belongs to.
    //
    // Measured on the device: a restore replayed eight archived handshakes and
    // minted eight invitations, several of them for conversations the backup
    // had just rebuilt in full. The user sees strangers asking to connect who
    // are in fact contacts they already have, and dismissing one tombstones a
    // row that then blocks the real conversation.
    //
    // An alias is 48 bits of the counterparty's own choosing and they mint a
    // fresh one per conversation, so a handshake carrying an alias we already
    // hold IS that conversation — not a new request. Refusing costs nothing and
    // fails closed: no bond is ever spent by NOT showing an invitation.
    if store
        .conversation_by_alias(&payload.alias)
        .is_some_and(|c| c.their_alias.as_deref() == Some(payload.alias.as_str()))
    {
        drop(store);
        return dropped(
            HANDSHAKE,
            txid,
            DropReason::ConversationAlreadyKnown,
            origin,
        );
    }

    let conversation_id = fresh_conversation_id();
    let conversation = ConversationRecord {
        conversation_id: conversation_id.clone(),
        // The sender, when our own node could tell us — not an empty string.
        //
        // An invitation with no address is a card asking the user to spend
        // 0.2 KAS on "Unknown sender", and it is invisible to every lookup, so
        // typing that same address later mints a SECOND bond beside theirs
        // instead of completing the one they already paid for. The accept flow
        // still resolves the refund destination itself at spend time — this is
        // for recognition, never for where money goes.
        contact_address: resolved_sender.unwrap_or_default(),
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
    warn_store(store.upsert_conversation(conversation));
    warn_store(store.record_message(MessageRecord {
        txid: txid.to_string(),
        conversation_id: conversation_id.clone(),
        direction: MessageDirection::Inbound,
        kind: StoredKind::Handshake,
        envelope: envelope_bytes,
        unix_ms: payload.timestamp,
        alias_on_wire: None,
        sealed_to: None,
        provenance: origin.row_source(),
        wire,
    }));
    drop(store);
    watch_acceptance(txid, block_time_ms);
    ping(&conversation_id);
    FoldOutcome::Recorded
}

/// Who may write in a conversation's thread (F2, PRE3-SENDER, §0.10).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CommSenderVerdict {
    /// The sender is the conversation's contact: fold it.
    Contact,
    /// Someone else sent it: refuse it (`SenderNotContact`). So is an archive
    /// row naming no one, or anyone for a row with no contact address.
    NotContact,
    /// Our node's page named no sender: ask the return-address lane, which
    /// applies this same rule once the chain names one.
    AwaitSender,
    /// Our node named a sender, but the row does not know its contact yet (an
    /// invitation whose sender has not resolved): HOLD the comm with its
    /// sender until the row's address is written, then judge it
    /// (`release_held_comms`). A settled refusal could not be judged again
    /// when the address lands (`wallet-security-auditor`).
    AwaitContact,
}

/// **A comm enters a contact's thread only when the transaction's sender is
/// that contact** — the F2 gate as a pure decision, so it is driven
/// exhaustively without a hub.
///
/// The alias routes, it never authenticates: it rides the wire in cleartext,
/// and the envelope seals to our published key, so both halves of the old
/// gate ("the alias matches and the envelope opens") are open to any observer
/// for one fee. The sender is input 0's previous-output address, the pin's
/// definition (`TransportEvent::sender`), compared with the contact address
/// we chose or our own node resolved. One rule for every alias the row
/// answers to, ours included.
///
/// On the fill lane `sender` is the archive's claim. It must name the contact
/// too, and the row keeps its `archive` provenance: the claim narrows what an
/// archive can file, it does not make the archive our node. An archive row
/// with no claim is refused; it never waits on a lookup, because its txid is a
/// label (D-139). An address-less row matches no sender, as in
/// [`acceptance_verdict`]: on the node lane the comm is held until the row
/// learns its contact, and an archive row is refused. Both sides are canonical
/// strings: every writer of
/// `contact_address` stores an `Address`'s own `to_string()` (the backup
/// restore included, since PRE3-SENDER), the page's sender is decoded the same
/// way, and the archive's claim is its indexer's `Address::to_string()`.
fn comm_sender_verdict(
    origin: EventOrigin,
    sender: Option<&str>,
    contact_address: &str,
) -> CommSenderVerdict {
    match sender {
        Some(sender) if !contact_address.is_empty() && sender == contact_address => {
            CommSenderVerdict::Contact
        }
        Some(_) if contact_address.is_empty() && origin == EventOrigin::Node => {
            CommSenderVerdict::AwaitContact
        }
        Some(_) => CommSenderVerdict::NotContact,
        None if origin == EventOrigin::Node => CommSenderVerdict::AwaitSender,
        None => CommSenderVerdict::NotContact,
    }
}

/// Node truth disproves an archive row: the archive filed it as the contact's,
/// and our own walk names a different sender for the same txid, or carries an
/// alias none of our rows answers to. The row leaves the thread (PRE3-SENDER).
/// Re-checked under the lock, so a racing writer's node row is never the one
/// removed. A hard delete, not the reorg tombstone: a ghost would still render
/// the forged text, and the txid's real acceptance would untombstone it
/// (`wallet-security-auditor`).
fn remove_disproven_archive_row(hub: &TransportHub, txid: &str) {
    // Remembered first: the fill's range start is inclusive, so it re-serves
    // its boundary row, and a removed row must not be filed again.
    note_refuted(txid);
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(conversation_id) = store
        .message(txid)
        .filter(|row| {
            row.direction == MessageDirection::Inbound
                && matches!(row.provenance, RowSource::FillSourced | RowSource::Unknown)
        })
        .map(|row| row.conversation_id.clone())
    else {
        return;
    };
    if let Err(e) = store.remove_message(txid) {
        log::warn!("transport-hub: store remove failed: {e}");
        return;
    }
    drop(store);
    log::info!(
        "transport-intake: archive row tx={txid} removed — our node names a sender who is not \
         the contact (PRE3-SENDER)"
    );
    ping(&conversation_id);
}

#[allow(clippy::too_many_arguments)]
fn handle_inbound_comm(
    hub: &TransportHub,
    txid: &str,
    body: &[u8],
    block_time_ms: Option<u64>,
    block_hash: Option<&str>,
    sender: Option<&str>,
    origin: EventOrigin,
    wire: WireNamespace,
) -> FoldOutcome {
    // Our own walk already refused this txid, or disproved an archive row for
    // it, or is HOLDING it until the chain or the row can judge it: the
    // archive's claim gets no hearing ahead of our node's (PRE3-SENDER,
    // `wallet-security-auditor`). Filed first, it would win the txid dedup,
    // and the comm our node proved would never be recorded.
    if origin == EventOrigin::Fill {
        if is_refuted(txid) {
            return dropped(COMM, txid, DropReason::SenderNotContact, origin);
        }
        if comm_already_parked(txid) {
            return dropped(COMM, txid, DropReason::SenderPending, origin);
        }
    }
    // DAG re-delivery / our own sent row echoing back: pre-crypto skip —
    // except a NODE event over a stored indexer claim (`FillSourced`) or
    // pre-V5 row (`Unknown`), which proceeds in OVERRIDE mode (V5,
    // finding 14) through the full verify-by-decrypt below.
    let override_row = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        match store.message(txid) {
            Some(row) => {
                let overridable = origin == EventOrigin::Node
                    && row.direction == MessageDirection::Inbound
                    && matches!(row.provenance, RowSource::FillSourced | RowSource::Unknown);
                if !overridable {
                    return dropped(COMM, txid, DropReason::AlreadyStored, origin);
                }
                Some(row.clone())
            }
            None => None,
        }
    };
    // The alias head sits OUTSIDE the envelope — split BEFORE any envelope
    // parse (P2.2 handover law).
    let Some((alias, sealed)) = split_comm_body(body) else {
        return dropped(COMM, txid, DropReason::MalformedCommHead, origin);
    };
    // Over an archive row: our node's own transaction for this txid carries a
    // different alias from the one the archive filed it under, so the filing
    // is disproven on the alias alone. The row goes, and the node's comm is
    // judged on its own merits, as if the archive had never spoken. A row
    // with no recorded alias (pre-V5) is never judged this way, and one whose
    // alias simply stopped routing (a re-handshake, a merge) keeps its row
    // (`wallet-security-auditor`).
    let override_row = match override_row {
        Some(old)
            if old
                .alias_on_wire
                .as_deref()
                .is_some_and(|filed| filed != alias) =>
        {
            remove_disproven_archive_row(hub, txid);
            None
        }
        other => other,
    };
    // Relevance without crypto: the alias must belong to one of our
    // conversations (either side's — senders tag with their own). It ROUTES;
    // the sender check below is what admits.
    let (conversation_id, bound, verdict) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(conversation) = store.conversation_by_alias(&alias) else {
            // An alias we do not know — but it may be a contact whose row we
            // LOST (a wipe, a reinstall, a handshake we never saw), and a
            // client that already knows us never re-announces itself. Their
            // alias is right here in cleartext; what is missing is proof the
            // message is theirs. See `revive_or_drop` (D-307) for the gate.
            //
            // Over an archive row whose alias merely stopped routing, our node
            // still judges its sender: a sender who is not that row's contact
            // disproves the filing (`wallet-security-auditor`).
            let disproven = match (&override_row, sender) {
                (Some(old), Some(sender)) => store
                    .conversation(&old.conversation_id)
                    .is_some_and(|c| !c.contact_address.is_empty() && c.contact_address != sender),
                _ => false,
            };
            drop(store);
            if disproven {
                remove_disproven_archive_row(hub, txid);
            }
            return revive_or_drop(
                hub,
                txid,
                alias,
                sealed,
                block_time_ms,
                block_hash,
                sender,
                origin,
                wire,
            );
        };
        // A DISMISSED INVITATION STAYS DISMISSED.
        //
        // This drop stops THIS row being re-armed. It is not what stops a
        // stranger costing the user money — they can always mint a NEW
        // invitation with a fresh dust handshake. The money is held by
        // `transport_prepare_accept`'s bond check, which refuses to refund a
        // bond that never arrived.
        //
        // Hiding a row that never became a contact is a local **block**, not
        // a mute. A `PendingInbound` row IS the accept affordance, and
        // accepting spends the §0.6 bond refund — so if a stranger could
        // re-arm it merely by writing again, the user's only exit from an
        // unwanted, money-spending invitation would be revocable by the very
        // party they dismissed (INV-6: no state whose exit needs the
        // counterparty's cooperation).
        //
        // This is refused HERE rather than inside `unhide_on_inbound`
        // deliberately: stopping only the un-hide would still record their
        // messages into a row no user can ever open — the silent sink that
        // the un-hide exists to prevent. Dropping is the honest answer.
        if comm_is_dismissed(
            conversation.status,
            store.is_conversation_tombstoned(&conversation.conversation_id),
        ) {
            return dropped(COMM, txid, DropReason::DismissedInvitation, origin);
        }
        // A BLOCKED ADDRESS'S TRAFFIC IS REFUSED BEFORE IT IS STORED, on the
        // routed branch too (`consensus-auditor`, MSG-BLOCK). The block
        // purges every row for the address, but their next handshake mints a
        // request — by design, so they can knock — and that row answers to
        // their alias; without this every comm they sent after it would be
        // recorded into the request, preview included. The address on a
        // request is the node's own sender resolution, so this keys on
        // chain-witnessed identity, not on the alias.
        if hub
            .block_list
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_blocked(&conversation.contact_address)
        {
            return dropped(COMM, txid, DropReason::BlockedContact, origin);
        }
        (
            conversation.conversation_id.clone(),
            (
                to_core_branch(conversation.bound_branch),
                conversation.bound_index,
            ),
            comm_sender_verdict(origin, sender, &conversation.contact_address),
        )
    };
    // THE SENDER CHECK (F2, PRE3-SENDER, §0.10), before any decrypt, so a
    // stranger writing under a known alias costs us no key work at all.
    match verdict {
        CommSenderVerdict::Contact => {}
        CommSenderVerdict::NotContact => {
            // Over an archive row the node has just disproved, the row goes:
            // a thread holds only what its contact sent. And our walk's
            // refusal is remembered, so the fill, which runs after the walk,
            // cannot file the archive's claim for the same txid.
            if origin == EventOrigin::Node {
                if override_row.is_some() {
                    remove_disproven_archive_row(hub, txid);
                }
                note_refuted(txid);
            }
            return dropped(COMM, txid, DropReason::SenderNotContact, origin);
        }
        CommSenderVerdict::AwaitSender | CommSenderVerdict::AwaitContact => {
            // Nothing node-proven can replace an archive row here, so it stays
            // as it is, with its `archive` provenance.
            if override_row.is_some() || comm_already_parked(txid) {
                return dropped(COMM, txid, DropReason::SenderPending, origin);
            }
        }
    }
    let envelope_bytes = decode_envelope_body(sealed);
    let Ok(envelope) = Envelope::from_bytes(&envelope_bytes) else {
        return dropped(COMM, txid, DropReason::MalformedEnvelope, origin);
    };
    // Validation decrypt: bound slot first (§0.7 fast path), then the window
    // (robustness against a counterparty that re-resolved our address). The
    // plaintext is DROPPED here — decrypt-on-view happens at thread pull.
    //
    // It proves the envelope was sealed to us, and nothing about who sealed
    // it: the seal is to our PUBLISHED key, so anyone can make one we open,
    // an archive included, which can also pair it with any txid it likes
    // (F68). The sender check above is what ties a row to its contact.
    let opened: KeySlot = match hub.decryptor.decrypt_at(bound, &envelope) {
        Ok(_) => bound,
        Err(CoreError::TransportOpen) => {
            match hub
                .decryptor
                .decrypt_scanning(hub.keys().slots.iter().copied(), &envelope)
            {
                Ok((slot, _)) => slot,
                // Alias matched but no key opens it — a spoofed head, or the
                // vault shut mid-stream. Two very different events; say which.
                Err(e) => return dropped(COMM, txid, decrypt_drop(&e), origin),
            }
        }
        Err(e) => return dropped(COMM, txid, decrypt_drop(&e), origin),
    };
    // THE FALLBACK (deliverable 4): the page named no sender, so the comm is
    // parked, sealed, on the revival lane's own machinery — the interest, the
    // locate, the return-address lookup — and `fold_parked_comm` applies this
    // same rule to the address the chain names. Never recorded before then.
    if verdict == CommSenderVerdict::AwaitSender {
        park_comm(
            txid,
            ParkedComm {
                alias,
                slot: opened,
                envelope: envelope_bytes,
                block_time_ms,
                wire,
                sender: None,
            },
        );
        if let Some(tracker) = dag::tracker_handle() {
            tracker.note_sender_interest(txid);
        }
        // Its own seat: a sibling with no sender never folds on this proof.
        schedule_sender_locate(
            txid.to_string(),
            txid.to_string(),
            block_hash.map(str::to_string),
        );
        log::info!(
            "transport-intake: comm tx={txid} named no sender on the page — parked for the \
             return-address lookup (PRE3-SENDER)"
        );
        return dropped(COMM, txid, DropReason::SenderPending, origin);
    }
    let sealed_to = (opened != bound).then(|| (to_key_branch(opened.0), opened.1));

    // Row clock = block time when the source knows it (fill + scans since
    // V2b): filled history sorts into its true position, not "now".
    let now = block_time_ms.unwrap_or_else(now_unix_ms);
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    // Re-check under the RE-TAKEN lock. The decrypt above ran unlocked, and
    // `transport_hide_conversation` runs concurrently on an FRB worker — so a
    // dismissal can land between the alias-resolution guard and here. Without
    // this, the message would be recorded into a row no user can ever open,
    // which is the silent sink that guard exists to prevent.
    if comm_is_dismissed(
        store
            .conversation(&conversation_id)
            .map_or(ConversationStatus::Active, |c| c.status),
        store.is_conversation_tombstoned(&conversation_id),
    ) {
        return dropped(COMM, txid, DropReason::DismissedInvitation, origin);
    }
    // Same re-check for a block landing inside the unlocked decrypt window,
    // and for the sender: the row's contact is read again under this lock.
    let address = store
        .conversation(&conversation_id)
        .map(|c| c.contact_address.clone());
    if let Some(address) = address.as_deref() {
        if hub
            .block_list
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_blocked(address)
        {
            return dropped(COMM, txid, DropReason::BlockedContact, origin);
        }
    }
    match address
        .as_deref()
        .map(|address| comm_sender_verdict(origin, sender, address))
    {
        Some(CommSenderVerdict::Contact) => {}
        // THE HOLD: the sender is known and the row is not. Decided and parked
        // under THIS lock, which every writer of a row's address takes first,
        // so no release can fall between the verdict and the park
        // (`consensus-auditor`, L73). Parked with its sender, sealed, and
        // nothing asked of the chain: the lookup would name the same address
        // and meet the same empty row. The writer releases it
        // (`release_held_comms`); a row named during the decrypt was matched
        // above and the comm is recorded.
        Some(CommSenderVerdict::AwaitContact) => {
            park_comm(
                txid,
                ParkedComm {
                    alias,
                    slot: opened,
                    envelope: envelope_bytes,
                    block_time_ms,
                    wire,
                    sender: sender.map(str::to_string),
                },
            );
            drop(store);
            log::info!(
                "transport-intake: comm tx={txid} held until its invitation names a sender \
                 (PRE3-SENDER)"
            );
            return dropped(COMM, txid, DropReason::SenderPending, origin);
        }
        Some(_) => {
            if origin == EventOrigin::Node {
                note_refuted(txid);
            }
            return dropped(COMM, txid, DropReason::SenderNotContact, origin);
        }
        // The row went inside the decrypt window (a merge folded it). A comm
        // that was the contact's keeps the old behaviour; one that was waiting
        // to be judged has nothing left to be judged against.
        None if verdict != CommSenderVerdict::Contact => {
            return dropped(COMM, txid, DropReason::StoreRace, origin);
        }
        None => {}
    }
    let record = MessageRecord {
        txid: txid.to_string(),
        conversation_id: conversation_id.clone(),
        direction: MessageDirection::Inbound,
        kind: StoredKind::Comm,
        envelope: envelope_bytes,
        unix_ms: now,
        alias_on_wire: Some(alias),
        sealed_to,
        provenance: origin.row_source(),
        wire,
    };

    // OVERRIDE mode (V5, finding 14): the node-resolved conversation is the
    // row's true home — when the claim had filed it elsewhere, both threads
    // get the re-pull nudge.
    if let Some(old) = override_row {
        match store.override_message(record) {
            Ok(Some(_)) => {}
            Ok(None) => return dropped(COMM, txid, DropReason::StoreRace, origin),
            Err(e) => {
                log::warn!("transport-hub: store append failed: {e}");
                return dropped(COMM, txid, DropReason::StoreFailed, origin);
            }
        }
        if let Some(existing) = store.conversation(&conversation_id) {
            let mut conversation = existing.clone();
            conversation.last_activity_unix_ms = conversation.last_activity_unix_ms.max(now);
            unhide_on_inbound(&mut store, &conversation_id);
            warn_store(store.upsert_conversation(conversation));
        }
        drop(store);
        watch_acceptance(txid, block_time_ms);
        ping(&conversation_id);
        if old.conversation_id != conversation_id {
            ping(&old.conversation_id);
        }
        return FoldOutcome::Recorded;
    }

    let recorded = store.record_message(record);
    if let Err(e) = &recorded {
        log::warn!("transport-hub: store append failed: {e}");
        return dropped(COMM, txid, DropReason::StoreFailed, origin);
    }
    if let Ok(true) = recorded {
        if let Some(existing) = store.conversation(&conversation_id) {
            let mut conversation = existing.clone();
            // Max, never assignment: an old filled row must not re-sort the
            // conversation list above genuinely newer traffic.
            conversation.last_activity_unix_ms = conversation.last_activity_unix_ms.max(now);
            unhide_on_inbound(&mut store, &conversation_id);
            warn_store(store.upsert_conversation(conversation));
        }
        drop(store);
        watch_acceptance(txid, block_time_ms);
        ping(&conversation_id);
        return FoldOutcome::Recorded;
    }
    // `Ok(false)` — the store's own txid dedup settled it.
    dropped(COMM, txid, DropReason::AlreadyStored, origin)
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
) -> Result<SignableSummaryDto, AppError> {
    let dest = validate_mainnet_address(&destination)?;
    if amount_sompi == 0 {
        // The Generator needs a real payment output; message value floors are
        // the D-054 machinery's job (send_minimum), never a hardcoded number.
        return Err(AppError::msg("enter an amount greater than zero"));
    }
    let payload = compose_bcast(&channel, &message).map_err(AppError::chain)?;

    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;

    // Same change rule as the payment path: back to `receive/0`, so a public
    // broadcast cannot sweep the identity address and silently kill every
    // conversation (see `send::payment_change_address`).
    let change = crate::api::send::payment_change_address()?;
    let signer = wallet::wallet_signer()?;
    let signer: Arc<dyn SignerT> = Arc::new(signer);

    let rpc = dag::shared_monitor().await?.rpc();

    let prepared = engine
        .prepare_send(
            dest,
            amount_sompi,
            change,
            signer,
            rpc,
            Some(payload),
            // Other conversations' coins sort last here too (D-169): a
            // handshake is an ordinary send with a payload, and it can strand
            // a neighbour exactly as a payment can.
            &crate::api::send::spend_exclusions(),
        )
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

    Ok(project_signable(
        nonce,
        SignableKind::Bcast,
        &summary,
        Some(payload_kind),
    ))
}

/// The spendable coins at `source` — waiting for our own change to mature, but
/// only when something is genuinely on its way to THIS address.
///
/// **Wait for our own change; do not refuse over it (D-148).** Source-address
/// discipline pins input[0] to `source` and routes change back to it, so every
/// send in the messages lane is serialized behind the previous one's change
/// becoming spendable. Refusing during that window told the user their funds
/// were the problem when the wallet was only waiting on itself, and it fired on
/// a backup, a handshake and a message alike.
///
/// **What is actually being waited on is ACCEPTANCE, not maturity.** The pin
/// force-matures a UTXO it recognises as belonging to one of our own outgoing
/// transactions (context.rs:590 → context.rs:299-300), so our change skips the
/// 100-DAA hold entirely and is spendable the moment the `UtxosChanged`
/// notification lands — see [`WalletEngine::settling_at`], which reads the
/// outgoing set for exactly this reason. [`MATURITY_WAIT`] is therefore sized
/// against the submit → acceptance-notification round trip, which is normally
/// about a second at ten blocks per second; the budget is loose because a slow
/// link, not the DAA clock, is what stretches it.
///
/// **The wait is gated address-locally** ([`WalletEngine::settling_at`]), not on
/// the wallet's folded balance. The balance answered a different question than
/// the one being asked: it could report a payment settling on an unrelated
/// address — buying this send a pointless twenty-four-second block it always
/// ends by refusing — or report nothing at all before the first snapshot lands,
/// refusing instantly on a funded address that was mid-settle. An address that
/// has simply never been funded is a different answer and deserves a different
/// sentence; waiting twenty seconds to say "no coins" helps nobody.
///
/// **Call this BEFORE measuring anything about the coin shape.** A floor
/// computed while the wallet is all-immature is measured over a UTXO set this
/// wait exists to change — and on a wallet whose every coin is settling there is
/// no floor to compute at all (`send.rs`,
/// `no_mature_coin_means_no_floor_at_all`), so the caller refuses with the
/// anti-dust sentence and never reaches this wait. Blaming the user's coin shape
/// for what is only a clock is the L92 scar in a second lane.
async fn await_spendable_at(
    engine: &WalletEngine,
    source: &Address,
) -> Result<Vec<UtxoEntryReference>, AppError> {
    let mut priority = engine
        .mature_utxos_at(source)
        .await
        .map_err(AppError::chain)?;
    if !priority.is_empty() {
        return Ok(priority);
    }
    // Which address this is decides BOTH refusal sentences below, so it is
    // computed once — after the fast path, so an ordinary send never pays for a
    // derivation only a refusal needs.
    //
    // `receive/0` is the identity address and the wallet's default (UX-R4b: no longer the only one it shows — the receive picker offers the whole window, and this branch's copy names `Main` for that reason).
    // Anything else is a conversation bound to the slot that decrypted its
    // handshake, or one a restore payload bound to a change branch
    // (`restored_conversation`). Those cannot be named to the user — the app
    // never surfaces a bound address — so no sentence below may prescribe
    // funding one.
    let identity = vault::wallet_address_at(Branch::Receive, 0).ok();
    let is_identity = identity.as_ref() == Some(source);
    if !engine.settling_at(source) {
        // ONE re-read before the hardest sentence in this file. The pin has a
        // state where a coin is in neither set we just looked at:
        // `handle_pending` retains a matured entry OUT of the processor's
        // pending map (processor.rs:279-285) and only THEN awaits `promote`,
        // which is what puts it into `mature` (context.rs:395-405). Read across
        // that gap and a wallet whose coin matured microseconds ago is told it
        // has no money.
        //
        // The sleep is the honest part. Re-reading immediately only narrows the
        // gap — nothing orders our read after the promote — whereas one poll
        // interval comfortably outlasts a promote made of local map operations.
        // It is spent only on the way to a refusal, and it is 1/60th of the wait
        // this branch is refusing to spend.
        tokio::time::sleep(MATURITY_POLL).await;
        priority = engine
            .mature_utxos_at(source)
            .await
            .map_err(AppError::chain)?;
        if !priority.is_empty() {
            return Ok(priority);
        }
        // The address itself never reaches logcat — it would tie the device to
        // an on-chain identity. Which KIND of address it is, is the whole
        // diagnosis and leaks nothing.
        log::warn!(
            "transport-send: refusing — source is dry and nothing is settling (identity address: {is_identity})"
        );
        return Err(AppError::msg(if is_identity {
            // "nothing on the way that I can see", not "nothing on the way":
            // one thing is invisible from here — a coinbase in stasis
            // (`settling_at`'s named blind spot). Prescribing "receive some KAS"
            // as the ONLY way forward would be false for a miner.
            // And it NAMES the address, which it did not have to before
            // UX-R4b: with a receive picker on the glass, "your wallet
            // address" no longer identifies one thing to a user who may have
            // just been paid at `Receive 05`. `Main` is the picker's own word
            // for `receive/0` (L92's rider — the refusal's wording is in
            // scope).
            "Main, your default address, has no spendable coins yet, and nothing on the way that \
             I can see — receive some KAS to Main to send messages from here"
        } else {
            // A conversation bound somewhere other than receive/0. Both halves
            // of the refill/drain question, said out loud (wallet-security
            // item 19, L92's destination): what REFILLS such an address is only
            // that conversation's own sends, because since D-148 every
            // payment's change goes home to receive/0; what DRAINS it is any
            // ordinary payment, because `prepare_send` draws from the
            // Generator's general UTXO iterator over every watched window
            // address with no exclusion for bound slots. So a payment can
            // strand a conversation the same way it once stranded the whole
            // wallet — one lane narrower, and with no address to show the user.
            // Logged as an open item; this sentence only refuses to lie about it.
            "this conversation can't send right now — its own return address has no coins, \
             and nothing is on the way to it"
        }));
    }
    let started = std::time::Instant::now();
    let deadline = started + MATURITY_WAIT;
    while priority.is_empty() && std::time::Instant::now() < deadline {
        tokio::time::sleep(MATURITY_POLL).await;
        priority = engine
            .mature_utxos_at(source)
            .await
            .map_err(AppError::chain)?;
    }
    // Say how long it actually took, every time. The fix's only other evidence
    // is an error the user DOESN'T see, and an absence proves nothing about a
    // window this short (INV-10) — this line is what makes the wait measurable
    // on glass instead of merely plausible.
    log::info!(
        "transport-send: waited {} ms for change to mature at the bound address, {} coin(s) now spendable",
        started.elapsed().as_millis(),
        priority.len()
    );
    if priority.is_empty() {
        // The budget expired. Count what the pin still calls unsettled at this
        // address so a repeat is diagnosable from a log rather than a block
        // explorer — a COUNT, never the txids: in this lane a txid IS a
        // message's identity (§0.4), and logcat is not where that belongs.
        log::warn!(
            "transport-send: {} ms elapsed with nothing spendable at the source; still-settling: {}",
            started.elapsed().as_millis(),
            engine.settling_at(source)
        );
        // Deliberately does NOT say "your last transaction is still settling",
        // and names a second path. Reaching here means something addressed to us
        // never arrived inside the budget, and the pin cannot tell us why: an
        // outgoing transaction that is submitted but never accepted is NEVER
        // evicted (`handle_outgoing` only retires one that has an acceptance
        // score, processor.rs:336-345), so this can also be a dead transaction
        // that will latch until a rescan. "A few seconds" alone would be a
        // promise the code cannot keep — naming a cause it did not check is the
        // L92 scar. Branched on the same rule as the dry sentence above: sending
        // a user to the Receive screen when the starved address is a
        // conversation's own is sending them to the wrong subsystem.
        return Err(AppError::msg(if is_identity {
            "still waiting on coins to reach your wallet address — try again in a few seconds, \
             and reopen the app if it keeps saying this"
        } else {
            "still waiting on coins to reach this conversation's return address — try again in \
             a few seconds, and reopen the app if it keeps saying this"
        }));
    }
    Ok(priority)
}

/// Build + stash one encrypted-kind transport send over the shared two-phase
/// seam; returns the B7 summary (payload kind decoded from the BUILT tx).
///
/// **Source-address discipline (D2/P4/D-067, the L47 scar).** Every send to a
/// conversation PINS input[0] to the conversation's bound own address `source`
/// and routes change back to it, so a Kasia-class counterpart — which resolves
/// who a tx is from by input[0]'s return address and drops/splits on a
/// mismatch (`conversation-manager-service.ts:181`, `messaging.store.ts:768`) —
/// sees exactly ONE identity for us, forever, and the address stays funded for
/// the next send. If `source` holds no spendable UTXO we surface an honest
/// "still confirming" message rather than silently spend from another address
/// (which fragments that identity — the whole bug).
///
/// **`priority` is passed IN, already waited for.** Every caller runs
/// [`await_spendable_at`] itself, because two of them must measure the coin
/// shape (`minimum_sendable`) after the wait and before this call. Waiting again
/// here would make the messages lane traverse the budget twice — up to 48 s
/// under a modal the user cannot dismiss — for a set the caller already holds.
/// One wait per send, owned by whoever needed it first.
async fn prepare_transport_send(
    dest: Address,
    amount_sompi: u64,
    wire: Vec<u8>,
    source: Address,
    priority: Vec<UtxoEntryReference>,
    intent: TransportIntent,
    pin: PinPolicy,
) -> Result<SignableSummaryDto, AppError> {
    // `await_spendable_at` errors rather than returning empty, and the pinned
    // Generator rejects an empty priority outright (a pinned send with nothing
    // to pin is a silent identity change — `prepare_send_pinned`). This is the
    // belt on the seam between them; it never crosses the bridge.
    debug_assert!(
        !priority.is_empty(),
        "priority must come from `await_spendable_at`, which never yields empty"
    );
    // D-069 structural check: a comm-carried kind IS a self-send — its
    // destination and pinned source are the same bound address (value
    // returns as change; the sheet leads with the fee). Debug-only belt: the
    // kind the DTO carries must never claim self-send over a tx that pays a
    // stranger. Never crosses the bridge (release-stripped).
    debug_assert!(
        !matches!(
            intent,
            TransportIntent::Comm { .. } | TransportIntent::SelfStash { .. }
        ) || dest == source,
        "a Comm or SelfStash intent must be a self-send (D-069): dest == source"
    );
    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;

    let priority_len = confinement_ceiling(&priority);
    let priority = match pin {
        PinPolicy::Default => priority,
        // Sort input[0] toward what the indexer can attribute (see `PinPolicy`).
        // The store answers "is this txid one of ours" — a HashMap hit per
        // UTXO, taken under a guard that is dropped before the next `.await`
        // (this file's own law: a `std::sync::Mutex` guard never crosses one).
        PinPolicy::OwnerAttributable => {
            let hub = hub().ok();
            let store = hub
                .as_ref()
                .map(|h| h.store.lock().unwrap_or_else(PoisonError::into_inner));
            let ordered = order_priority_for_owner(
                priority,
                |entry| {
                    (
                        entry.utxo.outpoint.index(),
                        entry.utxo.outpoint.transaction_id().to_string(),
                    )
                },
                |txid| store.as_ref().is_some_and(|s| s.has_message_txid(txid)),
            );
            drop(store);
            ordered
        }
    };
    let signer = wallet::wallet_signer()?;
    let signer: Arc<dyn SignerT> = Arc::new(signer);
    let rpc = dag::shared_monitor().await?.rpc();

    let prepared = engine
        .prepare_send_pinned(
            dest,
            amount_sompi,
            priority,
            source,
            signer,
            rpc,
            Some(wire),
            // This conversation's own coins are the PINNED block and are taken
            // out of the pool before any demotion, so the reservation set can
            // only ever demote a NEIGHBOUR's coins here (D-169).
            &crate::api::send::spend_exclusions(),
        )
        .await
        .map_err(|e| {
            // Live buckets for the shortfall classifier (same read as the
            // payment path, send.rs — INV-8 honesty over node-read balance).
            let (mature, pending, outgoing) = wallet::latest_snapshot()
                .map(|s| {
                    (
                        s.mature_sompi.unwrap_or(0),
                        s.pending_sompi.unwrap_or(0),
                        s.outgoing_sompi.unwrap_or(0),
                    )
                })
                .unwrap_or((0, 0, 0));
            friendly_prepare_error(e, amount_sompi, mature, pending, outgoing)
        })?;

    // SOURCE CONFINEMENT — only for the owner-attributable lane.
    //
    // The pinned Generator consumes `priority` first and then falls through to
    // the general UTXO iterator, while routing ALL change to `source`. For a
    // comm that is merely a top-up. For a backup it is a slow leak with teeth:
    // it would migrate a coin out of another conversation's §0.7 bound change
    // address into this one, and that conversation's next message would then
    // fail with "waiting on confirming funds" at a perfectly healthy balance —
    // a D-067 fragmentation caused by a housekeeping transaction.
    //
    // Refuse instead, and say why. A backup deferred by a minute costs nothing;
    // a wedged conversation costs a diagnosis.
    if pin == PinPolicy::OwnerAttributable && prepared.summary().utxo_count as usize > priority_len
    {
        return Err(AppError::msg(
            "your main address is still settling — try the backup again in a minute",
        ));
    }

    let built = prepared.final_payload();
    let payload_kind = parse_payload(&built)
        .map(|(kind, _)| kind)
        .unwrap_or_else(|| "none".to_string());

    let nonce = next_nonce();
    let kind = kind_of_intent(&intent);
    stash_intent(nonce, intent);
    let summary = prepared.summary().clone();
    *PENDING_TRANSPORT
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some((nonce, prepared));

    Ok(project_signable(nonce, kind, &summary, Some(payload_kind)))
}

/// The SOURCE-CONFINEMENT ceiling: how many of the caller's pinned coins can
/// actually PIN. `prepare_send_pinned` withholds covenant-bound coins before
/// building (D-211's `pinned_priority_or_refuse`), so a ceiling taken on the
/// raw set would be inflated by covenant dust on the bound address and let a
/// draw BEYOND the pin — a neighbour conversation's coin — pass as confined
/// (closure-audit F-1, wallet-security re-dispatch; L129: measure on the same
/// side of a filter as the thing the measurement governs).
fn confinement_ceiling(priority: &[UtxoEntryReference]) -> usize {
    priority
        .iter()
        .filter(|entry| !kaspaverse_chain::is_covenant_bound(entry))
        .count()
}

/// The flow mode a stashed intent describes — RUST's knowledge, carried on
/// the canonical summary so the sheet's rendering can never be steered by a
/// caller flag (V5; the D-069 self-send semantics ride `SelfSendFrame`).
fn kind_of_intent(intent: &TransportIntent) -> SignableKind {
    match intent {
        TransportIntent::Bcast => SignableKind::Bcast,
        TransportIntent::Handshake { .. } => SignableKind::Bond,
        TransportIntent::Accept { .. } => SignableKind::BondRefund,
        // A backup is a self-send whose value returns as change, so the honest
        // ceremony is the existing one: the sheet leads with the FEE, never
        // with a spend. The `contextNote` on the Dart side says what it is.
        TransportIntent::Comm { .. } | TransportIntent::SelfStash { .. } => {
            SignableKind::SelfSendFrame
        }
    }
}

/// Honest friendly mapping of the Generator's typed errors for the compose
/// surfaces (the carried L-pattern from `StorageMassExceeded`, P2.1 note).
/// `InsufficientFunds` routes through the SAME shortfall classifier as the
/// payment path (V5, finding 7's second half): settling change from a
/// just-broadcast send rides the `outgoing` bucket, and a comm/handshake
/// minutes after a send must say "still settling", never "insufficient" at
/// ample balance. Pure over its inputs; tested.
fn friendly_prepare_error(
    e: ChainError,
    amount_sompi: u64,
    mature_sompi: u64,
    pending_sompi: u64,
    outgoing_sompi: u64,
) -> AppError {
    match e {
        ChainError::TransactionTooHeavy => AppError::msg(
            "this message is too large for one transaction — shorten it and try again",
        ),
        ChainError::InsufficientFunds { .. } => AppError::msg(shortfall_message(
            amount_sompi,
            mature_sompi,
            pending_sompi,
            outgoing_sompi,
        )),
        ChainError::StorageMassExceeded { .. } => AppError::msg(
            "this send is too small for your current coins — the network anti-dust \
             rule. Nothing was sent — wait for pending funds or add to your balance.",
        ),
        other => AppError::chain(other),
    }
}

/// Phase 1 (initiate a conversation): fresh alias + the live-shape handshake
/// JSON, sealed to the recipient's address key; 0.2 KAS bond (§0.6 — THE one
/// provenance-cited constant, refunded in their acceptance). The plaintext is
/// re-sealed to self HERE so the stash holds ciphertext only (§0.4).
/// Which existing row a handshake to its address REUSES rather than minting
/// beside: one we opened and are still waiting on (a retry announces the same
/// alias), or one a contact's message revived after a wipe (D-307 — `Active`
/// with no alias of ours, and the handshake is what gives it one).
fn handshake_reuses(row: &ConversationRecord) -> bool {
    (row.status == ConversationStatus::PendingOutbound && row.initiated_by_me)
        || (row.status == ConversationStatus::Active && row.my_alias.is_empty())
}

pub async fn transport_prepare_handshake(
    destination: String,
) -> Result<SignableSummaryDto, AppError> {
    let dest = validate_mainnet_address(&destination)?;
    let recipient_x_only = x_only_of(&dest)?;
    let hub = hub()?; // the store must be live before we can promise persistence

    // ONE CONVERSATION PER CONTACT — the live population's model, and the
    // repair for how this wallet ended up holding two rows for one person.
    //
    // Minting blind put a fresh `PendingOutbound` row beside a conversation
    // the user already had: a second identity for the same contact, with a
    // second alias and no knowledge of theirs. Their client then answered the
    // repeat handshake idempotently and sent nothing, so the new row could
    // never complete while the old one held the alias.
    //
    // Reuse keeps the conversation id, OUR alias and the bound slot verbatim:
    // re-deriving the slot is the D-067 identity-fragmentation class, and
    // keeping the alias is what lets an acceptance to EITHER handshake land on
    // the one row (`conversation_awaiting_response` matches the echoed alias).
    //
    // Reuse does NOT avoid the second 0.2 KAS — only the refusals do — and
    // against a counterparty who already knows us that bond is never refunded,
    // because their client sends no response (D-139). Sending a message is
    // usually the cheaper repair: it costs a fee only.
    //
    // Adding a contact is also an explicit UN-HIDE. The user typed this
    // address; reusing or refusing a row they can no longer see would spend a
    // bond into an invisible conversation and leave the address permanently
    // unreachable, since nothing in the UI can un-hide one (INV-6). A
    // dismissed invitation can never reach here — those rows carry no contact
    // address — so this cannot resurrect one.
    let existing = {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let rows: Vec<ConversationRecord> = store
            .conversations_for_contact_address(&dest.to_string())
            .into_iter()
            .cloned()
            .collect();
        // FIRST match, not last: the vector is most-established first, and the
        // row we pick decides which alias goes back on the wire.
        let reuse = rows.iter().find(|r| handshake_reuses(r)).cloned();
        // Un-hide ONLY the row this call reuses. Restoring every hidden row
        // for the address would hand back the broken duplicate the user hid —
        // the very state this change exists to converge away from. INV-6 needs
        // the row we reuse to be reachable, and nothing more.
        //
        // **An Active row is deliberately NOT un-hidden here**, and that is a
        // correction (`consensus-auditor`, 2026-08-17). Un-hiding it and then
        // refusing against it made "hide this, then invite them again" close
        // its own exit: the row came back and the refusal below pointed at it.
        // With the send path now also refusing a superseded conversation, a
        // contact whose live thread is the broken one had NO per-contact way
        // out at all — only the total wipe, which costs every other
        // conversation. That satisfies INV-6 by the letter and fails it where
        // it matters.
        if let Some(row) = reuse.as_ref() {
            // Through `may_unhide`, like every other un-hide site. It is a
            // no-op today — a `PendingInbound` row carries no contact address,
            // so it cannot appear in this vector at all — but recording the
            // sender at fold time (the F2 follow-up this file already names)
            // is exactly what would put one here and silently re-arm a refund
            // the user declined.
            if may_unhide(
                row.status,
                store.is_conversation_tombstoned(&row.conversation_id),
            ) {
                warn_store(store.untombstone_conversation(&row.conversation_id));
                log::info!("transport-send: re-adding a hidden contact — conversation restored");
            }
        }
        // Tombstoned rows do not block a fresh invitation. Hiding one IS the
        // user saying "not this thread", so treating it as a live conversation
        // and refusing would leave the address unreachable by any per-contact
        // gesture — the same INV-6 reason the expired-invitation carve-out
        // below already gives for falling through.
        // A REVIVED row (D-307: Active, no alias of ours) is not "already a
        // conversation" for this purpose — it is the one Active row a
        // handshake exists to complete, and `handshake_reuses` picked it up
        // above.
        if rows.iter().any(|r| {
            r.status == ConversationStatus::Active
                && !r.my_alias.is_empty()
                && !store.is_conversation_tombstoned(&r.conversation_id)
        }) {
            return Err(AppError::msg(
                "you already have a conversation with this address. Open it from your messages instead of sending another invitation.",
            ));
        }
        // THEY invited US, and it is still acceptable — accepting refunds the
        // bond they already paid and completes the conversation, where a
        // handshake of ours spends a second one and strands theirs.
        //
        // This became reachable only once an invitation recorded its sender; it
        // was a stated gap for as long as the row carried no address to match.
        // An expired, dismissed or archive-sourced invitation deliberately does
        // NOT match: the accept path refuses those permanently, so refusing here
        // too would make that address unreachable forever (INV-6).
        if rows.iter().any(|r| invitation_is_acceptable(&store, r)) {
            return Err(AppError::msg(
                "this address already invited you — accept their invitation instead. \
                 That returns the bond they paid and opens the conversation; sending \
                 your own would spend a second one.",
            ));
        }
        reuse
    };
    // That gap is now CLOSED. It stood open for as long as a `PendingInbound`
    // row carried no contact address: invisible to an address lookup, so
    // handshaking someone whose invitation was already in the list spent a
    // second bond beside theirs. The node lane now records the sender when it
    // folds the handshake, and the acceptance event backfills it when the bond
    // is accepted — which is the usual path, because the activity record the
    // resolver needs does not exist yet at fold time.
    //
    // Residual, stated: an invitation recovered only from the history archive
    // still carries no address (identity never comes from an indexer, D-139),
    // so that one case can still mint a second bond.

    // A revived row has no alias of ours to reuse — that is the whole reason
    // it is being handshaken — so it gets a fresh one here, and the row
    // carries it from the commit on.
    let my_alias = match &existing {
        Some(row) if !row.my_alias.is_empty() => row.my_alias.clone(),
        _ => fresh_alias(),
    };
    let timestamp_ms = now_unix_ms();
    let payload = HandshakePayload::initial(&my_alias, timestamp_ms)
        .map_err(AppError::core)?
        .to_plaintext()
        .map_err(AppError::core)?;

    let envelope = encrypt(&recipient_x_only, &payload).map_err(AppError::core)?;
    let wire = compose_handshake_wire(&envelope.to_bytes()).map_err(AppError::chain)?;

    // §0.7 binding for an outbound conversation: receive/0 — which is also THE
    // address the wallet hands out (`vault_receive_address`), so our whole
    // transport identity is this one address (D2/P4). Source-address discipline
    // pins the handshake's input[0] to it and returns change to it, so the
    // address Kasia resolves for us == the address we seal with == receive/0,
    // and it self-funds for every later message in the conversation.
    // Reuse binds to the slot the conversation ALREADY has — re-deriving it
    // would repoint our input[0] at an address the counterpart does not know
    // us by (D-067).
    let bound: KeySlot = match &existing {
        Some(row) => (to_core_branch(row.bound_branch), row.bound_index),
        None => (Branch::Receive, 0),
    };
    let own_address = vault::wallet_address_at(bound.0, bound.1)?;
    let reseal = encrypt(&x_only_of(&own_address)?, &payload)
        .map_err(AppError::core)?
        .to_bytes();

    let conversation = match existing {
        // A retry on the row we already have: same id, same slot; the alias
        // it already had, or the fresh one a revived row was missing.
        Some(row) => ConversationRecord {
            my_alias: my_alias.clone(),
            last_activity_unix_ms: timestamp_ms,
            ..row
        },
        None => ConversationRecord {
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
        },
    };

    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;
    let priority = await_spendable_at(&engine, &own_address).await?;

    prepare_transport_send(
        dest,
        HANDSHAKE_BOND_SOMPI,
        wire,
        own_address, // source-address discipline: input[0] + change = receive/0
        priority,
        TransportIntent::Handshake {
            conversation,
            reseal,
            timestamp_ms,
        },
        PinPolicy::Default,
    )
    .await
}

/// Is there already a conversation with this address that the user can just
/// OPEN? Returns its id, or `None` if adding this contact means a handshake.
///
/// **A distinguishable answer, deliberately — not a parsed error string.** The
/// same question is settled authoritatively inside `transport_prepare_handshake`,
/// which refuses rather than spending a second bond, but a refusal reaches the UI
/// as prose. Asking here lets the surface do the useful thing (open the thread)
/// instead of telling the user to go and find it, and it asks BEFORE a confirm
/// sheet quotes a bond the user does not need to pay.
///
/// This is a hint, not the guard: the prepare path keeps its own refusal, so a
/// race between this call and the ceremony still cannot mint a duplicate.
///
/// **Adding a contact is an explicit un-hide** (INV-6, the same rule the
/// handshake path applies). If the row is hidden, typing that address is the
/// user asking for it back — nothing else in the UI can restore one. A
/// `PendingInbound` row is never un-hidden or returned here: that is a
/// dismissed invitation, its Accept button spends a bond, and a stranger must
/// not be able to re-arm it.
pub fn transport_existing_conversation(
    address: String,
) -> Result<Option<ContactRouteDto>, AppError> {
    let dest = validate_mainnet_address(&address)?;
    let hub = hub()?;
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let rows: Vec<ConversationRecord> = store
        .conversations_for_contact_address(&dest.to_string())
        .into_iter()
        .cloned()
        .collect();

    // A LIVE CONVERSATION OUTRANKS EVERYTHING — checked first, deliberately.
    //
    // This used to start with the invitation branch, and the reason it gave was
    // sound but conditional: accepting refunds the bond they already paid,
    // where sending our own handshake spends a SECOND 0.2 KAS. That argument
    // only holds when the alternative is spending. If a working thread already
    // exists, opening it spends nothing at all, so nothing outranks it.
    //
    // Left first, the invitation branch became an own-goal
    // (`wallet-security-auditor`, 2026-08-17): `conversations_for_contact_address`
    // sorts oldest-established first, so "add this contact" could route to a
    // stale-but-still-acceptable invitation (`invite_expired` bounds that to
    // the pruning horizon — days, not months); accepting it re-stamps
    // `created_unix_ms` to now,
    // which makes THAT row the newest Active one — superseding the thread that
    // actually works, refusing sends into it, and leaving the dead alias as the
    // only sendable one. Exactly the failure this change exists to end,
    // re-created by our own routing.
    //
    // Their invitation is not lost by this: it stays in Requests, where
    // accepting it is a deliberate act rather than a side effect of typing an
    // address.
    // An Active row with no alias of ours (D-307's revived row) cannot be
    // sent into yet, but it IS the thread — the user reads it there and it
    // offers the handshake that makes it answerable. Routing them into a
    // fresh invitation instead would mint the same handshake beside it.
    let found = rows
        .iter()
        .find(|c| {
            c.status == ConversationStatus::Active
                || comm_sendable(c.status, c.initiated_by_me, &c.contact_address, &c.my_alias)
        })
        .map(|c| (c.conversation_id.clone(), c.status));

    // Only when no live thread exists: THEIR invitation outranks sending one
    // of our own, because accepting refunds the bond they already paid.
    //
    // Only when the accept path would actually succeed. Expired, dismissed or
    // archive-sourced invitations are refused there, and routing the user into
    // a dead end would leave them unable to reach that address at all (INV-6).
    if found.is_none() {
        let acceptable = rows.iter().find(|c| invitation_is_acceptable(&store, c));
        if let Some(invitation) = acceptable {
            return Ok(Some(ContactRouteDto {
                conversation_id: invitation.conversation_id.clone(),
                accept_first: true,
            }));
        }
    }

    // `found` was computed above, before the invitation branch, because a live
    // thread outranks it. It is a conversation the user could actually TALK in,
    // decided by the same predicate the send path uses rather than a second
    // copy of the rule.
    //
    // It used to have to skip *superseded* rows as well —
    // `conversations_for_contact_address` sorts oldest-established first, so on
    // a contact who had re-handshaked after wiping their client a bare `find`
    // routed the user into the replaced thread. **There is no such pair any
    // more** (D-305): `TransportStore::merge_contact` folds duplicate rows per
    // contact at every door one can arrive through, so these rows are one row,
    // and the oldest-first sort has nothing stale to land on.
    let Some((conversation_id, status)) = found else {
        return Ok(None);
    };
    if may_unhide(status, store.is_conversation_tombstoned(&conversation_id)) {
        warn_store(store.untombstone_conversation(&conversation_id));
        log::info!("transport: re-adding a hidden contact — conversation restored");
    }
    drop(store);
    ping(&conversation_id);
    Ok(Some(ContactRouteDto {
        conversation_id,
        accept_first: false,
    }))
}

/// The raw bytes of a file attachment, for saving it to the device.
///
/// Fetched on DEMAND rather than pushed with every thread row: a thread pull
/// renders dozens of messages, and shipping every attachment's bytes across
/// the FFI to draw a card would be wasteful for the common case and unbounded
/// for the bad one. The card is drawn from the description; the bytes cross
/// only when the user asks to save.
///
/// The name returned alongside is OURS — scrubbed to a base name in the
/// parser, so a caller writing a file cannot be handed `../../something`.
pub fn transport_attachment_bytes(
    conversation_id: String,
    txid: String,
) -> Result<AttachmentBytesDto, AppError> {
    let hub = hub()?;
    let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let record = store
        .message(&txid)
        .filter(|m| m.conversation_id == conversation_id)
        .cloned()
        .ok_or_else(|| AppError::msg("message not found"))?;
    let bound = store
        .conversation(&conversation_id)
        .map(|c| (to_core_branch(c.bound_branch), c.bound_index))
        .ok_or_else(|| AppError::msg("conversation not found"))?;
    drop(store);

    let envelope =
        Envelope::from_bytes(&record.envelope).map_err(|_| AppError::msg("unreadable message"))?;
    let slot = record
        .sealed_to
        .map(|(b, i)| (to_core_branch(b), i))
        .unwrap_or(bound);
    let plaintext = open_with_fallback(&hub, slot, &envelope).map_err(|e| match e {
        CoreError::VaultLocked => AppError::msg("wallet is locked — unlock to save this file"),
        _ => AppError::msg("unreadable message"),
    })?;
    let body = String::from_utf8_lossy(&plaintext).into_owned();
    match Attachment::parse(&body) {
        Some(Ok(file)) => Ok(AttachmentBytesDto {
            name: file.name,
            bytes: file.bytes,
        }),
        Some(Err(_)) => Err(AppError::msg("this file could not be decoded")),
        None => Err(AppError::msg("this message is not a file")),
    }
}

/// A file's bytes plus the safe base name to write them under.
#[derive(Clone)]
pub struct AttachmentBytesDto {
    pub name: String,
    pub bytes: Vec<u8>,
}

/// **A size, never the file** — the strictest case of the posture
/// `ConversationDto` and `ThreadMessageDto` carry, because `bytes` is a whole
/// decrypted attachment rather than one line of it. A derived `Debug` here
/// would put a counterparty's file into a log with one `{:?}`
/// (`ffi-leak-auditor`, this sitting).
impl std::fmt::Debug for AttachmentBytesDto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AttachmentBytesDto")
            .field("name", &self.name.len())
            .field("bytes", &self.bytes.len())
            .finish()
    }
}

/// Name (or rename) a contact. An empty name clears it back to the address.
///
/// Keyed on the ADDRESS, not the conversation: a name belongs to a person, and
/// conversation ids are minted fresh on a re-handshake and can change across a
/// restore. Returns the stored name, or `None` when cleared.
///
/// The text is the user's own, so it is not foreign — but it is cleaned and
/// bounded at the write (control characters dropped, whitespace collapsed,
/// length capped) so no list row, header or log line can be forged by a paste.
/// Never logged: this is user content (§4), so only its presence is reportable.
pub fn transport_set_contact_name(
    address: String,
    name: String,
) -> Result<Option<String>, AppError> {
    let dest = validate_mainnet_address(&address)?;
    let dir = vault::transport_store_dir()?;
    let mut names = kaspaverse_chain::ContactNames::load(&dir);
    let stored = names.set(&dest.to_string(), &name);
    names.save(&dir).map_err(AppError::chain)?;
    log::info!(
        "transport: contact name {}",
        if stored.is_some() { "set" } else { "cleared" }
    );
    ping_notice_inputs();
    Ok(stored)
}

/// One saved contact: the address, and the name the user gave it.
///
/// The pair travels together because a name without its address is not a
/// contact — it is a label the wallet cannot route to, and every surface that
/// renders a name must be able to show the address it stands for (BG-15: a
/// name never replaces an address on a funds surface).
#[derive(Clone, Debug)]
pub struct ContactDto {
    pub address: String,
    pub name: String,
}

/// Every saved contact, sorted by name.
///
/// The write side (`transport_set_contact_name`) has existed since the
/// messaging lane needed to label a thread; this is the read that lets a
/// surface OTHER than a conversation ask "who do I know?" — the Send screen's
/// contacts card and the receipt's "save as contact".
///
/// **Nothing secret crosses.** An address is public by construction and a name
/// is the user's own label for it; neither is key material, and the store is
/// device-local plaintext JSON by design (`contact_names.rs`) — this read adds
/// no exposure the write did not already have.
///
/// **Sorted here rather than at each caller.** Two surfaces now render this
/// list, and an order computed twice is an order that will disagree once
/// (BG-21). The comparator folds case before comparing, so `dev fund` sits
/// beside `Dev Fund` instead of every capital being banished to the top, and
/// ties break on the address so the order is total rather than merely stable.
///
/// Infallible in practice: a missing or corrupt file reads as "no contacts"
/// (`ContactNames::load`), which costs the user a list and never a send.
pub fn transport_contact_names() -> Result<Vec<ContactDto>, AppError> {
    let dir = vault::transport_store_dir()?;
    let names = kaspaverse_chain::ContactNames::load(&dir);
    let mut out: Vec<ContactDto> = names
        .names
        .into_iter()
        // **Cleaned and validated on the way OUT, not only on the way in.**
        //
        // The write has sanitized since `sanitize_name` existed — but the
        // deceptive-format filter (bidi overrides, zero-width joiners, the BOM)
        // landed one commit AFTER the store did, so a name written in that
        // window carries only control-character filtering. Nothing re-cleaned
        // it, and this read now carries names onto a funds surface, where an
        // RLO inside `This matches <name> in your contacts.` reorders the
        // sentence around it (`wallet-security-auditor`, UX-R2B). Re-running
        // the same function makes the read total against any past build and
        // against a hand-edited `contact.names`.
        //
        // The address is re-checked for the same reason and by the pinned
        // crate's own parse (INV-9): a row whose key does not parse is a
        // tappable destination the wallet cannot route to, and it is dropped
        // rather than offered. Both filters are free — this file is tens of
        // rows, read once per mount.
        .filter(|(address, _)| validate_mainnet_address(address).is_ok())
        .map(|(address, name)| ContactDto {
            address,
            name: kaspaverse_chain::sanitize_name(&name),
        })
        .filter(|c| !c.name.is_empty())
        .collect();
    out.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.address.cmp(&b.address))
    });
    log::info!("transport: {} contact(s) read", out.len());
    Ok(out)
}

/// Where "add this contact" should actually go.
#[derive(Clone, Debug)]
pub struct ContactRouteDto {
    pub conversation_id: String,
    /// `true` when this address has already invited US: accepting refunds
    /// the bond they paid and completes the conversation, where sending our
    /// own invitation would spend a second one and strand theirs.
    pub accept_first: bool,
}

/// Phase 1 (accept an inbound handshake): resolve the SENDER via the node's
/// own return-address lookup (consensus data, never payload content — §0.3:
/// this flow commits value), build the acceptance response, refund the 0.2
/// KAS bond (§0.6).
pub async fn transport_prepare_accept(
    conversation_id: String,
) -> Result<SignableSummaryDto, AppError> {
    let hub = hub()?;
    let (their_alias, handshake_txid, bound) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let conversation = store
            .conversation(&conversation_id)
            .ok_or_else(|| AppError::msg("conversation not found"))?;
        if conversation.status != ConversationStatus::PendingInbound {
            return Err(AppError::msg("this conversation isn't awaiting an accept"));
        }
        // ── EVERY CONDITION BELOW IS ALSO A CONDITION OF
        // `invitation_is_acceptable`. The gates that POINT here mirror this
        // rule; tightening this one without tightening that one is how the app
        // came to refuse a handshake saying "accept their invitation instead"
        // while Accept refused saying "your node has no record of this". These
        // are stated separately only because each failure earns its own
        // sentence — the SET must stay identical.
        //
        // The invariant lives at the SPEND, not in the render path. A
        // dismissed invitation is unreachable today only because the list
        // filters it out and Dart is the sole caller — so any future surface
        // handing back a conversation_id (deep link, notification, restore)
        // would spend 0.2 KAS on a card the user explicitly dismissed.
        if store.is_conversation_tombstoned(&conversation_id) {
            return Err(AppError::msg(
                "you dismissed this invitation — accepting it would return a bond you chose not to take up",
            ));
        }
        // Terminal-vs-transient taxonomy (V5, finding 15): past the pruning
        // horizon the bond can never resolve — the honest refusal is
        // permanent, never "try again in a few seconds". Defense in depth
        // with the card's own `invite_expired` gate (a row can cross the
        // horizon while on screen).
        if invite_expired(
            conversation.status,
            conversation.created_unix_ms,
            now_unix_ms(),
        ) {
            return Err(AppError::msg(
                "this invitation has expired and can no longer be accepted",
            ));
        }
        let their_alias = conversation
            .their_alias
            .clone()
            .ok_or_else(|| AppError::msg("handshake carried no alias"))?;
        let txid = conversation
            .handshake_txid
            .clone()
            .ok_or_else(|| AppError::msg("handshake transaction unknown"))?;
        // An invitation our own node has never seen cannot be accepted, because
        // accepting SPENDS: it returns the 0.2 KAS bond to an address resolved
        // from the claimed handshake tx. F3's provenance badge does not reach
        // this decision — a `pending_in` card has `onTap: null`, so the thread
        // (and the badge) is unreachable until AFTER acceptance, which puts the
        // honesty marker after the money moves in precisely the case it exists
        // for: an archive that manufactured a whole contact (consensus-auditor,
        // run-1 fix wave re-verify).
        //
        // **An ALLOWLIST, not a denylist** (`consensus-auditor`, 2026-08-17).
        // This used to refuse only `FillSourced`, which meant a MISSING row —
        // `None` — sailed through the one gate standing between an unverified
        // claim and a 0.2 KAS spend. `None` is reachable without anyone
        // deleting anything: the inbound fold upserts the conversation and
        // records its handshake row under two separate `warn_store` calls, so
        // a swallowed write error leaves a `PendingInbound` row whose
        // `handshake_txid` points at nothing. It was also reachable by simply
        // clearing the thread until that path learned to keep this row.
        // Naming what MAY spend leaves nothing to be forgotten, and puts
        // `Unknown` on the refusing side explicitly rather than by omission.
        //
        // A wait, not a dead end (INV-6): the node-override lane flips the row
        // to `NodeScanned` the moment our own scan reaches that txid, and this
        // clears itself.
        if !accept_provenance_ok(&store, &txid) {
            // Two different truths, two different sentences. "From an archive"
            // is false when the row is simply missing, and a wrong diagnosis
            // sends the user to wait for a catch-up that will never fix it.
            return Err(AppError::msg(
                if matches!(
                    store.message(&txid).map(|m| m.provenance),
                    Some(RowSource::FillSourced)
                ) {
                    "this invitation came from a history archive and your own node has \
                     not seen it yet — accepting would return the bond on an unverified \
                     claim. It will clear once your node catches up."
                } else {
                    "your node has no record of this invitation, so the bond cannot be \
                     returned safely. Long-press the request to hide it, then add them \
                     as a contact yourself."
                },
            ));
        }
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
        // NOT "still confirming". This fires both while a real bond confirms AND
        // permanently for a txid that never paid us at all, and the transient
        // wording made the permanent case look like a retry (the V5 finding-15
        // taxonomy sin). Say both halves and let the user tell them apart.
        AppError::msg(
            "your node has not seen a payment from this invitation. If it has just \
             arrived, wait a few seconds; if it never does, the invitation carried \
             no bond and accepting it would send your own coins for nothing.",
        )
    })?;

    // The bond must have been RECEIVED before we refund it. Accepting spends
    // HANDSHAKE_BOND_SOMPI to an address resolved from the counterparty's own
    // transaction, and nothing checked what that transaction paid us — so a
    // real dust transaction carrying a handshake payload sealed to our public
    // receive address earned 0.2 KAS per accept, repeatably, for the cost of
    // dust plus a fee. **Defection paid**, which is the one thing the design law
    // forbids (D-019, stag hunt not prisoner's dilemma).
    //
    // Kasia does NOT check this — see the note on `HANDSHAKE_BOND_SOMPI`. This
    // is a deliberate divergence UPWARD, and it is interop-safe: every genuine
    // Kasia handshake pays exactly 0.2 (`messaging.store.ts:1086` defaults it,
    // and the only two call sites that override are the response and the
    // self-stash), and ours pays the same constant.
    //
    // Refuse rather than refund-what-arrived: a partial refund still costs us a
    // network fee per fake invitation, so it converts a profitable grief into a
    // cheap one instead of ending it.
    let received = engine
        .activity_value_sompi(&handshake_txid)
        .unwrap_or_default();
    if received < HANDSHAKE_BOND_SOMPI {
        return Err(AppError::msg(format!(
            "this invitation did not carry the {} KAS bond — it paid {}. Accepting \
             would send your own coins to a stranger who paid nothing, so the \
             wallet refuses. You can still ignore or dismiss the invitation.",
            format_kas(HANDSHAKE_BOND_SOMPI),
            format_kas(received),
        )));
    }
    let rpc = dag::shared_monitor().await?.rpc();
    let sender = resolve_return_address(&rpc, &handshake_txid, daa)
        .await
        .map_err(AppError::chain)?;
    let dest = validate_mainnet_address(&sender)?;
    // ONE ROW PER CONTACT, AT THE SPEND (`wallet-security-auditor`,
    // 2026-09-07). The sender fact arrives in two places — the backfill lane
    // and right here — and a rule keyed on it must run in both (L186). If this
    // address already has a conversation, their handshake IS the answer to it
    // (or a refresh of it): the fold's D-139 arm and the merge both take the
    // accept card away for exactly that case, and this ceremony must not be
    // the one path that still pays a second 0.2 KAS for it. Write the address
    // the node just named, fold, and refuse if this row was the one folded.
    {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let others = store
            .conversations_for_contact_address(&sender)
            .iter()
            .any(|c| c.conversation_id != conversation_id);
        if others {
            if let Some(row) = store.conversation(&conversation_id).cloned() {
                if row.contact_address.is_empty() {
                    warn_store(store.upsert_conversation(ConversationRecord {
                        contact_address: sender.clone(),
                        ..row
                    }));
                }
            }
            let folded = match store.merge_contact(&sender) {
                Ok(folded) => folded,
                Err(e) => {
                    log::warn!("transport-hub: contact merge failed: {e}");
                    None
                }
            };
            let still_acceptable = !accept_target_missing(&store, &conversation_id);
            drop(store);
            // This step wrote the invitation's address, so it releases what the
            // invitation held, into the row that now holds the sender
            // (PRE3-SENDER, `wallet-security-auditor`).
            let host = folded
                .as_ref()
                .map_or(conversation_id.as_str(), |(h, _)| h.as_str());
            release_held_comms(&hub, host, &their_alias, &sender);
            if let Some((host, _)) = folded.as_ref() {
                ping(host);
            }
            if !still_acceptable {
                ping(&conversation_id);
                log::info!(
                    "transport-send: accept refused — the invitation is from a contact we \
                     already hold and was folded into that conversation (D-305)"
                );
                return Err(AppError::msg(
                    "this request is from a contact you already have a conversation with — it \
                     has been folded into that conversation, so there is nothing to accept. \
                     Open the conversation and send.",
                ));
            }
        }
    }
    let recipient_x_only = x_only_of(&dest)?;

    let my_alias = fresh_alias();
    let timestamp_ms = now_unix_ms();
    let payload = HandshakePayload::response(&my_alias, &their_alias, timestamp_ms)
        .map_err(AppError::core)?
        .to_plaintext()
        .map_err(AppError::core)?;

    let envelope = encrypt(&recipient_x_only, &payload).map_err(AppError::core)?;
    let wire = compose_handshake_wire(&envelope.to_bytes()).map_err(AppError::chain)?;

    // `bound` is the slot whose key opened THEIR handshake — i.e. the address
    // the counterpart already knows us by (they encrypted to it). Source-address
    // discipline pins our acceptance's input[0] to exactly this address so Kasia
    // matches the response to the pending conversation by sender address
    // (`conversation-manager-service.ts:181`) instead of minting a second
    // "stranger" contact — the precise D-067 failure. Non-negotiable here: the
    // counterpart resolves us by input[0], so we cannot spend from elsewhere.
    let own_address = vault::wallet_address_at(bound.0, bound.1)?;
    let reseal = encrypt(&x_only_of(&own_address)?, &payload)
        .map_err(AppError::core)?
        .to_bytes();

    let priority = await_spendable_at(&engine, &own_address).await?;

    prepare_transport_send(
        dest.clone(),
        HANDSHAKE_BOND_SOMPI, // the refund — the same provenance-cited norm
        wire,
        own_address, // source-address discipline: input[0] = the address they know
        priority,
        TransportIntent::Accept {
            conversation_id,
            contact_address: dest.to_string(),
            my_alias,
            reseal,
            timestamp_ms,
        },
        PinPolicy::Default,
    )
    .await
}

/// Phase 1 (a message in an active conversation): seal to the contact's
/// address key, tag the wire with OUR alias (the live convention), and
/// **self-send the value** — the tx destination is our OWN bound address, so
/// the message value returns to us as change and the only real cost is the
/// network fee (§0.6 amended by D-069, founder-approved at the P2.3b sitting).
/// This matches the live population: Kasia comms are self-sends (Gate K §K6);
/// the recipient discovers the message by scanning for our alias in the
/// payload, never by receiving value (their comm intake ignores outputs). The
/// earlier value-to-recipient reading cost ~0.1 KAS/message on the anti-dust
/// floor — proven unusable at the sitting.
pub async fn transport_prepare_comm(
    conversation_id: String,
    text: String,
) -> Result<SignableSummaryDto, AppError> {
    if text.trim().is_empty() {
        return Err(AppError::msg("enter a message"));
    }
    prepare_comm_plaintext(conversation_id, text).await
}

/// May we send a comm in this conversation?
///
/// **We used to require `Active`, and that was stricter than the protocol.**
/// Sending needs exactly two things: OUR alias (it rides the wire head) and
/// THEIR address (the envelope is sealed to it). A conversation we initiated
/// has both the moment the handshake is broadcast — the counterparty's alias
/// is needed to *read* what they send, never to write to them.
///
/// The cost of the old rule was total. Against a counterparty who already
/// knows us, the live population answers a repeat handshake idempotently and
/// **emits no response** (`conversation-manager-service.ts:181-213`), so
/// `PendingOutbound` is a state our conversation can never leave. Meanwhile
/// their side is already active and monitoring our alias. We were refusing to
/// speak into a channel that was open the whole time — measured on the
/// founder's device, where a thread that had worked since July went silent in
/// both directions.
///
/// A whitelist, never `!= something`: a status added later is refused by
/// default rather than silently becoming sendable.
///
/// The two emptiness guards are load-bearing, not decoration. A
/// `PendingInbound` row carries `contact_address: ""` and `my_alias: ""` until
/// its accept resolves them, so without these a restored or legacy row could
/// put an empty alias head on mainnet.
fn comm_sendable(
    status: ConversationStatus,
    initiated_by_me: bool,
    contact_address: &str,
    my_alias: &str,
) -> bool {
    let state_allows = match status {
        ConversationStatus::Active => true,
        // Ours to speak in: we opened it and we hold both halves.
        ConversationStatus::PendingOutbound => initiated_by_me,
        // Theirs to answer: accepting is where their bond is refunded, and
        // skipping it would take their money silently.
        ConversationStatus::PendingInbound => false,
    };
    state_allows && !contact_address.is_empty() && !my_alias.is_empty()
}

/// **Everything a comm send needs, built once** — the shared body of the
/// message PREPARE and of the live fee figure above the send button.
///
/// The two must price the same transaction or the glass lies about what a tap
/// will cost, and "the same" is not loose here: the namespace token, the alias
/// head and the base64 envelope are most of a message's mass, and the pinned
/// spend order decides which coins are drawn. So both go through this, and
/// neither composes a wire of its own.
///
/// The one thing that legitimately differs between a preview and a prepare is
/// the envelope's random nonce — and an envelope's LENGTH is fixed by its
/// layout (`nonce(12) ‖ SEC1 key(33) ‖ ct+tag`), so the mass, and therefore
/// the fee, is identical.
struct CommPlan {
    /// The conversation's bound address: the self-send destination, the
    /// input[0] source and the change target, all one address (D-069).
    own_address: Address,
    /// The pinned spend order — input[0] identity (D-067).
    priority: Vec<UtxoEntryReference>,
    /// The anti-dust floor for THIS wallet's live coin shape (D-054), probed
    /// against the same pinned order the send will use.
    floor: u64,
    /// The composed wire bytes, in the dialect this counterparty speaks.
    wire_bytes: Vec<u8>,
    my_alias: String,
    bound: KeySlot,
    wire: WireNamespace,
}

/// Build the plan, or say honestly why not.
///
/// `waiting` is the difference between the two callers and it is the only one:
///
///  - the PREPARE waits for the bound address's coins to mature
///    ([`await_spendable_at`], which polls and can spend a maturity window),
///    because a user who has tapped send is owed the send rather than a
///    refusal about a clock;
///  - the PREVIEW never waits. It runs on a keystroke, so it takes one look at
///    the mature set and gives up if it is empty. No fee appears, and the tap
///    behind it still routes through the ceremony, which produces the real
///    sentence.
async fn plan_comm(
    conversation_id: &str,
    text: &str,
    waiting: bool,
) -> Result<Option<CommPlan>, AppError> {
    let hub = hub()?;
    let (contact_address, my_alias, bound, wire) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let conversation = store
            .conversation(conversation_id)
            .ok_or_else(|| AppError::msg("conversation not found"))?;
        if !comm_sendable(
            conversation.status,
            conversation.initiated_by_me,
            &conversation.contact_address,
            &conversation.my_alias,
        ) {
            return Err(AppError::msg(match conversation.status {
                ConversationStatus::PendingInbound => {
                    "accept this invitation first — that is where their bond is refunded"
                }
                _ => "this conversation isn't ready to send yet",
            }));
        }
        (
            conversation.contact_address.clone(),
            conversation.my_alias.clone(),
            (
                to_core_branch(conversation.bound_branch),
                conversation.bound_index,
            ),
            // ANSWER IN THEIR DIALECT (§K11). KaChat 4.0 writes `kchat:1:`
            // and may no longer look at `ciph_msg:`; Kasia has never looked
            // at `kchat:`. The store derives which one this counterparty
            // speaks from their newest inbound comm — `ciph_msg` until they
            // have said anything, which is also what a stranger gets.
            store.conversation_wire(conversation_id),
        )
    };
    // The recipient address is the ENCRYPTION target only — the envelope is
    // sealed to their key so they can decrypt. The tx VALUE goes to us (below).
    let recipient = validate_mainnet_address(&contact_address)?;
    let recipient_x_only = x_only_of(&recipient)?;
    // The conversation's bound own address — the destination (self-send, D-069),
    // the input[0] source, and the change target all at once, so the counterpart
    // keeps seeing one identity and the value never leaves our wallet.
    let own_address = vault::wallet_address_at(bound.0, bound.1)?;

    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;
    // FIRST, because the floor below is measured over the mature UTXO set and
    // this is the wait that set is waiting on. Measure first and an all-immature
    // wallet has no floor at all — `minimum_sendable` answers `None` and the
    // send dies blaming the user's coin shape for a clock. The set travels down
    // into `prepare_transport_send`, so the budget is spent once.
    let priority = if waiting {
        await_spendable_at(&engine, &own_address).await?
    } else {
        let mature = engine
            .mature_utxos_at(&own_address)
            .await
            .map_err(AppError::chain)?;
        if mature.is_empty() {
            return Ok(None);
        }
        mature
    };
    // The self-send output still clears Kaspa's anti-dust floor (storage mass is
    // charged on every output, ours included) — the honest computed minimum for
    // THIS wallet's live coin shape (D-054), recomputed per send. The probe
    // already models payment-to-own_address + change-to-own_address, exactly the
    // self-send shape, so the floor it finds is the one that gets built.
    //
    // The floor is probed with the SAME pinned set the send below will pin, so
    // it prices the pinned spend order, not a hypothetical plain one.
    let floor = engine
        .minimum_sendable(
            own_address.clone(),
            &priority,
            &crate::api::send::spend_exclusions(),
        )
        .map_err(AppError::chain)?;
    let Some(floor) = floor else {
        if !waiting {
            return Ok(None);
        }
        return Err(AppError::msg(
            "your balance can't cover a message right now (anti-dust floor)",
        ));
    };

    let envelope = encrypt(&recipient_x_only, text.as_bytes()).map_err(AppError::core)?;
    let wire_bytes =
        compose_comm_wire_in(wire, &my_alias, &envelope.to_bytes()).map_err(AppError::chain)?;

    Ok(Some(CommPlan {
        own_address,
        priority,
        floor,
        wire_bytes,
        my_alias,
        bound,
        wire,
    }))
}

/// The shared self-send comm PREPARE (D-069). Seal `text` to the contact,
/// self-send the computed floor to our OWN bound address (input[0] + change =
/// that address, D2/D-068), and stash the built-but-unsigned plan. Every
/// comm-carried plaintext — a plain message OR a `kv:1:` game frame — funnels
/// through here, so the tx-construction / self-send / source-address path is
/// IDENTICAL for all of them; only the plaintext bytes differ (frames are
/// hints, never a new send path — the send-path audit surface is unchanged).
async fn prepare_comm_plaintext(
    conversation_id: String,
    text: String,
) -> Result<SignableSummaryDto, AppError> {
    // `waiting`, so `None` is unreachable on this arm: every "no plan" case
    // above is an `Err` with its own sentence when the caller has tapped send.
    let plan = plan_comm(&conversation_id, &text, true)
        .await?
        .ok_or_else(|| AppError::msg("this conversation isn't ready to send yet"))?;

    // The re-seal is the LOCAL copy — it never rides the wire, so the preview
    // does not pay for it and it is built only here.
    let reseal = encrypt(&x_only_of(&plan.own_address)?, text.as_bytes())
        .map_err(AppError::core)?
        .to_bytes();

    let timestamp_ms = now_unix_ms();
    prepare_transport_send(
        plan.own_address.clone(), // SELF-SEND (D-069): value returns as change — cost = fee
        plan.floor,
        plan.wire_bytes,
        plan.own_address, // source discipline: input[0] + change = the same bound addr
        plan.priority,
        TransportIntent::Comm {
            conversation_id,
            alias_on_wire: plan.my_alias,
            reseal,
            sealed_to: (to_key_branch(plan.bound.0), plan.bound.1),
            timestamp_ms,
            wire: plan.wire,
        },
        PinPolicy::Default,
    )
    .await
}

/// **What this exact message would cost, priced by the Generator now** — the
/// figure that streams above the send button as the user types (founder
/// ruling, 2026-09-08: *"direct fee estimates where the numbers change the way
/// it does on the send screen … the fee must be tiny above the send button"*).
///
/// It is the send screen's `send_fee_preview` for the messaging lane, and it
/// keeps that function's whole contract: signerless, stash-free, read-only,
/// safe to call on every keystroke, and **built rather than estimated** — the
/// same [`plan_comm`] the prepare runs, priced through the same two-shape
/// decision (`chain::send::shipped_two_shape`) the ceremony's figure comes
/// from.
///
/// `None` — and the glass shows no figure — whenever no transaction can be
/// built right now: the bound address has no mature coins yet, the wallet is
/// below the anti-dust floor, the engine is not up, or the pinned coins are
/// covenant-fenced. **A missing figure never blocks the send**: the tap falls
/// through to the confirm ceremony, which states Rust's own reason. A figure
/// this cannot produce is one the user is not asked to act on.
pub async fn transport_comm_fee_preview(
    conversation_id: String,
    text: String,
) -> Result<Option<u64>, AppError> {
    if text.trim().is_empty() {
        return Ok(None);
    }
    let Some(plan) = plan_comm(&conversation_id, &text, false).await? else {
        return Ok(None);
    };
    let Some(engine) = wallet::engine_handle() else {
        return Ok(None);
    };
    engine
        .fee_preview_pinned(
            plan.own_address.clone(),
            plan.own_address,
            plan.floor,
            &plan.priority,
            Some(plan.wire_bytes),
            &crate::api::send::spend_exclusions(),
        )
        .map_err(AppError::chain)
}

/// **Does sending a message stop at the confirm sheet?** `true` by default.
///
/// The preference behind the founder's *"Turn off signing for messages"*
/// toggle — see [`kaspaverse_chain::prefs::MessagePrefs`] for what it does and
/// does not govern (the ceremony, never the signature).
pub fn transport_message_signing() -> Result<bool, AppError> {
    let dir = vault::transport_store_dir()?;
    Ok(MessagePrefs::load(&dir).sign_messages)
}

/// Set it. Persisted durably, because the safe state is the ceremony and a
/// torn write may not be able to remove one.
pub fn transport_set_message_signing(sign_messages: bool) -> Result<(), AppError> {
    let dir = vault::transport_store_dir()?;
    MessagePrefs { sign_messages }
        .save(&dir)
        .map_err(AppError::chain)?;
    log::info!(
        "transport: message confirm ceremony is now {}",
        if sign_messages { "on" } else { "off" }
    );
    Ok(())
}

/// **Send a message without the confirm sheet** — the whole of what turning
/// signing off buys, and the only door in this bridge that broadcasts without
/// one.
///
/// Founder ruling, 2026-09-08: *"users who prefer not signing everytime they
/// want to send a message can absolutely do so."* This is that, built with the
/// bounds it needs rather than as an exception carved out of the ceremony.
///
/// **Every gate is here, in Rust, and none of them is in Dart.** A Dart bug, a
/// hostile deep link or a future call site cannot reach a ceremony-free
/// broadcast for anything but a plain message, because there is nothing else
/// to call:
///
/// 1. **The preference must actually be off.** If the user has the ceremony
///    on, this refuses rather than honouring a caller that skipped it.
/// 2. **It builds its own intent.** The plaintext goes through
///    [`prepare_comm_plaintext`], so the kind is `Comm` by construction — a
///    handshake, an accept (which refunds a counterparty's bond), a stash and
///    a payment are not expressible here.
/// 3. **The built chain must be confined to this conversation's own address.**
///    Every output of every leg is decoded with the pin's own standard script
///    reader and compared against the bound address read from the store BEFORE
///    the build (`PreparedSend::pays_only`) — so a chain that paid anybody else
///    is refused with the money still in the wallet, and a rebinding mid-flight
///    fails closed. The summary's kind and destination are checked too, but
///    those are echoes of the intent; this one is the artifact.
/// 4. **The fee must be under
///    [`MessagePrefs::UNCEREMONIOUS_FEE_CEILING`].** Above it the caller is
///    told to use the sheet, and the sheet shows the figure. This is what
///    keeps the toggle honest on the payload-variable lane — a large
///    attachment or a chained build costs real money and gets a second look.
///
/// A refusal ABANDONS the stash before returning, so nothing is left half-
/// prepared for a later commit to find.
pub async fn transport_send_comm_now(
    conversation_id: String,
    text: String,
) -> Result<SendOutcomeDto, AppError> {
    if text.trim().is_empty() {
        return Err(AppError::msg("enter a message"));
    }
    let dir = vault::transport_store_dir()?;
    let sign_messages = MessagePrefs::load(&dir).sign_messages;
    if sign_messages {
        return Err(AppError::msg(UNCEREMONIOUS_OFF));
    }
    // The bound address this conversation's self-send MUST land on, read
    // before the build so the check below compares against the store's own
    // answer rather than against the build's. A rebinding mid-flight fails
    // closed.
    let expected = {
        let hub = hub()?;
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let conversation = store
            .conversation(&conversation_id)
            .ok_or_else(|| AppError::msg("conversation not found"))?;
        vault::wallet_address_at(
            to_core_branch(conversation.bound_branch),
            conversation.bound_index,
        )?
    };

    let summary = prepare_comm_plaintext(conversation_id, text).await?;

    // ── The gate runs on the BUILT plan, before any broadcast. ────────────
    //
    // **The confinement question is asked of the ARTIFACT**, and it is asked
    // first because it is the strongest thing said here. `summary.kind` and
    // `summary.destination` are echoes of the intent and of the argument that
    // built it — real, and they prove the conversation's binding did not move
    // between the store read and the build — but this is the only broadcast
    // door in the bridge with no human in it, so the decisive check decodes
    // the built outputs with the pin's own standard script reader
    // (`ffi-leak-auditor` BLOCK, this sitting: the doc claimed this check and
    // the call did not exist).
    let confined = {
        let guard = PENDING_TRANSPORT
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        match guard.as_ref() {
            Some((stored, prepared)) if *stored == summary.nonce => prepared.pays_only(&expected),
            // No plan under this nonce is not a pass. Something replaced the
            // stash between the prepare and here; `transport_commit` would
            // refuse it too, and refusing now keeps the reason honest.
            _ => false,
        }
    };
    if !confined {
        transport_abandon();
        log::warn!(
            "transport-send: unceremonious send refused — the built chain has an output this \
             conversation's own address does not own"
        );
        return Err(AppError::msg(UNCEREMONIOUS_NEEDS_CONFIRMING));
    }
    if let Some(refusal) = unceremonious_refusal(&summary, &expected.to_string(), sign_messages) {
        transport_abandon();
        log::warn!(
            "transport-send: unceremonious send refused — {}",
            refusal.why
        );
        return Err(AppError::msg(match refusal.kind {
            // The only refusal that can name a figure, and the figure is the
            // whole reason it exists.
            UncerimoniousRefusal::FEE => format!(
                "this message costs {} KAS — more than messages usually do, so it needs \
                 confirming",
                format_kas(summary.fee_sompi)
            ),
            _ => refusal.said.to_string(),
        }));
    }
    transport_commit(summary.nonce).await
}

/// What the caller is told when the preference still says *confirm*. Named,
/// because Dart matches nothing on it and a human reads it.
const UNCEREMONIOUS_OFF: &str = "message signing is on — confirm this send on the sheet";

/// The sentence every post-build refusal shares.
///
/// **It does not say "use the sheet".** In the only state that produces these,
/// the user has turned the sheet off — so the caller's job is to open it
/// anyway, and it does (`thread_screen._send` falls through to the confirm
/// ceremony on a refusal from this door). A sentence prescribing a control the
/// user has removed is a dead end (`wallet-security-auditor`, this sitting).
const UNCEREMONIOUS_NEEDS_CONFIRMING: &str = "this send needs confirming";

/// Why an unceremonious send was refused, and what to say about it.
struct UncerimoniousRefusal {
    /// The log line — diagnostic, never user-facing, never content.
    why: &'static str,
    /// The sentence the user reads, unless the caller substitutes a figure.
    said: &'static str,
    /// Which arm fired, so the caller can decide to say more.
    kind: u8,
}

impl UncerimoniousRefusal {
    const PREFERENCE: u8 = 0;
    const KIND: u8 = 1;
    const DESTINATION: u8 = 2;
    const FEE: u8 = 3;
}

/// **The intent-level half of the gate on the only ceremony-free broadcast
/// door, as a pure function** — so all four arms are exercised rather than
/// asserted about.
///
/// **What this proves, stated exactly**, because the difference matters:
/// `summary.kind` is `kind_of_intent`'s answer and `summary.destination` is
/// the address handed to the build echoed back, so those two arms prove the
/// intent was a comm and that the conversation's binding did not move between
/// the store read and the build. They do **not** read the built outputs.
/// `summary.fee_sompi` IS a built figure — the Generator's aggregate, so a
/// chained build is priced whole rather than one leg at a time.
///
/// The artifact-level half runs at the call site and runs FIRST:
/// `PreparedSend::pays_only` decodes every output of every built leg
/// (`ffi-leak-auditor` · `consensus-auditor`, this sitting).
///
/// `None` means every bound holds and the plan may be committed.
fn unceremonious_refusal(
    summary: &SignableSummaryDto,
    expected: &str,
    sign_messages: bool,
) -> Option<UncerimoniousRefusal> {
    // 1. The preference must actually be off. A caller that skipped it is a
    //    bug, and it is refused rather than honoured.
    if sign_messages {
        return Some(UncerimoniousRefusal {
            why: "the preference still says confirm",
            said: UNCEREMONIOUS_OFF,
            kind: UncerimoniousRefusal::PREFERENCE,
        });
    }
    // 2. A comm is a self-send frame. A bond, a refund and a payment are all
    //    other kinds and none of them may pass here.
    if summary.kind != SignableKind::SelfSendFrame {
        return Some(UncerimoniousRefusal {
            why: "the built transaction is not a self-send frame",
            said: UNCEREMONIOUS_NEEDS_CONFIRMING,
            kind: UncerimoniousRefusal::KIND,
        });
    }
    // 3. And it pays THIS conversation's own bound address. A build that paid
    //    anybody else is refused with the money still in the wallet.
    if summary.destination != expected {
        return Some(UncerimoniousRefusal {
            why: "the built transaction pays an address that is not this conversation's own",
            said: UNCEREMONIOUS_NEEDS_CONFIRMING,
            kind: UncerimoniousRefusal::DESTINATION,
        });
    }
    // 4. The ceiling. `fee_sompi` is the Generator's AGGREGATE fee, so a
    //    chained build is priced whole rather than one leg at a time.
    if summary.fee_sompi > MessagePrefs::UNCEREMONIOUS_FEE_CEILING {
        return Some(UncerimoniousRefusal {
            why: "the fee is above the unceremonious ceiling",
            said: UNCEREMONIOUS_NEEDS_CONFIRMING,
            kind: UncerimoniousRefusal::FEE,
        });
    }
    None
}

/// Phase 1 — compose a `kv:1:challenge` (Attack & Defend) as a self-send comm.
/// `stake` is a DISPLAY value in KAS (`None` ⇒ a friendly, no-stake duel); it
/// binds NO value here — frames are hints, the real wager binds at the P3
/// covenant. The readable invite line is GENERATED in `core::frames` from the
/// fields (never free-typed), so it can't misrepresent the card. Rides the
/// shared comm prepare above — no new send-path economics.
pub async fn transport_prepare_challenge(
    conversation_id: String,
    stake: Option<String>,
) -> Result<SignableSummaryDto, AppError> {
    let id = fresh_challenge_id();
    let plaintext =
        build_challenge(GAME_ATTACK_DEFEND, stake.as_deref(), &id).map_err(AppError::core)?;
    prepare_comm_plaintext(conversation_id, plaintext).await
}

/// Phase 1 — compose a social `kv:1:accept` for the challenge `ref_id`. This is
/// NOT a wager and NEVER auto-spends: it is a self-send comm the user confirms
/// through the normal hold-to-sign ceremony (§0.5 law a). NB: deliberately
/// distinct from [`transport_prepare_accept`], the handshake-bond acceptance.
pub async fn transport_prepare_challenge_accept(
    conversation_id: String,
    ref_id: String,
) -> Result<SignableSummaryDto, AppError> {
    let plaintext = build_accept(GAME_ATTACK_DEFEND, &ref_id).map_err(AppError::core)?;
    prepare_comm_plaintext(conversation_id, plaintext).await
}

/// Phase 1 — compose a `kv:1:taunt` (personality) as a self-send comm. The text
/// is the frame's own content; empty text is refused in `core::frames`.
pub async fn transport_prepare_taunt(
    conversation_id: String,
    text: String,
) -> Result<SignableSummaryDto, AppError> {
    let plaintext = build_taunt(&text).map_err(AppError::core)?;
    prepare_comm_plaintext(conversation_id, plaintext).await
}

// ── D-138: the conversation backup (`self_stash`) ─────────────────────────

/// How many conversations one backup carries. A bound, not a target: the
/// payload is masses-and-fees, and a wallet with hundreds of threads should
/// back up its live ones rather than fail to build a transaction at all.
const STASH_SNAPSHOT_MAX: usize = 64;

/// How many conversations one fill run may CREATE from restored stash rows.
///
/// Set to the snapshot PARSE bound deliberately, so it can never bite inside a
/// single snapshot. A cap below the snapshot size would refuse the tail of a
/// perfectly good backup, and a refusal is `Settled` — the cursor would step
/// past conversations it never restored while reporting a clean walk. The real
/// bound on how much one indexer response can grow the store is
/// `MAX_SNAPSHOT_ROWS`, applied at parse; this is the same number so the two
/// can never drift apart.
const STASH_CREATE_CAP: usize = kaspaverse_core::handshake::MAX_SNAPSHOT_ROWS;

/// Which conversations belong in a backup, newest-active first.
///
/// A row with no counterparty address or no alias of ours is skipped, because
/// restoring it would produce a conversation that cannot send. In practice that
/// is exactly the `PendingInbound` rows — invitations we have not accepted —
/// and they are the one class already recoverable from chain, since their
/// handshake was addressed TO us and `handshakes/by-receiver` finds it.
///
/// Hidden conversations are skipped too. The tombstone IS the user's
/// suppression record; a backup that carried it would hand it back at the next
/// restore, which is the opposite of what hiding means.
fn stashable_rows(store: &TransportStore) -> Vec<ConversationRecord> {
    let mut rows: Vec<ConversationRecord> = store
        .list_conversations()
        .into_iter()
        .filter(|c| !store.is_conversation_tombstoned(&c.conversation_id))
        .filter(|c| !c.contact_address.is_empty() && !c.my_alias.is_empty())
        .collect();
    // Newest activity first, so a wallet past the cap keeps the threads it is
    // actually using. Ties break on id purely so the payload is deterministic.
    //
    // **Deliberately NOT truncated here.** The cap belongs to the payload, not
    // to the count: `transport_stash_state` uses this same helper for its
    // denominator, and truncating first made the cap invisible — a wallet with
    // 70 conversations was told "All 64 backed up" while six were in no backup
    // at all and nothing would ever say so. The truncation happens at the one
    // place that builds a transaction.
    rows.sort_by(|a, b| {
        b.last_activity_unix_ms
            .cmp(&a.last_activity_unix_ms)
            .then(a.conversation_id.cmp(&b.conversation_id))
    });
    rows
}

fn branch_token(branch: KeyBranch) -> &'static str {
    match branch {
        KeyBranch::Receive => BOUND_BRANCH_RECEIVE,
        KeyBranch::Change => BOUND_BRANCH_CHANGE,
    }
}

/// Phase 1 of the D-138 backup: seal a snapshot of every conversation to our
/// OWN key and park it on chain, so a restore-from-seed rebuilds contacts and
/// not just money.
///
/// **Why this is a deliberate user action rather than automatic.** Kasia emits
/// a stash from inside its handshake flow. We do not: there is exactly one
/// `PENDING_TRANSPORT` slot, so preparing a backup while a confirm sheet is
/// open would destroy the plan the user is looking at, and a backup that
/// appeared unbidden would spend a fee the user never agreed to. One explicit
/// action, one transaction, everything in it.
///
/// A backup fired straight after a handshake used to fail outright, because it
/// is funded from `receive/0` and that address's change had not come back yet.
/// [`await_spendable_at`] — which this function runs before it measures
/// anything — now waits for that change instead of refusing, so the cost of
/// firing one too early is a short pause, not an error.
///
/// The value is a self-send that returns as change (D-069), so the honest cost
/// is the network fee.
pub async fn transport_prepare_stash() -> Result<SignableSummaryDto, AppError> {
    let hub = hub()?;
    let timestamp_ms = now_unix_ms();

    let mut rows = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        stashable_rows(&store)
    };
    if rows.is_empty() {
        return Err(AppError::msg(
            "there are no conversations to back up yet — start one first",
        ));
    }
    // The payload cap applies HERE and only here — see `stashable_rows`.
    if rows.len() > STASH_SNAPSHOT_MAX {
        log::info!(
            "self-stash: {} conversations, backing up the {STASH_SNAPSHOT_MAX} most recent",
            rows.len()
        );
        rows.truncate(STASH_SNAPSHOT_MAX);
    }

    // `covered` is built from the payloads that ACTUALLY went in, not from the
    // rows we set out to carry. Claiming coverage for a conversation the
    // snapshot skipped would make the backup notice go quiet about the one
    // thread that is still unprotected — a lie by omission in the exact place
    // the user is trusting the count.
    let mut covered = Vec::with_capacity(rows.len());
    let mut payloads = Vec::with_capacity(rows.len());
    let mut skipped = 0usize;
    for row in &rows {
        match SavedHandshakePayload::new(
            &row.my_alias,
            row.their_alias.as_deref(),
            &row.contact_address,
            &row.conversation_id,
            branch_token(row.bound_branch),
            row.bound_index,
            !row.initiated_by_me,
            row.created_unix_ms,
        ) {
            Ok(payload) => {
                covered.push(row.conversation_id.clone());
                payloads.push(payload);
            }
            // Shape only, never a value: a malformed row is a bug in OUR store,
            // and the diagnosis needs the count, not the contents (§4).
            Err(_) => skipped += 1,
        }
    }
    if skipped > 0 {
        log::warn!("self-stash: {skipped} conversation(s) failed validation and were left out");
    }
    let snapshot = SavedHandshakeSnapshot::new(payloads, timestamp_ms).map_err(|_| {
        AppError::msg(
            "none of your conversations could be backed up — this is a bug, please report it",
        )
    })?;
    // AUTHORSHIP TAG — the restore refuses anything it cannot prove we wrote.
    // Sealing does not prove it: the envelope goes to our own PUBLIC key, so
    // any party that knows our receive address — including whichever archive we
    // ask — can produce one our key opens. See `attach_stash_tag`.
    let untagged = snapshot.to_plaintext().map_err(AppError::core)?;
    let tag = hub.decryptor.stash_tag(&untagged).map_err(AppError::core)?;
    let plaintext = attach_stash_tag(&untagged, &tag).map_err(AppError::core)?;

    // receive/0: the one address a restore can derive from the seed alone,
    // before any store exists. It is also our canonical transport identity
    // (D2/P4) and — because a single-address Kasia derives the same address
    // from the same mnemonic — the one that keeps this artifact readable by
    // their client too.
    let own_address = vault::wallet_address_at(Branch::Receive, 0)?;
    let envelope = encrypt(&x_only_of(&own_address)?, &plaintext).map_err(AppError::core)?;
    let wire = compose_self_stash_wire(&envelope.to_bytes()).map_err(AppError::chain)?;

    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;
    // Same order, same reason as the comm path: the floor is a measurement of
    // the mature set, so it must be taken after the wait, never before it.
    let priority = await_spendable_at(&engine, &own_address).await?;
    // Probed with the pinned set for the same reason as the comm path above.
    let floor = engine
        .minimum_sendable(
            own_address.clone(),
            &priority,
            &crate::api::send::spend_exclusions(),
        )
        .map_err(AppError::chain)?
        .ok_or_else(|| {
            AppError::msg("your balance can't cover a backup right now (anti-dust floor)")
        })?;

    prepare_transport_send(
        own_address.clone(), // self-send (D-069): the value comes straight back
        floor,
        wire,
        own_address,
        priority,
        TransportIntent::SelfStash {
            covered,
            timestamp_ms,
        },
        PinPolicy::OwnerAttributable,
    )
    .await
}

/// What the last backup covered, for the honest notice.
#[derive(Clone, Debug)]
pub struct StashStateDto {
    /// When the last backup was committed (unix ms), `0` if never.
    pub last_unix_ms: u64,
    /// Whether a history walk has actually read that backup back. Until it
    /// has, the wallet says "sent" rather than "backed up" — the indexer's
    /// attribution can fail quietly and leave it unfindable.
    pub confirmed_readable: bool,
    /// How many of today's conversations that backup still covers.
    pub covered: u32,
    /// How many conversations could be backed up right now.
    pub total: u32,
}

/// Backup coverage. `covered` counts only conversations that are BOTH in the
/// last snapshot AND still present — so deleting a thread cannot make the
/// wallet claim coverage it does not have, and starting one immediately shows
/// as uncovered.
pub fn transport_stash_state() -> Result<StashStateDto, AppError> {
    let hub = hub()?;
    let dir = vault::transport_store_dir()?;
    let state = kaspaverse_chain::history_fill::StashState::load(&dir);
    let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let rows = stashable_rows(&store);
    let covered = rows
        .iter()
        .filter(|r| state.covered.contains(&r.conversation_id))
        .count();
    Ok(StashStateDto {
        last_unix_ms: state.last_unix_ms,
        confirmed_readable: state.confirmed_readable,
        covered: covered as u32,
        total: rows.len() as u32,
    })
}

/// Phase 2: sign + broadcast the stashed transport plan identified by `nonce`.
/// Same stale-nonce refusal, partial-honesty (B6) and change-cursor discipline
/// as the payment path — one shared implementation. On a CLEAN broadcast the
/// stashed intent folds into the transport store (conversation + sent row).
pub async fn transport_commit(nonce: u64) -> Result<SendOutcomeDto, AppError> {
    // THE ROW MUST STILL EXIST BEFORE THE MONEY MOVES (`wallet-security-auditor`,
    // 2026-09-07). An Accept's 0.2 KAS refund is prepared against an invitation
    // row, and a whole confirm-and-sign dwell passes before this call. The
    // backfill merge (D-305) can fold that row into a conversation we already
    // hold inside the dwell — the same activity record fires both — and the
    // Accept arm of `apply_intent` would then find no row to record the alias
    // the acceptance announced: money gone for a conversation that no longer
    // exists, and an alias the counterparty now listens on held nowhere.
    // Refuse BEFORE the broadcast, abandon the stash, and say why.
    if let Some(conversation_id) = pending_accept_target(nonce) {
        let missing = match hub() {
            Ok(hub) => {
                let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
                accept_target_missing(&store, &conversation_id)
            }
            Err(_) => true,
        };
        if missing {
            transport_abandon();
            ping(&conversation_id);
            log::info!(
                "transport-send: accept commit refused — its invitation was folded into an \
                 existing conversation during the ceremony; nothing was sent (D-305)"
            );
            return Err(AppError::msg(
                "this request was folded into a conversation you already have while you \
                 were confirming — nothing was sent. Open the conversation and send.",
            ));
        }
    }
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
/// Fold a prepare-time conversation snapshot onto whatever the store learned
/// while we were signing.
///
/// A handshake commit lands minutes after its prepare — a whole confirm-and-
/// sign ceremony — and on a retry to a contact we already have, the row can
/// change underneath us in exactly the ways that matter: their acceptance
/// arrives, or an inbound message teaches us their alias. Blind-upserting the
/// snapshot would undo precisely the repairs that make a stuck conversation
/// work again, and the wallet would fall silent with nothing in the log.
///
/// So the live row wins on everything it can have learned, and the snapshot
/// only supplies what it alone knows (the broadcast txid, already set).
fn merge_handshake_commit(
    snapshot: ConversationRecord,
    live: &ConversationRecord,
) -> ConversationRecord {
    ConversationRecord {
        // Fill in, never clobber: an alias that arrived mid-ceremony is the
        // whole point.
        their_alias: live.their_alias.clone().or(snapshot.their_alias),
        // Both inbound legs rebind the slot to the key the counterparty
        // actually sealed to; writing the stale one back would repoint our
        // input[0] at an address they do not know us by (D-067).
        bound_branch: live.bound_branch,
        bound_index: live.bound_index,
        status: match live.status {
            // Anything past pending-outbound was learned while we signed.
            ConversationStatus::PendingOutbound => snapshot.status,
            other => other,
        },
        last_activity_unix_ms: live
            .last_activity_unix_ms
            .max(snapshot.last_activity_unix_ms),
        ..snapshot
    }
}

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
            // MERGE, never overwrite. `conversation` is the snapshot taken at
            // PREPARE, and on a retry to a contact we already have, a whole
            // signing ceremony can pass in between — long enough for their
            // acceptance to land, or for the alias re-learn to activate the
            // row. Blind-upserting the snapshot would undo exactly the fix
            // that unbroke this conversation, and the wallet would go quiet
            // again with nothing in the log to say why.
            let conversation = match store.conversation(&conversation_id) {
                Some(live) => merge_handshake_commit(conversation, live),
                None => conversation,
            };
            // Inviting someone is asking for them back (D-308).
            lift_block_on_contact(&hub, &conversation.contact_address, "inviting them");
            let sealed_to = Some((conversation.bound_branch, conversation.bound_index));
            warn_store(store.upsert_conversation(conversation));
            warn_store(store.record_message(MessageRecord {
                txid: txid.to_string(),
                conversation_id: conversation_id.clone(),
                direction: MessageDirection::Outbound,
                kind: StoredKind::Handshake,
                envelope: reseal,
                unix_ms: timestamp_ms,
                alias_on_wire: None,
                sealed_to,
                provenance: RowSource::Own,
                // We compose every handshake in `ciph_msg` (§K11): a stranger's
                // client is unknown, and KaChat still documents that form.
                wire: WireNamespace::CiphMsg,
            }));
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
            let mut held = None;
            if let Some(existing) = store.conversation(&conversation_id) {
                let mut conversation = existing.clone();
                // An invitation that did not know its sender held its sender's
                // comms; accepting names it (PRE3-SENDER). Released whether or
                // not the address was already written: `transport_prepare_accept`
                // may have written it a step earlier (`wallet-security-auditor`),
                // and a release with nothing held is a no-op.
                held = conversation
                    .their_alias
                    .clone()
                    .map(|alias| (alias, contact_address.clone()));
                conversation.contact_address = contact_address;
                conversation.my_alias = my_alias;
                conversation.status = ConversationStatus::Active;
                conversation.last_activity_unix_ms = timestamp_ms;
                // Accepting their handshake is the founder's own way back in
                // for a blocked contact (D-308): the block lifts here, at the
                // moment the refund is on the wire.
                lift_block_on_contact(
                    &hub,
                    &conversation.contact_address,
                    "accepting their request",
                );
                // Re-stamp establishment on OUR clock at the moment the
                // conversation actually becomes one.
                //
                // `created_unix_ms` ORDERS things — it is a tiebreak in
                // `TransportStore::merge_contact`'s host rank, deciding which
                // of two rows for one contact keeps its identity when they
                // fold. Until this line the value on
                // an inbound row came from `block_time_ms` at fold, which on
                // the fill lane is an INDEXER's claim (`transport.rs`'s fill
                // rows pass the indexer's `block_time` straight through). The
                // existing defences do hold — accept refuses a `FillSourced`
                // handshake, and the node's own scan re-stamps the row while
                // it is still `PendingInbound` — but both are indirect, and a
                // bound the design depends on should be asserted rather than
                // inferred (`consensus-auditor`, 2026-08-17). This asserts it:
                // no value an archive ever supplied can survive into the
                // ordering, because going Active overwrites it.
                //
                // **Load-bearing together with `transport_existing_conversation`'s
                // ordering**: this stamp makes a freshly-accepted row the newest
                // Active one for its contact, which is correct only because that
                // function looks for a live thread BEFORE it offers an
                // invitation.
                //
                // **Monotone within its comparison set, not merely "now".** A
                // device clock correction backwards between two establishments
                // with one contact would otherwise invert the comparison. The
                // rule that read it used to be `superseded_by`, which would
                // then refuse the live thread and route the user into the dead
                // one with full confidence — the original bug, endorsed by the
                // fix for it (`consensus-auditor`, 2026-08-17). That rule was
                // removed with D-305's repair wave, and the monotonicity is
                // kept rather than dropped with it: `merge_contact` now reads
                // the same field to pick which of two folding rows is the
                // host, so an inverted comparison would choose the wrong
                // identity to keep. Stepping past the newest Active row for
                // this same contact costs nothing when the clock is sane and
                // is the whole guarantee when it is not.
                let newest_for_contact = store
                    .conversations_for_contact_address(&conversation.contact_address)
                    .into_iter()
                    .filter(|c| c.conversation_id != conversation.conversation_id)
                    .filter(|c| c.status == ConversationStatus::Active)
                    .map(|c| c.created_unix_ms)
                    .max();
                conversation.created_unix_ms = match newest_for_contact {
                    Some(newest) => timestamp_ms.max(newest.saturating_add(1)),
                    None => timestamp_ms,
                };
                let sealed_to = Some((conversation.bound_branch, conversation.bound_index));
                warn_store(store.upsert_conversation(conversation));
                warn_store(store.record_message(MessageRecord {
                    txid: txid.to_string(),
                    conversation_id: conversation_id.clone(),
                    direction: MessageDirection::Outbound,
                    kind: StoredKind::Handshake,
                    envelope: reseal,
                    unix_ms: timestamp_ms,
                    alias_on_wire: None,
                    sealed_to,
                    provenance: RowSource::Own,
                    // We compose every handshake in `ciph_msg` (§K11): a stranger's
                    // client is unknown, and KaChat still documents that form.
                    wire: WireNamespace::CiphMsg,
                }));
            } else {
                // The commit guard refuses before broadcast when the row is
                // gone, so reaching here means the row vanished INSIDE the
                // broadcast. Never silent: the refund has left and the alias it
                // announced has no row to live on.
                log::warn!(
                    "transport-send: accept committed but its invitation row is gone — the \
                     alias it announced is not recorded (tx={txid})"
                );
            }
            drop(store);
            if let Some((alias, sender)) = held {
                release_held_comms(&hub, &conversation_id, &alias, &sender);
            }
            ping(&conversation_id);
        }
        TransportIntent::Comm {
            conversation_id,
            alias_on_wire,
            reseal,
            sealed_to,
            timestamp_ms,
            wire,
        } => {
            warn_store(store.record_message(MessageRecord {
                txid: txid.to_string(),
                conversation_id: conversation_id.clone(),
                direction: MessageDirection::Outbound,
                kind: StoredKind::Comm,
                envelope: reseal,
                unix_ms: timestamp_ms,
                alias_on_wire: Some(alias_on_wire),
                sealed_to: Some(sealed_to),
                provenance: RowSource::Own,
                wire,
            }));
            if let Some(existing) = store.conversation(&conversation_id) {
                let mut conversation = existing.clone();
                conversation.last_activity_unix_ms = timestamp_ms;
                warn_store(store.upsert_conversation(conversation));
            }
            drop(store);
            ping(&conversation_id);
        }
        TransportIntent::SelfStash {
            covered,
            timestamp_ms,
        } => {
            // Deliberately touches NEITHER store. A backup records what it
            // covered and nothing else — it is not a message, it does not
            // belong to a conversation, and writing a row for it would put our
            // own metadata JSON into a thread as a chat bubble (the stash is
            // sealed to us, so `transport_thread` would happily decrypt and
            // render it).
            drop(store);
            if let Ok(dir) = vault::transport_store_dir() {
                let state = kaspaverse_chain::history_fill::StashState {
                    last_unix_ms: timestamp_ms,
                    last_txid: txid.to_string(),
                    covered,
                    // A fresh backup is unproven until a walk reads it back —
                    // broadcasting is not the same as being findable.
                    confirmed_readable: false,
                };
                if let Err(e) = state.save(&dir) {
                    // A lost coverage record costs one redundant backup — a
                    // fee — and never costs history. Warn, never fail: the
                    // transaction is already on the wire.
                    log::warn!("self-stash: coverage record not saved: {e}");
                }
            }
            log::info!("self-stash: backup committed");
            ping_notice_inputs();
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

/// Is this invitation one the user could still Accept — and therefore one no
/// other gesture may quietly step around?
///
/// **Gates asked this question and asked it differently.**
/// `transport_existing_conversation` routes to Accept and
/// `transport_prepare_handshake` refuses a second bond because Accept is
/// available. (A third, `transport_start_over`, also had to not destroy
/// history for a request Accept would answer; it was removed with D-305's
/// repair wave, and this predicate is unchanged by that — the two remaining
/// callers are why it exists.) When the spend gate tightened to an allowlist
/// (`accept_provenance_ok`) and these did not, the app could refuse a
/// handshake saying "accept their invitation instead" while Accept refused
/// saying "your node has no record of this" — two contradictory refusals and
/// an unreachable address (INV-6, `wallet-security-auditor`, 2026-08-17).
///
/// `handshake_txid` presence is implied: `accept_provenance_ok` needs the row
/// it names.
fn invitation_is_acceptable(store: &TransportStore, c: &ConversationRecord) -> bool {
    c.status == ConversationStatus::PendingInbound
        && c.their_alias.is_some()
        && !store.is_conversation_tombstoned(&c.conversation_id)
        && !invite_expired(c.status, c.created_unix_ms, now_unix_ms())
        && c.handshake_txid
            .as_deref()
            .is_some_and(|txid| accept_provenance_ok(store, txid))
}

/// May we accept this invitation's bond refund, on provenance grounds?
///
/// **An allowlist, and ONE copy of it.** Accepting SPENDS: it returns 0.2 KAS
/// to an address resolved from the claimed handshake tx, so the row backing
/// that claim must be one our own node saw (`NodeScanned`) or one we wrote
/// ourselves (`Own`). `FillSourced` is an untrusted archive's word (D-070);
/// `Unknown` is a pre-provenance frame; **`None` is no row at all** — reachable
/// without any deletion, because the inbound fold upserts the conversation and
/// records its handshake row under two separate `warn_store` calls.
///
/// Shared because the router and the spend used to hold different versions of
/// it: `transport_existing_conversation` excluded only `FillSourced`, so it
/// would route the user to Accept and the accept would then refuse — the dead
/// end that function's own comment says leaves an address unreachable (INV-6).
fn accept_provenance_ok(store: &TransportStore, handshake_txid: &str) -> bool {
    matches!(
        store.message(handshake_txid).map(|m| m.provenance),
        Some(RowSource::NodeScanned | RowSource::Own)
    )
}

/// Whether a pending-inbound invitation is PERMANENTLY dead (V5, finding
/// 15): its bond is older than the node's pruning horizon, so
/// `transport_prepare_accept`'s sender resolution can never succeed — the
/// bond UTXO is long spent and the tx pruned (the return-address RPC is gone
/// with it), the sealed payload carries no sender address, and a funds
/// destination may never ride an unverifiable indexer hint (D-070). The
/// discriminator is the conversation's block-time `created_unix_ms` (V2b)
/// against the PIN-READ horizon (INV-9 — computed here, never re-derived in
/// Dart; only the bool crosses the FFI). Saturating: a future-dated clock
/// never expires anything. Pure; tested.
fn invite_expired(status: ConversationStatus, created_unix_ms: u64, now_ms: u64) -> bool {
    status == ConversationStatus::PendingInbound
        && now_ms.saturating_sub(created_unix_ms) > kaspaverse_chain::pruning_horizon_ms()
}

/// The addresses a coin-consolidation must leave alone: the bound own-address
/// of every non-tombstoned conversation whose binding is NOT the identity slot
/// (receive/0). Since D-148 every payment's change goes home to receive/0, so
/// NOTHING refills a non-identity bound address — a consolidation that
/// swallowed those coins would strand its conversation, unable to send until
/// hand-refilled (the open item logged at `await_spendable_at`). Status is
/// deliberately ignored: all three states can still move funds from their
/// binding (a PendingInbound accept refunds the bond from it), and hidden
/// rows can be revived by inbound traffic.
///
/// Fails CLOSED (no transport hub → error, never an empty list): an empty
/// answer on a wallet that HAS live conversations would quietly de-fund them,
/// which is the exact harm this set exists to prevent.
pub(crate) fn drain_exclusions() -> Result<Vec<Address>, AppError> {
    // The store lock is dropped BEFORE any derivation. Each slot costs an
    // HMAC-SHA512 and a secp256k1 child derivation — the pin caches neither —
    // and holding the messages store across that run blocks every transport
    // read for its whole duration, for nothing: the slots have already been
    // copied out by then. The live fee preview made this path callable while
    // the user types, which is what surfaced it (`wallet-security-auditor`,
    // UX-4B); the win applies equally to `send_minimum` and `send_prepare`,
    // which have always called it.
    let slots: HashSet<(Branch, u32)> = {
        let hub = hub()?;
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store
            .list_conversations()
            .into_iter()
            .filter(|c| !store.is_conversation_tombstoned(&c.conversation_id))
            .map(|c| (to_core_branch(c.bound_branch), c.bound_index))
            .filter(|slot| *slot != (Branch::Receive, 0))
            .collect()
    };
    slots
        .into_iter()
        .map(|(branch, index)| vault::wallet_address_at(branch, index))
        .collect()
}

/// **The read marks, seeded once on the build that introduces them.**
///
/// An upgrade must not invent unread messages. Every conversation on this
/// device predates the feature and has already been read *on this device*, so
/// the first pull with no `read.marks` file writes a mark at each thread's
/// newest inbound row and reports nothing unread. Only genuinely new arrivals
/// count after that.
///
/// The seed is keyed on the FILE being unusable, not on a conversation's mark
/// being absent — a per-conversation fallback would silently swallow the first
/// message of every new contact, which is the one message a count exists to
/// announce.
///
/// A failed write is not a failed pull: the marks are re-seeded next time and
/// the list still renders, so this returns the marks either way.
fn read_marks(store: &TransportStore) -> ReadMarks {
    let Some(dir) = vault::transport_store_dir().ok() else {
        return ReadMarks::default();
    };
    // **Absent OR unreadable**, not merely absent: a torn write must re-seed
    // rather than leave every thread on the device reading as unread
    // (`consensus-auditor`, this sitting).
    if let Some(marks) = ReadMarks::read(&dir) {
        return marks;
    }
    let mut marks = ReadMarks::default();
    for conversation in store.list_conversations() {
        if let Some(newest) = store.newest_inbound(&conversation.conversation_id) {
            marks.advance(&conversation.conversation_id, newest.unix_ms, &newest.txid);
        }
    }
    log::info!(
        "transport: seeded read marks for {} conversation(s) on first use",
        marks.marks.len()
    );
    if let Err(e) = marks.save(&dir) {
        log::warn!("transport: could not persist the seeded read marks ({e})");
    }
    marks
}

/// **Everything inbound in this conversation has now been seen.**
///
/// Called by the open thread — on its first frame with rows, and on each new
/// arrival while it is visible. **Never by the list**, which draws a row
/// without showing what is in it.
///
/// Idempotent and forward-only ([`ReadMarks::advance`]): a stale pull, a
/// re-entered thread or an out-of-order ping can only re-assert a mark, never
/// rewind one and bring back a count the user has already cleared.
///
/// Returns whether the mark actually moved, so a caller can skip a re-pull it
/// does not need. The list is pinged when it did, because that is the moment
/// a badge disappears.
pub fn transport_mark_read(conversation_id: String) -> Result<bool, AppError> {
    let hub = hub()?;
    let dir = vault::transport_store_dir()?;
    let newest = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store
            .newest_inbound(&conversation_id)
            .map(|m| (m.unix_ms, m.txid.clone()))
    };
    // Nothing inbound is nothing to mark, and writing a mark anyway would
    // stamp a thread the counterparty has never written in.
    let Some((unix_ms, txid)) = newest else {
        return Ok(false);
    };
    let mut marks = ReadMarks::load(&dir);
    if !marks.advance(&conversation_id, unix_ms, &txid) {
        return Ok(false);
    }
    marks.save(&dir).map_err(AppError::chain)?;
    ping(&conversation_id);
    Ok(true)
}

/// **How much decrypted text one conversation row may carry.**
///
/// A CUSTODY bound, not a layout one — how much plaintext leaves the vault per
/// row on a list refresh. The widest single column this app renders is the
/// unfolded tablet's 700 dp (`R3`), which holds about 107 characters of the
/// preview's 13 px Jakarta; this clears that with room, so the `…` a user
/// actually sees is always the widget's own ellipsis against the real frame
/// and never a Rust truncation pretending to be one.
const PREVIEW_CHARS: usize = 120;

/// **One conversation's last line, opened and bounded** (D-303).
///
/// The whole decrypt-on-view discipline of [`thread_row`], for one row, with
/// everything a list cannot use left sealed: no frame fields, no attachment
/// bytes, no per-row `AttachmentDto`. What comes back is a single line already
/// safe to draw.
///
/// Every branch is a DECIDED answer rather than a default, because a list row
/// falling through to an empty string is indistinguishable from a message that
/// says nothing:
///
///  - a handshake or legacy row ⇒ `None`, and the row draws the state it drew
///    before previews existed (*Wants to connect*, *Awaiting their accept*).
///    Those sentences already exist on the glass and in one place; minting a
///    second set here would be two copies of one string;
///  - a file ⇒ the noun the thread's own card uses, never the JSON body;
///  - a `kv:1:` frame ⇒ its generated human line, which is what the bubble
///    shows too;
///  - an envelope no key opens ⇒ *Encrypted message*, which is the truth;
///  - a locked vault ⇒ `None` for every row, so the list still renders.
///
/// **Whitespace-collapsed before it is cut.** A message may be many lines, and
/// a raw newline inside a single-line `Text` forges structure into the row —
/// the same reasoning `sanitize_name` applies to a name the user types.
fn preview_line(hub: &TransportHub, bound: KeySlot, record: &MessageRecord) -> Option<String> {
    if record.kind != StoredKind::Comm {
        return None;
    }
    let envelope = Envelope::from_bytes(&record.envelope).ok()?;
    let slot = record
        .sealed_to
        .map(|(b, i)| (to_core_branch(b), i))
        .unwrap_or(bound);
    let plaintext = match open_with_fallback(hub, slot, &envelope) {
        Ok(plaintext) => plaintext,
        // A locked vault is not a broken row: the list shows state lines until
        // it is unlocked, exactly as it did before this field existed.
        Err(CoreError::VaultLocked) => return None,
        Err(_) => return Some("Encrypted message".to_string()),
    };
    let body = String::from_utf8_lossy(&plaintext).into_owned();
    // A file body is the WHOLE plaintext, so it is tested before the frame
    // split — otherwise a row previews a wall of base64.
    // Named `preview`, not `line`: the tripwire above matches on identifier,
    // and a plaintext-bearing local wants a name the guard can see.
    let preview = match Attachment::parse(&body) {
        Some(Ok(file)) => file.kind.as_token().to_string(),
        Some(Err(_)) => "Attachment".to_string(),
        None => split_frame(&body).0,
    };
    bound_preview(&preview)
}

/// Collapse a message body to ONE bounded display line.
///
/// Pure, so the shaping is testable without a vault: the decrypt above is the
/// part that needs one, and this is the part that has to be right about a
/// counterparty's bytes.
///
/// **Whitespace-collapsed before it is cut.** A message may be many lines, and
/// a raw newline inside a single-line `Text` forges structure into the row —
/// the same reasoning `sanitize_name` applies to a name the user types. It
/// also folds the runs of spaces a padded body would otherwise spend the
/// whole budget on.
///
/// **Cut char-wise, never byte-wise**: a slice inside a UTF-8 code point is a
/// panic, and this is the one path that carries a stranger's text.
///
/// `None` for a body that is nothing but whitespace — the row then shows its
/// state rather than a blank second line pretending to be a message.
fn bound_preview(line: &str) -> Option<String> {
    let collapsed: String = line.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        return None;
    }
    Some(if collapsed.chars().count() > PREVIEW_CHARS {
        collapsed.chars().take(PREVIEW_CHARS).collect::<String>() + "…"
    } else {
        collapsed
    })
}

/// All conversations, most recently active first.
///
/// **This is the one function on this bridge that returns decrypted user
/// content for rows the user is not looking at** ([`ConversationDto::preview`]
/// — D-303 rules the feature; `wallet-security-auditor` returned CONCERNS on
/// this shape 2026-09-08 and every finding was taken here or in the caller).
/// The custody rules that follow from it: the plaintext is bounded per row
/// ([`PREVIEW_CHARS`]), it is never logged (see this DTO's hand-written
/// `Debug`), it is not produced at all while the vault is locked, and the
/// caller **drops it when the vault locks** — `MessagingService.dropDecrypted`,
/// driven from the shell's own leave-home transition, because the list that
/// holds these lines is an app-lifetime singleton no screen owns.
pub fn transport_conversations() -> Result<Vec<ConversationDto>, AppError> {
    let hub = hub()?;
    let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let now = now_unix_ms();
    // Loaded once per pull, not per row. Names are device-local metadata, so a
    // missing or unreadable file costs labels and never a conversation.
    let names = vault::transport_store_dir()
        .map(|dir| kaspaverse_chain::ContactNames::load(&dir))
        .unwrap_or_default();
    let marks = read_marks(&store);
    // `store` before `block_list` — the hub's lock order.
    let blocked = hub
        .block_list
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    // One pass over every stored row for both of `M1`'s answers, rather than
    // `messages_for` once per listed conversation.
    let mut tails = store.conversation_tails(&marks);
    Ok(store
        .list_conversations()
        .into_iter()
        // Hidden rows are matchable but not shown — that asymmetry IS the fix
        // (see `transport_hide_conversation`).
        .filter(|c| !store.is_conversation_tombstoned(&c.conversation_id))
        .map(|c| ConversationDto {
            invite_expired: invite_expired(c.status, c.created_unix_ms, now),
            // **Cleaned on read, like `transport_contact_names`.** The
            // deceptive-format filter (bidi overrides, zero-width, the BOM)
            // landed one commit AFTER the store, so a name written in that
            // window carries only control-character filtering and nothing
            // re-cleans it — and this join feeds the conversation list and the
            // thread header. Empty after cleaning means no usable name, which
            // is `None` rather than a blank row.
            contact_name: names
                .get(&c.contact_address)
                .map(kaspaverse_chain::sanitize_name)
                .filter(|n| !n.is_empty()),
            preview: tails
                .get(&c.conversation_id)
                .and_then(|tail| tail.newest.as_ref())
                .and_then(|newest| {
                    preview_line(
                        &hub,
                        (to_core_branch(c.bound_branch), c.bound_index),
                        newest,
                    )
                }),
            unread: tails
                .remove(&c.conversation_id)
                .map_or(0, |tail| tail.unread),
            blocked: blocked.is_blocked(&c.contact_address),
            reply_needs_handshake: c.status == ConversationStatus::Active && c.my_alias.is_empty(),
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

/// Hide a conversation — forget its CONTENT, keep its IDENTITY.
///
/// This used to hard-delete the conversation row, and that was the defect
/// behind the worst interop failure this project has had. The row is the only
/// place the counterparty's alias lives, and their alias is the only thing
/// that routes their messages to us. Deleting it did not stop them writing —
/// it made every message they sent afterwards undeliverable, permanently,
/// because a client that already knows us never re-announces itself.
///
/// So: the messages are still purged — hide must forget what was said, and
/// the sheet copy promises exactly that — but the conversation row is
/// tombstoned rather than removed. It stops appearing in the list and stops
/// being swept for history, while remaining matchable by alias and by address
/// so an acceptance or a later message can still find its home.
///
/// Idempotent: hiding an unknown id is a no-op success.
pub fn transport_hide_conversation(conversation_id: String) -> Result<(), AppError> {
    let hub = hub()?;
    let hidden = {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        hide_conversation_rows(&mut store, &conversation_id)
    };
    // Nudge any open list to re-pull. The thread does NOT 404 — the row
    // survives by design; it simply stops being listed. Pinged even when the
    // scrub failed: the hide itself is on disk by then (PRE3-LOG).
    ping(&conversation_id);
    hidden
}

/// Hide's store half: content goes, identity stays, and the content's sealed
/// bytes leave the file now rather than at some later compaction, because
/// hide promises to forget what was said (PRE3-LOG, F30). Pure over the
/// store, so it is tested without a hub.
fn hide_conversation_rows(
    store: &mut TransportStore,
    conversation_id: &str,
) -> Result<(), AppError> {
    // Content goes. Identity stays. A removal that fails is reported, and the
    // row is NOT hidden: a hidden row's unremoved words could be retried by
    // nothing and would come back with the contact's next message. Listed,
    // the user's retry reaches them (`ffi-leak-auditor` +
    // `wallet-security-auditor`, PRE3-LOG). What was removed is scrubbed
    // either way.
    let txids: Vec<String> = store
        .messages_for(conversation_id)
        .into_iter()
        .map(|m| m.txid)
        .collect();
    let mut unremoved = None;
    for txid in txids {
        if let Err(e) = store.remove_message(&txid) {
            log::warn!("transport-hub: store remove failed: {e}");
            unremoved.get_or_insert(e);
        }
    }
    if let Some(e) = unremoved {
        if let Err(scrub) = store.scrub() {
            log::warn!("transport-hub: scrub after a partial hide failed: {scrub}");
        }
        return Err(AppError::chain(e));
    }
    store
        .tombstone_conversation(conversation_id)
        .map_err(AppError::chain)?;
    store.scrub().map_err(AppError::chain)
}

/// Forget what was SAID in one conversation, keeping the conversation itself.
///
/// The narrow, safe half of "delete this chat": it removes exactly what
/// [`transport_hide_conversation`] removes — every stored message row — and
/// then stops. The row stays listed, stays sendable, stays matchable. The
/// thread simply starts empty.
///
/// **Why this exists beside hide rather than inside it.** Hide answers "I do
/// not want to see this person"; it purges the content AND takes the row off
/// the list, and it comes back the moment they write. This answers a different
/// question — "I do not want these words on my phone" — for a conversation the
/// user intends to keep using. Folding the two together would mean the only
/// way to clear a thread is to also stop seeing it.
///
/// **Why it does not delete the row.** The row holds the counterparty's alias,
/// which is the only thing that routes their messages to us and is never
/// re-announced on the wire. Deleting it is the July regression; that is what
/// [`transport_wipe_all`] is for, and it is safe there only because it leaves
/// nothing behind to be orphaned.
///
/// Local only. The ciphertext stays on chain forever (D-088) — the confirm
/// copy must say so.
///
/// Idempotent: clearing an unknown or already-empty conversation is a no-op
/// success.
pub fn transport_clear_messages(conversation_id: String) -> Result<WipeReportDto, AppError> {
    let hub = hub()?;
    // Sealed BEFORE anything is removed, exactly like the wipe. A fill walking
    // right now holds a pre-clear copy of the cursors and blind-writes it back
    // when it finishes — clobbering this floor and re-folding every historical
    // inbound comm into the thread being emptied, leaving a half-restored
    // thread under a "N messages cleared" notice.
    //
    // Only this conversation's comm cursor moves: a clear is a statement about
    // one thread, and raising the global floor would silently stop the catch-up
    // for every other conversation the user still wants.
    let floor_persisted = seal_erasure(|cursors| {
        let entry = cursors.comms.entry(conversation_id.clone()).or_default();
        *entry = (*entry).max(now_unix_ms());
    });
    let cleared = {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        clear_conversation_rows(&mut store, &conversation_id)
    };
    let cleared = match cleared {
        Ok(cleared) => cleared,
        Err(e) => {
            // Rows may have gone before the failure: the thread re-pulls either way.
            ping(&conversation_id);
            return Err(e);
        }
    };

    log::info!(
        "transport-clear: {cleared} message row(s) removed from one conversation, \
         floor_persisted={floor_persisted}"
    );
    ping(&conversation_id);
    Ok(WipeReportDto {
        conversations: 0,
        messages: u32::try_from(cleared).unwrap_or(u32::MAX),
        side_files_cleared: 0,
        // A clear touches one conversation's words; no invitation dies here.
        pending_bonds: 0,
        floor_persisted,
    })
}

/// Clear's store half: every message row of one conversation but its
/// establishing handshake, then the words out of the file. Counts what went.
/// Pure over the store, so it is tested without a hub.
fn clear_conversation_rows(
    store: &mut TransportStore,
    conversation_id: &str,
) -> Result<usize, AppError> {
    // THE ESTABLISHING HANDSHAKE ROW IS NOT "A MESSAGE" AND IS NOT CLEARED.
    //
    // It is evidence a money gate depends on. `transport_prepare_accept`
    // refuses to refund a bond whose handshake row is `FillSourced` (an
    // indexer claim, D-070) — and that check reads the row through
    // `handshake_txid`. Delete it and the check evaluates
    // `matches!(None, Some(FillSourced))` → false, so a fail-CLOSED guard
    // on a 0.2 KAS spend silently becomes fail-open
    // (`wallet-security-auditor`, 2026-08-17). The gesture is also offered
    // on an invitation card, which is exactly where that matters.
    //
    // Nothing is lost by keeping it: a handshake row carries no body to
    // the thread view — it renders as a system line, not as words anyone
    // said.
    let keep = store
        .conversation(conversation_id)
        .and_then(|c| c.handshake_txid.clone());
    let txids: Vec<String> = store
        .messages_for(conversation_id)
        .into_iter()
        .map(|m| m.txid)
        .filter(|txid| Some(txid) != keep.as_ref())
        .collect();
    // COUNT WHAT WENT, NOT WHAT WAS ASKED FOR, and surface a failure
    // instead of warning past it (`ffi-leak-auditor`, 2026-08-17). The
    // sibling purge inside `hide_conversation_rows` now reports its first
    // failed removal too (PRE3-LOG); here the count reaches the user as "N
    // messages cleared", and a swallowed write error would make that a
    // promise the disk never kept. Partial progress is reported honestly by the error, not
    // rolled back — the rows that did go are gone.
    let mut cleared = 0usize;
    for txid in txids {
        store.remove_message(&txid).map_err(AppError::chain)?;
        cleared += 1;
    }
    // "I do not want these words on my phone" has to reach the file, not
    // only the screen: each removed row's frame, envelope included, stayed
    // behind its `Remove` until a compaction that never came (PRE3-LOG,
    // F30), and a copy kept aside held all of them. A failure is the error,
    // like a failed remove above, because the count returned would
    // otherwise promise something the disk lacks; the next transport start
    // finishes the rewrite whether or not the user retries
    // ([`TransportStore::finish_removals`]).
    store.scrub().map_err(AppError::chain)?;
    Ok(cleared)
}

/// What a wipe destroyed. Counts and shapes only — a report about erasing
/// user content may not carry any of it across the bridge (§4).
#[derive(Clone, Debug)]
pub struct WipeReportDto {
    pub conversations: u32,
    pub messages: u32,
    /// Contact names and the backup-coverage record: cleared alongside,
    /// because each is a claim about data that no longer exists.
    pub side_files_cleared: u32,
    /// Unanswered contact requests destroyed — each holding 0.2 KAS the sender
    /// paid, which only an Accept could have returned. Somebody else's money,
    /// so it gets its own number and its own sentence in the confirmation.
    pub pending_bonds: u32,
    /// Did the history-catch-up floor persist?
    ///
    /// **The one field here a user must be told about.** The floor is what
    /// stops the next indexer fill rebuilding every conversation from our own
    /// on-chain backup and re-downloading every message from a third party.
    /// If it did not persist, the erase happened but is not durable against
    /// the next catch-up — and the confirm sheet promised "cannot be undone".
    ///
    /// It is a field rather than an error because the store IS wiped by then:
    /// failing the call would report "nothing was deleted" about an empty
    /// store, which is the worse lie. So the call succeeds and says which kind
    /// of success it was.
    pub floor_persisted: bool,
}

/// **The handshake bond, in sompi** (§0.6 — the one amount the transport
/// spends that is not a fee).
///
/// It exists because the figure was written into eight UI strings as the
/// literal `0.2 KAS`, and the truth is [`HANDSHAKE_BOND_SOMPI`] one crate
/// down. Eight copies of a money figure are eight chances to tell a user the
/// wrong price of an irreversible spend the day the constant moves — the same
/// defect `maturity_thresholds` was added to close for the lifecycle rungs
/// (UX-R3, `consensus-auditor`: a UI literal is a BLOCK).
///
/// Synchronous and I/O-free — it reads a `const`, so a surface can render the
/// price in its first frame and never has to paint a number it does not have.
#[flutter_rust_bridge::frb(sync)]
pub fn transport_handshake_bond_sompi() -> u64 {
    HANDSHAKE_BOND_SOMPI
}

/// What [`transport_wipe_all`] would destroy, without destroying it.
///
/// The confirm sheet's number comes from HERE and never from the conversation
/// list, which filters hidden rows the wipe still destroys. `side_files_cleared`
/// is always 0 — nothing has been cleared yet.
pub fn transport_wipe_preview() -> Result<WipeReportDto, AppError> {
    let hub = hub()?;
    let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let report = store.wipe_preview();
    Ok(WipeReportDto {
        conversations: u32::try_from(report.conversations).unwrap_or(u32::MAX),
        messages: u32::try_from(report.messages).unwrap_or(u32::MAX),
        side_files_cleared: 0,
        pending_bonds: u32::try_from(report.pending_bonds).unwrap_or(u32::MAX),
        // Nothing has been floored yet; a preview claims no durability.
        floor_persisted: false,
    })
}

/// Erase every conversation, every message and every local trace of them.
///
/// **Why the TOTAL erase is the safe one, and a single-row delete is not.**
/// A conversation row is the only place a counterparty's alias lives, and a
/// client that already knows us answers a repeat handshake with silence
/// (`conversation-manager-service.ts:181-213`). Delete one row and they keep
/// writing into a thread we can no longer route — the July regression, which
/// is why [`transport_hide_conversation`] tombstones instead of removing.
/// Erasing EVERYTHING leaves nothing half-bound: no surviving row holds a lost
/// alias, and the user knows they are starting over with everyone.
///
/// It is also, measured on the founder's device 2026-08-17, how a broken
/// conversation actually gets repaired. A client that has forgotten you is the
/// only one that will handshake you afresh, and a fresh handshake is what
/// re-binds both sides. This is that gesture, made available on our side.
///
/// **What it does NOT touch, deliberately:**
/// - `fill.config` — the indexer posture is a setting the user chose, not
///   data they wrote. Wiping it would silently re-enter the §0 default.
/// - `scan.cursor` — a position on the chain, not user content. Resetting it
///   would re-walk history the user just asked to be rid of.
///
///   **And that is only half the truth, so read the other half.** The node
///   catch-up walks FORWARD from that cursor, so an erase landing while a
///   replay is in flight can re-fold handshakes mined before it and re-create
///   conversations in the emptied store as fresh invitations. Comms cannot come
///   back that way (post-erase they drop unrouted, `NoConversationForAlias`),
///   and the window is bounded by the cursor's own write cadence and the
///   walk's replay (LINK-Q3: a gap's oldest hour, then what followed each
///   arm's mark; it was `MAX_CATCHUP_PAGES`), which a replay after a lock now
///   also runs — but it is a real, accepted residual, not a free
///   omission. The node lane has no epoch guard; closing it means an erase
///   check inside the fold's own lock scope, which is a change to the live
///   intake path and is deliberately NOT made at the end of this sitting
///   (`consensus-auditor`, 2026-08-17, dispositioned). IDEAS_BACKLOG carries
///   its trigger.
/// - The vault, keys and coins. This erases messages, never money.
///
/// **What it cannot do:** reach the chain. Every message is public ciphertext
/// on a public DAG, permanently, and anyone holding the seed can decrypt it
/// again (D-088). The confirm copy says so; this doc says so; nothing in this
/// lane may imply otherwise.
///
/// Not undoable. The caller owns the confirmation.
pub fn transport_wipe_all() -> Result<WipeReportDto, AppError> {
    let hub = hub()?;

    // FIRST, before anything is destroyed. A prepare in flight otherwise
    // outlives the wipe, and confirming its signature afterwards runs
    // `apply_intent` against an empty store: the Handshake arm upserts its
    // prepare-time snapshot and the conversation the user just erased comes
    // back fully formed, while the Comm arm records a message against a
    // conversation id that no longer exists. Ordered first because abandoning
    // AFTER leaves a window for exactly that confirm; abandoning first has
    // none — a confirm either applies to the live store and is then erased, or
    // finds nothing. The plan is built-but-unsigned, so dropping it spends
    // nothing.
    transport_abandon();

    // SEAL THE ERASURE BEFORE DESTROYING ANYTHING. This stamps the catch-up
    // floor and bumps the generation under one gate, so a fill walk already
    // running fails its next commit check and one about to start reads the
    // floored cursors. Doing it first also means the store is never emptied
    // while a walk still believes its pre-erase cursors are current.
    //
    // A wipe is a statement about all history up to now, so `now` is the floor
    // — stamped as a SCALAR, not raised per key. Raising per key covered only
    // keys that already existed, and with the fill disabled by default the
    // usual state is that `fill.cursors` does not exist at all: the raise
    // touched nothing, the save "succeeded", and enabling History & backup
    // later rebuilt everything. `FillCursors::start_at` applies the scalar to
    // every lane, including ones added later.
    //
    // This does NOT close the door on a deliberate future restore: that would
    // be its own explicit action, lowering the floor on purpose.
    let floor_persisted = seal_erasure(|cursors| {
        cursors.raise_floor(now_unix_ms());
        // Belt, not the mechanism: `start_at` already floors every lane, and
        // these keys name conversations that will not exist in a moment.
        cursors.comms.clear();
    });

    let report = {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store.wipe().map_err(AppError::chain)?
    };

    // Two side files assert something about the rows just destroyed: names
    // label addresses we no longer have a thread with, and the stash state
    // claims a backup covers a list that no longer exists. Both read as their
    // default when missing, so removal IS the reset.
    //
    // Counted, not fatal: the store is already wiped, and failing the whole
    // call over a leftover label would report "nothing was deleted" about a
    // store that is empty — the worst possible lie in this lane.
    let side_files_cleared = vault::transport_store_dir()
        .map(|dir| clear_side_files(&dir))
        .unwrap_or(0);

    // In-memory claims about txids that no longer have a home. Left standing,
    // a parked acceptance would complete into a conversation the user deleted
    // and mint it back from nothing. `REFUTED` stays: it holds our node's own
    // verdicts on txids, which a wipe does not change, and it only ever stops
    // an archive from filing one of them (PRE3-SENDER).
    PENDING_COMMS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();
    PENDING_ACCEPTANCE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clear();

    log::info!(
        "transport-wipe: {} conversation(s) and {} message(s) erased, {side_files_cleared} side file(s) cleared, floor_persisted={floor_persisted}",
        report.conversations,
        report.messages
    );
    // The notice inputs changed and nothing else can say so: the backup
    // coverage this screen reports was just deleted, and the gap notice is
    // derived from cursors that no longer exist.
    //
    // NOT a list refresh — the empty ping is the notice sentinel and Dart
    // answers it with `refreshFillState()` alone (`messaging_service.dart`).
    // The conversation list is re-pulled by the CALLER, which is the only
    // side that knows the wipe was asked for; a per-conversation ping is not
    // available here because there is deliberately no conversation left to
    // name.
    ping_notice_inputs();

    Ok(WipeReportDto {
        conversations: u32::try_from(report.conversations).unwrap_or(u32::MAX),
        messages: u32::try_from(report.messages).unwrap_or(u32::MAX),
        side_files_cleared,
        pending_bonds: u32::try_from(report.pending_bonds).unwrap_or(u32::MAX),
        floor_persisted,
    })
}

/// The side files a wipe takes with the store, and the one it leaves.
///
/// Names label addresses we no longer have a thread with, and the stash state
/// claims a backup covers a list that no longer exists; both read as their
/// default when missing, so removal IS the reset. **`block.list` is NOT here,
/// on purpose** (D-308): a block is the user's refusal about a person, not a
/// claim about the rows just destroyed — and with the revival path live, a
/// wipe that dropped it would hand every refused address a way back in on
/// their next message. The user lifts a block from the Blocked list, or by
/// accepting that person's next request; nothing else does.
///
/// Counted, not fatal: the store is already wiped, and failing the whole call
/// over a leftover label would report "nothing was deleted" about a store that
/// is empty — the worst possible lie in this lane.
fn clear_side_files(dir: &Path) -> u32 {
    let mut cleared = 0u32;
    for path in [
        kaspaverse_chain::ContactNames::path(dir),
        kaspaverse_chain::history_fill::StashState::path(dir),
    ] {
        match std::fs::remove_file(&path) {
            Ok(()) => cleared += 1,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => log::warn!("transport-wipe: a side file survived: {e}"),
        }
    }
    cleared
}

/// **Block a contact — a reset to strangers** (D-308, the founder's design).
///
/// Three things, in an order that never leaves a purged thread with no
/// refusal behind it:
///
/// 1. **The refusal is written first, durably** (`block.list`, keyed on the
///    address and nothing else). If anything
///    below fails, the block stands and the rows die on the next attempt; the
///    reverse order would purge the thread and then lose the reason.
/// 2. **Every row for the address is destroyed, with its messages** — the
///    conversation, their alias, our alias, all of it. This is the one caller
///    `TransportStore::remove_conversation` warns it must never have as a
///    "cleanup", and the warning is right: the alias goes, and their messages
///    become unroutable. That is the point. Hide keeps the row so a mute can
///    end when they write; a block is *no*, and what ends it is a handshake.
/// 3. **The in-memory claims that could resurrect them go too** — a parked
///    comm under their alias, a parked acceptance for their row.
///
/// It sits in FRONT of the revival path (D-307): their next comm is refused
/// on the alias before any decrypt, and on the address after any resolution,
/// so it never mints anything. Their next HANDSHAKE still surfaces — marked —
/// because that is the one door a stranger has, it costs them the bond, and
/// the choice is the user's; accepting it lifts the block.
///
/// **Touches no money.** Nothing is refunded, nothing is stranded: a request
/// they have already paid for is dismissed like any other (the bond stays
/// where it was paid, exactly as Ignore leaves it), and a request they send
/// later is Accept-able or Dismiss-able like any other.
///
/// Never on the wire — telling someone they are blocked is a feature nobody
/// asked for, and on a public ledger it would be permanent.
///
/// Refuses a row whose sender is not known yet: there is no address to key
/// the refusal on, so nothing it promised would hold. The request card's
/// Ignore is the right gesture for that row.
pub fn transport_block_conversation(conversation_id: String) -> Result<(), AppError> {
    let hub = hub()?;
    let dir = vault::transport_store_dir()?;
    let (address, alias) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let conversation = store
            .conversation(&conversation_id)
            .ok_or_else(|| AppError::msg("conversation not found"))?;
        if conversation.contact_address.is_empty() {
            return Err(AppError::msg(
                "their address isn't known yet, so there is nothing to block. Ignore the \
                 request instead, or wait for the lookup.",
            ));
        }
        (
            conversation.contact_address.clone(),
            conversation.their_alias.clone(),
        )
    };
    // 1. The refusal, first and durably — and in memory only once it is on
    // disk (PRE3-LOG, F46), so a failed save leaves no session-only refusal.
    {
        let mut list = hub
            .block_list
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        list.commit(&dir, |list| list.block(&address, now_unix_ms()))
            .map_err(AppError::chain)?;
    }
    // 2. The rows. Sealed before they are destroyed, like every erase in this
    // lane: a fill walk in flight holds a pre-block copy of the cursors and
    // must not write a floor for threads that no longer exist.
    let ids: Vec<String> = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store
            .conversations_for_contact_address(&address)
            .iter()
            .map(|c| c.conversation_id.clone())
            .collect()
    };
    let floor_persisted = seal_erasure(|cursors| {
        for id in &ids {
            cursors.comms.remove(id);
        }
    });
    let ((rows, messages), scrubbed) = {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        block_purge(&mut store, &address)?
    };
    // 3. The claims.
    if let Some(alias) = alias.as_deref() {
        PENDING_COMMS
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .forget_alias(alias);
    }
    PENDING_ACCEPTANCE
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .retain(|(_, claim)| !ids.contains(&claim.conversation_id));
    log::info!(
        "transport-block: 1 address blocked — {rows} conversation row(s) and {messages} \
         message row(s) removed, floor_persisted={floor_persisted}"
    );
    for id in &ids {
        ping(id);
    }
    // **Not an error.** The block is complete by now: the refusal is saved,
    // the rows are gone, the claims are dropped. Only the words' removal from
    // the file failed, which the next transport start in this process finishes
    // (after a relaunch, the load compacts the removed rows and a copy that
    // could not be deleted waits for the next erase or wipe). Reporting it
    // as a failed block would tell the user something false, and a retry
    // would find no conversation to block (`ffi-leak-auditor`, PRE3-LOG).
    if let Err(e) = scrubbed {
        log::warn!(
            "transport-block: the scrub after a block failed ({e}); the next start finishes it"
        );
    }
    Ok(())
}

/// Move a present-but-unreadable `block.list` aside as `block.list.corrupt`,
/// so the durable-write guarantee is not undone by the one thing it cannot
/// cover: a file that exists and does not parse. Reading it as empty and then
/// saving over it would erase every refusal silently.
fn quarantine_unreadable_block_list(dir: &Path) {
    let path = BlockList::path(dir);
    if !path.exists() || BlockList::read(dir).is_some() {
        return;
    }
    let aside = path.with_extension("list.corrupt");
    match std::fs::rename(&path, &aside) {
        Ok(()) => log::warn!(
            "block-list: unreadable — moved aside as block.list.corrupt; reading as nobody \
             blocked until the user blocks again"
        ),
        Err(e) => log::warn!("block-list: unreadable and could not be moved aside: {e}"),
    }
}

/// The start sweep's store half (D-308): every row for each blocked address
/// but a live request, then their sealed bytes out of the file when anything
/// went (PRE3-LOG, F30). Best-effort, as the sweep always was: a failure is
/// warned and the next start sweeps again. Pure over the store, so it is
/// tested without a hub.
fn sweep_blocked_rows(store: &mut TransportStore, addresses: &[String]) -> (usize, usize) {
    let mut swept = (0usize, 0usize);
    for address in addresses {
        match purge_contact_rows(store, address, true) {
            Ok((rows, messages)) => {
                swept.0 += rows;
                swept.1 += messages;
            }
            Err(e) => log::warn!("transport-block: start sweep failed: {}", e.message),
        }
    }
    if swept.0 > 0 {
        log::info!(
            "transport-block: {} row(s) and {} message(s) for blocked addresses removed at start",
            swept.0,
            swept.1
        );
        // A compaction, not a scrub: copies kept aside are deleted by an erase
        // the user asks for or by a wipe, never by the start's housekeeping
        // (the first start's load may have made one moments ago).
        if let Err(e) = store.compact() {
            log::warn!("transport-block: compaction after the start sweep failed: {e}");
        }
    }
    swept
}

/// The transport start's store step: the blocked-address sweep (D-308), then
/// whatever an erase left undone (PRE3-LOG, F30). The store lives for the
/// process, so this start is where a failed scrub or an uncompacted removal is
/// finished, not a reload that no longer comes. Pure over the store, so it is
/// tested without a hub (`consensus-auditor`: the call was otherwise one
/// untested line that the gate could lose).
fn start_store_step(store: &mut TransportStore, blocked: &[String]) {
    sweep_blocked_rows(store, blocked);
    if let Err(e) = store.finish_removals() {
        log::warn!("transport-store: finishing removals at start failed: {e}");
    }
}

/// The block's store half: every row for the address, then their sealed
/// bytes out of the file and its copies, not only off the screen (PRE3-LOG,
/// F30). The scrub's outcome is returned beside the counts, not raised: by
/// then the rows are gone for good, and the block's claims and pings must
/// still run (`ffi-leak-auditor` + `consensus-auditor`); a scrub that failed
/// is finished by the next transport start
/// ([`TransportStore::finish_removals`]). Pure over the store, so it is
/// tested without a hub.
fn block_purge(
    store: &mut TransportStore,
    address: &str,
) -> Result<((usize, usize), kaspaverse_chain::Result<()>), AppError> {
    let purged = purge_contact_rows(store, address, false)?;
    Ok((purged, store.scrub()))
}

/// Destroy every conversation row for an address and every message in them.
/// Counts what WENT, and surfaces a failed write rather than warning past it:
/// a partial purge is reported by the error, and the rows that did go are
/// gone.
///
/// `keep_live_requests`: the start sweep passes `true`, because a request the
/// blocked address knocked with AFTER the block is the one door D-308 keeps
/// open — it surfaces marked, and accepting it lifts the block. Purging it on
/// the next unlock would strand the bond they paid with no gesture made
/// (`consensus-auditor` + `wallet-security-auditor`, MSG-BLOCK). The block
/// itself passes `false`: at that moment every row is the thread being ended.
fn purge_contact_rows(
    store: &mut TransportStore,
    address: &str,
    keep_live_requests: bool,
) -> Result<(usize, usize), AppError> {
    let ids: Vec<String> = store
        .conversations_for_contact_address(address)
        .iter()
        .filter(|c| {
            !(keep_live_requests
                && c.status == ConversationStatus::PendingInbound
                && !store.is_conversation_tombstoned(&c.conversation_id))
        })
        .map(|c| c.conversation_id.clone())
        .collect();
    let mut messages = 0usize;
    for id in &ids {
        for row in store.messages_for(id) {
            store.remove_message(&row.txid).map_err(AppError::chain)?;
            messages += 1;
        }
        store.remove_conversation(id).map_err(AppError::chain)?;
    }
    Ok((ids.len(), messages))
}

/// Lift a block on an address, when the user does it deliberately. Nothing
/// else happens: their next message can revive the thread (D-307) and their
/// next handshake is a plain request. Returns whether there was one to lift.
pub fn transport_unblock_contact(address: String) -> Result<bool, AppError> {
    let hub = hub()?;
    let dir = vault::transport_store_dir()?;
    let mut list = hub
        .block_list
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    // On disk first, then in memory (PRE3-LOG, F46): a failed save used to
    // lift the block for the session and leave it in force after a restart.
    let lifted = list
        .commit(&dir, |list| list.unblock(&address))
        .map_err(AppError::chain)?;
    if lifted {
        log::info!("transport-block: 1 address unblocked");
    }
    Ok(lifted)
}

/// The block lifted by one of the two gestures that mean it: accepting the
/// person's request, or inviting them ourselves (typing their address and
/// paying a bond is the user asking for them back — the same rule that makes
/// adding a contact an explicit un-hide). Logged as a consequence, because the
/// list the user reads will be one shorter and nothing else says why.
fn lift_block_on_contact(hub: &TransportHub, address: &str, why: &str) {
    let mut list = hub
        .block_list
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    if !list.is_blocked(address) {
        return;
    }
    // On disk first, then in memory (PRE3-LOG, F46). A lift whose save fails
    // is not made at all, so memory and disk agree that the block stands.
    match vault::transport_store_dir().and_then(|dir| {
        list.commit(&dir, |list| list.unblock(address))
            .map_err(AppError::chain)
    }) {
        Ok(_) => log::info!("transport-block: {why} lifted a block"),
        Err(e) => log::warn!(
            "transport-block: a lift did not persist, so the block stands: {}",
            e.message
        ),
    }
}

/// One blocked address, for the Blocked addresses list (`M5`, D-308).
#[derive(Clone)]
pub struct BlockedContactDto {
    pub address: String,
    /// The local name the user gave this address, when they gave one — so
    /// the list reads as people, not keys. Device only, like the name itself.
    pub contact_name: Option<String>,
    pub since_unix_ms: u64,
}

/// Redacted like [`ConversationDto`]'s: a name is a real person's.
impl std::fmt::Debug for BlockedContactDto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BlockedContactDto")
            .field("address", &self.address)
            .field("contact_name", &self.contact_name.as_ref().map(|n| n.len()))
            .field("since_unix_ms", &self.since_unix_ms)
            .finish()
    }
}

/// Every blocked address, newest first, with the name the user gave it.
pub fn transport_blocked_contacts() -> Result<Vec<BlockedContactDto>, AppError> {
    let hub = hub()?;
    let names = vault::transport_store_dir()
        .map(|dir| kaspaverse_chain::ContactNames::load(&dir))
        .unwrap_or_default();
    let list = hub
        .block_list
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone();
    Ok(list
        .entries()
        .into_iter()
        .map(|(address, entry)| BlockedContactDto {
            address: address.to_string(),
            // Cleaned on read, like every other reader of `contact.names`.
            contact_name: names
                .get(address)
                .map(kaspaverse_chain::sanitize_name)
                .filter(|n| !n.is_empty()),
            since_unix_ms: entry.since_unix_ms,
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
        let tombstoned = store.is_message_tombstoned(&record.txid);
        thread.push(thread_row(&hub, bound, record, tombstoned)?);
    }
    Ok(thread)
}

/// Build the display row for ONE stored record — the decrypt-on-view unit
/// (§0.4) shared by [`transport_thread`] and [`transport_thread_since`].
/// Handshake rows are system rows (no body); comm rows open per call and the
/// plaintext crosses once as the DTO. Vault locked ⇒ the whole pull errors.
fn thread_row(
    hub: &TransportHub,
    bound: KeySlot,
    record: MessageRecord,
    tombstoned: bool,
) -> Result<ThreadMessageDto, AppError> {
    let outbound = record.direction == MessageDirection::Outbound;
    let provenance = row_source_label(record.provenance);
    match record.kind {
        StoredKind::Handshake | StoredKind::Legacy => Ok(ThreadMessageDto {
            txid: record.txid,
            kind: "handshake".to_string(),
            outbound,
            unix_ms: record.unix_ms,
            text: String::new(),
            readable: true,
            frame: None,
            attachment: None,
            tombstoned,
            provenance,
        }),
        StoredKind::Comm => {
            let mut attachment: Option<AttachmentDto> = None;
            let (text, frame, readable) = match Envelope::from_bytes(&record.envelope) {
                Ok(envelope) => {
                    let slot = record
                        .sealed_to
                        .map(|(b, i)| (to_core_branch(b), i))
                        .unwrap_or(bound);
                    match open_with_fallback(hub, slot, &envelope) {
                        Ok(plaintext) => {
                            // Split the readable line from any `kv:1:` frame.
                            // Only the parsed result crosses the bridge; an
                            // unknown/forward tail degrades to its line (P5).
                            let body = String::from_utf8_lossy(&plaintext).into_owned();
                            // A file body is the WHOLE plaintext, so it is
                            // checked before frame-splitting — otherwise the
                            // JSON object renders as a wall of text in a chat
                            // bubble, which is exactly what it used to do.
                            if let Some(parsed) = Attachment::parse(&body) {
                                let dto = match parsed {
                                    Ok(file) => AttachmentDto {
                                        name: file.name.clone(),
                                        size_bytes: file.bytes.len() as u64,
                                        kind: file.kind.as_token().to_string(),
                                        text: file.as_text(),
                                        broken: false,
                                        view_mime: file.view_mime().to_string(),
                                    },
                                    // Say "this file did not decode" rather
                                    // than dumping the body that failed.
                                    Err(_) => AttachmentDto {
                                        name: "attachment".to_string(),
                                        size_bytes: 0,
                                        kind: "other".to_string(),
                                        text: None,
                                        broken: true,
                                        view_mime: "application/octet-stream".to_string(),
                                    },
                                };
                                attachment = Some(dto);
                                (String::new(), None, true)
                            } else {
                                let (text, frame) = split_frame(&body);
                                (text, frame, true)
                            }
                        }
                        Err(CoreError::VaultLocked) => {
                            return Err(AppError::msg("wallet is locked — unlock to read messages"))
                        }
                        Err(_) => (String::new(), None, false),
                    }
                }
                Err(_) => (String::new(), None, false),
            };
            Ok(ThreadMessageDto {
                txid: record.txid,
                kind: "comm".to_string(),
                outbound,
                unix_ms: record.unix_ms,
                text,
                readable,
                frame,
                attachment,
                tombstoned,
                provenance,
            })
        }
    }
}

/// Sompi rendered exactly, to all 8 decimals.
///
/// NOT the pinned crate's `sompi_to_kaspa_string`: that one goes through `f64`
/// (`wallet/core/src/utils.rs:34,44` @ `01b532e`), and this project does not put
/// money through binary floating point — DS-2 wants the exact figure at the
/// moment of commitment, and a refusal that names an amount is such a moment.
/// Integer division and remainder are exact for every u64.
fn format_kas(sompi: u64) -> String {
    format!("{}.{:08}", sompi / 100_000_000, sompi % 100_000_000)
}

/// The stable wire label for a stored row's provenance.
///
/// One mapping, here, so a store-layer variant rename cannot silently change
/// what the glass says about where a message came from.
fn row_source_label(source: RowSource) -> String {
    match source {
        RowSource::NodeScanned => "node",
        RowSource::FillSourced => "archive",
        RowSource::Own => "own",
        RowSource::Unknown => "unknown",
    }
    .to_string()
}

/// A chain timestamp the glass can actually render, or `None`.
///
/// Two ways this is not a number we may hand onward. `0` means the accepting
/// block could not be fetched and there is no chain timestamp at all, so the
/// glass shows no time rather than a 1970 stamp or this device's clock.
///
/// And the upper bound is not defensive dressing: this value is
/// `block.header.timestamp` as reported by whichever resolver node answered,
/// so it is **remote input on a funds surface** and nothing upstream bounds it.
/// Dart's `DateTime.fromMillisecondsSinceEpoch` THROWS above 100,000,000 days
/// (`BigInt.toInt()` clamps a `u64` to `i64::MAX`, which is far past it), and
/// the call sits inside the receipt's build — so one nonsense header would
/// replace the user's only record of a send that has already left, txid
/// included, with an error widget. Out of range therefore reads as *no time*,
/// which is a state the surface already renders correctly.
fn chain_stamp(ms: u64) -> Option<u64> {
    /// `DateTime`'s own ceiling: 100,000,000 days either side of the epoch.
    const DART_MAX_MS: u64 = 8_640_000_000_000_000;
    (ms != 0 && ms <= DART_MAX_MS).then_some(ms)
}

/// Mirror the chain crate's `TxStatus` for display (nothing recomputed).
fn tx_status_dto(status: kaspaverse_chain::TxStatus) -> TxStatusDto {
    use kaspaverse_chain::TxStatus;
    match status {
        TxStatus::Submitted => TxStatusDto {
            kind: TxStatusKind::Submitted,
            blue_depth: None,
            waited_ms: None,
            accepted_unix_ms: None,
        },
        TxStatus::Accepted {
            blue_depth,
            accepted_unix_ms,
        } => TxStatusDto {
            kind: TxStatusKind::Accepted,
            blue_depth: Some(blue_depth),
            waited_ms: None,
            accepted_unix_ms: chain_stamp(accepted_unix_ms),
        },
        TxStatus::Confirmed {
            blue_depth,
            accepted_unix_ms,
        } => TxStatusDto {
            kind: TxStatusKind::Confirmed,
            blue_depth: Some(blue_depth),
            waited_ms: None,
            accepted_unix_ms: chain_stamp(accepted_unix_ms),
        },
        TxStatus::Displaced => TxStatusDto {
            kind: TxStatusKind::Displaced,
            blue_depth: None,
            waited_ms: None,
            accepted_unix_ms: None,
        },
        TxStatus::Stalled { waited_ms } => TxStatusDto {
            kind: TxStatusKind::Stalled,
            blue_depth: None,
            waited_ms: Some(waited_ms),
            accepted_unix_ms: None,
        },
    }
}

/// Incremental thread pull (V2): decrypt ONLY the rows strictly after
/// `after_txid` in the store's `(unix_ms, txid)` order, and return the
/// current status of EVERY row so status transitions of already-rendered
/// rows (tombstone flips, acceptance progress) land without re-decrypting
/// the conversation. Cursor semantics:
///
/// - rows are write-once (`unix_ms`/`txid` never change after recording), so
///   a cursor's sort position is stable;
/// - an absent or UNKNOWN cursor (e.g. the anchor row was removed) degrades
///   to the full thread — the caller keys rows by txid, so the merge is
///   idempotent, never duplicating;
/// - a new row CAN sort behind a live cursor (inbound handshake rows carry
///   the sender-claimed `payload.timestamp`; same-ms txid tie-breaks) and
///   would then be absent from `messages` — but never from `statuses`,
///   which covers every row. THE CALLER CONTRACT: a statuses txid you have
///   never rendered means a stranded row — do one full re-pull (cursor
///   `None`), whose statuses ⊇ all rows, so it converges in one step
///   (consensus-audit V2 finding 1; the thread screen implements this).
///
/// §0.4 unchanged: decrypt-on-view, per call, vault-locked errors, plaintext
/// crosses once and dies with the widget. The tracker is a soft dependency
/// (V1 law): unavailable ⇒ `acceptance: None`, store truth stands alone.
pub async fn transport_thread_since(
    conversation_id: String,
    after_txid: Option<String>,
) -> Result<ThreadDeltaDto, AppError> {
    // Resolve the tracker BEFORE taking the store lock — never hold a std
    // MutexGuard across an await (mirrors dag_monitor.rs / wallet.rs).
    let tracker = super::dag::shared_tracker().await.ok();

    let hub = hub()?;
    let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let conversation = store
        .conversation(&conversation_id)
        .ok_or_else(|| AppError::msg("conversation not found"))?;
    let bound: KeySlot = (
        to_core_branch(conversation.bound_branch),
        conversation.bound_index,
    );

    let records = store.messages_for(&conversation_id);
    let start = tail_start(&records, after_txid.as_deref());

    let statuses = records
        .iter()
        .map(|record| MessageStatusDto {
            txid: record.txid.clone(),
            tombstoned: store.is_message_tombstoned(&record.txid),
            acceptance: tracker
                .as_ref()
                .and_then(|t| t.status(&record.txid))
                .map(tx_status_dto),
        })
        .collect();

    let mut messages = Vec::new();
    for record in records.into_iter().skip(start) {
        let tombstoned = store.is_message_tombstoned(&record.txid);
        messages.push(thread_row(&hub, bound, record, tombstoned)?);
    }
    Ok(ThreadDeltaDto { messages, statuses })
}

/// The tracker's live answer for one txid (V2 sitting request: the chip
/// streams "N confirmations"). Depth is computed AT READ from the live sink
/// blue score (node-read, INV-9 — `AcceptanceTracker::status`), so a 1 Hz
/// poll of this fn yields a climbing counter. `None` = unwatched / pruned /
/// tracker unavailable — the caller's chip simply doesn't count.
pub async fn tx_acceptance_status(txid: String) -> Result<Option<TxStatusDto>, AppError> {
    let Ok(tracker) = super::dag::shared_tracker().await else {
        return Ok(None);
    };
    Ok(tracker.status(&txid).map(tx_status_dto))
}

/// Where the decrypt tail begins for an incremental pull: strictly after the
/// cursor row in the store's `(unix_ms, txid)` sort order. An absent or
/// UNKNOWN cursor (anchor removed / foreign txid) yields 0 — the full thread,
/// which a txid-keyed caller merges idempotently. Pure; tested.
fn tail_start(records: &[MessageRecord], after_txid: Option<&str>) -> usize {
    after_txid
        .and_then(|txid| records.iter().position(|r| r.txid == txid))
        .map(|i| i + 1)
        .unwrap_or(0)
}

/// Split a decrypted comm body into its display text and any recognized `kv:1:`
/// frame. Pure and total — `core::frames::parse` never touches value-bearing
/// state, so a forged frame changes only this display DTO (§0.3). A plain
/// message or an unknown/forward-version tail carries no frame and renders as
/// an ordinary bubble; a recognized frame's readable line becomes the text (the
/// machine tail stays out of Dart) with the card fields taken from the JSON.
fn split_frame(body: &str) -> (String, Option<FrameDto>) {
    match frames::parse(body) {
        frames::Parsed::Plain(text) => (text, None),
        frames::Parsed::Unknown { line } => (line, None),
        frames::Parsed::Frame(f) => (f.line.clone(), Some(frame_dto(f))),
    }
}

fn frame_dto(f: frames::KvFrame) -> FrameDto {
    FrameDto {
        kind: f.kind.as_token().to_string(),
        game: clamp_display(f.game),
        stake: clamp_display(f.stake),
        // A challenge's own id, or the id an accept/result references.
        id: clamp_display(f.id.or(f.ref_id)),
        detail: clamp_display(f.detail),
    }
}

/// Bound a counterparty-controlled frame field before it crosses to the card.
/// A frame binds no value and is already tx-mass-bounded on the wire, so this is
/// display defence-in-depth (wallet-security/ux P2.4 note) — a hostile inbound
/// frame can't inject an over-long string into a card. Char-wise (never splits a
/// UTF-8 code point); matches the build-side `core::frames` field cap.
fn clamp_display(field: Option<String>) -> String {
    const MAX: usize = 64;
    let s = field.unwrap_or_default();
    if s.chars().count() > MAX {
        s.chars().take(MAX).collect()
    } else {
        s
    }
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
            .decrypt_scanning(hub.keys().slots.iter().copied(), envelope)
            .map(|(_, plaintext)| plaintext),
        other => other,
    }
}

/// Sparse, content-free conversation-change pings (a conversation id) —
/// Dart re-pulls [`transport_conversations`] / [`transport_thread`] on each.
/// Nothing decrypted ever streams (§0.4: no Dart state manager holds content).
pub async fn subscribe_thread_pings(sink: StreamSink<String>) -> Result<(), AppError> {
    let mut pings = thread_pings().subscribe();
    log::info!("transport: ping subscriber attached");
    tokio::spawn(async move {
        loop {
            match pings.recv().await {
                Ok(conversation_id) => {
                    if sink.add(conversation_id).is_err() {
                        // Three lights (V3/L55): a dead Dart listener is loud —
                        // a silent one is where a frozen thread list hides.
                        log::warn!("transport: ping sink detached — forwarding stopped");
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

/// Subscribe to live `ciph_msg:`/`kchat:` matches as the message walk folds
/// them (accepted transactions, LINK-Q3). Discrete deliveries, not snapshots:
/// there is deliberately no cached-latest replay (unlike
/// `subscribe_dag_updates`) — history is the P2.3 message store's job; this
/// stream is the live wire, for the dev panel. Foreground-only by
/// construction: the walk rides the shared socket's `dag_pause()`/
/// `dag_resume()` posture (D-053).
pub async fn subscribe_transport_events(
    sink: StreamSink<TransportEventDto>,
) -> Result<(), AppError> {
    let monitor = dag::shared_monitor().await?;
    let mut events = monitor.subscribe_transport();
    log::info!("transport: event subscriber attached");
    // Runs on FRB's tokio runtime; exits when the Dart listener goes away
    // (sink.add fails) — e.g. on hot restart, leaving the connection up (L4).
    tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(event) => {
                    if sink.add(to_dto(event)).is_err() {
                        // Three lights (V3/L55): the live wire's Dart listener
                        // died — messages now arrive only via store catch-up.
                        log::warn!("transport: event sink detached — forwarding stopped");
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

    /// **A skip's reading is the node's own clock** (LINK-Q4, `consensus-
    /// auditor` round 1): the span between the two blocks' times; nothing when
    /// the landing is not ahead of the cursor; a pruned start is beyond the
    /// horizon; an unanswered read is an unknown length — never "pruned".
    #[test]
    fn a_skip_is_read_by_the_nodes_own_block_times() {
        use BlockTime::*;
        let reading =
            skip_reading(Known(1_000, 10), Known(1_000 + 69 * 60_000, 41_410)).expect("a skip");
        assert_eq!(
            (reading.gap_minutes, reading.beyond_horizon, reading.skipped),
            (Some(69), false, true)
        );
        assert!(
            skip_reading(Known(5_000, 50), Known(5_000, 50)).is_none(),
            "landed where it was"
        );
        assert!(
            skip_reading(Known(5_000, 50), Known(9_000, 40)).is_none(),
            "behind the cursor"
        );
        // A real skip onto a block stamped EARLIER (a cursor block from the
        // future, inside the pin's 132 s tolerance): DAA says ahead.
        let early = skip_reading(Known(90_000, 50), Known(30_000, 700)).expect("a skip");
        assert_eq!((early.gap_minutes, early.skipped), (Some(0), true));
        let pruned = skip_reading(Pruned, Known(9, 9)).expect("a skip");
        assert!(pruned.beyond_horizon && pruned.gap_minutes.is_none());
        for (from, to) in [
            (Unknown, Known(9, 9)),
            (Known(9, 9), Unknown),
            (Unknown, Unknown),
            (Known(9, 9), Pruned),
        ] {
            let unknown = skip_reading(from, to).expect("a skip");
            assert!(
                !unknown.beyond_horizon && unknown.gap_minutes.is_none() && unknown.skipped,
                "{from:?} → {to:?}: unknown, never pruned"
            );
        }
    }

    /// **A skip after a completed fill un-heals the notice** (`wallet-security-
    /// auditor`, round 1 note): the fill covered what was missing at the
    /// open, not a span the walk skipped later. The only test that touches
    /// these two globals.
    #[test]
    fn a_skip_after_a_completed_fill_reads_incomplete() {
        *LAST_FILL.lock().unwrap_or_else(PoisonError::into_inner) = Some(FillReportDto {
            ran: true,
            complete: true,
            pages: 3,
            new_rows: 1,
            error: None,
            at_unix_ms: 1,
        });
        *GAP_AGE.lock().unwrap_or_else(PoisonError::into_inner) = None;
        let before = WALK_SKIPS.load(std::sync::atomic::Ordering::SeqCst);
        assert!(!walk_skipped_since(before));
        fold_skip(GapAgeDto {
            gap_minutes: Some(7),
            beyond_horizon: false,
            skipped: true,
        });
        let report = LAST_FILL
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
            .unwrap();
        assert!(!report.complete, "no longer reads healed");
        assert!(walk_skipped_since(before));
        let run = |complete| FillReportDto {
            ran: true,
            complete,
            pages: 5,
            new_rows: 2,
            error: None,
            at_unix_ms: 2,
        };
        assert!(
            !store_fill_report(run(true), before).complete,
            "a fill that read the count before the skip does not read complete"
        );
        assert!(
            !LAST_FILL
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone()
                .unwrap()
                .complete
        );
        let now = WALK_SKIPS.load(std::sync::atomic::Ordering::SeqCst);
        assert!(
            store_fill_report(run(true), now).complete,
            "one that began after it is whole"
        );
        // Through the run's own seam: a skip while the walk runs.
        let runtime = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap();
        let skipped_mid_walk = runtime.block_on(counted_fill(async {
            fold_skip(GapAgeDto {
                gap_minutes: Some(2),
                beyond_horizon: false,
                skipped: true,
            });
            run(true)
        }));
        assert!(!skipped_mid_walk.complete, "a skip mid-walk: incomplete");
        assert!(runtime.block_on(counted_fill(async { run(true) })).complete);
        assert_eq!((report.pages, report.new_rows), (3, 1), "its record kept");
        let gap = transport_gap_age().expect("a gap");
        assert_eq!((gap.gap_minutes, gap.skipped), (Some(7), true));
    }

    /// **The notice widens and never narrows** (LINK-Q4): the open's own
    /// reading and every later skip fold into one — the longer span, a pruned
    /// cursor anywhere, a skip anywhere; an unknown length never erases a
    /// known one.
    #[test]
    fn a_gap_reading_widens_the_notice_and_never_narrows_it() {
        let gap = |minutes: Option<u64>, beyond_horizon: bool, skipped: bool| GapAgeDto {
            gap_minutes: minutes,
            beyond_horizon,
            skipped,
        };
        let open = gap(Some(136), false, false);
        let skip = gap(Some(69), false, true);
        let merged = merged_gap(Some(open), skip);
        assert_eq!(merged.gap_minutes, Some(136), "the longer span");
        assert!(merged.skipped, "a skip anywhere");
        assert!(!merged.beyond_horizon);
        let merged = merged_gap(Some(merged), gap(None, true, true));
        assert_eq!(
            merged.gap_minutes,
            Some(136),
            "an unknown length erases nothing"
        );
        assert!(merged.beyond_horizon, "a pruned cursor anywhere");
        let first = merged_gap(None, gap(Some(5), false, true));
        assert_eq!((first.gap_minutes, first.skipped), (Some(5), true));
        let quiet = merged_gap(Some(gap(Some(5), false, true)), gap(Some(3), false, false));
        assert!(quiet.skipped, "a later reading never clears a skip");
    }

    /// The row's second line is shaped for a list, not for a thread: one
    /// line, bounded, and never blank where a message exists.
    #[test]
    fn a_preview_is_one_collapsed_line_inside_the_custody_bound() {
        assert_eq!(
            bound_preview("Got it, thank you — confirmed on my side"),
            Some("Got it, thank you — confirmed on my side".to_string())
        );
        // A multi-line message cannot forge a second row.
        assert_eq!(
            bound_preview("first line\nsecond line"),
            Some("first line second line".to_string())
        );
        // Runs of padding do not get to spend the budget.
        assert_eq!(
            bound_preview("   spaced   out   "),
            Some("spaced out".to_string())
        );
        // Whitespace alone is no news at all — the row shows its state.
        assert!(bound_preview("").is_none());
        assert!(bound_preview("  \n\t ").is_none());

        // The bound holds, and the marker says it was cut.
        let long = "x".repeat(PREVIEW_CHARS + 40);
        let cut = bound_preview(&long).expect("a long body still previews");
        assert_eq!(cut.chars().count(), PREVIEW_CHARS + 1);
        assert!(cut.ends_with('…'));
        // Exactly at the bound is NOT cut — an off-by-one here would put an
        // ellipsis on a message that fits.
        let exact = "y".repeat(PREVIEW_CHARS);
        assert_eq!(bound_preview(&exact), Some(exact));
    }

    /// The cut is char-wise. A byte-wise slice of a multi-byte body panics,
    /// and the bodies here are written by strangers.
    #[test]
    fn a_preview_never_cuts_inside_a_code_point() {
        // Emoji are 4 bytes each: a byte-wise take would land mid-sequence.
        let body = "🙂".repeat(PREVIEW_CHARS + 10);
        let cut = bound_preview(&body).expect("previewed");
        assert_eq!(cut.chars().count(), PREVIEW_CHARS + 1);
        assert!(cut.starts_with('🙂'));
        // And a body whose characters are wider than one byte still counts in
        // characters, not bytes — otherwise a Japanese message would be cut to
        // a third of a Latin one.
        let jp = "あ".repeat(40);
        assert_eq!(bound_preview(&jp), Some(jp));
    }

    /// **All four arms of the only ceremony-free broadcast door.**
    ///
    /// This is the gate that stands where a confirm sheet used to, so each arm
    /// is exercised rather than asserted about — the checklist's own point: an
    /// untested refusal is a refusal nobody has seen fire.
    #[test]
    fn the_unceremonious_gate_refuses_every_way_it_can() {
        let own = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf";
        let other = "kaspa:qqcwl7zlmt6d3cwwvmsdkktfnkd2r0mzx4pu4xcvfdfpnukka7ezy4zn86jlr";
        let plan = |kind: SignableKind, destination: &str, fee: u64| SignableSummaryDto {
            nonce: 1,
            kind,
            destination: destination.to_string(),
            amount_sompi: 20_000,
            fee_sompi: fee,
            total_sompi: 20_000 + fee,
            mass: 2036,
            tx_count: 1,
            utxo_count: 1,
            resulting_coins: 0,
            payload_len: Some(214),
            payload_kind: Some("comm".to_string()),
            fee_strategy: crate::api::send::FeeStrategyKind::SenderPays,
            priority_fee_sompi: 0,
            typical_amount_sompi: None,
            typical_now_utxos: None,
            typical_now_fee_sompi: None,
            typical_after_fee_sompi: None,
        };
        let ok = plan(SignableKind::SelfSendFrame, own, 14_300);

        // The whole point: an ordinary message, with the preference off, goes.
        assert!(unceremonious_refusal(&ok, own, false).is_none());

        // 1. The preference still says confirm — refused even though the plan
        //    is otherwise perfect. A caller that skipped the sheet is a bug.
        assert_eq!(
            unceremonious_refusal(&ok, own, true).map(|r| r.kind),
            Some(UncerimoniousRefusal::PREFERENCE)
        );

        // 2. Not a self-send frame. A bond, a refund and a payment all land
        //    here — the acceptance especially, which moves a counterparty's
        //    money and must never leave without being confirmed.
        for kind in [
            SignableKind::Bond,
            SignableKind::BondRefund,
            SignableKind::Payment,
            SignableKind::Bcast,
        ] {
            assert_eq!(
                unceremonious_refusal(&plan(kind, own, 14_300), own, false).map(|r| r.kind),
                Some(UncerimoniousRefusal::KIND),
                "{kind:?} must never send without confirming"
            );
        }

        // 3. Built to pay somebody who is not this conversation's own bound
        //    address — refused with the money still in the wallet.
        assert_eq!(
            unceremonious_refusal(
                &plan(SignableKind::SelfSendFrame, other, 14_300),
                own,
                false
            )
            .map(|r| r.kind),
            Some(UncerimoniousRefusal::DESTINATION)
        );

        // 4. The ceiling, on both sides of it. AT the ceiling still passes —
        //    the bound is "more than", and an off-by-one here would refuse a
        //    send the constant says is fine.
        let ceiling = MessagePrefs::UNCEREMONIOUS_FEE_CEILING;
        assert!(unceremonious_refusal(
            &plan(SignableKind::SelfSendFrame, own, ceiling),
            own,
            false
        )
        .is_none());
        assert_eq!(
            unceremonious_refusal(
                &plan(SignableKind::SelfSendFrame, own, ceiling + 1),
                own,
                false
            )
            .map(|r| r.kind),
            Some(UncerimoniousRefusal::FEE)
        );
    }

    /// No refusal from this door may prescribe the sheet the user has turned
    /// off — the caller opens it instead (`thread_screen._send`).
    #[test]
    fn a_post_build_refusal_never_prescribes_a_control_the_user_removed() {
        assert!(!UNCEREMONIOUS_NEEDS_CONFIRMING.contains("sheet"));
        // The preference arm MAY name it: in that state the sheet is on.
        assert!(UNCEREMONIOUS_OFF.contains("sheet"));
    }

    /// The one bound the founder's toggle rests on: with the confirm sheet
    /// off, the ceiling has to print as a figure the refusal can say out loud.
    ///
    /// The two INEQUALITIES that place it — above an ordinary message's fee
    /// and an order of magnitude under the handshake bond — are `const`
    /// assertions beside the constant itself, where they fail at compile time
    /// rather than in a test run (a runtime `assert!` over two constants is
    /// also what clippy's `assertions_on_constants` objects to, correctly:
    /// nothing about it needs a test binary).
    #[test]
    fn the_unceremonious_ceiling_prints_as_a_figure_a_refusal_can_state() {
        assert_eq!(
            format_kas(MessagePrefs::UNCEREMONIOUS_FEE_CEILING),
            "0.05000000"
        );
    }

    /// A block header timestamp is whatever the answering node said, and
    /// nothing upstream bounds it. Dart's `DateTime.fromMillisecondsSinceEpoch`
    /// THROWS outside 100,000,000 days either side of the epoch, and the
    /// ceremony calls it inside the receipt's own `build` — so one nonsense
    /// header would replace the user's only record of a send that has already
    /// left, txid included, with an error widget. Out of range must therefore
    /// read as *no time*, which the surface already renders correctly
    /// (`wallet-security-auditor`, UX-4B).
    ///
    /// The two bounds are Dart's, measured rather than remembered: 8.64e15 ms
    /// renders as 275760-09-13, 8.64e15 + 1 throws `RangeError`, and a `u64`
    /// arrives via `BigInt.toInt()` which clamps to `i64::MAX` — also a throw.
    #[test]
    fn a_chain_stamp_outside_dart_s_range_reads_as_no_time() {
        // Zero is the accepting block being unfetchable: no time, not 1970.
        assert_eq!(chain_stamp(0), None);
        assert_eq!(chain_stamp(1), Some(1));
        // A real acceptance passes through untouched.
        assert_eq!(chain_stamp(883_612_800_000), Some(883_612_800_000));
        // The ceiling itself is admissible; one millisecond past it is not.
        assert_eq!(
            chain_stamp(8_640_000_000_000_000),
            Some(8_640_000_000_000_000)
        );
        assert_eq!(chain_stamp(8_640_000_000_000_001), None);
        assert_eq!(chain_stamp(u64::MAX), None);
    }

    /// The confinement ceiling counts only coins that can actually PIN
    /// (closure-audit F-1 / L129): covenant dust on the bound address must
    /// never raise the ceiling the built chain is judged against, or a draw
    /// beyond the pin passes as confined.
    #[test]
    fn confinement_ceiling_ignores_covenant_dust() {
        let free = UtxoEntryReference::simulated(1_000);
        let mut cov_utxo = (*UtxoEntryReference::simulated(5_000).utxo).clone();
        cov_utxo.covenant_id = Some(cov_utxo.outpoint.transaction_id());
        let cov = UtxoEntryReference::from(cov_utxo);
        assert_eq!(confinement_ceiling(std::slice::from_ref(&free)), 1);
        assert_eq!(
            confinement_ceiling(&[free, cov]),
            1,
            "covenant dust never raises the confinement ceiling"
        );
    }

    /// FLOOR BEFORE BUMP. This ordering BLOCKED twice in one sitting and was
    /// argued in four paragraphs of prose with nothing asserting it.
    ///
    /// Bump-then-floor leaves a window the width of the whole erase body: a
    /// fill walk starting inside it reads the NEW generation and the PRE-floor
    /// cursors, matches every guard it later meets, folds our own on-chain
    /// backup into the emptied store, and saves floor-0 cursors over the top.
    /// The observation point is inside the mutate closure — the only place that
    /// can see the ordering rather than infer it.
    #[test]
    fn seal_erasure_stamps_the_floor_before_it_bumps_the_generation() {
        let (_guard, _dir) = crate::api::vault::tests::enter();
        let before = erase_epoch();

        let mut epoch_during_floor = None;
        let persisted = seal_erasure(|cursors| {
            epoch_during_floor = Some(erase_epoch());
            cursors.raise_floor(4_242);
        });

        assert!(
            persisted,
            "the floor must be durable for the flag to be true"
        );
        assert_eq!(
            epoch_during_floor,
            Some(before),
            "the generation must still be the OLD one while the floor is written — \
             bumping first was the round-4 BLOCK"
        );
        assert_eq!(erase_epoch(), before + 1, "and bumped exactly once after");

        let dir = vault::transport_store_dir().unwrap();
        assert_eq!(
            kaspaverse_chain::history_fill::FillCursors::load(&dir).floor_unix_ms,
            4_242,
            "the floor is on disk, not merely in the closure"
        );

        // THE PROPERTY THAT ACTUALLY PROTECTS THE WALK: a start taken through
        // the same door the walk uses sees the new generation AND the floored
        // cursors together. Asserting the closure's view alone would still pass
        // with the bump moved between `mutate` and `save` — which re-opens the
        // window in full, because the walk reads the cursors from DISK.
        let (walk_epoch, walk_cursors) = gated_walk_start(&dir);
        assert_eq!(walk_epoch, before + 1);
        assert_eq!(
            walk_cursors.floor_unix_ms, 4_242,
            "a walk that sees the new generation must also see the floor — \
             seeing one without the other is the whole race"
        );
    }

    /// THE GATE, ON REAL THREADS — the property the single-threaded test above
    /// cannot reach.
    ///
    /// An observer that sees generation N must see the floor generation N
    /// stamped. Seeing one without the other IS the race: a walk holding
    /// pre-floor cursors under a post-floor epoch matches every guard it later
    /// meets and writes its stale cursors back over the erase.
    ///
    /// Seal `i` stamps floor `i * 1000` and bumps to `base + i`, so the
    /// invariant is checkable from the pair alone, with no shared bookkeeping
    /// between the threads.
    #[test]
    fn a_walk_can_never_see_a_generation_without_its_floor() {
        let (_guard, _dir) = crate::api::vault::tests::enter();
        let dir = vault::transport_store_dir().unwrap();
        let base = erase_epoch();

        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let reader_stop = stop.clone();
        let reader_dir = dir.clone();
        let reader = std::thread::spawn(move || {
            let mut observations = 0u32;
            while !reader_stop.load(std::sync::atomic::Ordering::SeqCst) {
                let (epoch, cursors) = gated_walk_start(&reader_dir);
                let seen = epoch - base;
                assert!(
                    cursors.floor_unix_ms >= seen * 1_000,
                    "observed generation {seen} with floor {} — a walk saw a                      generation without the floor that generation stamped",
                    cursors.floor_unix_ms
                );
                observations += 1;
            }
            observations
        });

        // Through `catch_unwind`, so a failing assertion here still STOPS and
        // JOINS the reader. Left to unwind, the reader survives the test as a
        // detached thread spinning on `ERASE_GATE` and a file read, then panics
        // on its own against a frozen floor — a second failure attributed to no
        // test, on a gate that is already red. The one arbiter of "done" does
        // not get to be confusing (INV-10).
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            for i in 1..=200u64 {
                assert!(seal_erasure(|c| {
                    c.raise_floor(i * 1_000);
                }));
            }
        }));
        stop.store(true, std::sync::atomic::Ordering::SeqCst);
        let observations = reader.join().expect("the reader must not have panicked");
        if let Err(panic) = outcome {
            std::panic::resume_unwind(panic);
        }

        assert!(
            observations > 0,
            "the reader has to have actually looked, or this proves nothing"
        );
        assert_eq!(erase_epoch(), base + 200);
    }

    /// Two erases racing must be order-free, because nothing serialises the
    /// USER's taps: `raise_floor` is a `max`, so the later floor wins and an
    /// out-of-order pair can never walk the floor backwards.
    #[test]
    fn erasures_are_idempotent_and_never_lower_the_floor() {
        let (_guard, _dir) = crate::api::vault::tests::enter();
        let before = erase_epoch();

        assert!(seal_erasure(|c| {
            c.raise_floor(9_000);
        }));
        assert!(seal_erasure(|c| {
            c.raise_floor(1_000);
        }));

        let dir = vault::transport_store_dir().unwrap();
        assert_eq!(
            kaspaverse_chain::history_fill::FillCursors::load(&dir).floor_unix_ms,
            9_000,
            "a later erase with an earlier clock must not hand back erased history"
        );
        assert_eq!(
            erase_epoch(),
            before + 2,
            "every erase bumps, even a no-op one"
        );
    }

    /// Finding 7, second half (V5): the transport prepare path classifies an
    /// `InsufficientFunds` refusal through the SAME shortfall classifier as
    /// the payment path — settling change (`outgoing`) reads as "still
    /// settling", maturing deposits (`pending`) as "not yet spendable", and
    /// an amount nothing in flight could cover as a true shortfall. The
    /// non-funds arms keep their compose-surface copy untouched.
    #[test]
    fn insufficient_funds_routes_through_the_shortfall_classifier() {
        let funds = |mature, pending, outgoing| {
            friendly_prepare_error(
                ChainError::InsufficientFunds {
                    additional_needed: 1,
                },
                50,
                mature,
                pending,
                outgoing,
            )
            .message
        };
        // Change from our own last send is on its way back.
        assert!(funds(10, 0, 45).contains("still settling from your last send"));
        // A maturing deposit covers it.
        assert!(funds(10, 45, 0).contains("not yet spendable"));
        // Nothing in flight could ever cover it — the honest refusal.
        assert!(funds(10, 5, 5).contains("insufficient funds"));
        // Non-funds arms keep their own compose-surface copy.
        assert!(
            friendly_prepare_error(ChainError::TransactionTooHeavy, 50, 0, 0, 0)
                .message
                .contains("too large for one transaction")
        );
        assert!(friendly_prepare_error(
            ChainError::StorageMassExceeded { storage_mass: 9 },
            50,
            0,
            0,
            0
        )
        .message
        .contains("anti-dust rule"));
    }

    /// Finding 15 (V5): the expiry discriminator flips EXACTLY past the
    /// pin-read pruning horizon — at the horizon the transient copy is still
    /// truthful; one ms past it the invitation is permanently dead. Only a
    /// PendingInbound row can expire, and a future-dated clock (skew) never
    /// expires anything (saturating).
    #[test]
    fn invite_expiry_flips_exactly_past_the_pinned_horizon() {
        let horizon = kaspaverse_chain::pruning_horizon_ms();
        let created = 1_000_000_u64;
        let pending = ConversationStatus::PendingInbound;
        assert!(!invite_expired(pending, created, created + horizon));
        assert!(invite_expired(pending, created, created + horizon + 1));
        assert!(!invite_expired(
            ConversationStatus::Active,
            created,
            created + horizon + 1
        ));
        assert!(!invite_expired(
            ConversationStatus::PendingOutbound,
            created,
            created + horizon + 1
        ));
        assert!(!invite_expired(pending, created + 10, created));
    }

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
            namespace: WireNamespace::CiphMsg,
            body: b"kv-dev:hi".to_vec(),
            addresses: vec!["kaspa:qz...".into()],
            block_time_ms: None,
            block_hash: None,
            sender: None,
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

    /// A minimal comm record for cursor tests — envelope bytes never opened
    /// (tail_start reads only txid/ordering).
    fn rec(txid: &str, unix_ms: u64) -> MessageRecord {
        MessageRecord {
            txid: txid.to_string(),
            conversation_id: "c1".to_string(),
            direction: MessageDirection::Outbound,
            kind: StoredKind::Comm,
            envelope: Vec::new(),
            unix_ms,
            alias_on_wire: None,
            sealed_to: None,
            provenance: RowSource::Own,
            wire: WireNamespace::CiphMsg,
        }
    }

    /// The V2 cursor law (`transport_thread_since`): strictly-after on a known
    /// anchor; full thread on an absent or unknown one (idempotent for a
    /// txid-keyed caller); a cursor at the tail yields an empty pull.
    #[test]
    fn tail_start_resolves_the_cursor_edge_cases() {
        let records = vec![rec("aa", 10), rec("bb", 20), rec("cc", 30)];

        // No cursor → the whole thread.
        assert_eq!(tail_start(&records, None), 0);
        // A known anchor → strictly after it.
        assert_eq!(tail_start(&records, Some("aa")), 1);
        assert_eq!(tail_start(&records, Some("bb")), 2);
        // The newest row as anchor → nothing new (empty tail).
        assert_eq!(tail_start(&records, Some("cc")), 3);
        // An unknown/removed anchor degrades to the full thread, never an
        // error and never a stranded gap.
        assert_eq!(tail_start(&records, Some("zz")), 0);
        // An empty thread tolerates any cursor.
        assert_eq!(tail_start(&[], Some("aa")), 0);
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
    /// place decrypted text may exist is the `thread_row` return path (shared
    /// by `transport_thread` and `transport_thread_since`).
    /// No `log::`/`tracing` call in this file may reference a plaintext,
    /// text, or body binding — reviewed by ffi-leak; this test scans every
    /// log call the module has (content words, not an allowlist).
    ///
    /// **It scans the whole MACRO, not the line `log::` appears on**, and that
    /// is a correction. It used to check one line, while nearly every log call
    /// in this file wraps — so the format string, where the identifiers
    /// actually are, sat on the lines it never looked at. Discovered by
    /// red-proving the widened word list: an injected
    /// `contact_address {dest}` line passed a guard written to forbid exactly
    /// that. A tripwire nobody has tried to trip is a hope, not a check
    /// (PB-031).
    ///
    /// **What it is not:** a proof. It knows the identifier NAMES this module
    /// uses, so a log line that binds an address to a differently-named local
    /// and prints that still passes. It is a tripwire for the mistake people
    /// actually make — reaching for the variable that is in scope — and the
    /// review is still the authority. Said plainly here because overclaiming a
    /// guard's reach is the thing this very change was fixing.
    #[test]
    fn module_logs_are_lifecycle_only() {
        let source = include_str!("transport.rs");
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
            calls.len() > 20,
            "the scanner found only {} log calls — it has stopped matching",
            calls.len()
        );
        // WIDENED AGAIN (`ffi-leak-auditor`, 2026-09-08): `preview` is a
        // plaintext-bearing name this module did not have until D-303, and it
        // is now a FIELD that crosses the FFI — so the guard has to know the
        // word or a future `log::warn!("preview {preview}")` walks past it.
        // Checked before adding: no existing log line in this module contains
        // a whole-word `preview` (`wipe_preview` and `fee_preview_pinned` are
        // `_`-joined and fail the boundary test), so this is a widening with
        // no false positives.
        const CONTENT: [&str; 4] = ["text", "plaintext", "body", "preview"];
        // WIDENED (`ffi-leak-auditor`, 2026-08-17). The original words caught
        // message BODIES and nothing else, while §4's discipline is that
        // identities stay out of logcat too — an address ties the device to an
        // on-chain identity, and in this lane a conversation id and an alias
        // are routing identities.
        const IDENTITY: [&str; 3] = ["conversation_id", "contact_address", "alias"];

        for call in calls {
            // What is EMITTED is the format string. Split it off so an
            // argument can be judged by a different rule.
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

            // An argument may MEASURE an identity — `conversation_id.is_empty()`
            // emits a bool and is the three-lights sentinel — but may never
            // pass one whole. The projection is the whole distinction, so it is
            // what the check looks for.
            // WHOLE identifiers only. `sanitize_node_text` is a sanitizer, not
            // a body, and matching "text" inside it would train the next reader
            // to silence the guard rather than answer it.
            let is_boundary = |c: Option<char>| !c.is_some_and(|c| c.is_alphanumeric() || c == '_');
            let occurrences = |haystack: &str, word: &str| -> Vec<usize> {
                let mut out = Vec::new();
                let bytes = haystack.as_bytes();
                for (at, _) in haystack.match_indices(word) {
                    let before = haystack[..at].chars().next_back();
                    let after = haystack[at + word.len()..].chars().next();
                    // A trailing `.` or `(` still counts as a boundary — that
                    // is the projection case, judged below.
                    if is_boundary(before) && (is_boundary(after) || after == Some('.')) {
                        let _ = bytes;
                        out.push(at);
                    }
                }
                out
            };
            // In the format string what matters is INLINE CAPTURE — `{alias}`
            // emits the value; "learned a contact's alias" is prose, and a log
            // lane that cannot say what it did in English is a worse lane.
            for word in CONTENT.iter().chain(IDENTITY.iter()) {
                for opener in [format!("{{{word}}}"), format!("{{{word}:")] {
                    assert!(
                        !format.contains(&opener),
                        "a log's FORMAT STRING captures {word}: {call}"
                    );
                }
            }
            // ONE rule for both lists: an argument may MEASURE the thing —
            // `plaintext.len()`, `conversation_id.is_empty()` — and may never
            // pass it whole. The projection is the entire distinction between a
            // shape and a leak (§4), so it is exactly what is checked.
            // The two functions whose entire job is to turn content into a
            // shape. NAMED, not pattern-matched, so adding a third is a
            // deliberate act a reviewer sees in the diff rather than a regex
            // quietly widening.
            const SHAPERS: [&str; 2] = ["describe_shape(", "sanitize_node_text("];
            for word in CONTENT.iter().chain(IDENTITY.iter()) {
                for at in occurrences(args, word) {
                    let after = &args[at + word.len()..];
                    // MEASURED — `plaintext.len()`, `conversation_id.is_empty()`.
                    if after.starts_with('.') {
                        continue;
                    }
                    // Or SHAPED — handed to one of the two describers above.
                    let before = args[..at].trim_end().trim_end_matches('&');
                    assert!(
                        SHAPERS.iter().any(|shaper| before.ends_with(shaper)),
                        "a log ARGUMENT passes {word} whole rather than measuring \
                         or shaping it: {call}"
                    );
                }
            }
        }
    }

    /// A fill cursor must never step over a row the fold could not take.
    /// This is the 2026-08-13 loss in miniature: rows at 10 and 30 fold, the
    /// row at 20 is held, and the walk's own cursor says 30. Persisting 30
    /// would make the row at 20 unreachable forever, because the only query
    /// the indexer offers starts at a block time.
    #[test]
    fn held_rows_pin_the_resume_point_below_them() {
        let mut held = HeldFloor::new();
        assert_eq!(held.resume_from(30), 30, "nothing held ⇒ the walk's cursor");
        assert!(!held.any());

        held.hold(20);
        held.hold(25);
        assert_eq!(held.resume_from(30), 20, "the LOWEST held row wins");
        assert!(held.any());
        assert!(held.notice().is_some(), "an incomplete walk stays honest");

        // A hold above the walk cursor can never push the cursor forward.
        let mut ahead = HeldFloor::new();
        ahead.hold(99);
        assert_eq!(ahead.resume_from(30), 30);
    }

    /// THE DENIAL-OF-SERVICE LAW behind [`DropReason::outcome`]. A cursor that
    /// holds on attacker-mintable input is a weapon: anyone can seal an
    /// envelope to a published receive address that no key of ours opens, and
    /// if that pinned the walk, one dust transaction would stop our history
    /// fill permanently. Only OUR OWN transient conditions may hold it.
    #[test]
    fn only_our_own_transient_failures_hold_the_cursor() {
        // Attacker-mintable — must never pin the walk.
        for reason in [
            DropReason::NoKeyOpensIt,
            DropReason::MalformedEnvelope,
            DropReason::UndecodablePayload,
            DropReason::MalformedCommHead,
            DropReason::NoConversationForAlias,
            DropReason::AlreadyStored,
            DropReason::NoTxid,
            // The revival lane's three (D-307/D-308): a parked comm is the
            // node lane's to finish, a blocked alias and a spent budget are
            // attacker-driven — none may pin a fill cursor.
            DropReason::SenderPending,
            DropReason::BlockedContact,
            DropReason::RevivalBudgetSpent,
        ] {
            assert_eq!(
                reason.outcome(),
                FoldOutcome::Settled,
                "{reason:?} is attacker-mintable or settled — it must not hold the cursor"
            );
        }
        // Ours, and transient — the row is probably real, so hold and retry.
        for reason in [
            DropReason::VaultLocked,
            DropReason::StoreRace,
            DropReason::StoreFailed,
            DropReason::NotAddressedToUs,
        ] {
            assert!(
                reason.outcome().holds(),
                "{reason:?} is our own transient condition — the row must be retried"
            );
        }
    }

    /// THE SEND GATE, which four independent audit lanes found separately.
    ///
    /// Requiring `Active` was stricter than the protocol: sending needs our
    /// alias and their address, both of which a conversation we initiated
    /// already has. Against a counterparty who answers a repeat handshake
    /// idempotently — emitting nothing — `PendingOutbound` is a state we can
    /// never leave, so the old rule silenced a thread whose far side was open
    /// the whole time.
    #[test]
    fn we_may_speak_in_a_conversation_we_opened() {
        use ConversationStatus::{Active, PendingInbound, PendingOutbound};
        let addr = "kaspa:qqwsnxvu";
        let mine = "8caa5e3c79ff";

        // The case that was broken on the founder's device.
        assert!(comm_sendable(PendingOutbound, true, addr, mine));
        assert!(comm_sendable(Active, true, addr, mine));
        assert!(comm_sendable(Active, false, addr, mine));

        // Theirs to answer: accepting is where their bond is refunded, and
        // skipping it would take their money silently.
        assert!(!comm_sendable(PendingInbound, false, addr, mine));
        assert!(!comm_sendable(PendingInbound, true, addr, mine));

        // A pending-outbound row we did NOT initiate is not ours to speak in.
        assert!(!comm_sendable(PendingOutbound, false, addr, mine));

        // The emptiness guards are load-bearing, not decoration: an unaccepted
        // row carries neither field, and an empty alias head would go on
        // mainnet.
        assert!(!comm_sendable(Active, true, "", mine), "no contact address");
        assert!(
            !comm_sendable(Active, true, addr, ""),
            "no alias of our own"
        );
        assert!(!comm_sendable(PendingOutbound, true, "", ""));
    }

    /// A HANDSHAKE COMMIT MUST NOT UNDO WHAT ARRIVED WHILE IT WAS SIGNING.
    ///
    /// The snapshot is taken at prepare; the commit lands a whole confirm-and-
    /// sign ceremony later. On a retry to a contact we already have, that
    /// window is long enough for their acceptance to arrive or for an inbound
    /// message to teach us their alias — the exact repairs that unbreak a
    /// stuck conversation. Writing the snapshot back would silently undo them.
    #[test]
    fn a_commit_keeps_what_the_store_learned_while_we_were_signing() {
        fn row(id: &str) -> ConversationRecord {
            ConversationRecord {
                conversation_id: id.to_string(),
                contact_address: "kaspa:qqwsnxvu".to_string(),
                my_alias: "8caa5e3c79ff".to_string(),
                their_alias: None,
                status: ConversationStatus::PendingOutbound,
                initiated_by_me: true,
                bound_branch: KeyBranch::Receive,
                bound_index: 0,
                created_unix_ms: 10,
                last_activity_unix_ms: 10,
                handshake_txid: None,
            }
        }

        // Their alias landed mid-ceremony, the fold rebound the slot to the
        // key they actually seal to, and the row went Active.
        let snapshot = ConversationRecord {
            handshake_txid: Some("newtx".into()),
            last_activity_unix_ms: 99,
            ..row("c1")
        };
        let live = ConversationRecord {
            their_alias: Some("90b4a1b640eb".into()),
            status: ConversationStatus::Active,
            bound_branch: KeyBranch::Change,
            bound_index: 7,
            last_activity_unix_ms: 500,
            ..row("c1")
        };
        let merged = merge_handshake_commit(snapshot, &live);
        assert_eq!(merged.their_alias.as_deref(), Some("90b4a1b640eb"));
        assert_eq!(
            merged.status,
            ConversationStatus::Active,
            "live status wins"
        );
        assert_eq!(
            merged.bound_branch,
            KeyBranch::Change,
            "live slot wins (D-067)"
        );
        assert_eq!(merged.bound_index, 7);
        assert_eq!(merged.last_activity_unix_ms, 500, "clocks never regress");
        assert_eq!(
            merged.handshake_txid.as_deref(),
            Some("newtx"),
            "the broadcast txid is the one thing only the snapshot knows"
        );

        // Nothing learned: the snapshot stands unchanged.
        let quiet = merge_handshake_commit(
            ConversationRecord {
                handshake_txid: Some("newtx".into()),
                ..row("c1")
            },
            &row("c1"),
        );
        assert!(quiet.their_alias.is_none());
        assert_eq!(quiet.status, ConversationStatus::PendingOutbound);
        assert_eq!(quiet.bound_index, 0);
    }

    /// HIDE MEANS TWO DIFFERENT THINGS, and getting them the wrong way round
    /// is a money bug in one direction and a silent sink in the other.
    ///
    /// On a conversation you already have, hide is a MUTE: their next message
    /// brings it back. On an invitation you turned down it is a BLOCK: that
    /// card spends the bond refund, so a stranger must never be able to
    /// re-arm it by writing again — an exit the counterparty can revoke is no
    /// exit at all (INV-6).
    ///
    /// These are pure predicates precisely so they can be pinned here. The
    /// guard they replaced was inspected-correct and still wrong: it straddled
    /// a lock release, and the next person to move a call site would have
    /// regressed it in silence.
    #[test]
    fn a_dismissed_invitation_stays_dismissed_but_a_muted_contact_returns() {
        use ConversationStatus::{Active, PendingInbound, PendingOutbound};

        // A hidden CONTACT reopens on inbound traffic.
        assert!(may_unhide(Active, true));
        assert!(may_unhide(PendingOutbound, true));
        // A dismissed INVITATION never does.
        assert!(!may_unhide(PendingInbound, true));
        // Nothing to reopen when the row was never hidden.
        assert!(!may_unhide(Active, false));
        assert!(!may_unhide(PendingInbound, false));

        // The mirror predicate: only a hidden invitation's traffic is refused.
        assert!(comm_is_dismissed(PendingInbound, true));
        assert!(!comm_is_dismissed(PendingInbound, false), "live invitation");
        assert!(
            !comm_is_dismissed(Active, true),
            "a muted contact still folds"
        );
        assert!(!comm_is_dismissed(PendingOutbound, true));

        // The two must never both fire, in any state.
        for status in [Active, PendingOutbound, PendingInbound] {
            for tombstoned in [true, false] {
                assert!(
                    !(may_unhide(status, tombstoned) && comm_is_dismissed(status, tombstoned)),
                    "reopen and refuse must be mutually exclusive: {status:?}/{tombstoned}"
                );
            }
        }
    }

    /// THE INDEXER MAY NOT DECIDE WHO YOU ARE TALKING TO.
    ///
    /// The address-keyed branch rewrites an existing conversation's alias and
    /// key slot. On the fill lane the txid is an indexer claim, and the
    /// decrypt proves only that the payload opens for us — nothing binds
    /// payload to txid. A hostile endpoint pairing an attacker's envelope with
    /// the txid of a real payment from a contact would otherwise rebind that
    /// contact's thread to the attacker. (consensus-auditor BLOCK, 2026-08-14.)
    #[test]
    fn only_the_node_lane_may_rebind_a_conversation_by_address() {
        // The gate is `origin == EventOrigin::Node`; pin the discriminator so
        // a later edit cannot widen it back to both lanes unnoticed.
        assert_eq!(EventOrigin::Node.row_source(), RowSource::NodeScanned);
        assert_eq!(EventOrigin::Fill.row_source(), RowSource::FillSourced);
        assert_ne!(
            EventOrigin::Node,
            EventOrigin::Fill,
            "the two lanes must stay distinguishable — the identity rule keys on it"
        );
    }

    // ── F4 moved into the walk (LINK-Q3) ──────────────────────────────────
    //
    // The reconnect replay's own state machine (`ReplayGap`) and its eight
    // tests left with it: the message walk's cursor never passes anything
    // unfolded, so a gap is replayed by construction. The property is held in
    // `kaspaverse_chain`'s `walk::tests::a_reconnect_gap_is_replayed_from_the_
    // committed_cursor`, and the lock's version of it just below.

    /// **The node lane holds the walk for a locked vault and nothing else**
    /// (LINK-Q3, deliverable 4). `Locked` is the one outcome `HubSink` acts on;
    /// every other drop, `NotAddressedToUs` above all (every stranger's
    /// handshake), must leave the walk free to commit, or one attacker-minted
    /// transaction would pin the message cursor forever.
    #[test]
    fn only_a_locked_vault_holds_the_message_walk() {
        assert_eq!(DropReason::VaultLocked.outcome(), FoldOutcome::Locked);
        for reason in [
            DropReason::NotAddressedToUs,
            DropReason::StoreRace,
            DropReason::StoreFailed,
            DropReason::NoConversationForAlias,
            DropReason::AlreadyStored,
            DropReason::RevivalBudgetSpent,
        ] {
            assert_ne!(
                reason.outcome(),
                FoldOutcome::Locked,
                "{reason:?} would pin the walk"
            );
        }
        // The fill still holds on all four of its own transient reasons.
        assert!(FoldOutcome::Locked.holds() && FoldOutcome::Held.holds());
        assert!(!FoldOutcome::Settled.holds() && !FoldOutcome::Recorded.holds());
    }

    /// **A page the locked vault refused is held, not passed** (LINK-Q3,
    /// deliverable 4), through the real fold: a hub whose vault has locked (a
    /// real decryptor on a dropped vault) folds a handshake addressed to one of
    /// its watched addresses, the decrypt answers `VaultLocked`, and `HubSink`
    /// answers `Held`, so the walk keeps the page for the unlock. A page with
    /// nothing that needs the vault still folds. Mutation: a sink that folds
    /// past the `Locked` drop answers `Folded` and the page is lost.
    #[tokio::test]
    async fn the_hub_sink_holds_a_page_the_locked_vault_refused() {
        use kaspaverse_chain::MessageSink;
        let dir = std::env::temp_dir().join(format!("kv-hubsink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let vault = kaspaverse_core::UnlockedVault::new(
            kaspaverse_core::KeyChain::from_seed(
                kaspaverse_core::SecretSeed::from_seed_bytes(Box::new([7u8; 64])),
                kaspaverse_core::Prefix::Mainnet,
            )
            .unwrap(),
        );
        let decryptor = vault.transport_decryptor();
        drop(vault); // the lock: every decrypt now answers VaultLocked
        let watched = Address::try_from(VICTIM_CONTACT).unwrap();
        let hub = Arc::new(TransportHub {
            store: Arc::new(Mutex::new(TransportStore::load(dir.clone()).unwrap())),
            decryptor,
            block_list: Arc::new(Mutex::new(BlockList::load(&dir))),
            keys: Mutex::new(Arc::new(KeyWindow::build(1, 0, &[watched]))),
        });
        let sink = HubSink { hub };
        // A structurally sound envelope (nonce, a tagged key, ciphertext):
        // the vault is asked before any curve math.
        let mut envelope = vec![0u8; 12];
        envelope.push(0x02);
        envelope.extend([0x11u8; 32]);
        envelope.extend([0x22u8; 16]);
        let event = |kind: &str, n: u8, body: Vec<u8>| TransportEvent {
            txid: Some(format!("{n:02x}").repeat(32)),
            kind: kind.to_string(),
            namespace: WireNamespace::CiphMsg,
            body,
            addresses: vec![VICTIM_CONTACT.to_string()],
            block_time_ms: Some(1_727_000_000_000),
            block_hash: Some("cb".repeat(32)),
            sender: None,
        };
        assert_eq!(
            sink.fold(vec![event("handshake", 1, envelope.clone())])
                .await,
            kaspaverse_chain::Verdict::Held,
            "a locked vault's drop must hold the page"
        );
        assert_eq!(
            sink.fold(vec![event("bcast", 2, b"x:y".to_vec())]).await,
            kaspaverse_chain::Verdict::Folded,
            "a page that needs no key folds"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── F5: the acceptance leg is gated on node truth ─────────────────────

    const VICTIM_CONTACT: &str =
        "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf";
    const ATTACKER: &str = "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692";

    /// **The takeover, refused.** The acceptance leg used to complete and
    /// REBIND a `PendingOutbound` conversation on a decryptable payload plus an
    /// echoed alias — and neither is private. `prepare_comm_plaintext` writes
    /// `comm:<alias>:` outside the envelope in cleartext, D-142 item 3 lets us
    /// send while `PendingOutbound` (the state that leaks the alias and never
    /// expires), and the envelope seals to our published receive address, which
    /// anyone may seal to. So one dust transaction bought a stranger the
    /// conversation: their alias, their key slot, status `Active`.
    ///
    /// The gate is the one `adopt_alias_from_sender` already applied to the
    /// comm lane — our own node's return-address lookup, compared against the
    /// contact address WE chose.
    #[test]
    fn an_acceptance_from_a_stranger_never_completes_a_conversation() {
        assert_eq!(
            acceptance_verdict(EventOrigin::Node, Some(ATTACKER), VICTIM_CONTACT),
            AcceptanceVerdict::NotOurContact,
            "a sender who is not our contact must never complete the handshake"
        );
        assert_eq!(
            acceptance_verdict(EventOrigin::Node, Some(VICTIM_CONTACT), VICTIM_CONTACT),
            AcceptanceVerdict::Complete,
            "the real counterparty must still be able to answer"
        );
    }

    /// An address-less row must not be completable by a sender that resolved
    /// to nothing. Both empty is the trap: string equality alone would call it
    /// a match and hand the conversation to whoever asked.
    #[test]
    fn an_addressless_conversation_matches_no_sender() {
        assert_eq!(
            acceptance_verdict(EventOrigin::Node, Some(""), ""),
            AcceptanceVerdict::NotOurContact
        );
        assert_eq!(
            acceptance_verdict(EventOrigin::Node, Some(ATTACKER), ""),
            AcceptanceVerdict::NotOurContact
        );
    }

    /// The fill lane may not complete an acceptance even when it somehow
    /// carries a matching sender: its txid is an indexer CLAIM, so nothing
    /// binds the payload that opened to the transaction that was labelled with
    /// it (D-139/D-074 — the same rule the address lane got in August).
    #[test]
    fn the_fill_lane_can_never_complete_an_acceptance() {
        // Every fill input REFUSES — including a matching sender, which the
        // caller cannot currently produce but the rule must still cover. The
        // first pass returned `NotOurContact` there, falling through to an
        // address lane that cannot match a fill row either, so it minted an
        // invitation — contradicting `AcceptanceUnverified`'s own promise that
        // it is never folded into one (consensus-auditor, F5).
        for sender in [None, Some(VICTIM_CONTACT), Some(ATTACKER), Some("")] {
            assert_eq!(
                acceptance_verdict(EventOrigin::Fill, sender, VICTIM_CONTACT),
                AcceptanceVerdict::Refuse,
                "node truth only — a fill row must refuse, sender={sender:?}"
            );
        }
    }

    /// The live lane's ordinary case. `resolve_handshake_sender` needs the
    /// bond's own activity record, which does not exist when the acceptance is
    /// first folded — so the common path is HELD, not completed and not lost.
    #[test]
    fn an_unresolved_sender_holds_the_acceptance_rather_than_applying_it() {
        assert_eq!(
            acceptance_verdict(EventOrigin::Node, None, VICTIM_CONTACT),
            AcceptanceVerdict::AwaitSender
        );
    }

    /// The park is bounded, idempotent and one-shot: these txids are
    /// attacker-mintable, so an unbounded or replayable hold would be a second
    /// hole where the first one was.
    #[test]
    fn the_acceptance_park_is_bounded_idempotent_and_one_shot() {
        let claim = |id: &str| ParkedAcceptance {
            conversation_id: id.to_string(),
            their_alias: "aaaaaaaaaaaa".to_string(),
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            envelope: vec![0xAB, 0xCD],
            unix_ms: 1_700_000_000_000,
            wire: WireNamespace::CiphMsg,
        };
        PENDING_ACCEPTANCE
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();

        park_acceptance("tx-a", claim("conv-a"));
        assert!(acceptance_already_parked("tx-a"));
        park_acceptance("tx-a", claim("conv-IMPOSTOR"));
        let taken = take_parked_acceptance("tx-a").expect("parked");
        assert_eq!(
            taken.conversation_id, "conv-a",
            "a second park must not overwrite the first claim"
        );
        assert!(
            take_parked_acceptance("tx-a").is_none(),
            "one shot — a taken claim cannot be replayed"
        );

        for n in 0..(PENDING_COMMS_CAPACITY + 8) {
            park_acceptance(&format!("{n:064x}"), claim("conv-bulk"));
        }
        let held = PENDING_ACCEPTANCE
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        assert_eq!(held, PENDING_COMMS_CAPACITY, "bounded");
        PENDING_ACCEPTANCE
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
    }

    /// The provenance labels are a STRINGLY-TYPED SEAM: Rust emits them,
    /// `thread_screen.dart` compares against the literal `'archive'` to draw the
    /// badge. Nothing else binds the two, so a rename here would delete the
    /// badge silently and the gate would stay green — the exact failure mode F16
    /// exists to kill, at the seam F3's fix depends on. Pin all four.
    #[test]
    fn row_source_labels_are_the_wire_contract() {
        assert_eq!(row_source_label(RowSource::NodeScanned), "node");
        assert_eq!(row_source_label(RowSource::FillSourced), "archive");
        assert_eq!(row_source_label(RowSource::Own), "own");
        assert_eq!(row_source_label(RowSource::Unknown), "unknown");
    }

    // ── D-138: the conversation backup ────────────────────────────────────

    /// Real mainnet addresses — `restored_conversation` validates the prefix,
    /// so a placeholder would pass the test for the wrong reason.
    const PARTNER_A: &str = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf";
    const PARTNER_B: &str = "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692";

    fn stash_payload(alias: &str, partner: &str, id: &str) -> SavedHandshakePayload {
        SavedHandshakePayload::new(
            alias,
            None,
            partner,
            id,
            BOUND_BRANCH_RECEIVE,
            0,
            false,
            1_000,
        )
        .unwrap()
    }

    fn stash_store(tag: &str) -> (TransportStore, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("kv-stash-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        (TransportStore::load(dir.clone()).unwrap(), dir)
    }

    /// `wallet-security-auditor` 2026-09-07: an Accept prepared against an
    /// invitation must find that invitation still there before the refund
    /// broadcasts. Gone (folded by the merge, or erased) or no longer awaiting
    /// an accept ⇒ the commit refuses; only a live `PendingInbound` row passes.
    #[test]
    fn an_accept_whose_invitation_was_folded_is_refused_before_broadcast() {
        let (mut store, dir) = stash_store("accept-guard");
        assert!(
            accept_target_missing(&store, "never-existed"),
            "no row ⇒ nothing to accept"
        );
        let mut invitation = ConversationRecord {
            conversation_id: "inv".to_string(),
            contact_address: String::new(),
            my_alias: String::new(),
            their_alias: Some("822deb62da52".to_string()),
            status: ConversationStatus::PendingInbound,
            initiated_by_me: false,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 150,
            last_activity_unix_ms: 150,
            handshake_txid: Some("hs".to_string()),
        };
        store.upsert_conversation(invitation.clone()).unwrap();
        assert!(
            !accept_target_missing(&store, "inv"),
            "a live invitation passes"
        );

        // The founder's shape: our own request to the same address exists, the
        // sender resolves, and the merge folds the invitation into it.
        store
            .upsert_conversation(ConversationRecord {
                conversation_id: "ours".to_string(),
                contact_address:
                    "kaspa:qqcwl7zlmt6d3cwwvmsdkktfnkd2r0mzx4pu4xcvfdfpnukka7ezy4zn86jlr"
                        .to_string(),
                my_alias: "5f06f494ee33".to_string(),
                their_alias: None,
                status: ConversationStatus::PendingOutbound,
                initiated_by_me: true,
                bound_branch: KeyBranch::Receive,
                bound_index: 0,
                created_unix_ms: 100,
                last_activity_unix_ms: 100,
                handshake_txid: Some("our-hs".to_string()),
            })
            .unwrap();
        invitation.contact_address =
            "kaspa:qqcwl7zlmt6d3cwwvmsdkktfnkd2r0mzx4pu4xcvfdfpnukka7ezy4zn86jlr".to_string();
        store.upsert_conversation(invitation).unwrap();
        let (host, _) = store
            .merge_contact("kaspa:qqcwl7zlmt6d3cwwvmsdkktfnkd2r0mzx4pu4xcvfdfpnukka7ezy4zn86jlr")
            .unwrap()
            .expect("two rows fold");
        assert_eq!(host, "ours");
        assert!(
            accept_target_missing(&store, "inv"),
            "folded away ⇒ the commit refuses before the money moves"
        );
        // …and a row that is present but no longer awaiting an accept refuses too.
        assert!(
            accept_target_missing(&store, "ours"),
            "Active is not acceptable"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// CORRECTION 6 TO THE LIVE POPULATION, and the rule that replaced it.
    ///
    /// Their loader `break`s after the first stash it decrypts — across ALL
    /// recipients — then advances its cursor past the rest, which its own
    /// ascending pagination never re-serves. Ours reads every row of the
    /// snapshot it chooses; what it does NOT do is merge across snapshots.
    ///
    /// A snapshot is a complete statement, not a delta, so an older one can only
    /// contribute rows the user has since HIDDEN — and after a wipe there is no
    /// tombstone left to refuse them, because the suppression record lived on
    /// the device being replaced. The newest backup revokes the one before it.
    /// ONLY THE NEWEST BACKUP SPEAKS, and "newest" must be a fact we can
    /// verify rather than one the archive chooses.
    ///
    /// A snapshot is a complete statement, not a delta, so an older one can only
    /// contribute rows the user has since HIDDEN — and after a wipe there is no
    /// tombstone left to refuse them. Ordering therefore has to be trustworthy:
    /// on the archive's `block_time` alone, a hostile server could replay a
    /// stale-but-genuine backup of ours under a fresh timestamp and resurrect
    /// exactly what hiding buried. `stashedAt` rides inside the MAC'd body, so
    /// an archive can omit a backup but never reorder two.
    #[test]
    fn only_the_newest_backup_speaks_and_the_order_is_not_the_archives_to_choose() {
        // The authenticated field decides, even when block_time disagrees.
        assert!(stash_supersedes(
            (Some(200), 1, "tx-late"),
            Some((Some(100), 9_999_999, "tx-early"))
        ));
        assert!(!stash_supersedes(
            (Some(100), 9_999_999, "tx-early"),
            Some((Some(200), 1, "tx-late"))
        ));

        // Nothing held yet.
        assert!(stash_supersedes((Some(1), 1, "tx"), None));

        // One of ours (stated build time) outranks a foreign row that has none.
        assert!(stash_supersedes(
            (Some(1), 1, "ours"),
            Some((None, 500, "theirs"))
        ));
        assert!(!stash_supersedes(
            (None, 500, "theirs"),
            Some((Some(1), 1, "ours"))
        ));

        // With neither stating one, fall back to block_time then lowest txid —
        // so two devices restoring the same history still agree.
        assert!(stash_supersedes((None, 20, "b"), Some((None, 10, "a"))));
        assert!(stash_supersedes(
            (None, 99, "0000"),
            Some((None, 99, "ffff"))
        ));
        assert!(!stash_supersedes(
            (None, 99, "ffff"),
            Some((None, 99, "0000"))
        ));

        // And the answer cannot depend on the order pages arrived in.
        let pick = |order: [(Option<u64>, u64, &'static str); 4]| {
            let mut current: Option<(Option<u64>, u64, &str)> = None;
            for candidate in order {
                if stash_supersedes(candidate, current) {
                    current = Some(candidate);
                }
            }
            current.unwrap().2
        };
        let rows = [
            (Some(10u64), 10u64, "tx1"),
            (Some(99), 5, "ffff"),
            (Some(99), 5, "0000"),
            (Some(5), 50, "tx0"),
        ];
        let mut reversed = rows;
        reversed.reverse();
        assert_eq!(pick(rows), pick(reversed));
        assert_eq!(pick(rows), "0000");
    }

    /// The restore creates conversations, so a row it cannot prove we wrote
    /// must never become one. Sealing does not prove it — the envelope goes to
    /// our own PUBLIC key, so the archive answering the query can mint one our
    /// key opens. Only the keyed tag separates ours from a stranger's.
    #[test]
    fn a_backup_we_cannot_prove_we_wrote_is_refused() {
        let snapshot = SavedHandshakeSnapshot::new(
            vec![stash_payload("aaaaaaaaaaaa", PARTNER_A, "id1")],
            5_000,
        )
        .unwrap();
        let untagged = snapshot.to_plaintext().unwrap();

        // A forged row: perfectly well-formed, sealed to a key it knows, no tag.
        assert!(
            split_stash_tag(&untagged).is_none(),
            "an untagged payload must never look authenticated"
        );

        // A tag from the wrong seed is present but does not verify — the fold
        // compares against OUR recomputation, so a mismatch is a refusal.
        let ours = [1u8; 32];
        let theirs = [2u8; 32];
        let forged = attach_stash_tag(&untagged, &theirs).unwrap();
        let (recovered, tag) = split_stash_tag(&forged).unwrap();
        assert_eq!(recovered, untagged, "the tag covers the whole payload");
        assert_ne!(tag, ours, "a stranger's tag is not ours");

        // And the refusal settles rather than wedging the walk: the row will
        // never authenticate, so re-serving it forever would be a self-inflicted
        // denial of service on our own history.
        assert_eq!(DropReason::StashNotOurs.outcome(), FoldOutcome::Settled);
    }

    /// A restored row must never mint the ONE status that carries a
    /// bond-spending Accept button. An archive can manufacture a whole
    /// conversation; it must never manufacture a reason to spend 0.2 KAS.
    #[test]
    fn a_restored_backup_never_creates_a_pending_inbound_row() {
        let pending = stash_payload("aaaaaaaaaaaa", PARTNER_A, "id1");
        let restored = restored_conversation(&pending, 30, 30).unwrap();
        assert_eq!(restored.status, ConversationStatus::PendingOutbound);

        let active = SavedHandshakePayload::new(
            "aaaaaaaaaaaa",
            Some("bbbbbbbbbbbb"),
            PARTNER_A,
            "id2",
            BOUND_BRANCH_CHANGE,
            3,
            true,
            1_000,
        )
        .unwrap();
        let restored = restored_conversation(&active, 30, 30).unwrap();
        assert_eq!(restored.status, ConversationStatus::Active);
        assert_eq!(restored.bound_branch, KeyBranch::Change);
        assert_eq!(restored.bound_index, 3);
        // Their hydrate hardcodes initiatedByMe = true even on a response leg.
        assert!(
            !restored.initiated_by_me,
            "a response leg was theirs to open"
        );
        assert!(
            restored.handshake_txid.is_none(),
            "the stash txid paid nobody — never offer it to the refund path"
        );
    }

    /// An out-of-window slot falls back rather than panicking or binding to a
    /// key we never derive. A stash with no slot at all is the KASIA case.
    #[test]
    fn an_unusable_bound_slot_falls_back_to_the_identity_address() {
        let mut far = stash_payload("aaaaaaaaaaaa", PARTNER_A, "id1");
        far.bound_branch = Some(BOUND_BRANCH_CHANGE.to_string());
        far.bound_index = Some(u32::MAX);
        let restored = restored_conversation(&far, 30, 30).unwrap();
        assert_eq!(restored.bound_branch, KeyBranch::Receive);
        assert_eq!(restored.bound_index, 0);

        let mut theirs = stash_payload("aaaaaaaaaaaa", PARTNER_A, "id1");
        theirs.bound_branch = None;
        theirs.bound_index = None;
        let restored = restored_conversation(&theirs, 30, 30).unwrap();
        assert_eq!(restored.bound_branch, KeyBranch::Receive);
        assert_eq!(restored.bound_index, 0);
    }

    #[test]
    fn a_backup_naming_an_address_off_our_network_is_refused() {
        let mut wrong = stash_payload("aaaaaaaaaaaa", PARTNER_A, "id1");
        wrong.partner_address = "kaspatest:qq1234".to_string();
        assert!(restored_conversation(&wrong, 30, 30).is_none());
        wrong.partner_address = "not an address".to_string();
        assert!(restored_conversation(&wrong, 30, 30).is_none());
    }

    /// THE DEFECT THAT MAKES "CREATE-ONLY" INSUFFICIENT.
    ///
    /// A restored row carries the ORIGINAL handshake's timestamp, so it is
    /// older than any live row by construction — and `conversation_by_alias`
    /// deliberately ranks the older establishment first, because the squatter
    /// is the one who arrives later. A create that merely avoided touching
    /// existing rows would therefore capture a live conversation's alias, and
    /// every message that contact sent would file into an invisible twin.
    #[test]
    fn a_backup_row_never_captures_a_live_conversations_alias() {
        let (mut store, dir) = stash_store("alias-capture");
        let live = ConversationRecord {
            conversation_id: "live".into(),
            contact_address: PARTNER_B.into(),
            my_alias: "aaaaaaaaaaaa".into(),
            their_alias: Some("eeeeeeeeeeee".into()),
            status: ConversationStatus::Active,
            initiated_by_me: true,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 900_000,
            last_activity_unix_ms: 900_000,
            handshake_txid: None,
        };
        store.upsert_conversation(live).unwrap();

        // A DIFFERENT counterparty, but claiming an alias the live row holds.
        let colliding = restored_conversation(
            &stash_payload("aaaaaaaaaaaa", PARTNER_A, "restored"),
            30,
            30,
        )
        .unwrap();
        assert!(
            colliding.created_unix_ms < 900_000,
            "the restored row IS older — that is what makes this dangerous"
        );
        assert!(!stash_row_is_free(&store, &colliding), "my_alias collision");

        // …and the same through THEIR alias.
        let mut via_theirs =
            restored_conversation(&stash_payload("ffffffffffff", PARTNER_A, "r2"), 30, 30).unwrap();
        via_theirs.their_alias = Some("eeeeeeeeeeee".into());
        assert!(
            !stash_row_is_free(&store, &via_theirs),
            "their_alias collision"
        );

        // A genuinely fresh conversation is still free to land.
        let fresh =
            restored_conversation(&stash_payload("cccccccccccc", PARTNER_A, "r3"), 30, 30).unwrap();
        assert!(stash_row_is_free(&store, &fresh));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The other two clauses: an id we already hold, and a counterparty we
    /// already talk to. Either would let an archive re-serve a stale identity
    /// over a live one — reverting `their_alias` to `None` and killing every
    /// inbound message with `NoConversationForAlias`.
    #[test]
    fn a_backup_row_never_displaces_a_conversation_we_already_have() {
        let (mut store, dir) = stash_store("displace");
        let live = ConversationRecord {
            conversation_id: "id1".into(),
            contact_address: PARTNER_A.into(),
            my_alias: "9999aaaa9999".into(),
            their_alias: Some("8888bbbb8888".into()),
            status: ConversationStatus::Active,
            initiated_by_me: true,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 900_000,
            last_activity_unix_ms: 900_000,
            handshake_txid: None,
        };
        store.upsert_conversation(live).unwrap();

        // Same conversation id.
        let same_id =
            restored_conversation(&stash_payload("cccccccccccc", PARTNER_B, "id1"), 30, 30)
                .unwrap();
        assert!(!stash_row_is_free(&store, &same_id));

        // Same counterparty, different id.
        let same_partner =
            restored_conversation(&stash_payload("dddddddddddd", PARTNER_A, "other"), 30, 30)
                .unwrap();
        assert!(!stash_row_is_free(&store, &same_partner));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// THE RESTORE SITTING, 2026-08-14, pinned as a test.
    ///
    /// A restore rebuilt ONE conversation out of three. The handshake sweep ran
    /// first, replayed archived handshakes into invitations, and the founder
    /// dismissed the ones he did not recognise — which tombstones the row but
    /// KEEPS it. Those dead rows then held the aliases of two real
    /// conversations and refused their authenticated backups permanently.
    ///
    /// Dismissing spam must never destroy the recovery of an unrelated thread.
    #[test]
    fn a_dismissed_invitation_cannot_block_a_real_backup() {
        let (mut store, dir) = stash_store("dismissed-blocks");
        // The junk invitation the handshake sweep minted: no address, no alias
        // of ours, holding the contact's alias.
        let invitation = ConversationRecord {
            conversation_id: "junk".into(),
            contact_address: String::new(),
            my_alias: String::new(),
            their_alias: Some("90b4a1b640eb".into()),
            status: ConversationStatus::PendingInbound,
            initiated_by_me: false,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 1,
            last_activity_unix_ms: 1,
            handshake_txid: Some("hs".into()),
        };
        store.upsert_conversation(invitation).unwrap();

        // The real conversation, from an authenticated backup, sharing that
        // contact's alias — because it IS that contact.
        let restored = restored_conversation(
            &SavedHandshakePayload::new(
                "8caa5e3c79ff",
                Some("90b4a1b640eb"),
                PARTNER_A,
                "real",
                BOUND_BRANCH_RECEIVE,
                0,
                false,
                1_000,
            )
            .unwrap(),
            30,
            30,
        )
        .unwrap();

        // While the invitation is LIVE it legitimately holds that alias.
        assert!(!stash_row_is_free(&store, &restored));

        // Dismissed, it holds nothing — it routes no traffic, so it has no
        // standing to refuse the real conversation.
        store.tombstone_conversation("junk").unwrap();
        assert!(
            stash_row_is_free(&store, &restored),
            "a dismissed invitation must not veto an authenticated backup"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Hiding a conversation still suppresses THAT conversation — the clause
    /// that counts tombstoned rows is the id one, and it must keep counting
    /// them or hiding stops meaning anything across a restore.
    #[test]
    fn hiding_a_conversation_still_survives_a_restore() {
        let (mut store, dir) = stash_store("hide-survives");
        let hidden = ConversationRecord {
            conversation_id: "same-id".into(),
            contact_address: PARTNER_B.into(),
            my_alias: "aaaaaaaaaaaa".into(),
            their_alias: Some("bbbbbbbbbbbb".into()),
            status: ConversationStatus::Active,
            initiated_by_me: true,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 5,
            last_activity_unix_ms: 5,
            handshake_txid: None,
        };
        store.upsert_conversation(hidden).unwrap();
        store.tombstone_conversation("same-id").unwrap();

        let same =
            restored_conversation(&stash_payload("cccccccccccc", PARTNER_A, "same-id"), 30, 30)
                .unwrap();
        assert!(
            !stash_row_is_free(&store, &same),
            "the id clause counts tombstones — that is how hiding survives"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Hiding is the user's suppression record. A backup that carried it — or a
    /// restore that ignored it — would hand back everything they deliberately
    /// put away. The tombstone keeps the row, so the id clause already refuses
    /// the rehydrate; the write side must not stash it in the first place.
    #[test]
    fn a_hidden_conversation_is_neither_backed_up_nor_restored_over() {
        let (mut store, dir) = stash_store("tombstone");
        let hidden = ConversationRecord {
            conversation_id: "hidden".into(),
            contact_address: PARTNER_A.into(),
            my_alias: "aaaaaaaaaaaa".into(),
            their_alias: Some("bbbbbbbbbbbb".into()),
            status: ConversationStatus::Active,
            initiated_by_me: true,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 5,
            last_activity_unix_ms: 5,
            handshake_txid: None,
        };
        store.upsert_conversation(hidden).unwrap();
        store.tombstone_conversation("hidden").unwrap();

        assert!(stashable_rows(&store).is_empty(), "never backed up");

        let rehydrate =
            restored_conversation(&stash_payload("cccccccccccc", PARTNER_A, "hidden"), 30, 30)
                .unwrap();
        assert!(
            !stash_row_is_free(&store, &rehydrate),
            "never restored over"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A backup must carry only conversations that could actually send after a
    /// restore. `PendingInbound` rows carry no counterparty address until they
    /// are accepted — and they are the one class already recoverable from
    /// chain, since their handshake was addressed to us.
    #[test]
    fn a_backup_skips_rows_that_could_not_send_after_a_restore() {
        let (mut store, dir) = stash_store("stashable");
        let usable = ConversationRecord {
            conversation_id: "ok".into(),
            contact_address: PARTNER_A.into(),
            my_alias: "aaaaaaaaaaaa".into(),
            their_alias: Some("bbbbbbbbbbbb".into()),
            status: ConversationStatus::Active,
            initiated_by_me: true,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 5,
            last_activity_unix_ms: 50,
            handshake_txid: None,
        };
        let invitation = ConversationRecord {
            conversation_id: "invite".into(),
            contact_address: String::new(),
            my_alias: String::new(),
            their_alias: Some("cccccccccccc".into()),
            status: ConversationStatus::PendingInbound,
            initiated_by_me: false,
            ..usable.clone()
        };
        store.upsert_conversation(usable).unwrap();
        store.upsert_conversation(invitation).unwrap();

        let rows = stashable_rows(&store);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].conversation_id, "ok");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// THE COUNT IS NOT THE PAYLOAD, and conflating them told the user a lie.
    ///
    /// `stashable_rows` feeds both the backup and the coverage notice. When it
    /// truncated, a wallet with 80 conversations backed up 64 and then reported
    /// "All 64 conversations backed up" — the other sixteen were in no backup,
    /// were never counted, and nothing in the app would ever have said so. The
    /// founder would learn it on the day the device was gone.
    ///
    /// So the list is complete and ordered here; the cap belongs to the one
    /// place that builds a transaction.
    #[test]
    fn the_backup_count_is_never_truncated_by_the_payload_cap() {
        let (mut store, dir) = stash_store("cap");
        for i in 0..(STASH_SNAPSHOT_MAX + 16) {
            store
                .upsert_conversation(ConversationRecord {
                    conversation_id: format!("c{i:03}"),
                    contact_address: PARTNER_A.into(),
                    my_alias: format!("{i:012}"),
                    their_alias: None,
                    status: ConversationStatus::PendingOutbound,
                    initiated_by_me: true,
                    bound_branch: KeyBranch::Receive,
                    bound_index: 0,
                    created_unix_ms: 1,
                    last_activity_unix_ms: i as u64,
                    handshake_txid: None,
                })
                .unwrap();
        }
        let rows = stashable_rows(&store);
        assert_eq!(
            rows.len(),
            STASH_SNAPSHOT_MAX + 16,
            "the DENOMINATOR counts every conversation, so the cap stays visible"
        );
        assert_eq!(
            rows[0].last_activity_unix_ms,
            (STASH_SNAPSHOT_MAX + 15) as u64,
            "newest first — a wallet past the cap keeps the threads it uses"
        );
        // …and the payload path is the one that cuts, which is what makes the
        // notice able to say "64 of 80" instead of "all 64".
        let mut payload_rows = rows.clone();
        payload_rows.truncate(STASH_SNAPSHOT_MAX);
        assert!(payload_rows.len() < rows.len(), "covered < total, honestly");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A refused backup row must SETTLE, never HOLD.
    ///
    /// The cursor-hold rule keys on who can cause a drop. A collision is caused
    /// by a live conversation of our own standing in the way — and that live
    /// row is the correct winner, so re-serving the same stash next run would
    /// refuse it identically, forever, and the walk would never pass it. That
    /// is a self-inflicted denial of service on our own history, the same class
    /// the `HeldFloor` rules were written to avoid.
    #[test]
    fn a_refused_backup_row_settles_rather_than_wedging_the_walk() {
        assert_eq!(
            DropReason::StashRefusedCollision.outcome(),
            FoldOutcome::Settled
        );
        // …while the genuinely transient ones still hold the cursor.
        assert!(DropReason::VaultLocked.outcome().holds());
        assert!(DropReason::StoreFailed.outcome().holds());
    }

    /// THE D-138 OWNER-ATTRIBUTION ORDERING.
    ///
    /// The indexer files a self-stash under an owner derived from input[0]'s
    /// previous outpoint — requiring **index 0**, and requiring that funding
    /// transaction to itself have been a `ciph_msg:` operation. Miss both and
    /// the row is only attributable by a deferred lookup that may never run
    /// during a historical gap-fill, which loses the backup silently and
    /// completely. So the best-shaped coin must lead.
    #[test]
    fn owner_attribution_puts_the_best_shaped_coin_at_input_zero() {
        // (index, funding txid) — the only two facts the rule reads.
        let coins = vec![
            (3u32, "unknown-a".to_string()), // wrong index      → last tier
            (0, "unknown-b".to_string()),    // right index only → middle tier
            (0, "ours".to_string()),         // both             → first
            (7, "unknown-c".to_string()),    // wrong index      → last tier
        ];
        let ordered =
            order_priority_for_owner(coins, |c| (c.0, c.1.clone()), |txid| txid == "ours");

        assert_eq!(ordered[0].1, "ours", "index 0 of one of our own txs leads");
        assert_eq!(ordered[1].0, 0, "then any index 0");
        // Stable inside the last tier: index 3 was supplied before index 7.
        assert_eq!(ordered[2].0, 3);
        assert_eq!(ordered[3].0, 7);
    }

    /// Never a filter. A wallet that has only ever RECEIVED holds no coin at
    /// index 0 of a protocol transaction, and it must still be able to back up.
    #[test]
    fn owner_attribution_reorders_but_never_discards() {
        let coins = vec![(5u32, "a".to_string()), (9, "b".to_string())];
        let ordered = order_priority_for_owner(coins, |c| (c.0, c.1.clone()), |_| false);
        assert_eq!(ordered.len(), 2, "every coin still spendable");
    }

    /// AN INVITATION WITH NO SENDER IS INVISIBLE, and that invisibility cost a
    /// second bond every time.
    ///
    /// A `PendingInbound` row used to store `contact_address: ""` even when the
    /// node had just told us who sent it, because the resolve was gated on a
    /// pre-check that is false on the very first invitation a wallet receives.
    /// The row then matched no address lookup, so typing that same address
    /// minted OUR handshake beside theirs: two bonds paid, theirs stranded.
    #[test]
    fn an_invitation_that_knows_its_sender_can_be_matched_by_address() {
        let (mut store, dir) = stash_store("invitation-sender");
        let invitation = ConversationRecord {
            conversation_id: "invite".into(),
            contact_address: PARTNER_A.into(), // recorded, not empty
            my_alias: String::new(),
            their_alias: Some("bbbbbbbbbbbb".into()),
            status: ConversationStatus::PendingInbound,
            initiated_by_me: false,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 1,
            last_activity_unix_ms: 1,
            handshake_txid: Some("hs".into()),
        };
        store.upsert_conversation(invitation).unwrap();

        // The lookup that decides whether adding this contact spends a bond
        // can now see it at all — that is the whole fix.
        let rows = store.conversations_for_contact_address(PARTNER_A);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].status, ConversationStatus::PendingInbound);

        // And it is still NOT something to open and talk in — accepting is
        // what completes it, so the openable rule must keep refusing it.
        assert!(!comm_sendable(
            rows[0].status,
            rows[0].initiated_by_me,
            &rows[0].contact_address,
            &rows[0].my_alias
        ));

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Adding a contact you already have should OPEN the thread, and the rule
    /// for "already have" is the send predicate — not a second copy of it.
    ///
    /// The pairing matters: a `PendingInbound` row must never answer this
    /// question. It is an invitation whose only affordance spends a bond, so
    /// routing "add contact" into it would put a payment button where the user
    /// asked for a chat — and if it had been dismissed, let a stranger re-arm it.
    #[test]
    fn the_openable_rule_is_the_send_rule() {
        use ConversationStatus::{Active, PendingInbound, PendingOutbound};
        const ADDR: &str = PARTNER_A;
        const ALIAS: &str = "aaaaaaaaaaaa";

        // Openable: a live conversation, or one we opened and can speak in.
        assert!(comm_sendable(Active, true, ADDR, ALIAS));
        assert!(comm_sendable(Active, false, ADDR, ALIAS));
        assert!(comm_sendable(PendingOutbound, true, ADDR, ALIAS));

        // Not openable: their invitation, in either direction.
        assert!(!comm_sendable(PendingInbound, false, ADDR, ALIAS));
        assert!(!comm_sendable(PendingInbound, true, ADDR, ALIAS));
        // Nor a row missing the halves a conversation needs to exist.
        assert!(!comm_sendable(Active, true, "", ALIAS));
        assert!(!comm_sendable(Active, true, ADDR, ""));
    }

    /// The scope is a WIRE CONSTANT shared with the live population and with
    /// the indexer's partition key. A rename here silently returns zero rows
    /// forever — the fill would report a clean, complete, empty walk.
    #[test]
    fn the_backup_scope_is_the_wire_contract() {
        assert_eq!(SELF_STASH, "self_stash");
        assert_eq!(STASH_SCOPE_SAVED_HANDSHAKE, "saved_handshake");
    }

    // ── D-307 / D-308: the revival path, and the refusal in front of it ──

    /// The revival budget is a fixed window: `limit` takes, then refusal
    /// until the window rolls, then `limit` again. Pure over the clock.
    #[test]
    fn the_rate_window_refuses_past_its_limit_and_refills_on_the_next_window() {
        let mut window = RateWindow::new();
        for _ in 0..3 {
            assert!(window.try_take(1_000, 3, 100));
        }
        assert!(!window.try_take(1_050, 3, 100), "spent inside the window");
        assert!(window.try_take(1_100, 3, 100), "a new window refills");
        assert!(window.try_take(1_199, 3, 100));
        assert!(window.try_take(1_199, 3, 100));
        assert!(!window.try_take(1_199, 3, 100));
        // A clock that goes backwards never grants extra takes.
        assert!(!window.try_take(900, 3, 100));
    }

    fn parked(alias: &str, bytes: usize) -> ParkedComm {
        parked_from(alias, bytes, Some(VICTIM_CONTACT))
    }

    fn parked_from(alias: &str, bytes: usize, sender: Option<&str>) -> ParkedComm {
        ParkedComm {
            alias: alias.to_string(),
            slot: (Branch::Receive, 0),
            envelope: vec![0u8; bytes],
            block_time_ms: Some(1_700_000_000_000),
            wire: WireNamespace::CiphMsg,
            sender: sender.map(str::to_string),
        }
    }

    /// Parked comms are attacker-mintable, so the set is bounded twice —
    /// by count and by sealed bytes — and an entry is taken once.
    #[test]
    fn parked_comms_are_bounded_by_count_and_by_bytes_and_taken_once() {
        let mut set = ParkedComms::new();
        set.park("tx-a", parked("aaaaaaaaaaaa", 10));
        assert!(set.contains("tx-a"));
        // A second park of the same txid keeps the first claim.
        set.park("tx-a", parked("IMPOSTOR", 10));
        assert_eq!(set.take("tx-a").unwrap().alias, "aaaaaaaaaaaa");
        assert!(set.take("tx-a").is_none(), "one shot");

        for n in 0..(PENDING_COMMS_CAPACITY + 8) {
            set.park(&format!("{n:064x}"), parked("bbbbbbbbbbbb", 1));
        }
        assert_eq!(
            set.entries.len(),
            PENDING_COMMS_CAPACITY,
            "bounded by count"
        );
        // The oldest went first.
        assert!(!set.contains(&format!("{:064x}", 0)));
        assert!(set.contains(&format!("{:064x}", PENDING_COMMS_CAPACITY + 7)));

        let mut fat = ParkedComms::new();
        fat.park("big-1", parked("cccccccccccc", PENDING_COMMS_BYTES / 2));
        fat.park("big-2", parked("cccccccccccc", PENDING_COMMS_BYTES / 2));
        fat.park("big-3", parked("cccccccccccc", 16));
        assert!(fat.bytes() <= PENDING_COMMS_BYTES, "bounded by bytes");
        assert!(!fat.contains("big-1"), "the oldest paid for the overflow");
        assert!(fat.contains("big-3"));

        // One entry over the byte bound is still parked — a bound that
        // refused every attachment larger than itself would be a silent hole.
        let mut one = ParkedComms::new();
        one.park("huge", parked("dddddddddddd", PENDING_COMMS_BYTES + 1));
        assert!(one.contains("huge"));
    }

    /// Siblings under one alias fold together ONLY when their own page named
    /// the same sender (PRE3-SENDER): a stranger's comm parked under the
    /// contact's alias is refused, not carried in on the contact's proof, and
    /// one whose page named nobody waits for its own resolution. A block
    /// forgets them all. The real path: the revival lane parks each comm with
    /// the page's sender (`revive_or_drop`); `fold_parked_comm` folds the
    /// siblings once one of them resolves.
    #[test]
    fn parked_siblings_fold_on_the_alias_and_the_sender_and_a_block_forgets_them() {
        let mut set = ParkedComms::new();
        set.park("tx-1", parked("aaaaaaaaaaaa", 1));
        set.park("tx-2", parked("bbbbbbbbbbbb", 1));
        set.park("tx-3", parked("aaaaaaaaaaaa", 1));
        set.park("tx-5", parked_from("aaaaaaaaaaaa", 1, Some(ATTACKER)));
        set.park("tx-6", parked_from("aaaaaaaaaaaa", 1, None));
        let first = set.take("tx-1").unwrap();
        let (siblings, refused) = set.take_siblings(&first.alias, VICTIM_CONTACT);
        let refused = refused.len();
        assert_eq!(
            siblings.iter().map(|(t, _)| t.as_str()).collect::<Vec<_>>(),
            ["tx-3"]
        );
        assert_eq!(refused, 1, "the stranger's sibling is refused");
        assert!(!set.contains("tx-5"), "and not kept to try again");
        assert!(
            set.contains("tx-6"),
            "an unnamed sibling waits for its own sender"
        );
        assert!(set.contains("tx-2"), "another alias is untouched");

        set.park("tx-4", parked("bbbbbbbbbbbb", 1));
        set.forget_alias("bbbbbbbbbbbb");
        assert!(!set.contains("tx-2"));
        assert!(!set.contains("tx-4"));
    }

    /// The free refusals run before the budget is charged: a fill row, a
    /// re-delivery and a blocked alias never spend a decrypt, and only a
    /// clear attempt takes one.
    #[test]
    fn the_revival_gate_charges_the_budget_only_for_a_real_attempt() {
        use std::cell::Cell;
        let charged = Cell::new(0);
        let budget = |ok: bool| {
            let charged = &charged;
            move || {
                charged.set(charged.get() + 1);
                ok
            }
        };
        assert_eq!(
            revival_refusal(EventOrigin::Fill, false, budget(true)),
            Some(DropReason::NoConversationForAlias),
            "a fill row never revives (D-139)"
        );
        assert_eq!(
            revival_refusal(EventOrigin::Node, true, budget(true)),
            Some(DropReason::SenderPending),
            "a re-delivery is already parked"
        );
        assert_eq!(charged.get(), 0, "neither free refusal charged the budget");
        assert_eq!(
            revival_refusal(EventOrigin::Node, false, budget(false)),
            Some(DropReason::RevivalBudgetSpent)
        );
        assert_eq!(
            revival_refusal(EventOrigin::Node, false, budget(true)),
            None
        );
        assert_eq!(charged.get(), 2);
    }

    /// The wipe clears the two side files that describe the rows it
    /// destroys, and KEEPS the block list (D-308): a refusal is not a claim
    /// about the rows, and the revival path would otherwise hand every
    /// refused address a way back in.
    #[test]
    fn a_wipe_clears_the_names_and_the_stash_state_and_keeps_the_block_list() {
        let dir = std::env::temp_dir().join(format!("kv-wipe-side-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(kaspaverse_chain::ContactNames::path(&dir), b"{}").unwrap();
        std::fs::write(
            kaspaverse_chain::history_fill::StashState::path(&dir),
            b"{}",
        )
        .unwrap();
        let mut list = BlockList::default();
        list.block(PARTNER_A, 1);
        list.save(&dir).unwrap();

        assert_eq!(clear_side_files(&dir), 2);
        assert!(!kaspaverse_chain::ContactNames::path(&dir).exists());
        assert!(!kaspaverse_chain::history_fill::StashState::path(&dir).exists());
        assert!(
            BlockList::load(&dir).is_blocked(PARTNER_A),
            "the refusal survives the wipe"
        );
        // Idempotent: nothing left to clear, still no error.
        assert_eq!(clear_side_files(&dir), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The row a contact's message mints after a wipe (D-307): readable,
    /// never an invitation (no bond button), and NOT sendable until a
    /// handshake announces an alias of ours — which is why the handshake
    /// path reuses it and the router opens it.
    #[test]
    fn a_revived_row_is_readable_reusable_and_not_yet_sendable() {
        let row = revived_conversation(PARTNER_A, "822deb62da52", (Branch::Change, 3), 5_000);
        assert_eq!(row.status, ConversationStatus::Active);
        assert!(row.my_alias.is_empty(), "no alias of ours to announce yet");
        assert_eq!(row.their_alias.as_deref(), Some("822deb62da52"));
        assert_eq!(row.contact_address, PARTNER_A);
        assert!(!row.initiated_by_me);
        assert_eq!((row.bound_branch, row.bound_index), (KeyBranch::Change, 3));
        assert_eq!(row.handshake_txid, None, "no bond, no accept card");
        assert_eq!(row.created_unix_ms, 5_000);
        assert!(!comm_sendable(
            row.status,
            row.initiated_by_me,
            &row.contact_address,
            &row.my_alias
        ));
        assert!(handshake_reuses(&row), "the handshake completes it");
        // The DTO flag is exactly this shape, and only this shape.
        let needs = |c: &ConversationRecord| {
            c.status == ConversationStatus::Active && c.my_alias.is_empty()
        };
        assert!(needs(&row));
        let mut announced = row.clone();
        announced.my_alias = "fa6d1afa79e1".into();
        assert!(!needs(&announced));
        assert!(
            !handshake_reuses(&announced),
            "an announced Active row is a refusal, not a reuse"
        );
        let mut theirs = row.clone();
        theirs.status = ConversationStatus::PendingInbound;
        assert!(!needs(&theirs));
        assert!(!handshake_reuses(&theirs));
    }

    /// A backup restored over a revived row FOLDS into it rather than being
    /// refused: the backup's alias is the voice the revived thread was
    /// missing, and the revived messages come along (D-307).
    #[test]
    fn a_backup_row_folds_a_revived_conversation_instead_of_being_refused() {
        let (mut store, dir) = stash_store("revived-merge");
        let revived = revived_conversation(PARTNER_A, "822deb62da52", (Branch::Receive, 0), 9_000);
        let revived_id = revived.conversation_id.clone();
        store.upsert_conversation(revived).unwrap();
        store
            .record_message(MessageRecord {
                txid: "revived-msg".into(),
                conversation_id: revived_id.clone(),
                direction: MessageDirection::Inbound,
                kind: StoredKind::Comm,
                envelope: vec![1, 2, 3],
                unix_ms: 9_000,
                alias_on_wire: Some("822deb62da52".into()),
                sealed_to: None,
                provenance: RowSource::NodeScanned,
                wire: WireNamespace::KChat,
            })
            .unwrap();

        // The restored row shares the address AND their alias with the
        // revived one — both clauses that refuse a standing row.
        let mut payload = stash_payload("cccccccccccc", PARTNER_A, "from-backup");
        payload.their_alias = Some("822deb62da52".into());
        let restored = restored_conversation(&payload, 30, 30).unwrap();
        assert!(
            stash_row_is_free(&store, &restored),
            "a revived row has no standing to refuse the backup"
        );
        store.upsert_conversation(restored).unwrap();
        let (host, report) = store.merge_contact(PARTNER_A).unwrap().expect("folded");
        assert_eq!(
            host, "from-backup",
            "the backup row outranks on the alias it holds"
        );
        assert_eq!(report.rows_folded, 1);
        assert_eq!(report.messages_rehomed, 1);
        let merged = store.conversation(&host).unwrap();
        assert_eq!(merged.my_alias, "cccccccccccc");
        assert_eq!(merged.their_alias.as_deref(), Some("822deb62da52"));
        assert_eq!(merged.status, ConversationStatus::Active);
        assert!(comm_sendable(
            merged.status,
            merged.initiated_by_me,
            &merged.contact_address,
            &merged.my_alias
        ));
        assert!(store.conversation(&revived_id).is_none());
        assert_eq!(
            store.message_conversation("revived-msg").as_deref(),
            Some(host.as_str())
        );

        // And a STANDING row still refuses, exactly as before.
        let other =
            restored_conversation(&stash_payload("dddddddddddd", PARTNER_A, "again"), 30, 30)
                .unwrap();
        assert!(!stash_row_is_free(&store, &other));
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn row_for(id: &str, address: &str, status: ConversationStatus) -> ConversationRecord {
        ConversationRecord {
            conversation_id: id.into(),
            contact_address: address.into(),
            my_alias: String::new(),
            their_alias: Some("822deb62da52".into()),
            status,
            initiated_by_me: false,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 1,
            last_activity_unix_ms: 1,
            handshake_txid: Some(format!("hs-{id}")),
        }
    }

    fn message_in(store: &mut TransportStore, txid: &str, id: &str, kind: StoredKind) {
        store
            .record_message(MessageRecord {
                txid: txid.into(),
                conversation_id: id.into(),
                direction: MessageDirection::Inbound,
                kind,
                envelope: vec![1],
                unix_ms: 1,
                alias_on_wire: None,
                sealed_to: None,
                provenance: RowSource::NodeScanned,
                wire: WireNamespace::CiphMsg,
            })
            .unwrap();
    }

    /// The block purges every row; the start sweep purges every row BUT a
    /// live request — the knock D-308 keeps open, whose bond must stay
    /// Accept-able (`consensus-auditor` + `wallet-security-auditor`).
    #[test]
    fn the_start_sweep_keeps_a_blocked_addresss_live_request() {
        let (mut store, dir) = stash_store("sweep-keeps-knock");
        store
            .upsert_conversation(row_for("thread", PARTNER_A, ConversationStatus::Active))
            .unwrap();
        store
            .upsert_conversation(row_for(
                "knock",
                PARTNER_A,
                ConversationStatus::PendingInbound,
            ))
            .unwrap();
        store
            .upsert_conversation(row_for(
                "old-knock",
                PARTNER_A,
                ConversationStatus::PendingInbound,
            ))
            .unwrap();
        store.tombstone_conversation("old-knock").unwrap();
        message_in(&mut store, "m1", "thread", StoredKind::Comm);
        message_in(&mut store, "hs-knock", "knock", StoredKind::Handshake);

        let (rows, messages) = purge_contact_rows(&mut store, PARTNER_A, true).unwrap();
        assert_eq!(
            (rows, messages),
            (2, 1),
            "the thread and the dismissed knock went"
        );
        assert!(
            store.conversation("knock").is_some(),
            "the live knock stays"
        );
        assert!(store.conversation("thread").is_none());
        assert!(store.conversation("old-knock").is_none());

        // The block itself takes everything.
        let (rows, _) = purge_contact_rows(&mut store, PARTNER_A, false).unwrap();
        assert_eq!(rows, 1);
        assert!(store.conversation("knock").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A blocked address's request keeps its handshake row (the accept gate
    /// reads it) and loses every comm that routed into it before the name
    /// landed (`wallet-security-auditor`, MSG-BLOCK).
    #[test]
    fn a_blocked_knock_keeps_its_handshake_and_loses_its_comms() {
        let (mut store, dir) = stash_store("knock-comms");
        store
            .upsert_conversation(row_for(
                "knock",
                PARTNER_A,
                ConversationStatus::PendingInbound,
            ))
            .unwrap();
        message_in(&mut store, "hs-knock", "knock", StoredKind::Handshake);
        message_in(&mut store, "c1", "knock", StoredKind::Comm);
        message_in(&mut store, "c2", "knock", StoredKind::Comm);
        assert_eq!(
            purge_comms_keeping_handshake(&mut store, "knock").unwrap(),
            2
        );
        let left: Vec<String> = store
            .messages_for("knock")
            .into_iter()
            .map(|m| m.txid)
            .collect();
        assert_eq!(left, ["hs-knock"]);
        assert_eq!(
            purge_comms_keeping_handshake(&mut store, "knock").unwrap(),
            0
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A present-but-unreadable block list is moved aside, never read as
    /// empty and overwritten; an absent one and a good one are left alone.
    #[test]
    fn an_unreadable_block_list_is_quarantined_at_start() {
        let dir = std::env::temp_dir().join(format!("kv-block-quarantine-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // Absent: nothing to do.
        quarantine_unreadable_block_list(&dir);
        assert!(!BlockList::path(&dir)
            .with_extension("list.corrupt")
            .exists());
        // Good: untouched.
        let mut list = BlockList::default();
        list.block(PARTNER_A, 1);
        list.save(&dir).unwrap();
        quarantine_unreadable_block_list(&dir);
        assert!(BlockList::load(&dir).is_blocked(PARTNER_A));
        // Corrupt: moved aside with its bytes, and the live read is empty.
        std::fs::write(BlockList::path(&dir), b"{ torn").unwrap();
        quarantine_unreadable_block_list(&dir);
        assert!(!BlockList::path(&dir).exists());
        let aside = BlockList::path(&dir).with_extension("list.corrupt");
        assert_eq!(std::fs::read(&aside).unwrap(), b"{ torn");
        assert!(BlockList::load(&dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A revived row shares their alias with a real, standing conversation
    /// for a DIFFERENT address (a squatter); the standing one must still
    /// refuse the backup even though the revived row ranks first.
    #[test]
    fn a_standing_row_behind_a_revived_one_still_refuses_a_backup() {
        let (mut store, dir) = stash_store("revived-squatter");
        let standing = ConversationRecord {
            conversation_id: "standing".into(),
            contact_address: PARTNER_B.into(),
            my_alias: "9999aaaa9999".into(),
            their_alias: Some("822deb62da52".into()),
            status: ConversationStatus::Active,
            initiated_by_me: true,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 100,
            last_activity_unix_ms: 100,
            handshake_txid: None,
        };
        store.upsert_conversation(standing).unwrap();
        store
            .upsert_conversation(revived_conversation(
                PARTNER_A,
                "822deb62da52",
                (Branch::Receive, 0),
                9_000,
            ))
            .unwrap();
        let mut payload = stash_payload("cccccccccccc", PARTNER_A, "from-backup");
        payload.their_alias = Some("822deb62da52".into());
        let restored = restored_conversation(&payload, 30, 30).unwrap();
        assert!(
            !stash_row_is_free(&store, &restored),
            "the standing row has the alias to defend"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── PRE3-SENDER (F2): a contact's thread holds only the contact ────────

    /// The one conversation these tests write into: the contact's alias and
    /// ours, 12 lowercase hex like the population's.
    const THEIR_ALIAS: &str = "c0ffee5e0d01";
    const MY_ALIAS: &str = "beefca11ab1e";
    const VICTIM_ID: &str = "c-victim";

    /// A hub over a REAL unlocked vault and a real store holding one Active
    /// conversation with `VICTIM_CONTACT`, bound to our receive slot 0: the
    /// shape the founder's KaChat and Kasia threads have. The vault comes back
    /// so the decryptor stays live; the key is what a stranger seals to, read
    /// off our published address like anyone could.
    fn sender_hub(
        tag: &str,
    ) -> (
        Arc<TransportHub>,
        std::path::PathBuf,
        kaspaverse_core::UnlockedVault,
        [u8; 32],
    ) {
        let dir = std::env::temp_dir().join(format!("kv-sender-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let keychain = || {
            kaspaverse_core::KeyChain::from_seed(
                kaspaverse_core::SecretSeed::from_seed_bytes(Box::new([9u8; 64])),
                kaspaverse_core::Prefix::Mainnet,
            )
            .unwrap()
        };
        let ours = keychain().receive_address(0).unwrap();
        let published_key = x_only_of(&ours).unwrap();
        let vault = kaspaverse_core::UnlockedVault::new(keychain());
        let mut store = TransportStore::load(dir.clone()).unwrap();
        store
            .upsert_conversation(ConversationRecord {
                conversation_id: VICTIM_ID.into(),
                contact_address: VICTIM_CONTACT.into(),
                my_alias: MY_ALIAS.into(),
                their_alias: Some(THEIR_ALIAS.into()),
                status: ConversationStatus::Active,
                initiated_by_me: true,
                bound_branch: KeyBranch::Receive,
                bound_index: 0,
                created_unix_ms: 1_000,
                last_activity_unix_ms: 1_000,
                handshake_txid: None,
            })
            .unwrap();
        let hub = Arc::new(TransportHub {
            store: Arc::new(Mutex::new(store)),
            decryptor: vault.transport_decryptor(),
            block_list: Arc::new(Mutex::new(BlockList::load(&dir))),
            keys: Mutex::new(Arc::new(KeyWindow::build(1, 0, &[ours]))),
        });
        (hub, dir, vault, published_key)
    }

    /// A comm exactly as the walk's page hands it to the hub: the wire the
    /// population writes (`kchat:1:comm:<alias>:<base64>`, composed by our own
    /// composer and parsed back by the scan's parser), a fresh txid, and the
    /// sender the page named. The txids are unique per test because the parked
    /// set is process-wide.
    fn page_comm(n: u8, alias: &str, envelope: &[u8], sender: Option<&str>) -> TransportEvent {
        let wire = compose_comm_wire_in(WireNamespace::KChat, alias, envelope).unwrap();
        let (namespace, kind, body) = kaspaverse_chain::parse_payload_in(&wire).unwrap();
        TransportEvent {
            txid: Some(format!("{n:02x}").repeat(32)),
            kind,
            namespace,
            body: body.to_vec(),
            addresses: vec![sender.unwrap_or(VICTIM_CONTACT).to_string()],
            block_time_ms: Some(1_727_000_000_000 + u64::from(n)),
            block_hash: Some("cb".repeat(32)),
            sender: sender.map(str::to_string),
        }
    }

    fn sealed(key: &[u8; 32], text: &[u8]) -> Vec<u8> {
        encrypt(key, text).unwrap().to_bytes()
    }

    fn thread(hub: &TransportHub) -> Vec<MessageRecord> {
        hub.store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .messages_for(VICTIM_ID)
    }

    /// Fold through `HubSink::fold`, the walk's own consumer (LINK-Q3): the
    /// real path from a page to the store, minus the RPC.
    async fn walk_folds(hub: &Arc<TransportHub>, event: TransportEvent) {
        use kaspaverse_chain::MessageSink;
        let sink = HubSink { hub: hub.clone() };
        assert_eq!(
            sink.fold(vec![event]).await,
            kaspaverse_chain::Verdict::Folded,
            "nothing here holds the page"
        );
    }

    /// **The F2 gate as a table.** Contact only when a sender is named and it
    /// is the row's contact; an address-less row matches no one, an empty
    /// sender included, and on the node lane holds the comm until the row
    /// learns its contact; a page with no sender asks the return-address lane;
    /// an archive row never waits.
    #[test]
    fn the_sender_verdict_admits_only_the_contact() {
        use CommSenderVerdict::*;
        use EventOrigin::*;
        let v = comm_sender_verdict;
        assert_eq!(v(Node, Some(VICTIM_CONTACT), VICTIM_CONTACT), Contact);
        assert_eq!(v(Fill, Some(VICTIM_CONTACT), VICTIM_CONTACT), Contact);
        assert_eq!(v(Node, Some(ATTACKER), VICTIM_CONTACT), NotContact);
        assert_eq!(v(Fill, Some(ATTACKER), VICTIM_CONTACT), NotContact);
        assert_eq!(
            v(Node, Some(""), ""),
            AwaitContact,
            "both empty is never a match"
        );
        assert_eq!(
            v(Node, Some(ATTACKER), ""),
            AwaitContact,
            "an address-less row holds"
        );
        assert_eq!(
            v(Fill, Some(ATTACKER), ""),
            NotContact,
            "an archive row never waits"
        );
        assert_eq!(
            v(Fill, Some(""), VICTIM_CONTACT),
            NotContact,
            "an empty claim"
        );
        assert_eq!(v(Node, None, VICTIM_CONTACT), AwaitSender);
        assert_eq!(
            v(Fill, None, VICTIM_CONTACT),
            NotContact,
            "an archive never waits"
        );
    }

    /// **F2 (a), refused: a stranger posting in a contact's thread.** Run 4's
    /// repro, step 2: anyone who read the alias off the wire seals "pay me" to
    /// our published key and self-sends it under the CONTACT's alias. The
    /// envelope opens, the alias routes, and until PRE3-SENDER it was filed as
    /// the contact's. Real path: the walk's page → `HubSink::fold` →
    /// `handle_inbound_comm`. The alias does route (asserted), so the refusal
    /// is the sender check's, not the alias gate's (PB-037).
    #[tokio::test]
    async fn a_strangers_comm_in_a_contacts_thread_is_refused() {
        let (hub, dir, _vault, key) = sender_hub("stranger");
        assert_eq!(
            hub.store
                .lock()
                .unwrap()
                .conversation_by_alias(THEIR_ALIAS)
                .map(|c| c.conversation_id.clone()),
            Some(VICTIM_ID.to_string()),
            "the alias routes to the victim's thread"
        );
        let event = page_comm(0x31, THEIR_ALIAS, &sealed(&key, b"pay me"), Some(ATTACKER));
        let txid = event.txid.clone().unwrap();
        walk_folds(&hub, event).await;
        assert!(
            thread(&hub).is_empty(),
            "a stranger's comm never enters the thread"
        );
        assert!(
            !comm_already_parked(&txid),
            "refused outright, never parked"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **F2 (b), refused: the contact's own old envelope, replayed.** Dedup is
    /// by txid, so the same sealed bytes in a fresh transaction were a fresh
    /// inbound row. Now the replay's sender is the replayer, and the thread
    /// keeps exactly the contact's original. Real path: as above, twice.
    #[tokio::test]
    async fn the_contacts_old_envelope_replayed_from_another_address_is_refused() {
        let (hub, dir, _vault, key) = sender_hub("replay");
        let envelope = sealed(&key, b"see you at eight");
        walk_folds(
            &hub,
            page_comm(0x41, THEIR_ALIAS, &envelope, Some(VICTIM_CONTACT)),
        )
        .await;
        walk_folds(
            &hub,
            page_comm(0x42, THEIR_ALIAS, &envelope, Some(ATTACKER)),
        )
        .await;
        let rows = thread(&hub);
        assert_eq!(
            rows.iter().map(|r| r.txid.as_str()).collect::<Vec<_>>(),
            [format!("{:02x}", 0x41).repeat(32).as_str()],
            "only the contact's own transaction is in the thread"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **One rule for our own alias.** `conversation_by_alias` matches either
    /// side, so our alias, which rides every comm we send, routes too. A
    /// stranger under it is refused like any other. Real path: as above.
    #[tokio::test]
    async fn our_own_alias_used_by_a_stranger_is_refused() {
        let (hub, dir, _vault, key) = sender_hub("own-alias");
        assert!(
            hub.store
                .lock()
                .unwrap()
                .conversation_by_alias(MY_ALIAS)
                .is_some(),
            "our alias routes to the thread"
        );
        walk_folds(
            &hub,
            page_comm(0x51, MY_ALIAS, &sealed(&key, b"it's me"), Some(ATTACKER)),
        )
        .await;
        assert!(thread(&hub).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The contact still writes.** Their comm, from their address, under
    /// their alias, lands as a node row in their thread; under our alias it
    /// lands too (one rule, the sender). This is the guard against the
    /// opposite mutant, a check that refuses the contact. Real path: as above.
    #[tokio::test]
    async fn the_contacts_own_comm_is_recorded() {
        let (hub, dir, _vault, key) = sender_hub("contact");
        walk_folds(
            &hub,
            page_comm(
                0x61,
                THEIR_ALIAS,
                &sealed(&key, b"hi"),
                Some(VICTIM_CONTACT),
            ),
        )
        .await;
        walk_folds(
            &hub,
            page_comm(
                0x62,
                MY_ALIAS,
                &sealed(&key, b"hi again"),
                Some(VICTIM_CONTACT),
            ),
        )
        .await;
        let rows = thread(&hub);
        assert_eq!(
            rows.len(),
            2,
            "both of the contact's comms are in the thread"
        );
        for row in &rows {
            assert_eq!(row.direction, MessageDirection::Inbound);
            assert_eq!(row.provenance, RowSource::NodeScanned);
            assert_eq!(row.sealed_to, None, "opened at the bound slot");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **An archive row must name the contact** (§0.10). The fill asks the
    /// archive for the contact's comms, and the archive's answer carries its
    /// own claim of who sent each row, parsed and ignored until now. A row
    /// claiming someone else, claiming no one, or carrying no claim is
    /// refused; the contact's row lands with its `archive` provenance, which
    /// is what the glass shows. Real path: `run_fill`'s comm sweep →
    /// `handle_inbound(…, Fill)` with `sender: Some(row.sender)`.
    #[tokio::test]
    async fn an_archive_row_whose_claimed_sender_disagrees_is_refused() {
        let (hub, dir, _vault, key) = sender_hub("archive");
        let fill =
            |n, sender: Option<&str>| page_comm(n, THEIR_ALIAS, &sealed(&key, b"old"), sender);
        for (n, claim) in [(0x71, Some(ATTACKER)), (0x72, Some("")), (0x73, None)] {
            let event = fill(n, claim);
            let txid = event.txid.clone().unwrap();
            assert_eq!(
                handle_inbound(&hub, event, EventOrigin::Fill).await,
                FoldOutcome::Settled
            );
            assert!(
                !comm_already_parked(&txid),
                "an archive row never waits on a lookup"
            );
        }
        assert!(
            thread(&hub).is_empty(),
            "no claim but the contact's is filed"
        );
        assert_eq!(
            handle_inbound(&hub, fill(0x74, Some(VICTIM_CONTACT)), EventOrigin::Fill).await,
            FoldOutcome::Recorded
        );
        let rows = thread(&hub);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            row_source_label(rows[0].provenance),
            "archive",
            "provenance on the glass"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Node truth over the archive's claim.** An archive row the archive
    /// filed as the contact's is removed when our own walk reaches its txid
    /// and names another sender; one our walk confirms becomes a node row.
    /// Real path: `run_fill` records the row, then the walk's `HubSink::fold`
    /// meets the same txid in OVERRIDE mode.
    #[tokio::test]
    async fn node_truth_removes_an_archive_row_it_disproves() {
        let (hub, dir, _vault, key) = sender_hub("override");
        let envelope = sealed(&key, b"claimed");
        let forged = page_comm(0x81, THEIR_ALIAS, &envelope, Some(VICTIM_CONTACT));
        let confirmed = page_comm(0x82, THEIR_ALIAS, &envelope, Some(VICTIM_CONTACT));
        let (forged_txid, confirmed_txid) = (
            forged.txid.clone().unwrap(),
            confirmed.txid.clone().unwrap(),
        );
        assert_eq!(
            handle_inbound(&hub, forged, EventOrigin::Fill).await,
            FoldOutcome::Recorded
        );
        assert_eq!(
            handle_inbound(&hub, confirmed, EventOrigin::Fill).await,
            FoldOutcome::Recorded
        );
        assert_eq!(thread(&hub).len(), 2);

        walk_folds(
            &hub,
            page_comm(0x81, THEIR_ALIAS, &envelope, Some(ATTACKER)),
        )
        .await;
        walk_folds(
            &hub,
            page_comm(0x82, THEIR_ALIAS, &envelope, Some(VICTIM_CONTACT)),
        )
        .await;
        let store = hub.store.lock().unwrap();
        assert!(
            store.message(&forged_txid).is_none(),
            "the disproven archive row is gone"
        );
        assert_eq!(
            store.message(&confirmed_txid).map(|r| r.provenance),
            Some(RowSource::NodeScanned),
            "the confirmed one is node truth now"
        );
        drop(store);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The fallback** (deliverable 4): a page that names no sender parks the
    /// comm for the return-address lane instead of filing it, and the lane's
    /// answer is held to the same rule: a stranger's is refused, the
    /// contact's lands as a node row. Real path: `HubSink::fold` parks →
    /// `SenderResolvable` (or the locate) → `adopt_alias_from_sender`'s lookup
    /// → `fold_parked_comm`, which this drives with the lookup's answer.
    #[tokio::test]
    async fn a_page_with_no_sender_waits_for_the_chain_to_name_one() {
        let (hub, dir, _vault, key) = sender_hub("fallback");
        let strangers = page_comm(0x91, THEIR_ALIAS, &sealed(&key, b"pay me"), None);
        let contacts = page_comm(0x92, THEIR_ALIAS, &sealed(&key, b"hello"), None);
        let (strangers_txid, contacts_txid) = (
            strangers.txid.clone().unwrap(),
            contacts.txid.clone().unwrap(),
        );
        walk_folds(&hub, strangers).await;
        walk_folds(&hub, contacts).await;
        assert!(
            thread(&hub).is_empty(),
            "nothing is filed before the chain names a sender"
        );
        assert!(comm_already_parked(&strangers_txid) && comm_already_parked(&contacts_txid));

        let parked = take_parked_comm(&strangers_txid).unwrap();
        fold_parked_comm(&hub, &strangers_txid, parked, ATTACKER);
        assert!(
            thread(&hub).is_empty(),
            "the lookup named a stranger: refused"
        );
        assert!(
            hub.store
                .lock()
                .unwrap()
                .conversation_by_contact_address(ATTACKER)
                .is_none(),
            "and the stranger is taught no alias, no row"
        );

        // A sibling the revival lane parked under the same alias, whose page
        // named someone else: refused when the contact's resolves, and
        // remembered against the archive.
        let sibling = "9a".repeat(32);
        park_comm(
            &sibling,
            ParkedComm {
                alias: THEIR_ALIAS.into(),
                slot: (Branch::Receive, 0),
                envelope: sealed(&key, b"me too"),
                block_time_ms: Some(1_727_000_000_000),
                wire: WireNamespace::KChat,
                sender: Some(INVITER.into()),
            },
        );
        let parked = take_parked_comm(&contacts_txid).unwrap();
        fold_parked_comm(&hub, &contacts_txid, parked, VICTIM_CONTACT);
        assert!(
            !comm_already_parked(&sibling),
            "another sender's sibling is refused"
        );
        assert!(is_refuted(&sibling), "and remembered against the archive");
        let rows = thread(&hub);
        assert_eq!(
            rows.iter().map(|r| r.txid.clone()).collect::<Vec<_>>(),
            [contacts_txid]
        );
        assert_eq!(rows[0].provenance, RowSource::NodeScanned);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A handshake and its first comm in ONE page both land** (PRE3-SENDER,
    /// `consensus-auditor` finding 1). A catch-up almost always carries a new
    /// contact's handshake and their first message together. The invitation
    /// used to be minted address-less and named seconds later, so the comm lane,
    /// which now admits only the row's contact, would have met an empty contact
    /// and refused that message for good. The handshake fold now takes the
    /// page's sender too, so the invitation knows who it is from at fold time.
    /// Real path: the walk's page → `HubSink::fold` → `handle_inbound_handshake`
    /// (no wallet engine here, so the return-address fallback can name no one:
    /// the page is the only source) → `handle_inbound_comm`.
    #[tokio::test]
    async fn a_handshake_and_its_first_comm_in_one_page_both_land() {
        use kaspaverse_chain::MessageSink;
        let (hub, dir, _vault, key) = sender_hub("one-page");
        let inviter = "kaspa:qp09uhj7te09uhj7te09uhj7te09uhj7te09uhj7te09uhj7te09un2xaekjp";
        let inviter_alias = "a1a1a1a1a1a1";
        let plaintext = HandshakePayload::initial(inviter_alias, 1_727_000_000_000)
            .unwrap()
            .to_plaintext()
            .unwrap();
        let wire = compose_handshake_wire(&sealed(&key, &plaintext)).unwrap();
        let (namespace, kind, body) = kaspaverse_chain::parse_payload_in(&wire).unwrap();
        let ours = hub.keys().watched.iter().next().unwrap().clone();
        let handshake = TransportEvent {
            txid: Some("a1".repeat(32)),
            kind,
            namespace,
            body: body.to_vec(),
            addresses: vec![ours],
            block_time_ms: Some(1_727_000_000_000),
            block_hash: Some("cb".repeat(32)),
            sender: Some(inviter.to_string()),
        };
        let comm = page_comm(
            0xa2,
            inviter_alias,
            &sealed(&key, b"hello, it's me"),
            Some(inviter),
        );
        let sink = HubSink { hub: hub.clone() };
        assert_eq!(
            sink.fold(vec![handshake, comm]).await,
            kaspaverse_chain::Verdict::Folded
        );
        let store = hub.store.lock().unwrap();
        let invitation = store
            .conversation_by_contact_address(inviter)
            .expect("the invitation knows its sender at fold time");
        assert_eq!(invitation.status, ConversationStatus::PendingInbound);
        let comms = store
            .messages_for(&invitation.conversation_id)
            .into_iter()
            .filter(|m| m.kind == StoredKind::Comm)
            .count();
        assert_eq!(comms, 1, "the first comm is in the invitation's thread");
        drop(store);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A restored contact is stored in the address's own form**
    /// (PRE3-SENDER, `consensus-auditor` finding 3). The pin's decoder drops
    /// non-zero padding bits, so a backup can spell a contact in a form that
    /// validates and is not canonical; stored raw, it would never equal the
    /// page's canonical sender and every message from that contact would be
    /// refused. The fixture is `VICTIM_CONTACT` with its padding bit set and
    /// its checksum recomputed; the first two assertions prove it is exactly
    /// that, without trusting how it was made. Real path: the self-stash
    /// restore → `restored_conversation` → the comm lane's sender check.
    #[test]
    fn a_restored_contact_is_stored_in_its_canonical_form() {
        const SAME_ADDRESS_OTHER_SPELLING: &str =
            "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xn2uxevjjg";
        let decoded = Address::try_from(SAME_ADDRESS_OTHER_SPELLING).expect("it validates");
        assert_eq!(
            decoded.to_string(),
            VICTIM_CONTACT,
            "it is the victim's contact"
        );
        let row = restored_conversation(
            &stash_payload("aaaaaaaaaaaa", SAME_ADDRESS_OTHER_SPELLING, "r-canon"),
            30,
            30,
        )
        .expect("a valid row");
        assert_eq!(row.contact_address, VICTIM_CONTACT);
        assert_eq!(
            comm_sender_verdict(
                EventOrigin::Node,
                Some(VICTIM_CONTACT),
                &row.contact_address
            ),
            CommSenderVerdict::Contact,
            "so the contact's own comm is admitted"
        );
    }

    const INVITER: &str = "kaspa:qp09uhj7te09uhj7te09uhj7te09uhj7te09uhj7te09uhj7te09un2xaekjp";
    const INVITER_ALIAS: &str = "b2b2b2b2b2b2";

    /// A handshake from `INVITER` sealed to our key, as a page or an archive
    /// row carries it: `sender` is the page's (node) or nothing (archive).
    fn handshake_event(
        hub: &TransportHub,
        key: &[u8; 32],
        n: u8,
        sender: Option<&str>,
    ) -> TransportEvent {
        handshake_event_as(hub, key, n, sender, INVITER_ALIAS)
    }

    /// [`handshake_event`] under a test's own alias: the parked set is
    /// process-wide and tests run in parallel, so two tests that park under one
    /// (alias, sender) would release each other's comms.
    fn handshake_event_as(
        hub: &TransportHub,
        key: &[u8; 32],
        n: u8,
        sender: Option<&str>,
        alias: &str,
    ) -> TransportEvent {
        let plaintext = HandshakePayload::initial(alias, 1_727_000_000_000)
            .unwrap()
            .to_plaintext()
            .unwrap();
        let wire = compose_handshake_wire(&sealed(key, &plaintext)).unwrap();
        let (namespace, kind, body) = kaspaverse_chain::parse_payload_in(&wire).unwrap();
        TransportEvent {
            txid: Some(format!("{n:02x}").repeat(32)),
            kind,
            namespace,
            body: body.to_vec(),
            addresses: vec![hub.keys().watched.iter().next().unwrap().clone()],
            block_time_ms: Some(1_727_000_000_000),
            block_hash: sender.map(|_| "cb".repeat(32)),
            sender: sender.map(str::to_string),
        }
    }

    /// **An invitation that does not know its sender HOLDS what it is sent**
    /// (PRE3-SENDER, `wallet-security-auditor` CONCERNS-1). An archive's
    /// invitation is minted address-less (D-139). The comm lane admits only a
    /// row's contact, and a settled refusal could never be judged again, so a
    /// comm meeting an address-less row is parked with its page's sender. When
    /// our own node folds the handshake, its page names the invitation, and
    /// the held comms are judged: the sender's lands, a stranger's under the
    /// same alias is refused. Real path: `run_fill` → `handle_inbound(Fill)`
    /// mints the invitation; the walk's `HubSink::fold` holds the comms; the
    /// walk reaching the handshake's txid takes `handle_inbound_handshake`'s
    /// OVERRIDE branch, which names it and calls `release_held_comms`.
    #[tokio::test]
    async fn an_invitation_holds_its_senders_comms_until_it_learns_who_sent_them() {
        let (hub, dir, _vault, key) = sender_hub("hold");
        assert_eq!(
            handle_inbound(
                &hub,
                handshake_event(&hub, &key, 0xb1, None),
                EventOrigin::Fill
            )
            .await,
            FoldOutcome::Recorded
        );
        let invitation = hub
            .store
            .lock()
            .unwrap()
            .conversation_by_alias(INVITER_ALIAS)
            .cloned()
            .unwrap();
        assert_eq!(invitation.status, ConversationStatus::PendingInbound);
        assert!(
            invitation.contact_address.is_empty(),
            "an archive sets no identity"
        );

        let theirs = page_comm(
            0xb2,
            INVITER_ALIAS,
            &sealed(&key, b"before you accept"),
            Some(INVITER),
        );
        let strangers = page_comm(
            0xb3,
            INVITER_ALIAS,
            &sealed(&key, b"pay me"),
            Some(ATTACKER),
        );
        let (theirs_txid, strangers_txid) = (
            theirs.txid.clone().unwrap(),
            strangers.txid.clone().unwrap(),
        );
        walk_folds(&hub, theirs).await;
        walk_folds(&hub, strangers).await;
        let comms = |hub: &TransportHub| {
            hub.store
                .lock()
                .unwrap()
                .messages_for(&invitation.conversation_id)
                .into_iter()
                .filter(|m| m.kind == StoredKind::Comm)
                .map(|m| m.txid)
                .collect::<Vec<_>>()
        };
        assert!(
            comms(&hub).is_empty(),
            "nothing is filed while the sender is unknown"
        );
        assert!(
            comm_already_parked(&theirs_txid) && comm_already_parked(&strangers_txid),
            "held, not refused"
        );
        // While it is held, an archive serves the same txid in a contact's
        // sweep, claiming the contact: it gets no hearing ahead of our node's
        // (`wallet-security-auditor` CONCERNS-C), or it would win the dedup.
        let forged = page_comm(
            0xb2,
            THEIR_ALIAS,
            &sealed(&key, b"forged"),
            Some(VICTIM_CONTACT),
        );
        assert_eq!(
            handle_inbound(&hub, forged, EventOrigin::Fill).await,
            FoldOutcome::Settled
        );
        assert!(thread(&hub).is_empty(), "the archive's copy is not filed");

        walk_folds(&hub, handshake_event(&hub, &key, 0xb1, Some(INVITER))).await;
        let named = hub
            .store
            .lock()
            .unwrap()
            .conversation(&invitation.conversation_id)
            .cloned()
            .unwrap();
        assert_eq!(
            named.contact_address, INVITER,
            "our node named the invitation"
        );
        assert_eq!(
            comms(&hub),
            [theirs_txid],
            "the sender's comm lands, the stranger's does not"
        );
        assert!(
            !comm_already_parked(&strangers_txid),
            "the stranger's is refused, not kept"
        );
        assert!(
            is_refuted(&strangers_txid),
            "and remembered against the archive"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A txid our walk refused is never filed from the archive**
    /// (`wallet-security-auditor` CONCERNS-2). The fill runs after the walk
    /// settles, so in the ordinary order the walk refuses a stranger's comm
    /// first and writes nothing; a hostile archive then claims "the contact
    /// sent it" for that txid. Real path: the walk's `HubSink::fold`, then
    /// `run_fill`'s comm sweep → `handle_inbound(Fill)`.
    #[tokio::test]
    async fn a_txid_our_walk_refused_is_never_filed_from_the_archive() {
        let (hub, dir, _vault, key) = sender_hub("refuted");
        let envelope = sealed(&key, b"pay me");
        walk_folds(
            &hub,
            page_comm(0xc1, THEIR_ALIAS, &envelope, Some(ATTACKER)),
        )
        .await;
        assert_eq!(
            handle_inbound(
                &hub,
                page_comm(0xc1, THEIR_ALIAS, &envelope, Some(VICTIM_CONTACT)),
                EventOrigin::Fill
            )
            .await,
            FoldOutcome::Settled
        );
        assert!(
            thread(&hub).is_empty(),
            "the archive's claim gets no second hearing"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **An archive row filed under an alias the chain does not show is
    /// removed** (`wallet-security-auditor` CONCERNS-2): our node's own
    /// transaction for that txid carries an alias none of our rows answers to,
    /// so the archive's filing is disproven before the revival judges the
    /// real comm. The node's sender is the contact here, so it is the alias
    /// alone that disproves (the sender rule has its own test). Real path:
    /// `run_fill` records the row, then the walk's `HubSink::fold` meets the
    /// txid with the chain's alias.
    #[tokio::test]
    async fn an_archive_row_under_an_alias_the_chain_does_not_show_is_removed() {
        let (hub, dir, _vault, key) = sender_hub("alias-disproved");
        let envelope = sealed(&key, b"claimed");
        let filed = page_comm(0xd1, THEIR_ALIAS, &envelope, Some(VICTIM_CONTACT));
        let txid = filed.txid.clone().unwrap();
        assert_eq!(
            handle_inbound(&hub, filed, EventOrigin::Fill).await,
            FoldOutcome::Recorded
        );
        walk_folds(
            &hub,
            page_comm(0xd1, "dddddddddddd", &envelope, Some(VICTIM_CONTACT)),
        )
        .await;
        assert!(
            hub.store.lock().unwrap().message(&txid).is_none(),
            "the archive's filing is gone"
        );
        assert!(is_refuted(&txid));
        let _ = take_parked_comm(&txid);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **An archive's invitation is never named from its txid label**
    /// (`wallet-security-auditor` round 2, CONCERNS-A; D-139). The sender
    /// lookup answers for any txid our wallet has a record of, so an archive
    /// could pair its own handshake with a real payment's txid and have the
    /// resweep name its row after a real contact, whose alias and key slot the
    /// merge would then take. Only a handshake row our node scanned may be
    /// named that way. Real path: `resweep_invitation_senders` and
    /// `backfill_invitation_sender` select rows through `nameable_invitation`.
    #[tokio::test]
    async fn an_archive_invitation_is_never_named_from_its_txid_label() {
        let (hub, dir, _vault, key) = sender_hub("label");
        handle_inbound(
            &hub,
            handshake_event(&hub, &key, 0xe1, None),
            EventOrigin::Fill,
        )
        .await;
        {
            let store = hub.store.lock().unwrap();
            let archives = store.conversation_by_alias(INVITER_ALIAS).cloned().unwrap();
            assert!(archives.contact_address.is_empty());
            assert!(
                !nameable_invitation(&store, &archives),
                "an archive's label names no one"
            );
        }
        // The same invitation as our node saw it with no page sender (off the
        // pin): its row is node truth, so the lookup may name it.
        let (hub2, dir2b, _vault2, key2) = sender_hub("label-node");
        handle_inbound(
            &hub2,
            handshake_event(&hub2, &key2, 0xe2, None),
            EventOrigin::Node,
        )
        .await;
        let store2 = hub2.store.lock().unwrap();
        let nodes = store2
            .conversation_by_alias(INVITER_ALIAS)
            .cloned()
            .unwrap();
        assert!(
            nodes.contact_address.is_empty(),
            "no page sender, no engine: unnamed"
        );
        assert!(
            nameable_invitation(&store2, &nodes),
            "a node-scanned invitation may be named"
        );
        drop(store2);
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&dir2b);
    }

    /// **Held comms land in the row the merge keeps** (`wallet-security-
    /// auditor` round 2, CONCERNS-B). When our node names an archive's
    /// invitation after a contact we already hold, the merge folds it into
    /// that contact's row, which may keep its own alias. Routed by the held
    /// alias, the comms would find no row and be lost; released into the merge
    /// host, they land. Real path: the walk's `HubSink::fold` holds the comm;
    /// the OVERRIDE branch names the invitation, merges, and releases into the
    /// host.
    #[tokio::test]
    async fn held_comms_land_in_the_row_a_merge_keeps() {
        const MERGE_ALIAS: &str = "f0f0f0f0f0f0";
        let (hub, dir, _vault, key) = sender_hub("merge");
        hub.store
            .lock()
            .unwrap()
            .upsert_conversation(ConversationRecord {
                conversation_id: "c-host".into(),
                contact_address: INVITER.into(),
                my_alias: "0ld0ld0ld0ld".into(),
                their_alias: Some("a0a0a0a0a0a0".into()),
                status: ConversationStatus::Active,
                initiated_by_me: true,
                bound_branch: KeyBranch::Receive,
                bound_index: 0,
                // Announced after the invitation's handshake, so the host's own
                // alias survives the merge.
                created_unix_ms: 1_800_000_000_000,
                last_activity_unix_ms: 1_800_000_000_000,
                handshake_txid: None,
            })
            .unwrap();
        handle_inbound(
            &hub,
            handshake_event_as(&hub, &key, 0xf1, None, MERGE_ALIAS),
            EventOrigin::Fill,
        )
        .await;
        let held = page_comm(0xf2, MERGE_ALIAS, &sealed(&key, b"it's me"), Some(INVITER));
        let held_txid = held.txid.clone().unwrap();
        walk_folds(&hub, held).await;
        assert!(comm_already_parked(&held_txid), "held");
        walk_folds(
            &hub,
            handshake_event_as(&hub, &key, 0xf1, Some(INVITER), MERGE_ALIAS),
        )
        .await;
        let store = hub.store.lock().unwrap();
        assert_eq!(
            store
                .conversation("c-host")
                .and_then(|c| c.their_alias.clone())
                .as_deref(),
            Some("a0a0a0a0a0a0"),
            "the host kept its own alias, so the held alias routes nowhere"
        );
        assert_eq!(
            store.message_conversation(&held_txid).as_deref(),
            Some("c-host"),
            "the held comm landed in the host"
        );
        drop(store);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **An archive row whose alias merely stopped routing is kept**
    /// (`wallet-security-auditor` round 2, N1). Our node's transaction carries
    /// the very alias the archive filed it under; the contact has since
    /// re-handshaked, so that alias routes nowhere now. Nothing is disproven:
    /// the row stays an archive row. Only a node alias different from the
    /// filed one disproves a filing. Real path: `run_fill` files the row; the
    /// contact's re-handshake moves their alias; the walk's `HubSink::fold`
    /// meets the txid.
    #[tokio::test]
    async fn an_archive_row_whose_alias_stopped_routing_is_kept() {
        // Its own alias: the parked set is process-wide, and the revival below
        // parks this comm under (alias, contact) for the rest of the run.
        const OLD_ALIAS: &str = "5a5a5a5a5a5a";
        let (hub, dir, _vault, key) = sender_hub("stale-alias");
        {
            let mut store = hub.store.lock().unwrap();
            let mut row = store.conversation(VICTIM_ID).cloned().unwrap();
            row.their_alias = Some(OLD_ALIAS.into());
            store.upsert_conversation(row).unwrap();
        }
        let envelope = sealed(&key, b"genuine");
        let filed = page_comm(0x15, OLD_ALIAS, &envelope, Some(VICTIM_CONTACT));
        let txid = filed.txid.clone().unwrap();
        assert_eq!(
            handle_inbound(&hub, filed, EventOrigin::Fill).await,
            FoldOutcome::Recorded
        );
        {
            let mut store = hub.store.lock().unwrap();
            let mut row = store.conversation(VICTIM_ID).cloned().unwrap();
            row.their_alias = Some("fefefefefefe".into());
            store.upsert_conversation(row).unwrap();
        }
        walk_folds(
            &hub,
            page_comm(0x15, OLD_ALIAS, &envelope, Some(VICTIM_CONTACT)),
        )
        .await;
        assert_eq!(
            hub.store
                .lock()
                .unwrap()
                .message(&txid)
                .map(|r| r.provenance),
            Some(RowSource::FillSourced),
            "a genuine filing is not removed"
        );
        assert!(!is_refuted(&txid));
        let _ = take_parked_comm(&txid);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **A blocked sender's other held comms go with it, and only its own**
    /// (`wallet-security-auditor` round 2, N3; `consensus-auditor` re-audit,
    /// CONCERNS-1): a blocked knock keeps its handshake row and nothing else,
    /// so what that address left parked under the alias must not wait for a
    /// later accept; a contact's comm parked under the same public alias is
    /// untouched. Real path: the return-address lookup names a blocked sender →
    /// `fold_parked_comm`.
    #[tokio::test]
    async fn a_blocked_senders_other_parked_comms_are_dropped() {
        let (hub, dir, _vault, key) = sender_hub("blocked");
        hub.block_list.lock().unwrap().block(INVITER, 1_000);
        let parked = |n: u8| ParkedComm {
            alias: "c3c3c3c3c3c3".into(),
            slot: (Branch::Receive, 0),
            envelope: sealed(&key, b"knock"),
            block_time_ms: Some(1_727_000_000_000 + u64::from(n)),
            wire: WireNamespace::KChat,
            sender: Some(INVITER.into()),
        };
        let (first, second) = ("a5".repeat(32), "a6".repeat(32));
        park_comm(&second, parked(2));
        let third = "a7".repeat(32);
        park_comm(
            &third,
            ParkedComm {
                sender: Some(VICTIM_CONTACT.into()),
                ..parked(3)
            },
        );
        fold_parked_comm(&hub, &first, parked(1), INVITER);
        assert!(
            !comm_already_parked(&second),
            "the knock's other comm is dropped too"
        );
        // A contact's comm parked beside it under the same public alias is not
        // the blocked address's to take (`consensus-auditor`): it keeps its own
        // lookup, unrefuted.
        assert!(
            comm_already_parked(&third),
            "another sender's comm stays parked"
        );
        assert!(!is_refuted(&third));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The override names only the invitation whose own handshake it is**
    /// (`consensus-auditor` re-audit, CONCERNS-2). The override finds its row
    /// by where the archive filed the txid. A store from before PRE3-SENDER can
    /// hold an archive COMM inside an address-less invitation; when our node
    /// later folds that txid as a handshake, the invitation must not be named
    /// from another transaction's sender. Real path: the walk's `HubSink::fold`
    /// → `handle_inbound_handshake`'s OVERRIDE branch.
    #[tokio::test]
    async fn the_override_names_only_the_invitation_whose_handshake_it_is() {
        let (hub, dir, _vault, key) = sender_hub("override-guard");
        let filed_txid = "e7".repeat(32);
        {
            let mut store = hub.store.lock().unwrap();
            store
                .upsert_conversation(ConversationRecord {
                    conversation_id: "c-old-invite".into(),
                    contact_address: String::new(),
                    my_alias: String::new(),
                    their_alias: Some("e6e6e6e6e6e6".into()),
                    status: ConversationStatus::PendingInbound,
                    initiated_by_me: false,
                    bound_branch: KeyBranch::Receive,
                    bound_index: 0,
                    created_unix_ms: 1_000,
                    last_activity_unix_ms: 1_000,
                    handshake_txid: Some("e5".repeat(32)),
                })
                .unwrap();
            store
                .record_message(MessageRecord {
                    txid: filed_txid.clone(),
                    conversation_id: "c-old-invite".into(),
                    direction: MessageDirection::Inbound,
                    kind: StoredKind::Comm,
                    envelope: sealed(&key, b"an older build's archive comm"),
                    unix_ms: 1_000,
                    alias_on_wire: Some("e6e6e6e6e6e6".into()),
                    sealed_to: None,
                    provenance: RowSource::FillSourced,
                    wire: WireNamespace::CiphMsg,
                })
                .unwrap();
        }
        walk_folds(
            &hub,
            handshake_event_as(&hub, &key, 0xe7, Some(INVITER), "e8e8e8e8e8e8"),
        )
        .await;
        let store = hub.store.lock().unwrap();
        assert_eq!(
            store
                .conversation("c-old-invite")
                .map(|c| c.contact_address.clone())
                .as_deref(),
            Some(""),
            "another transaction's sender names no one"
        );
        drop(store);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **…and removed when our node names another sender** (`wallet-security-
    /// auditor` confirmation, note 2). The alias stopped routing, so the alias
    /// proves nothing either way; the sender still does. Real path: as above,
    /// with the walk's page naming a stranger.
    #[tokio::test]
    async fn an_archive_row_whose_alias_stopped_routing_falls_to_a_stranger_sender() {
        const OLD_ALIAS: &str = "6b6b6b6b6b6b";
        let (hub, dir, _vault, key) = sender_hub("stale-alias-stranger");
        {
            let mut store = hub.store.lock().unwrap();
            let mut row = store.conversation(VICTIM_ID).cloned().unwrap();
            row.their_alias = Some(OLD_ALIAS.into());
            store.upsert_conversation(row).unwrap();
        }
        let envelope = sealed(&key, b"claimed");
        let filed = page_comm(0x16, OLD_ALIAS, &envelope, Some(VICTIM_CONTACT));
        let txid = filed.txid.clone().unwrap();
        assert_eq!(
            handle_inbound(&hub, filed, EventOrigin::Fill).await,
            FoldOutcome::Recorded
        );
        {
            let mut store = hub.store.lock().unwrap();
            let mut row = store.conversation(VICTIM_ID).cloned().unwrap();
            row.their_alias = Some("fdfdfdfdfdfd".into());
            store.upsert_conversation(row).unwrap();
        }
        walk_folds(&hub, page_comm(0x16, OLD_ALIAS, &envelope, Some(ATTACKER))).await;
        assert!(
            hub.store.lock().unwrap().message(&txid).is_none(),
            "a stranger's transaction is not the contact's archive row"
        );
        assert!(is_refuted(&txid));
        let _ = take_parked_comm(&txid);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Only a HANDSHAKE row names an invitation** (a sibling session's
    /// `wallet-security-auditor`, forwarded and verified). The provenance gate
    /// reads a row's provenance, not its kind: a node-scanned COMM row under
    /// the invitation's `handshake_txid` must not pass for its handshake. Real
    /// path: `resweep_invitation_senders` / `backfill_invitation_sender`
    /// select through `nameable_invitation`.
    #[tokio::test]
    async fn a_comm_row_under_the_label_names_no_invitation() {
        let (hub, dir, _vault, key) = sender_hub("label-kind");
        let label = "4c".repeat(32);
        let mut store = hub.store.lock().unwrap();
        let invitation = ConversationRecord {
            conversation_id: "c-label-kind".into(),
            contact_address: String::new(),
            my_alias: String::new(),
            their_alias: Some("4d4d4d4d4d4d".into()),
            status: ConversationStatus::PendingInbound,
            initiated_by_me: false,
            bound_branch: KeyBranch::Receive,
            bound_index: 0,
            created_unix_ms: 1_000,
            last_activity_unix_ms: 1_000,
            handshake_txid: Some(label.clone()),
        };
        store.upsert_conversation(invitation.clone()).unwrap();
        store
            .record_message(MessageRecord {
                txid: label.clone(),
                conversation_id: VICTIM_ID.into(),
                direction: MessageDirection::Inbound,
                kind: StoredKind::Comm,
                envelope: sealed(&key, b"a node comm"),
                unix_ms: 1_000,
                alias_on_wire: Some(THEIR_ALIAS.into()),
                sealed_to: None,
                provenance: RowSource::NodeScanned,
                wire: WireNamespace::KChat,
            })
            .unwrap();
        assert!(
            !nameable_invitation(&store, &invitation),
            "a comm is not the invitation's handshake"
        );
        drop(store);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The refutation memory is bounded, oldest out** (a sibling session's
    /// `consensus-auditor`, forwarded and verified): a refusal is
    /// attacker-mintable at chain rate, so the set holds at most
    /// `REFUTED_CAPACITY` txids and forgets the oldest first; a repeat is not
    /// a second entry.
    #[test]
    fn the_refutation_memory_is_bounded_oldest_out() {
        let mut set = RefutedTxids::new();
        set.note("first");
        set.note("first");
        assert_eq!(set.order.len(), 1, "a repeat is one entry");
        for n in 0..REFUTED_CAPACITY {
            set.note(&format!("{n:064x}"));
        }
        assert_eq!(set.order.len(), REFUTED_CAPACITY, "bounded");
        assert!(!set.contains("first"), "the oldest went first");
        assert!(set.contains(&format!("{:064x}", REFUTED_CAPACITY - 1)));
        assert!(set.contains(&format!("{:064x}", 0)));
    }

    /// **F30 through every erase lane.** Clear, hide and block leave the
    /// removed message's sealed bytes in no file of the store's folder: not in
    /// `messages.kvlog`, and not in a copy an earlier load kept aside (planted
    /// here). The start sweep compacts the log but leaves the copy, which may
    /// be the one this very start made. The search finds the words before
    /// (it can look). Each lane's store half is the code the public call runs.
    #[test]
    fn every_erase_lane_takes_the_words_out_of_the_file() {
        let holding = |dir: &std::path::Path, needle: &[u8]| -> Vec<String> {
            let mut found: Vec<String> = std::fs::read_dir(dir)
                .unwrap()
                .map(|e| e.unwrap().path())
                .filter(|path| {
                    std::fs::read(path)
                        .map(|bytes| bytes.windows(needle.len()).any(|w| w == needle))
                        .unwrap_or(false)
                })
                .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
                .collect();
            found.sort();
            found
        };
        for (n, lane) in ["clear", "hide", "block", "sweep"].into_iter().enumerate() {
            let (mut store, dir) = stash_store(&format!("f30-{lane}"));
            store
                .upsert_conversation(row_for("thread", PARTNER_A, ConversationStatus::Active))
                .unwrap();
            let words: Vec<u8> = (0..61u8)
                .map(|i| i.wrapping_mul(29) ^ (0x40 + n as u8))
                .collect();
            store
                .record_message(MessageRecord {
                    txid: format!("said-{lane}"),
                    conversation_id: "thread".into(),
                    direction: MessageDirection::Inbound,
                    kind: StoredKind::Comm,
                    envelope: words.clone(),
                    unix_ms: 1,
                    alias_on_wire: None,
                    sealed_to: None,
                    provenance: RowSource::NodeScanned,
                    wire: WireNamespace::CiphMsg,
                })
                .unwrap();
            let aside = "messages.kvlog.unreadable-1-00000000";
            std::fs::copy(dir.join("messages.kvlog"), dir.join(aside)).unwrap();
            assert_eq!(
                holding(&dir, &words),
                ["messages.kvlog", aside],
                "{lane}: before, the search finds the words"
            );

            match lane {
                "clear" => assert_eq!(clear_conversation_rows(&mut store, "thread").unwrap(), 1),
                "hide" => hide_conversation_rows(&mut store, "thread").unwrap(),
                "block" => {
                    let (purged, scrubbed) = block_purge(&mut store, PARTNER_A).unwrap();
                    assert_eq!(purged, (1, 1));
                    scrubbed.unwrap();
                }
                _ => assert_eq!(
                    sweep_blocked_rows(&mut store, &[PARTNER_A.to_string()]),
                    (1, 1)
                ),
            }
            let expected: &[&str] = if lane == "sweep" { &[aside] } else { &[] };
            assert_eq!(
                holding(&dir, &words),
                expected,
                "{lane}: after, no file holds the words but what the lane may not touch"
            );
            assert!(TransportStore::load(dir.clone())
                .unwrap()
                .message(&format!("said-{lane}"))
                .is_none());
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    /// **One store per directory per process** (PRE3-LOG): every hub
    /// generation gets the same store and block list, so a lane still holding
    /// an old hub writes through the same log as the live one, and nothing is
    /// cut or refused. Both writes survive a reload.
    #[test]
    fn every_hub_generation_shares_one_store_and_one_block_list() {
        let dir = std::env::temp_dir().join(format!("kv-hub-stores-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (old_store, old_list) = hub_stores(&dir).unwrap();
        let (new_store, new_list) = hub_stores(&dir).unwrap();
        assert!(Arc::ptr_eq(&old_store, &new_store));
        assert!(Arc::ptr_eq(&old_list, &new_list));

        new_store
            .lock()
            .unwrap()
            .upsert_conversation(row_for("live", PARTNER_A, ConversationStatus::Active))
            .unwrap();
        old_store
            .lock()
            .unwrap()
            .upsert_conversation(row_for("stale", PARTNER_A, ConversationStatus::Active))
            .unwrap();
        let reloaded = TransportStore::load(dir.clone()).unwrap();
        assert!(reloaded.conversation("live").is_some());
        assert!(reloaded.conversation("stale").is_some());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **Hide reports a removal it could not make, and does not hide**
    /// (`ffi-leak-auditor` + `wallet-security-auditor`, PRE3-LOG): never Ok
    /// over words still in the file, and never a hidden row no retry reaches.
    #[test]
    fn hide_reports_a_removal_it_could_not_make() {
        let (mut store, dir) = stash_store("hide-unremoved");
        store
            .upsert_conversation(row_for("thread", PARTNER_A, ConversationStatus::Active))
            .unwrap();
        message_in(&mut store, "m1", "thread", StoredKind::Comm);
        // One byte appended behind the store: the log refuses to write over
        // bytes it does not own, so the removal fails, whoever runs the test.
        let log = dir.join("messages.kvlog");
        let mut bytes = std::fs::read(&log).unwrap();
        bytes.push(0x5A);
        std::fs::write(&log, &bytes).unwrap();

        assert!(hide_conversation_rows(&mut store, "thread").is_err());
        assert!(
            store.message("m1").is_some(),
            "the row was not removed, and hide says so"
        );
        assert!(
            !store.is_conversation_tombstoned("thread"),
            "and the thread stays listed, so a retry can reach the row"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// **The start finishes a scrub an erase could not** (`consensus-auditor`,
    /// PRE3-LOG): the start's store step runs `finish_removals`, so a copy that
    /// could not be deleted at the erase is deleted at the next start.
    #[test]
    fn the_start_step_finishes_a_failed_scrub() {
        let (mut store, dir) = stash_store("start-finishes");
        store
            .upsert_conversation(row_for("thread", PARTNER_A, ConversationStatus::Active))
            .unwrap();
        message_in(&mut store, "m1", "thread", StoredKind::Comm);
        let aside = dir.join("messages.kvlog.unreadable-8-1-00000000");
        std::fs::create_dir_all(aside.join("undeletable")).unwrap();
        assert!(
            clear_conversation_rows(&mut store, "thread").is_err(),
            "the scrub failed"
        );

        std::fs::remove_dir_all(&aside).unwrap();
        std::fs::write(&aside, b"the words").unwrap();
        start_store_step(&mut store, &[]);
        assert!(
            !aside.exists(),
            "the start deleted the copy the erase could not"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
