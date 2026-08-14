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
    compose_bcast, compose_comm_wire, compose_handshake_wire, compose_self_stash_wire,
    decode_envelope_body, parse_payload, resolve_return_address, split_comm_body, AcceptanceEvent,
    Address, ChainError, ConversationRecord, ConversationStatus, KeyBranch, MessageDirection,
    MessageRecord, PreparedSend, RowSource, SignerT, StoredKind, TransportEvent, TransportStore,
    WatchSource, HANDSHAKE_BOND_SOMPI, STASH_SCOPE_SAVED_HANDSHAKE,
};
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
    use kaspaverse_chain::history_fill::{encode_hex, walk_pages, FillCursors, IndexerClient};

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
    let mut cursors = FillCursors::load(dir);

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
                let start = cursors.stash.get(&owner).copied().unwrap_or(0);
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
                    for payload in snapshot.rows() {
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
                if let Some((_, proven_txid, _)) = &newest {
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
        let start = cursors.handshakes.get(&address).copied().unwrap_or(0);
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
        let start = cursors.comms.get(&conversation_id).copied().unwrap_or(0);
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

    if let Err(e) = cursors.save(dir) {
        log::warn!("history-fill: cursor save failed: {e}");
    }
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
    monitor.set_transport_cursor(cursor_path);
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
    let sender = match resolve_return_address(&monitor.rpc(), txid, accepting_daa_score).await {
        Ok(sender) => sender,
        Err(e) => {
            log::info!(
                "transport-intake: sender lookup failed for tx={txid}: {}",
                kaspaverse_chain::sanitize_node_text(&e.to_string())
            );
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

/// May inbound traffic reopen this hidden conversation?
///
/// A conversation you already have: yes — hide is a mute. An invitation you
/// turned down: never. That card spends the bond refund, so a stranger must
/// not be able to re-arm it by writing again (INV-6: no exit that the
/// counterparty can revoke).
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
                // Never regress the activity clock: a FILLED old acceptance must
                // not re-sort the conversation above newer traffic.
                conversation.last_activity_unix_ms = conversation.last_activity_unix_ms.max(now);
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
            // An acceptance we have no pending side for — fall through and treat
            // it as a fresh inbound handshake (the live app does the same).
        }
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
    // The second condition is a free pre-check: with no conversation holding a
    // counterparty address there is nothing to match, and the fold loop should
    // not pay a round trip to learn that.
    let can_match_by_address = origin == EventOrigin::Node && {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store.conversations_have_any_contact_address()
    };
    if can_match_by_address {
        if let Some(sender) = resolve_handshake_sender(txid).await {
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

    // Same two-consumer change seam as the payment path (vault.rs is the
    // single source): fresh change registered + signer over the watched window.
    let cursor = wallet::next_change_index();
    let change = vault::change_address_at(cursor)?;
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
async fn prepare_transport_send(
    dest: Address,
    amount_sompi: u64,
    wire: Vec<u8>,
    source: Address,
    intent: TransportIntent,
    pin: PinPolicy,
) -> Result<SignableSummaryDto, AppError> {
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

    let priority = engine
        .mature_utxos_at(&source)
        .await
        .map_err(AppError::chain)?;
    if priority.is_empty() {
        return Err(AppError::msg(
            "this conversation's address is waiting on confirming funds — try again in a few seconds",
        ));
    }
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
        // Un-hide ONLY the row this call actually acts on. Restoring every
        // hidden row for the address would hand back the broken duplicate the
        // user hid — the very state this change exists to converge away from.
        // INV-6 needs the row we reuse or refuse toward to be reachable, and
        // nothing more.
        let acted_on = rows
            .iter()
            .find(|r| r.status == ConversationStatus::Active)
            .or(reuse.as_ref());
        if let Some(row) = acted_on {
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
        if rows.iter().any(|r| r.status == ConversationStatus::Active) {
            return Err(AppError::msg(
                "you already have a conversation with this address. Open it from your messages instead of sending another invitation.",
            ));
        }
        reuse
    };
    // A gap, stated rather than implied: we cannot refuse a duplicate when
    // THEY invited US first. A `PendingInbound` row carries no contact address
    // until its accept resolves the sender, so it is invisible to an address
    // lookup — handshaking someone whose invitation is already in your list
    // still spends a second bond beside theirs. Closing it needs the sender
    // recorded at fold time, which is the same work as F2.

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

    prepare_transport_send(
        dest,
        HANDSHAKE_BOND_SOMPI,
        wire,
        own_address, // source-address discipline: input[0] + change = receive/0
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
pub fn transport_existing_conversation(address: String) -> Result<Option<String>, AppError> {
    let dest = validate_mainnet_address(&address)?;
    let hub = hub()?;
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);

    // Most-established first, and only rows the user could actually TALK in —
    // decided by the same predicate the send path uses, not a second copy of
    // the rule. Opening a thread you cannot speak in would answer "you already
    // have this contact" with a dead end.
    let found = store
        .conversations_for_contact_address(&dest.to_string())
        .into_iter()
        .find(|c| comm_sendable(c.status, c.initiated_by_me, &c.contact_address, &c.my_alias))
        .map(|c| (c.conversation_id.clone(), c.status));

    let Some((conversation_id, status)) = found else {
        return Ok(None);
    };
    if may_unhide(status, store.is_conversation_tombstoned(&conversation_id)) {
        warn_store(store.untombstone_conversation(&conversation_id));
        log::info!("transport: re-adding a hidden contact — conversation restored");
    }
    drop(store);
    ping(&conversation_id);
    Ok(Some(conversation_id))
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
        // A wait, not a dead end (INV-6): the node-override lane flips the row
        // to `NodeScanned` the moment our own scan reaches that txid, and this
        // clears itself.
        if matches!(
            store.message(&txid).map(|m| m.provenance),
            Some(RowSource::FillSourced)
        ) {
            return Err(AppError::msg(
                "this invitation came from a history archive and your own node has \
                 not seen it yet — accepting would return the bond on an unverified \
                 claim. It will clear once your node catches up.",
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

    prepare_transport_send(
        dest.clone(),
        HANDSHAKE_BOND_SOMPI, // the refund — the same provenance-cited norm
        wire,
        own_address, // source-address discipline: input[0] = the address they know
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
    let floor = engine
        .minimum_sendable(own_address.clone())
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
/// a stash from inside its handshake flow. We cannot: a backup is funded from
/// `receive/0`, and immediately after a handshake spends that address its
/// change is unconfirmed, so `mature_utxos_at` finds nothing. Nor can several
/// backups be emitted back to back, for the same reason — and there is exactly
/// one `PENDING_TRANSPORT` slot, so preparing one while a confirm sheet is open
/// would destroy the plan the user is looking at. One explicit action, one
/// transaction, everything in it.
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
    let floor = engine
        .minimum_sendable(own_address.clone())
        .map_err(AppError::chain)?
        .ok_or_else(|| {
            AppError::msg("your balance can't cover a backup right now (anti-dust floor)")
        })?;

    prepare_transport_send(
        own_address.clone(), // self-send (D-069): the value comes straight back
        floor,
        wire,
        own_address,
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
    Ok(store
        .list_conversations()
        .into_iter()
        // Hidden rows are matchable but not shown — that asymmetry IS the fix
        // (see `transport_hide_conversation`).
        .filter(|c| !store.is_conversation_tombstoned(&c.conversation_id))
        .map(|c| ConversationDto {
            invite_expired: invite_expired(c.status, c.created_unix_ms, now),
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
            tombstoned,
            provenance,
        }),
        StoredKind::Comm => {
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
                            let (text, frame) = split_frame(&body);
                            (text, frame, true)
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
    /// log line the module has (content words, not an allowlist).
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
