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
    resolve_return_address, split_comm_body, AcceptanceEvent, Address, ChainError,
    ConversationRecord, ConversationStatus, KeyBranch, MessageDirection, MessageRecord,
    PreparedSend, RowSource, SignerT, StoredKind, TransportEvent, TransportStore, WatchSource,
    HANDSHAKE_BOND_SOMPI,
};
use kaspaverse_core::frames::{
    self, build_accept, build_challenge, build_taunt, fresh_challenge_id, GAME_ATTACK_DEFEND,
};
use kaspaverse_core::handshake::{fresh_alias, fresh_conversation_id, HandshakePayload};
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
        let address = address.to_string();
        let start = cursors.handshakes.get(&address).copied().unwrap_or(0);
        let outcome = walk_pages(
            |cursor| client.handshakes_by_receiver(&address, cursor),
            start,
            now_unix_ms(),
        )
        .await;
        report.pages += outcome.pages;
        for row in &outcome.items {
            let Some(body) = kaspaverse_chain::history_fill::decode_hex(&row.message_payload)
            else {
                continue; // malformed hint row — omitted data, never an error
            };
            let event = TransportEvent {
                txid: Some(row.tx_id.clone()),
                kind: "handshake".to_string(),
                body,
                addresses: vec![row.receiver.clone()],
                block_time_ms: Some(row.block_time),
            };
            if handle_inbound(hub, event, EventOrigin::Fill) {
                report.new_rows += 1;
            }
        }
        if outcome.cursor > start {
            cursors.handshakes.insert(address, outcome.cursor);
        }
        if !outcome.complete {
            report.complete = false;
            if report.error.is_none() {
                report.error = outcome.error;
            }
        }
    }

    // Comm sweep: per ACTIVE conversation, by (contact address, THEIR alias)
    // — the sender tags comms with their own alias (§K7 partition key).
    let conversations: Vec<(String, String, String)> = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        store
            .list_conversations()
            .into_iter()
            .filter(|c| c.status == ConversationStatus::Active)
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
        let alias_hex = encode_hex(their_alias.as_bytes());
        let start = cursors.comms.get(&conversation_id).copied().unwrap_or(0);
        let outcome = walk_pages(
            |cursor| client.comms_by_sender(&contact_address, &alias_hex, cursor),
            start,
            now_unix_ms(),
        )
        .await;
        report.pages += outcome.pages;
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
            if handle_inbound(hub, event, EventOrigin::Fill) {
                report.new_rows += 1;
            }
        }
        if outcome.cursor > start {
            cursors.comms.insert(conversation_id, outcome.cursor);
        }
        if !outcome.complete {
            report.complete = false;
            if report.error.is_none() {
                report.error = outcome.error;
            }
        }
    }

    if let Err(e) = cursors.save(dir) {
        log::warn!("history-fill: cursor save failed: {e}");
    }
    report
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
                    handle_inbound(&fold_hub, event, EventOrigin::Node);
                }
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
                    let txid = match &event {
                        AcceptanceEvent::Accepted { txid }
                        | AcceptanceEvent::Confirmed { txid, .. }
                        | AcceptanceEvent::Displaced { txid }
                        | AcceptanceEvent::DisplacedElapsed { txid }
                        | AcceptanceEvent::Stalled { txid, .. } => txid.clone(),
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

/// One scan match → store/conversation fold. Content never reaches a log
/// line from here (§4: message plaintext is treated like key material for
/// logging; even sealed bodies are logged as shapes only). Returns whether a
/// NEW row was recorded — the live scan ignores it; the V2b fill counts it
/// (its report is row-counts, never content).
fn handle_inbound(hub: &TransportHub, event: TransportEvent, origin: EventOrigin) -> bool {
    // The store law keys on txid (D-065); an id-less event (exotic — both the
    // node's verbose data AND the pinned recompute failed) cannot be stored.
    let Some(txid) = event.txid else { return false };
    match event.kind.as_str() {
        "handshake" => handle_inbound_handshake(
            hub,
            &txid,
            &event.body,
            &event.addresses,
            event.block_time_ms,
            origin,
        ),
        "comm" => handle_inbound_comm(hub, &txid, &event.body, event.block_time_ms, origin),
        // `legacy` (VNone): parse-layer tolerance is fixture-pinned in chain;
        // conversation semantics for the unversioned generation are
        // consciously deferred (the population emits versioned forms since
        // 2025). `payment` memos: deferred (not a P2.3 deliverable). `bcast`:
        // plaintext dev/broadcast lane, rendered by the dev panel. Unknown
        // kinds: forward-compat opaque (§0.5) — visible on the dev wire view.
        _ => false,
    }
}

fn handle_inbound_handshake(
    hub: &TransportHub,
    txid: &str,
    body: &[u8],
    addresses: &[String],
    block_time_ms: Option<u64>,
    origin: EventOrigin,
) -> bool {
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
                return false;
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
        return false;
    }
    let envelope_bytes = decode_envelope_body(body);
    let Ok(envelope) = Envelope::from_bytes(&envelope_bytes) else {
        return false;
    };
    // Establishment scan: whichever watched key opens it becomes the §0.7
    // binding. Not ours / vault locked ⇒ skip (live-only law: an envelope
    // seen while locked is missed, same as one seen while offline). This
    // decrypt is ALSO the fill's verify step: an indexer row no watched key
    // opens is dropped here — omission is possible, forgery is not (D-074).
    let Ok((slot, plaintext)) = hub
        .decryptor
        .decrypt_scanning(keys.handshake_slots().iter().copied(), &envelope)
    else {
        return false;
    };
    let Ok(payload) = HandshakePayload::from_plaintext(&plaintext) else {
        log::debug!("transport-hub: undecodable handshake payload skipped");
        return false;
    };
    drop(plaintext); // Zeroizing — wiped here; the store keeps ciphertext only

    // Conversation clocks ride the block time when the source knows it (the
    // fill; the scans since V2b) so filled history lands in true order.
    let now = block_time_ms.unwrap_or_else(now_unix_ms);
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
            Ok(None) => return false, // a racing writer settled it first
            Err(e) => {
                log::warn!("transport-hub: store append failed: {e}");
                return false;
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
        return true;
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
            return true;
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
    true
}

fn handle_inbound_comm(
    hub: &TransportHub,
    txid: &str,
    body: &[u8],
    block_time_ms: Option<u64>,
    origin: EventOrigin,
) -> bool {
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
                    return false;
                }
                Some(row.clone())
            }
            None => None,
        }
    };
    // The alias head sits OUTSIDE the envelope — split BEFORE any envelope
    // parse (P2.2 handover law).
    let Some((alias, sealed)) = split_comm_body(body) else {
        return false;
    };
    // Relevance without crypto: the alias must belong to one of our
    // conversations (either side's — senders tag with their own).
    let (conversation_id, bound) = {
        let store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(conversation) = store.conversation_by_alias(&alias) else {
            return false;
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
        return false;
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
                Err(_) => return false, // alias matched but no key opens it — spoofed head
            }
        }
        Err(_) => return false, // vault locked mid-stream — live-only law
    };

    // Row clock = block time when the source knows it (fill + scans since
    // V2b): filled history sorts into its true position, not "now".
    let now = block_time_ms.unwrap_or_else(now_unix_ms);
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
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
            Ok(None) => return false, // a racing writer settled it first
            Err(e) => {
                log::warn!("transport-hub: store append failed: {e}");
                return false;
            }
        }
        if let Some(existing) = store.conversation(&conversation_id) {
            let mut conversation = existing.clone();
            conversation.last_activity_unix_ms = conversation.last_activity_unix_ms.max(now);
            warn_store(store.upsert_conversation(conversation));
        }
        drop(store);
        watch_acceptance(txid, block_time_ms);
        ping(&conversation_id);
        if old.conversation_id != conversation_id {
            ping(&old.conversation_id);
        }
        return true;
    }

    let recorded = store.record_message(record);
    if let Err(e) = &recorded {
        log::warn!("transport-hub: store append failed: {e}");
    }
    if let Ok(true) = recorded {
        if let Some(existing) = store.conversation(&conversation_id) {
            let mut conversation = existing.clone();
            // Max, never assignment: an old filled row must not re-sort the
            // conversation list above genuinely newer traffic.
            conversation.last_activity_unix_ms = conversation.last_activity_unix_ms.max(now);
            warn_store(store.upsert_conversation(conversation));
        }
        drop(store);
        watch_acceptance(txid, block_time_ms);
        ping(&conversation_id);
        return true;
    }
    false
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
) -> Result<SignableSummaryDto, AppError> {
    // D-069 structural check: a comm-carried kind IS a self-send — its
    // destination and pinned source are the same bound address (value
    // returns as change; the sheet leads with the fee). Debug-only belt: the
    // kind the DTO carries must never claim self-send over a tx that pays a
    // stranger. Never crosses the bridge (release-stripped).
    debug_assert!(
        !matches!(intent, TransportIntent::Comm { .. }) || dest == source,
        "a Comm intent must be a self-send (D-069): dest == source"
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
        TransportIntent::Comm { .. } => SignableKind::SelfSendFrame,
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
    hub()?; // the store must be live before we can promise persistence

    let my_alias = fresh_alias();
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
        own_address, // source-address discipline: input[0] + change = receive/0
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

/// Hide a conversation — tombstone the row (and its messages replay-drop with
/// it via the store's own remove path). The P2.3b cleanup affordance for zombie
/// pending rows (D-068): the KaChat-era pending contacts and the counterpart's
/// own stranger-conversation the sitting surfaced. Local-only bookkeeping — it
/// removes nothing on-chain and signals nothing to the counterpart; a future
/// handshake from the same address simply re-creates a fresh row. Idempotent:
/// hiding an unknown id is a no-op success.
pub fn transport_hide_conversation(conversation_id: String) -> Result<(), AppError> {
    let hub = hub()?;
    let mut store = hub.store.lock().unwrap_or_else(PoisonError::into_inner);
    // Cascade: REMOVE the conversation's messages first so no orphaned
    // sealed rows linger, then the conversation row itself. (A hard remove —
    // deliberately not the V1 reversible reorg tombstone: hide is a local
    // purge the user asked for, not a chain observation.)
    let txids: Vec<String> = store
        .messages_for(&conversation_id)
        .into_iter()
        .map(|m| m.txid)
        .collect();
    for txid in txids {
        warn_store(store.remove_message(&txid));
    }
    store
        .remove_conversation(&conversation_id)
        .map_err(AppError::chain)?;
    drop(store);
    // Nudge any open list to re-pull (the thread, if open, will 404 and pop).
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
}
