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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use kaspaverse_chain::{
    compose_bcast, compose_comm_wire, compose_handshake_wire, compose_self_stash_wire,
    decode_envelope_body, parse_payload, resolve_return_address, split_comm_body, AcceptanceEvent,
    Address, ChainError, ConversationRecord, ConversationStatus, KeyBranch, MessageDirection,
    MessageRecord, PreparedSend, RowSource, SignerT, StoredKind, TransportEvent, TransportStore,
    UtxoEntryReference, WalletEngine, WatchSource, HANDSHAKE_BOND_SOMPI,
    STASH_SCOPE_SAVED_HANDSHAKE,
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
    /// This thread has been REPLACED by a newer live one with the same
    /// counterparty, and typing here would reach nobody.
    ///
    /// A conversation is a pair of locally-minted aliases, and the protocol's
    /// only repair is for one side to forget and re-handshake. When they do,
    /// we correctly accept the new handshake — and the old row is left holding
    /// an alias no one monitors any more. Sending into it succeeds at every
    /// layer we control (built, signed, broadcast, fee paid) and is read by no
    /// one. This bool is what lets the UI say so instead of the user
    /// discovering it hours later.
    ///
    /// Derived per pull from the record set, never stored — see
    /// `TransportStore::superseded_by`.
    pub superseded: bool,
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
#[derive(Clone, Debug)]
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
static HUB_TASK: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);
/// V1 consumer #2 (reorg tombstones) — replaced like [`HUB_TASK`] on re-unlock
/// so one stream never feeds two folders.
static ACCEPTANCE_TASK: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);
/// F4's reconnect replay — replaced like [`HUB_TASK`] so a re-unlock never
/// leaves two tasks walking the DAG over the same gap.
static REPLAY_TASK: Mutex<Option<tokio::task::JoinHandle<()>>> = Mutex::new(None);

/// Which block the reconnect replay must walk from (F4) — the whole subtlety
/// of that fix, kept as a state machine so it can be proven without a socket.
///
/// The bound is captured when the socket **drops**. Reading the cursor when the
/// replay wakes instead would look identical and do nothing: subscriptions are
/// registered before `emit(Connected)` in `handle_connect`, so post-reconnect
/// `BlockAdded` notifications can already have advanced the persisted cursor
/// past the gap by then, and the walk would start above the messages it exists
/// to recover.
/// Deliberately NOT `#[derive(Default)]`. A derived `Default` is a **public**
/// associated fn returning this type, and FRB reads that as a reason to export
/// it: codegen generated a whole Dart `ReplayGap` class and pulled `Hash` into
/// a new generated `lib.dart`, putting an internal state machine on the FFI
/// surface for nothing. A private constructor keeps this side of the bridge.
struct ReplayGap {
    low: Option<kaspaverse_chain::Hash>,
}

impl ReplayGap {
    fn new() -> Self {
        Self { low: None }
    }

    /// The socket dropped. `cursor_now` is the persisted cursor read at this
    /// instant — at most `TRANSPORT_CURSOR_MIN_WRITE_SECS` behind the true
    /// drop point, which errs BELOW the gap, where dedup-by-txid absorbs it.
    ///
    /// **Earliest bound wins**, the same rule as [`Self::on_lag`]. An armed
    /// bound is only ever cleared by a `Connected` that consumed it, so if one
    /// survives to here its gap is still unwalked and it is necessarily the
    /// earlier of the two. Overwriting would raise the floor above that gap —
    /// the silent no-op this type exists to prevent, arriving by a second door
    /// — and an unguarded `on_drop(None)` would erase an armed bound outright.
    /// Reachable whenever a `Connected` is lost to a lag, which the sizing
    /// below makes ordinary rather than exotic.
    fn on_drop(&mut self, cursor_now: Option<kaspaverse_chain::Hash>) {
        self.arm(cursor_now);
    }

    /// Events were lost, and a drop may be among them. Arm from the best bound
    /// available rather than assume the window was covered (PB-025).
    fn on_lag(&mut self, cursor_now: Option<kaspaverse_chain::Hash>) {
        self.arm(cursor_now);
    }

    /// One rule, one place: never raise the floor, never clear an armed bound.
    fn arm(&mut self, cursor_now: Option<kaspaverse_chain::Hash>) {
        if self.low.is_none() {
            self.low = cursor_now;
        }
    }

    /// The socket came back. `None` = nothing to replay (the first connect of a
    /// session, whose gap the unlock catch-up already owns). One shot: a bound
    /// consumed here must not re-walk on the next reconnect.
    fn on_connect(&mut self) -> Option<kaspaverse_chain::Hash> {
        self.low.take()
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
    let report = fill_walks(hub, &dir, &config).await;
    FILL_RUNNING.store(false, Ordering::SeqCst);
    *LAST_FILL.lock().unwrap_or_else(PoisonError::into_inner) = Some(report.clone());
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
                            if dropped(SELF_STASH, &row.tx_id, reason, EventOrigin::Fill)
                                == FoldOutcome::Held
                            {
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
                                        == FoldOutcome::Held
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
                            FoldOutcome::Held => held.hold(0),
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
            };
            if erase_epoch() != epoch {
                return abandon_wiped_walk(report);
            }
            match handle_inbound(hub, event, EventOrigin::Fill).await {
                FoldOutcome::Recorded => report.new_rows += 1,
                FoldOutcome::Settled => {}
                FoldOutcome::Held => held.hold(row.block_time),
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
                body,
                addresses: Vec::new(),
                block_time_ms: Some(row.block_time),
            };
            if erase_epoch() != epoch {
                return abandon_wiped_walk(report);
            }
            match handle_inbound(hub, event, EventOrigin::Fill).await {
                FoldOutcome::Recorded => report.new_rows += 1,
                FoldOutcome::Settled => {}
                FoldOutcome::Held => held.hold(row.block_time),
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
    validate_mainnet_address(&payload.partner_address).ok()?;

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
        contact_address: payload.partner_address.clone(),
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
fn stash_row_is_free(store: &TransportStore, record: &ConversationRecord) -> bool {
    let live = |id: &str| !store.is_conversation_tombstoned(id);
    let alias_is_free = |alias: &str| {
        store
            .conversation_by_alias(alias)
            .is_none_or(|c| !live(&c.conversation_id))
    };
    store.conversation(&record.conversation_id).is_none()
        && store
            .conversations_for_contact_address(&record.contact_address)
            .iter()
            .all(|c| !live(&c.conversation_id))
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
    let conversation_id = record.conversation_id.clone();
    {
        let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
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

    let transport_dir = vault::transport_store_dir()?;
    let store = TransportStore::load(transport_dir.clone()).map_err(AppError::chain)?;
    let cursor_path = transport_dir.join("scan.cursor");
    // The PRIOR session's last scan point, read BEFORE we arm the live cursor —
    // the anchor for the catch-up replay (P5/D-067). None on first ever run.
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
        store: Mutex::new(store),
        decryptor,
        keys: Mutex::new(Arc::new(KeyWindow::build(
            window_receive,
            window_change,
            &watched_addresses,
        ))),
    });
    *HUB.lock().unwrap_or_else(PoisonError::into_inner) = Some(hub.clone());

    let monitor = dag::shared_monitor().await?;
    // Subscribe BEFORE the catch-up so its re-emitted matches land in this
    // receiver's buffer and are folded, not dropped.
    let mut events = monitor.subscribe_transport();
    let fold_hub = hub.clone();
    let task = tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(event) => {
                    handle_inbound(&fold_hub, event, EventOrigin::Node).await;
                }
                // Missed live events are the live-only law's accepted cost
                // (D-049) — but in a change whose whole theme is that no
                // rejection may be silent, this was the last silent one. The
                // fold now awaits I/O, so lag is no longer exotic: say how
                // many were lost rather than discarding them mutely.
                Err(RecvError::Lagged(n)) => {
                    log::info!("transport-intake: fold lagged — {n} live event(s) dropped");
                    continue;
                }
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

    // Arm the live cursor (the BlockAdded scan now persists scan progress), then
    // run the catch-up replay in the BACKGROUND so unlock returns immediately
    // and missed messages surface as the walk finds them (P5/D-067). The fold
    // task above is already draining, so the replay's matches are folded (and
    // deduped by txid against anything the live scan already caught).
    monitor.set_transport_cursor(cursor_path.clone());
    let catch_up_monitor = monitor.clone();
    let fill_hub = hub.clone();
    tokio::spawn(async move {
        if let Err(e) = catch_up_monitor.catch_up_transport(catch_up_from).await {
            log::warn!("transport-hub: catch-up ended early: {e}");
        }
        // V2b auto-fill (D-074) — SEQUENCED after the node catch-up so node
        // truth folds first: a fill row's txid is an indexer CLAIM (we hold
        // only its payload, so the pinned recompute cannot check it); folding
        // node-scanned rows first means a mislabeled hint cannot suppress a
        // message the node was about to deliver (consensus-audit finding,
        // V2b). Config-gated inside (defaults OFF, the §0 lock); a first-ever
        // run (no cursor) still fills — that IS the restore-from-seed case
        // the V0 casualty lived. Deliberately unconditional on gap size: the
        // rewind covers ~20 min, the indexer covers the rest, and txid dedup
        // makes the overlap free.
        run_fill(&fill_hub).await;
    });

    // ── F4: replay the gap on RECONNECT, not only on unlock ────────────────
    //
    // `catch_up_transport` had exactly ONE call site — the spawn just above,
    // inside `transport_start`, which early-returns while the hub's decryptor
    // is live. So it ran once per vault unlock and never again, and every
    // `ciph_msg:` landing in a block while the socket was down was lost:
    // notifications are live-only (D-049), and within
    // `TRANSPORT_CURSOR_MIN_WRITE_SECS` of the first post-reconnect block the
    // persisted cursor advances past the gap, so the next app open could not
    // recover it either. The watchdog only fires past `lastBlockAgeSecs > 30`
    // and the endpoint race must then rebind, so a real gap is ~300 blocks.
    //
    // The sibling acceptance lane has recovered its own gap on every reconnect
    // since V1 (`acceptance.rs`, the `DagEvent::Connected` arm). This is that
    // pattern, owed to the message lane. Note what D-087's PB-022 sweep asked
    // — "is each subscription re-established?" (it was) — and what it did not:
    // "is each *gap* replayed?"
    //
    // **The low bound is taken when the socket DROPS, never when the replay
    // wakes.** Subscriptions are registered before `emit(Connected)` in
    // `handle_connect`, so post-reconnect `BlockAdded` notifications can
    // already be advancing the persisted cursor by the time `Connected`
    // reaches this task — reading the cursor then would silently hand the walk
    // a low bound above the gap and make the whole thing a no-op.
    let replay_monitor = monitor.clone();
    let mut dag_rx = monitor.subscribe();
    // **The walk runs OFF this loop**, and that is load-bearing rather than
    // tidy. Awaiting `catch_up_transport` inline would stop draining `dag_rx`
    // for the length of a walk, and this receiver is not idle: `DagEvent`
    // carries `VirtualDaaScore` + `SinkBlueScore` at roughly the block rate
    // into a 256-slot broadcast, so a stalled loop overflows it in tens of
    // seconds while a real ~300-block walk over mobile takes longer. Every
    // walk would then end in `Lagged`, and — worse — a `Disconnected` arriving
    // during one would be handled only after it finished, reading the cursor
    // at a moment when the reconnect had already dragged it past the gap.
    // That is precisely the no-op `ReplayGap` exists to prevent, re-entering
    // one level up: the fix defeating itself through the door it built.
    let replay = tokio::spawn(async move {
        let read_cursor = || kaspaverse_chain::DagMonitor::read_transport_cursor(&cursor_path);
        let mut gap = ReplayGap::new();
        // Single-flight, so a flapping socket cannot fan out overlapping walks
        // over the same blocks.
        let walking = Arc::new(AtomicBool::new(false));
        let sweeping = Arc::new(AtomicBool::new(false));
        // Sweep immediately the first time, then at most every
        // `SWEEP_INTERVAL`.
        let mut last_sweep = tokio::time::Instant::now() - SWEEP_INTERVAL;
        loop {
            match dag_rx.recv().await {
                Ok(kaspaverse_chain::DagEvent::Disconnected) => gap.on_drop(read_cursor()),
                Ok(kaspaverse_chain::DagEvent::Connected { .. }) => {}
                Ok(_) => {}
                Err(RecvError::Lagged(n)) => {
                    log::info!("transport-hub: dag events lagged — {n} dropped, arming replay");
                    gap.on_lag(read_cursor());
                }
                Err(RecvError::Closed) => break,
            }
            // ONE decision point, re-evaluated after every event rather than
            // only on `Connected`. That is what closes the liveness hole: a
            // bound armed while a walk was in flight would otherwise wait for
            // a further reconnect that may never come. `VirtualDaaScore` and
            // `SinkBlueScore` tick at roughly the block rate, so this is
            // re-checked continuously for as long as the chain is moving —
            // and if it is not moving, there is no gap accruing either.
            //
            // Connectivity is asked of the MONITOR, not remembered from an
            // event this task saw. A latch would be exactly as lossy as the
            // receiver feeding it: the `Lagged` arm exists because a lag can
            // hide a drop, and the same lag can hide the `Connected` — leaving
            // the task holding an armed bound while believing the socket is
            // down, with nothing able to consume it until a fresh reconnect
            // that may never come.
            let connected = replay_monitor.is_connected();
            if connected && !walking.load(Ordering::SeqCst) {
                if let Some(low) = gap.on_connect() {
                    walking.store(true, Ordering::SeqCst);
                    let walk_monitor = replay_monitor.clone();
                    let done = walking.clone();
                    tokio::spawn(async move {
                        match walk_monitor.catch_up_transport(Some(low)).await {
                            Ok(n) => log::info!(
                                "transport-hub: reconnect replay re-emitted {n} match(es)"
                            ),
                            Err(e) => {
                                log::warn!("transport-hub: reconnect replay ended early: {e}")
                            }
                        }
                        done.store(false, Ordering::SeqCst);
                    });
                }
            }
            // F5's completion lane rides here for the same reason the walk
            // does: this is the one task in the hub that wakes at the block
            // rate without being on the fold's critical path. Single-flight,
            // spawned rather than awaited, and skipped entirely when nothing
            // is parked — which is the overwhelmingly common case.
            // THROTTLED, not merely single-flight. Single-flight caps
            // concurrency at one; it does not cap RATE, and this loop wakes at
            // roughly 20 events/s. An entry whose lookup fails FAST — a node
            // that answers `get_utxo_return_address` with an immediate error —
            // would otherwise be retried as fast as the previous attempt
            // returned: a spin against our own node, and being rate-limited or
            // dropped by it produces a `Disconnected`, which is this loop's own
            // trigger machinery. Resolution latency is dominated by the
            // activity record landing, never by how often we ask, so a slow
            // cadence costs nothing real.
            if connected
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
    if let Some(old) = REPLAY_TASK
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .replace(replay)
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

/// Resolve the gap-age (cursor block time vs now) with a connect-tolerant
/// retry budget, then store + log + span-mark it. A node that is CONNECTED
/// yet repeatedly cannot answer for the cursor block has pruned it — the gap
/// is at least the pin-read pruning horizon (an honest "≥", never a guess).
async fn resolve_gap_age(monitor: &kaspaverse_chain::DagMonitor, cursor: kaspaverse_chain::Hash) {
    const ATTEMPTS: u32 = 15;
    let mut connected_failures = 0u32;
    for _attempt in 0..ATTEMPTS {
        match monitor.rpc().rpc_api().get_block(cursor, false).await {
            Ok(block) => {
                let now = now_unix_ms();
                let minutes = now.saturating_sub(block.header.timestamp) / 60_000;
                *GAP_AGE.lock().unwrap_or_else(PoisonError::into_inner) = Some(GapAgeDto {
                    gap_minutes: Some(minutes),
                    beyond_horizon: false,
                });
                kaspaverse_chain::spans::mark_with("open_gap_min", &minutes.to_string());
                log::info!("transport-hub: history gap ≈ {minutes} min at open");
                ping_notice_inputs();
                return;
            }
            Err(_) if monitor.is_connected() => {
                // Connected but unanswered — tolerate transient node errors
                // before concluding the block is pruned.
                connected_failures += 1;
                if connected_failures >= 3 {
                    let horizon_min = kaspaverse_chain::pruning_horizon_ms() / 60_000;
                    *GAP_AGE.lock().unwrap_or_else(PoisonError::into_inner) = Some(GapAgeDto {
                        gap_minutes: None,
                        beyond_horizon: true,
                    });
                    kaspaverse_chain::spans::mark_with("open_gap_min", "beyond_horizon");
                    log::info!(
                        "transport-hub: cursor block pruned — history gap ≥ {horizon_min} min \
                         (pruning horizon)"
                    );
                    ping_notice_inputs();
                    return;
                }
                tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
            }
            Err(_) => {
                // Still dialing — wait for the socket.
                tokio::time::sleep(std::time::Duration::from_millis(1000)).await;
            }
        }
    }
    log::info!("transport-hub: gap-age unresolved this open (node unreachable)");
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
/// finding 14). Everything delivered through the monitor's broadcast lane
/// (live BlockAdded scan + catch-up walk) is node truth; only the fill's
/// direct calls are indexer claims. A parameter, not a `TransportEvent`
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
    /// opens is passed over, loudly logged, and left to the node lane — the
    /// decrypt IS the verification step, and a row that fails it is not ours
    /// by the only test we trust (D-074: omission is possible, forgery is not).
    fn outcome(self) -> FoldOutcome {
        match self {
            DropReason::VaultLocked
            | DropReason::StoreRace
            | DropReason::StoreFailed
            | DropReason::NotAddressedToUs => FoldOutcome::Held,
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
/// `None` when the bond has not reached our activity record yet — the live
/// scan routinely sees a handshake before its accepting block exists. The
/// caller then falls back to the alias-only path, so a slow resolution costs
/// a duplicate conversation at worst, never a lost message.
/// **Bounded**, because the NODE lane awaits this inline in the fold loop that
/// drains the BlockAdded broadcast. An unbounded RPC here would let one slow
/// node stall that loop, and a stalled consumer is a LAGGED channel — which on
/// this stream means live messages are dropped outright. The lookup is a
/// best-effort enrichment; the fold below works without it, so it must never
/// be able to cost more than it can give.
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

/// An alias we could not route, parked until the chain names its sender.
///
/// Bounded and in-memory, like the tracker's own interest set: these txids
/// are attacker-mintable, so nothing here may be durable or unbounded.
/// Losing an entry costs one deferred lookup, never a message — the fill
/// re-walks the thread from block time zero once the conversation is Active.
static PENDING_ALIAS: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

/// Cap for [`PENDING_ALIAS`] — the same order as the tracker's interest set.
const PENDING_ALIAS_CAPACITY: usize = 256;

/// Whether this txid is already awaiting resolution.
///
/// Checked BEFORE the decrypt, not after: the DAG delivers one transaction in
/// several blocks, and on the founder's device a single message hit this path
/// twelve times — twelve full key-window scans, and twelve identical log
/// lines, for one message.
fn alias_already_parked(txid: &str) -> bool {
    PENDING_ALIAS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .any(|(t, _)| t == txid)
}

/// Remember `txid -> alias` while we wait to learn who sent it.
fn park_alias(txid: &str, alias: &str) {
    let mut parked = PENDING_ALIAS.lock().unwrap_or_else(PoisonError::into_inner);
    if parked.iter().any(|(t, _)| t == txid) {
        return;
    }
    if parked.len() >= PENDING_ALIAS_CAPACITY {
        parked.remove(0);
    }
    parked.push((txid.to_string(), alias.to_string()));
}

fn take_parked_alias(txid: &str) -> Option<String> {
    let mut parked = PENDING_ALIAS.lock().unwrap_or_else(PoisonError::into_inner);
    let pos = parked.iter().position(|(t, _)| t == txid)?;
    Some(parked.remove(pos).1)
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
}

/// Acceptances awaiting their sender, keyed by txid.
///
/// Bounded and in-memory for the same reason as [`PENDING_ALIAS`]: these txids
/// are attacker-mintable, so nothing here may be durable or unbounded. Losing
/// an entry costs the conversation nothing permanent — it stays
/// `PendingOutbound`, and the counterparty's next comm re-learns their alias
/// through [`adopt_alias_from_sender`], which applies the same sender check.
static PENDING_ACCEPTANCE: Mutex<Vec<(String, ParkedAcceptance)>> = Mutex::new(Vec::new());

/// Whether this txid's acceptance is already awaiting its sender. Checked
/// before the work, like [`alias_already_parked`]: the DAG delivers one
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
    if parked.len() >= PENDING_ALIAS_CAPACITY {
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
/// Node lane only, by construction: the DAA score comes from the VCC stream
/// our own node emits, never from a fill row.
async fn adopt_alias_from_sender(txid: &str, accepting_daa_score: u64) {
    let Some(alias) = take_parked_alias(txid) else {
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

    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(existing) = store.conversation_by_contact_address(&sender) else {
        log::info!("transport-intake: tx={txid} sender matches no conversation");
        return;
    };
    // Never overwrite an alias we already hold: this path exists to fill a
    // gap, not to let the newest message redefine who a contact is.
    if existing.their_alias.is_some() {
        return;
    }
    let mut conversation = existing.clone();
    let conversation_id = conversation.conversation_id.clone();
    conversation.their_alias = Some(alias);
    // Their message proves the handshake completed on their side, whatever
    // our own side was still waiting for.
    if conversation.status == ConversationStatus::PendingOutbound {
        conversation.status = ConversationStatus::Active;
    }
    unhide_on_inbound(&mut store, &conversation_id);
    warn_store(store.upsert_conversation(conversation));
    drop(store);
    log::info!(
        "transport-intake: learned a contact's alias from their message (tx={txid}) — \
         conversation active"
    );
    ping(&conversation_id);
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
async fn backfill_invitation_sender(txid: &str, accepting_daa_score: u64) {
    let Ok(hub) = hub() else { return };
    // Cheap first: is there even an address-less invitation for this txid?
    let needs_backfill = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store.list_conversations().into_iter().any(|c| {
            c.status == ConversationStatus::PendingInbound
                && c.contact_address.is_empty()
                && c.handshake_txid.as_deref() == Some(txid)
        })
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
    let Some(existing) = store.list_conversations().into_iter().find(|c| {
        c.status == ConversationStatus::PendingInbound
            && c.contact_address.is_empty()
            && c.handshake_txid.as_deref() == Some(txid)
    }) else {
        return; // accepted or changed while we were on the network
    };
    let conversation_id = existing.conversation_id.clone();
    let conversation = ConversationRecord {
        contact_address: sender,
        ..existing
    };
    warn_store(store.upsert_conversation(conversation));
    drop(store);
    log::info!("transport-intake: recorded the sender of an invitation (tx={txid})");
    ping(&conversation_id);
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
/// "Traffic", not "the contact": a comm proves only that the envelope opened
/// under one of our keys, and both our receive addresses and our alias are
/// public, so any wire observer can mint one. Hiding a CONTACT is therefore
/// revocable by a stranger for the price of a dust transaction. That is an
/// accepted residual — no money rides on a contact row — and it closes when
/// comms carry sender authentication (backlog #5). It is exactly why the
/// invitation case is NOT treated the same way.
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
            // "someone wrote", not "the contact wrote": a comm proves only
            // that the envelope opened under one of our keys, never who sent
            // it. Sender authentication is still owed (backlog #5).
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
                origin,
            )
            .await
        }
        "comm" => handle_inbound_comm(hub, &txid, &event.body, event.block_time_ms, origin),
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

async fn handle_inbound_handshake(
    hub: &TransportHub,
    txid: &str,
    body: &[u8],
    addresses: &[String],
    block_time_ms: Option<u64>,
    origin: EventOrigin,
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
    // binding. Not ours / vault locked ⇒ skip (live-only law: an envelope
    // seen while locked is missed, same as one seen while offline). This
    // decrypt is ALSO the fill's verify step: an indexer row no watched key
    // opens is dropped here — omission is possible, forgery is not (D-074).
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
            };
            match store.override_message(record) {
                Ok(Some(_)) => {}
                Ok(None) => return dropped(HANDSHAKE, txid, DropReason::StoreRace, origin),
                Err(e) => {
                    log::warn!("transport-hub: store append failed: {e}");
                    return dropped(HANDSHAKE, txid, DropReason::StoreFailed, origin);
                }
            }
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
                    warn_store(store.upsert_conversation(conversation));
                }
            }
            drop(store);
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
    // So we match their semantics. The sender comes from the node's own
    // return-address lookup — consensus data, never payload content (§0.3) —
    // and it is available here precisely because a handshake PAYS us the
    // bond, which is what puts it in the P1.5 activity record.
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
    // the node (D-074: omission is acceptable, forgery is not — the same reason
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
    let resolved_sender = if origin == EventOrigin::Node {
        resolve_handshake_sender(txid).await
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
    }));
    drop(store);
    watch_acceptance(txid, block_time_ms);
    ping(&conversation_id);
    FoldOutcome::Recorded
}

fn handle_inbound_comm(
    hub: &TransportHub,
    txid: &str,
    body: &[u8],
    block_time_ms: Option<u64>,
    origin: EventOrigin,
) -> FoldOutcome {
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
    // Relevance without crypto: the alias must belong to one of our
    // conversations (either side's — senders tag with their own).
    let (conversation_id, bound) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(conversation) = store.conversation_by_alias(&alias) else {
            // An alias we do not know — but it may be a contact whose alias we
            // LOST (hidden thread, reinstall, or a handshake we never saw).
            // Their alias is right here in cleartext; what is missing is proof
            // the message is theirs. Park it and ask the chain who sent it.
            //
            // Gated on actually missing one, because this decrypt scans the
            // whole key window and every stranger's comm reaches this line.
            if origin == EventOrigin::Node
                && !alias_already_parked(txid)
                && store.has_conversation_awaiting_alias()
            {
                drop(store);
                let envelope_bytes = decode_envelope_body(sealed);
                if Envelope::from_bytes(&envelope_bytes).is_ok_and(|envelope| {
                    hub.decryptor
                        .decrypt_scanning(hub.keys().slots.iter().copied(), &envelope)
                        .is_ok()
                }) {
                    // It opened under one of our keys, so it was sealed to us.
                    // That is not proof of authorship — the sender check is —
                    // but it is enough to be worth resolving.
                    park_alias(txid, &alias);
                    if let Some(tracker) = dag::tracker_handle() {
                        tracker.note_sender_interest(txid);
                    }
                    log::info!(
                        "transport-intake: unroutable comm tx={txid} sealed to us — \
                         awaiting sender to learn the alias"
                    );
                }
            }
            return dropped(COMM, txid, DropReason::NoConversationForAlias, origin);
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
        return dropped(COMM, txid, DropReason::MalformedEnvelope, origin);
    };
    // Validation decrypt: bound slot first (§0.7 fast path), then the window
    // (robustness against a counterparty that re-resolved our address). The
    // plaintext is DROPPED here — decrypt-on-view happens at thread pull.
    // This is ALSO the fill's verify step (D-074): an indexer can OMIT an
    // envelope, never forge one past this decrypt.
    let sealed_to = match hub.decryptor.decrypt_at(bound, &envelope) {
        Ok(_) => None,
        Err(CoreError::TransportOpen) => {
            match hub
                .decryptor
                .decrypt_scanning(hub.keys().slots.iter().copied(), &envelope)
            {
                Ok((slot, _)) => Some((to_key_branch(slot.0), slot.1)),
                // Alias matched but no key opens it — a spoofed head, or the
                // vault shut mid-stream. Two very different events; say which.
                Err(e) => return dropped(COMM, txid, decrypt_drop(&e), origin),
            }
        }
        Err(e) => return dropped(COMM, txid, decrypt_drop(&e), origin),
    };

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
    // `receive/0` is the identity address, the only one the wallet ever shows.
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
            "your wallet address has no spendable coins yet, and nothing on the way that I can see \
             — receive some KAS to it to send from here"
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

    let priority_len = priority.len();
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
        let reuse = rows
            .iter()
            .find(|r| r.status == ConversationStatus::PendingOutbound && r.initiated_by_me)
            .cloned();
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
        if rows.iter().any(|r| {
            r.status == ConversationStatus::Active
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

    let my_alias = match &existing {
        Some(row) => row.my_alias.clone(),
        None => fresh_alias(),
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
        // A retry on the row we already have: same id, same alias, same slot.
        Some(row) => ConversationRecord {
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
    let found = rows
        .iter()
        .find(|c| {
            comm_sendable(c.status, c.initiated_by_me, &c.contact_address, &c.my_alias)
                && store.superseded_by(&c.conversation_id).is_none()
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
    // thread outranks it. It is a conversation the user could actually TALK in
    // — decided by the same predicate the send path uses, not a second copy of
    // the rule — and it must be the LIVE one.
    // `conversations_for_contact_address` sorts oldest-established first (an
    // inbound fold wants the row it can complete), so on a contact who
    // re-handshaked after wiping their client, a bare `find` routes the user
    // into the replaced thread: the exact dead end this function exists to
    // avoid, reached by answering "you already have this contact" with the one
    // row that no longer works. Skipping superseded rows uses the same derived
    // rule the send path refuses on, so the two can never disagree.
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
#[derive(Clone, Debug)]
pub struct AttachmentBytesDto {
    pub name: String,
    pub bytes: Vec<u8>,
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
    let hub = hub()?;
    let (contact_address, my_alias, bound) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let conversation = store
            .conversation(&conversation_id)
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
        // REFUSE A REPLACED THREAD — the one failure this lane cannot detect
        // downstream. Every other refusal above describes a state we can see;
        // this one describes a state only the COUNTERPARTY can see. Their
        // client wiped and re-handshaked, so it monitors the new alias pair
        // and nothing else, while this row still holds a perfectly valid alias
        // of ours. The send would build, sign, broadcast, pay its fee and
        // arrive nowhere, reporting success at every step.
        //
        // Refusing costs the user nothing — the live thread is right there and
        // the message re-types in seconds. Not refusing costs a fee and a
        // message they believe was delivered, which is how this was found:
        // hours of one-way silence with no error anywhere.
        if store.superseded_by(&conversation_id).is_some() {
            return Err(AppError::msg(
                "this conversation has been replaced — your contact started a new one, and only \
                 that thread reaches them. Open the newer conversation with them and send there.",
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
    // The recipient address is the ENCRYPTION target only — the envelope is
    // sealed to their key so they can decrypt. The tx VALUE goes to us (below).
    let recipient = validate_mainnet_address(&contact_address)?;
    let recipient_x_only = x_only_of(&recipient)?;
    // The conversation's bound own address — the destination (self-send, D-069),
    // the input[0] source, and the change target all at once, so the counterpart
    // keeps seeing one identity and the value never leaves our wallet.
    let own_address = vault::wallet_address_at(bound.0, bound.1)?;

    // The self-send output still clears Kaspa's anti-dust floor (storage mass is
    // charged on every output, ours included) — the honest computed minimum for
    // THIS wallet's live coin shape (D-054), recomputed per send. The probe
    // already models payment-to-own_address + change-to-own_address, exactly the
    // self-send shape, so the floor it finds is the one that gets built.
    let engine = wallet::engine_handle()
        .ok_or_else(|| AppError::msg("wallet is still connecting — try again in a moment"))?;
    // FIRST, because the floor below is measured over the mature UTXO set and
    // this is the wait that set is waiting on. Measure first and an all-immature
    // wallet has no floor at all — `minimum_sendable` answers `None` and the
    // send dies blaming the user's coin shape for a clock. The set travels down
    // into `prepare_transport_send`, so the budget is spent once.
    let priority = await_spendable_at(&engine, &own_address).await?;
    // The floor is probed with the SAME pinned set the send below will pin, so
    // it prices the pinned spend order, not a hypothetical plain one.
    let floor = engine
        .minimum_sendable(own_address.clone(), &priority)
        .map_err(AppError::chain)?
        .ok_or_else(|| {
            AppError::msg("your balance can't cover a message right now (anti-dust floor)")
        })?;

    let envelope = encrypt(&recipient_x_only, text.as_bytes()).map_err(AppError::core)?;
    let wire = compose_comm_wire(&my_alias, &envelope.to_bytes()).map_err(AppError::chain)?;

    let reseal = encrypt(&x_only_of(&own_address)?, text.as_bytes())
        .map_err(AppError::core)?
        .to_bytes();

    let timestamp_ms = now_unix_ms();
    prepare_transport_send(
        own_address.clone(), // SELF-SEND (D-069): value returns as change — cost = fee
        floor,
        wire,
        own_address, // source discipline: input[0] + change = the same bound addr
        priority,
        TransportIntent::Comm {
            conversation_id,
            alias_on_wire: my_alias,
            reseal,
            sealed_to: (to_key_branch(bound.0), bound.1),
            timestamp_ms,
        },
        PinPolicy::Default,
    )
    .await
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
        .minimum_sendable(own_address.clone(), &priority)
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
            if let Some(existing) = store.conversation(&conversation_id) {
                let mut conversation = existing.clone();
                conversation.contact_address = contact_address;
                conversation.my_alias = my_alias;
                conversation.status = ConversationStatus::Active;
                conversation.last_activity_unix_ms = timestamp_ms;
                // Re-stamp establishment on OUR clock at the moment the
                // conversation actually becomes one.
                //
                // `created_unix_ms` now ORDERS things — `superseded_by` uses
                // it to decide which of two threads with one contact is live,
                // and a losing thread is refused. Until this line the value on
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
                // invitation. Reverting either one alone re-opens the case where
                // accepting a stale invitation supersedes a working thread.
                //
                // **Monotone within its comparison set, not merely "now".** A
                // device clock correction backwards between two establishments
                // with one contact would otherwise invert the comparison, and
                // `superseded_by` would refuse the live thread and route the
                // user into the dead one with full confidence — the original
                // bug, endorsed by the fix for it (`consensus-auditor`,
                // 2026-08-17). Stepping past the newest Active row for this
                // same contact costs nothing when the clock is sane and is the
                // whole guarantee when it is not.
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
                }));
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
/// **Three gates asked this question and two of them asked it differently.**
/// `transport_existing_conversation` routes to Accept, `transport_prepare_handshake`
/// refuses a second bond because Accept is available, and `transport_start_over`
/// must not destroy history for a request that Accept would answer. When the
/// spend gate tightened to an allowlist (`accept_provenance_ok`) and these did
/// not, the app could refuse a handshake saying "accept their invitation
/// instead" while Accept refused saying "your node has no record of this" —
/// two contradictory refusals and an unreachable address (INV-6,
/// `wallet-security-auditor`, 2026-08-17).
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

/// All conversations, most recently active first.
pub fn transport_conversations() -> Result<Vec<ConversationDto>, AppError> {
    let hub = hub()?;
    let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    let now = now_unix_ms();
    // Loaded once per pull, not per row. Names are device-local metadata, so a
    // missing or unreadable file costs labels and never a conversation.
    let names = vault::transport_store_dir()
        .map(|dir| kaspaverse_chain::ContactNames::load(&dir))
        .unwrap_or_default();
    Ok(store
        .list_conversations()
        .into_iter()
        // Hidden rows are matchable but not shown — that asymmetry IS the fix
        // (see `transport_hide_conversation`).
        .filter(|c| !store.is_conversation_tombstoned(&c.conversation_id))
        .map(|c| ConversationDto {
            invite_expired: invite_expired(c.status, c.created_unix_ms, now),
            contact_name: names.get(&c.contact_address).map(str::to_string),
            superseded: store.superseded_by(&c.conversation_id).is_some(),
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
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    // Content goes. Identity stays.
    let txids: Vec<String> = store
        .messages_for(&conversation_id)
        .into_iter()
        .map(|m| m.txid)
        .collect();
    for txid in txids {
        warn_store(store.remove_message(&txid));
    }
    store
        .tombstone_conversation(&conversation_id)
        .map_err(AppError::chain)?;
    drop(store);
    // Nudge any open list to re-pull. The thread does NOT 404 — the row
    // survives by design; it simply stops being listed.
    ping(&conversation_id);
    Ok(())
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
            .conversation(&conversation_id)
            .and_then(|c| c.handshake_txid.clone());
        let txids: Vec<String> = store
            .messages_for(&conversation_id)
            .into_iter()
            .map(|m| m.txid)
            .filter(|txid| Some(txid) != keep.as_ref())
            .collect();
        // COUNT WHAT WENT, NOT WHAT WAS ASKED FOR, and surface a failure
        // instead of warning past it (`ffi-leak-auditor`, 2026-08-17). The
        // sibling purge inside `transport_hide_conversation` uses
        // `warn_store`, which is survivable there because it reports no
        // number; here the count reaches the user as "N messages cleared", and
        // a swallowed write error would make that a promise the disk never
        // kept. Partial progress is reported honestly by the error, not
        // rolled back — the rows that did go are gone.
        let mut cleared = 0usize;
        for txid in txids {
            store.remove_message(&txid).map_err(AppError::chain)?;
            cleared += 1;
        }
        cleared
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

/// Retire every live conversation with one contact, so a fresh contact request
/// to them can be minted. The per-contact exit (INV-6).
///
/// **One operation, because two were worse than none.** The gesture is
/// "hide the broken thread, then invite them again", and doing that from Dart
/// as two calls half-applies in exactly the case it exists for: with TWO live
/// conversations against one address — the situation this whole change is
/// about — hiding one leaves the other `Active`, and
/// [`transport_prepare_handshake`] then refuses, having already destroyed the
/// first thread's messages. The user loses history and sends nothing
/// (`consensus-auditor`, 2026-08-17). Retiring them ALL first makes the
/// following prepare succeed by construction.
///
/// **Tombstone, never delete.** Every row keeps the counterparty's alias, so
/// if they write to an old thread it comes back with its binding intact — the
/// July regression is not re-opened here.
///
/// **Messages ARE destroyed**, the same purge [`transport_hide_conversation`]
/// performs, because that is what hiding a thread means in this app. The
/// caller's copy must say so.
///
/// **`Active` rows only.** An unaccepted invitation is deliberately untouched:
/// hiding one is permanent (`may_unhide` refuses `PendingInbound`), and it is
/// the only route to refunding the 0.2 KAS bond the counterparty already paid.
/// Retiring it to send our own handshake would spend 0.2 KAS of ours to strand
/// 0.2 KAS of theirs.
///
/// **Deliberately does NOT call `transport_abandon`, unlike the total wipe.**
/// The wipe must, because its Handshake arm would upsert a prepare-time
/// snapshot into an emptied store and mint back a conversation the user
/// erased. Here it cannot: `PENDING_INTENT` is a single slot, a staged
/// handshake to this same contact cannot coexist with this call's own
/// invitation/Active preconditions, and a staged Comm confirm writes a NEW
/// message row rather than restoring an erased one.
///
/// Returns what was retired AND whether the catch-up floor is durable. That
/// last flag is not decoration: this sheet promises "the messages do not [come
/// back]", and without a persisted floor an opt-in history catch-up can hand
/// them back. Zero conversations is a success — there was nothing live to
/// retire, and the caller may go straight to the handshake.
pub fn transport_start_over(contact_address: String) -> Result<WipeReportDto, AppError> {
    let dest = validate_mainnet_address(&contact_address)?;
    let hub = hub()?;

    // ONE set, computed ONCE, under a lock held across the whole operation.
    //
    // This read the set, dropped the lock to seal, and re-derived it — and the
    // gap was two file operations wide, one of them an fsync. A conversation
    // turning `Active` inside it (an inbound comm firing `unhide_on_inbound`,
    // an accept completing) landed in the retire set but never in the floored
    // set: its messages destroyed, its comm cursor untouched, and the next fill
    // handing that history back from a third-party indexer (INV-8). The
    // function exists BECAUSE doing this in two steps half-applies, and it was
    // reproducing that internally (`consensus-auditor`, 2026-08-17, round 5).
    //
    // Lock order is `store` then `ERASE_GATE`, which is the only ordering
    // anywhere in this file — nothing takes the store while holding the gate,
    // so this cannot deadlock. `seal_erasure` is sync, so no `.await` crosses
    // the guard (L7).
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);

    let rows: Vec<ConversationRecord> = store
        .conversations_for_contact_address(&dest.to_string())
        .into_iter()
        .cloned()
        .collect();

    // REFUSE BEFORE DESTROYING, not after.
    //
    // The handshake that follows this call refuses when an acceptable
    // invitation from the same contact exists — and by then we would have
    // purged the messages and tombstoned the threads for a request that never
    // went out. That is the exact scenario the feature exists for (they wiped,
    // re-handshaked, and an invitation now sits beside a stale Active row), so
    // it is not a corner (`wallet-security-auditor`, 2026-08-17). Same sentence
    // as the prepare's, because it is the same fact.
    if rows.iter().any(|c| invitation_is_acceptable(&store, c)) {
        return Err(AppError::msg(
            "this address already invited you — accept their invitation instead. \
             That returns the bond they paid and opens the conversation; sending \
             your own would spend a second one. If you would rather not, \
             long-press the request and hide it first.",
        ));
    }

    let targets: Vec<String> = rows
        .iter()
        .filter(|c| c.status == ConversationStatus::Active)
        .filter(|c| !store.is_conversation_tombstoned(&c.conversation_id))
        .map(|c| c.conversation_id.clone())
        .collect();

    // This purges messages, so it is a content destruction like the other two
    // and seals the same way — otherwise an in-flight fill re-folds the very
    // history we retire, and `unhide_on_inbound` brings the dead thread back.
    // No global floor: only these conversations' comm cursors move, because a
    // start-over is a statement about one contact, and raising the global floor
    // would stop catch-up for every other conversation the user still wants.
    let floor_persisted = seal_erasure(|cursors| {
        let floor = now_unix_ms();
        for id in &targets {
            let entry = cursors.comms.entry(id.clone()).or_default();
            *entry = (*entry).max(floor);
        }
    });

    let mut purged = 0usize;
    for conversation_id in &targets {
        let txids: Vec<String> = store
            .messages_for(conversation_id)
            .into_iter()
            .map(|m| m.txid)
            .collect();
        for txid in txids {
            // Counted, and a write failure stops the whole call — the same
            // honesty `transport_clear_messages` owes, for the same reason:
            // the caller renders this number as "messages deleted".
            store.remove_message(&txid).map_err(AppError::chain)?;
            purged += 1;
        }
        store
            .tombstone_conversation(conversation_id)
            .map_err(AppError::chain)?;
    }
    drop(store);

    log::info!(
        "transport-start-over: {} live conversation(s) retired for one contact, \
         {purged} message row(s) purged, floor_persisted={floor_persisted}",
        targets.len()
    );
    for conversation_id in &targets {
        ping(conversation_id);
    }
    Ok(WipeReportDto {
        conversations: u32::try_from(targets.len()).unwrap_or(u32::MAX),
        messages: u32::try_from(purged).unwrap_or(u32::MAX),
        side_files_cleared: 0,
        // Active rows only — start-over refuses outright when an acceptable
        // invitation exists, so none is ever destroyed here.
        pending_bonds: 0,
        floor_persisted,
    })
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
///   and the window is bounded by the cursor's own write cadence and
///   `MAX_CATCHUP_PAGES` — but it is a real, accepted residual, not a free
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
    let mut side_files_cleared = 0u32;
    if let Ok(dir) = vault::transport_store_dir() {
        for path in [
            kaspaverse_chain::ContactNames::path(&dir),
            kaspaverse_chain::history_fill::StashState::path(&dir),
        ] {
            match std::fs::remove_file(&path) {
                Ok(()) => side_files_cleared += 1,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => log::warn!("transport-wipe: a side file survived: {e}"),
            }
        }
    }

    // In-memory claims about txids that no longer have a home. Left standing,
    // a parked acceptance would complete into a conversation the user deleted
    // and mint it back from nothing.
    PENDING_ALIAS
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
/// (`wallet/core/src/utils.rs:34,44` @ `cfafeb4`), and this project does not put
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

/// Mirror the chain crate's `TxStatus` for display (nothing recomputed).
fn tx_status_dto(status: kaspaverse_chain::TxStatus) -> TxStatusDto {
    use kaspaverse_chain::TxStatus;
    match status {
        TxStatus::Submitted => TxStatusDto {
            kind: TxStatusKind::Submitted,
            blue_depth: None,
            waited_ms: None,
        },
        TxStatus::Accepted { blue_depth } => TxStatusDto {
            kind: TxStatusKind::Accepted,
            blue_depth: Some(blue_depth),
            waited_ms: None,
        },
        TxStatus::Confirmed { blue_depth } => TxStatusDto {
            kind: TxStatusKind::Confirmed,
            blue_depth: Some(blue_depth),
            waited_ms: None,
        },
        TxStatus::Displaced => TxStatusDto {
            kind: TxStatusKind::Displaced,
            blue_depth: None,
            waited_ms: None,
        },
        TxStatus::Stalled { waited_ms } => TxStatusDto {
            kind: TxStatusKind::Stalled,
            blue_depth: None,
            waited_ms: Some(waited_ms),
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
            body: b"kv-dev:hi".to_vec(),
            addresses: vec!["kaspa:qz...".into()],
            block_time_ms: None,
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
        const CONTENT: [&str; 3] = ["text", "plaintext", "body"];
        // WIDENED (`ffi-leak-auditor`, 2026-08-17). The original words caught
        // message BODIES and nothing else, while §4's discipline is that
        // identities stay out of logcat too — an address ties the device to an
        // on-chain identity, and in this lane a conversation id and an alias
        // are routing identities.
        const IDENTITY: [&str; 3] = ["conversation_id", "contact_address", "alias"];

        for call in calls {
            // What is EMITTED is the format string. Split it off so an
            // argument can be judged by a different rule.
            let (format, args) = match (call.find('"'), call.rfind('"')) {
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
            assert_eq!(
                reason.outcome(),
                FoldOutcome::Held,
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

    // ── F4: the reconnect replay walks from the DROP, not from the wake ───

    fn hash_of(byte: u8) -> kaspaverse_chain::Hash {
        kaspaverse_chain::Hash::from_bytes([byte; 32])
    }

    /// **The race the fix exists to survive.** `AT_DROP` is where the gap
    /// begins; `AFTER_RECONNECT` is where the persisted cursor has already been
    /// dragged to by the `BlockAdded` notifications that resume before
    /// `Connected` reaches this task. A replay that read the cursor on wake
    /// would walk from `AFTER_RECONNECT` — above every message in the gap — and
    /// be a silent no-op that looks exactly like a working fix.
    #[test]
    fn the_replay_walks_from_the_cursor_as_it_stood_at_the_drop() {
        const AT_DROP: u8 = 0x11;
        const AFTER_RECONNECT: u8 = 0x99;

        let mut gap = ReplayGap::new();
        gap.on_drop(Some(hash_of(AT_DROP)));
        // …blocks resume and the live scan advances the persisted cursor…
        let _cursor_now = Some(hash_of(AFTER_RECONNECT));
        assert_eq!(
            gap.on_connect(),
            Some(hash_of(AT_DROP)),
            "the replay must start where the gap did, not where the cursor got to"
        );
    }

    /// The first connect of a session replays nothing: no drop has happened, so
    /// there is no gap, and `transport_start`'s own catch-up already owns the
    /// closed-app window. Arming here would double-walk every unlock.
    #[test]
    fn a_first_connect_replays_nothing() {
        let mut gap = ReplayGap::new();
        assert_eq!(gap.on_connect(), None);
    }

    /// One shot. A bound already walked must not be walked again on the next
    /// reconnect — that would re-emit the same gap on every future bind.
    #[test]
    fn a_replayed_gap_is_not_replayed_again() {
        let mut gap = ReplayGap::new();
        gap.on_drop(Some(hash_of(1)));
        assert!(gap.on_connect().is_some());
        assert_eq!(
            gap.on_connect(),
            None,
            "a second reconnect must not re-walk a gap already covered"
        );
    }

    /// A lag may have hidden a drop, so it arms — but it must never overwrite a
    /// bound already taken at a real drop, which is older and therefore covers
    /// more. Overwriting would narrow the walk to above the gap: the same
    /// silent no-op, arriving by a different door.
    #[test]
    fn a_lag_arms_the_replay_but_never_narrows_an_existing_bound() {
        let mut fresh = ReplayGap::new();
        fresh.on_lag(Some(hash_of(0x55)));
        assert_eq!(
            fresh.on_connect(),
            Some(hash_of(0x55)),
            "a lag that may have hidden a drop must still arm a replay"
        );

        let mut armed = ReplayGap::new();
        armed.on_drop(Some(hash_of(0x11))); // the real drop, lower
        armed.on_lag(Some(hash_of(0x99))); // a later lag, higher
        assert_eq!(
            armed.on_connect(),
            Some(hash_of(0x11)),
            "the earlier bound wins — a lag must never raise the floor"
        );
    }

    /// The reverse order, which the first pass left untested and got wrong:
    /// `on_drop` overwrote unconditionally while `on_lag` refused to, so a
    /// lag-armed bound was silently raised by the next real drop and the window
    /// between them was never walked. Reachable whenever a `Connected` is lost
    /// to a lag — which a 256-slot event buffer against block-rate traffic
    /// makes ordinary, not exotic. Both entry points now obey one rule
    /// (wallet-security + consensus, F4).
    #[test]
    fn a_drop_never_narrows_a_bound_a_lag_already_armed() {
        let mut gap = ReplayGap::new();
        gap.on_lag(Some(hash_of(0x11))); // armed low by a lag…
        gap.on_drop(Some(hash_of(0x99))); // …then a real drop, higher
        assert_eq!(
            gap.on_connect(),
            Some(hash_of(0x11)),
            "the earlier bound wins whichever call armed it"
        );
    }

    /// Two drops with no `Connected` between them — the shape a lost
    /// `Connected` produces. The first gap is still unwalked, so its bound is
    /// the one that must survive.
    #[test]
    fn a_second_drop_keeps_the_first_gaps_bound() {
        let mut gap = ReplayGap::new();
        gap.on_drop(Some(hash_of(0x11)));
        gap.on_drop(Some(hash_of(0x22)));
        assert_eq!(gap.on_connect(), Some(hash_of(0x11)));
    }

    /// A cursor that reads back `None` must not ERASE an armed bound. Wiping it
    /// would turn a recoverable gap into a permanent one, silently — and the
    /// unguarded `self.low = cursor_now` did exactly that.
    #[test]
    fn an_unreadable_cursor_never_erases_an_armed_bound() {
        let mut gap = ReplayGap::new();
        gap.on_drop(Some(hash_of(0x11)));
        gap.on_drop(None);
        gap.on_lag(None);
        assert_eq!(gap.on_connect(), Some(hash_of(0x11)));
    }

    /// No cursor at all (a first-ever run has none) arms nothing rather than
    /// walking from an invented point.
    #[test]
    fn a_drop_with_no_persisted_cursor_arms_nothing() {
        let mut gap = ReplayGap::new();
        gap.on_drop(None);
        assert_eq!(gap.on_connect(), None);
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

        for n in 0..(PENDING_ALIAS_CAPACITY + 8) {
            park_acceptance(&format!("{n:064x}"), claim("conv-bulk"));
        }
        let held = PENDING_ACCEPTANCE
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        assert_eq!(held, PENDING_ALIAS_CAPACITY, "bounded");
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
        assert_eq!(DropReason::VaultLocked.outcome(), FoldOutcome::Held);
        assert_eq!(DropReason::StoreFailed.outcome(), FoldOutcome::Held);
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
}
