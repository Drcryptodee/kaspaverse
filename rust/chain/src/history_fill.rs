//! V2b history fill (D-074, first D-070 integration): a `ciph_msg` indexer as
//! a **verifiable hint** — it can point at envelopes we missed while closed,
//! it can never forge one (every returned envelope is verified by LOCAL
//! decryption in the existing inbound pipeline; txid dedup makes replays
//! harmless). INV-8 as amended D-070: optional, disable-able, endpoint
//! replaceable; node-only stays fully functional. Membrane (D-068/D-070):
//! messages are the social layer — covenant/game STATE never rides this.
//!
//! This module owns the untrusted-accelerator plumbing only: the HTTP client
//! (the resolver's own `workflow-http` from the pinned tree — D-074's
//! pinned-crates-first ruling), the response DTOs (pinned against the
//! kasia-indexer source at `api/v1/{handshakes,contextual_messages}.rs` —
//! clone-read 2026-07-10, L43), the page walker, and the on-disk fill
//! config/cursor state. Decryption, relevance, and the store live in the
//! bridge's inbound pipeline — the fill has NO decrypt surface of its own.
//!
//! Source-pinned API reality (diverges from Kasia's own client, PB-003):
//! the server clamps `limit` to **50** (`params.limit.unwrap_or(10).min(50)`),
//! not the 100 their web client asks for; `block_time` is an INCLUSIVE
//! ascending range start, so the walker advances a txid-dedup'd cursor and
//! tolerates boundary re-serves. Their client never paginates — we do.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::error::{ChainError, Result};

/// The hosted default — a replaceable convenience, never a dependency
/// (D-070 clause 3; Kasia's live instance, studied at `fd1ba0c`).
pub const DEFAULT_INDEXER: &str = "https://indexer.kasia.fyi";

/// Server-side page clamp, from the indexer source (`.min(50)`).
pub const PAGE_LIMIT: usize = 50;

/// Pages per single walk (one address or one conversation) — bounds a
/// first-enable full-history walk. 40 × 50 = 2 000 rows; a capped walk is
/// reported incomplete (never silently truncated) and resumes from its
/// advanced cursor next run.
pub const PAGE_BUDGET: u32 = 40;

/// Per-page HTTP deadline. `workflow-http`'s native path sets no timeout of
/// its own; an unreachable indexer must fail the fill honestly, not hang it.
const PAGE_TIMEOUT: Duration = Duration::from_secs(10);

// ── Response DTOs (pinned to the indexer's serde Serialize shapes) ─────────

/// One row of `GET /handshakes/by-receiver` (also `/by-sender`).
/// `message_payload` is the indexer's hex encoding of the stored bytes —
/// for a v1 handshake those are the RAW sealed-envelope bytes after
/// `ciph_msg:1:handshake:` (their `op.sealed_hex`, stored verbatim).
/// Unused response fields (`accepting_block`, `accepting_daa_score`) are
/// ignored by serde — acceptance truth comes from our node, never a hint.
#[derive(Debug, Clone, Deserialize)]
pub struct IndexerHandshake {
    pub tx_id: String,
    pub sender: String,
    pub receiver: String,
    pub block_time: u64,
    pub message_payload: String,
}

/// One row of `GET /contextual-messages/by-sender`. `message_payload` is hex
/// of the bytes after `comm:<alias>:` — for the live population that is
/// base64 TEXT (the emitters' `btoa`), which `decode_envelope_body` already
/// normalises. `alias` echoes the query's alias hex.
#[derive(Debug, Clone, Deserialize)]
pub struct IndexerComm {
    pub tx_id: String,
    pub sender: String,
    pub alias: String,
    pub block_time: u64,
    pub message_payload: String,
}

/// One row of `GET /self-stash/by-owner` — our OWN conversation metadata,
/// sealed to our own key and parked on chain so a restore-from-seed rebuilds
/// contacts and not just money (D-138).
///
/// `stashed_data` is hex of the RAW sealed envelope (the bytes after
/// `self_stash:<scope>:`) — verified against a real Kasia stash transaction on
/// 2026-08-14, same raw convention as a handshake.
///
/// `owner` is the indexer's CLAIM about whose stash this is, and we never lean
/// on it (INV-8) — nor on the envelope opening, which proves only that someone
/// knew our published address. What makes a row ours is the keyed authorship
/// tag inside the plaintext (`kaspaverse-core::handshake::attach_stash_tag`).
#[derive(Debug, Clone, Deserialize)]
pub struct IndexerSelfStash {
    pub tx_id: String,
    pub block_time: u64,
    pub stashed_data: String,
}

// ── The client (thin: URL build + fetch + parse; no policy) ────────────────

pub struct IndexerClient {
    base: String,
}

impl IndexerClient {
    /// `base` must be an `http(s)://` URL (validated at config-set time too —
    /// this is the last line of defense for a hand-edited config file).
    pub fn new(base: &str) -> Result<Self> {
        let base = base.trim().trim_end_matches('/').to_string();
        if !(base.starts_with("https://") || base.starts_with("http://")) {
            return Err(ChainError::Message(
                "indexer endpoint must be an http(s) URL".into(),
            ));
        }
        Ok(Self { base })
    }

    /// Handshakes bonded to `receiver_address`, ascending from
    /// `since_block_time` (inclusive). Recovers NEW inbound contacts too.
    pub async fn handshakes_by_receiver(
        &self,
        receiver_address: &str,
        since_block_time: u64,
    ) -> Result<Vec<IndexerHandshake>> {
        let url = format!(
            "{}/handshakes/by-receiver?address={}&block_time={}&limit={}",
            self.base, receiver_address, since_block_time, PAGE_LIMIT
        );
        fetch_json(&url).await
    }

    /// Comms tagged with (`sender_address`, `alias_hex`), ascending from
    /// `since_block_time` (inclusive). `alias_hex` is the hex encoding of the
    /// on-wire alias STRING bytes (their partition key), ≤32 hex chars.
    pub async fn comms_by_sender(
        &self,
        sender_address: &str,
        alias_hex: &str,
        since_block_time: u64,
    ) -> Result<Vec<IndexerComm>> {
        let url = format!(
            "{}/contextual-messages/by-sender?address={}&alias={}&block_time={}&limit={}",
            self.base, sender_address, alias_hex, since_block_time, PAGE_LIMIT
        );
        fetch_json(&url).await
    }

    /// Self-stash rows owned by `owner_address` under `scope`, ascending from
    /// `since_block_time` (inclusive).
    ///
    /// **`scope` goes on the wire HEX-ENCODED**, and that is not a guess: the
    /// indexer partitions self-stash rows in the same column it uses for comm
    /// aliases, so a plain `saved_handshake` is answered
    /// `{"error":"Invalid alias hex: Invalid input length 14"}`. Measured
    /// against the live endpoint 2026-08-14; the live population encodes it the
    /// same way (`historical-syncer.ts`, "encode alias as hex string").
    pub async fn self_stash_by_owner(
        &self,
        owner_address: &str,
        scope: &str,
        since_block_time: u64,
    ) -> Result<Vec<IndexerSelfStash>> {
        let url = format!(
            "{}/self-stash/by-owner?owner={}&scope={}&block_time={}&limit={}",
            self.base,
            owner_address,
            encode_hex(scope.as_bytes()),
            since_block_time,
            PAGE_LIMIT
        );
        fetch_json(&url).await
    }
}

/// One GET with the fill's deadline; errors carry network/HTTP text only
/// (never payload content — bodies are on-chain public data anyway, but the
/// log discipline stays shape-only).
async fn fetch_json<T: serde::de::DeserializeOwned + 'static>(url: &str) -> Result<T> {
    match tokio::time::timeout(PAGE_TIMEOUT, workflow_http::get_json::<T>(url)).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(e)) => Err(ChainError::Message(format!("indexer request failed: {e}"))),
        Err(_) => Err(ChainError::Message(
            "indexer request timed out (10 s)".into(),
        )),
    }
}

// ── The page walker (pure policy; injectable fetch — unit-tested) ──────────

/// Accessors the walker needs from a page row.
pub trait FillItem {
    fn tx_id(&self) -> &str;
    fn block_time(&self) -> u64;
}

impl FillItem for IndexerHandshake {
    fn tx_id(&self) -> &str {
        &self.tx_id
    }
    fn block_time(&self) -> u64 {
        self.block_time
    }
}

impl FillItem for IndexerComm {
    fn tx_id(&self) -> &str {
        &self.tx_id
    }
    fn block_time(&self) -> u64 {
        self.block_time
    }
}

impl FillItem for IndexerSelfStash {
    fn tx_id(&self) -> &str {
        &self.tx_id
    }
    fn block_time(&self) -> u64 {
        self.block_time
    }
}

/// Outcome of one bounded walk. `cursor` is the resume point (max block_time
/// observed; the inclusive range start re-serves the boundary row next run —
/// txid dedup absorbs it). `complete` = the server ran out of rows within
/// budget; a capped or errored walk reports `false` so the honest notice
/// stays up (never silence — D-074).
pub struct WalkOutcome<T> {
    pub items: Vec<T>,
    pub cursor: u64,
    pub complete: bool,
    pub pages: u32,
    pub error: Option<String>,
}

/// Block-time sanity ceiling: a real block's timestamp is consensus-bounded
/// near wall-clock; a row claiming a block_time further in the future than
/// this slack is hostile or corrupt. Consumed unclamped it could wedge the
/// persisted cursor at `u64::MAX` forever or pin a conversation atop the
/// list permanently (consensus-audit finding, V2b) — such rows are skipped
/// and logged (shape only), and never advance the cursor.
const FUTURE_SKEW_MS: u64 = 10 * 60 * 1000;

/// Walk pages ascending from `start_cursor` until a short page, the budget,
/// or no-progress (a full page of already-seen txids). A no-progress FULL
/// page reports `complete: false`: with ≥PAGE_LIMIT rows sharing one
/// block_time the cursor cannot advance past the wall (the API has no
/// offset), so rows beyond it are unreachable — that is truncation and must
/// keep the honest notice up, never read as drained (consensus-audit
/// finding, V2b). Dedup is per-walk; store-level txid dedup is the durable
/// layer behind it. `now_unix_ms` anchors the future-skew clamp.
pub async fn walk_pages<T, F, Fut>(
    mut fetch: F,
    start_cursor: u64,
    now_unix_ms: u64,
) -> WalkOutcome<T>
where
    T: FillItem,
    F: FnMut(u64) -> Fut,
    Fut: std::future::Future<Output = Result<Vec<T>>>,
{
    let ceiling = now_unix_ms.saturating_add(FUTURE_SKEW_MS);
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut items: Vec<T> = Vec::new();
    let mut cursor = start_cursor;
    let mut pages = 0u32;
    let mut skipped_future = 0u32;
    loop {
        if pages >= PAGE_BUDGET {
            log::info!(
                "history-fill: walk hit its {PAGE_BUDGET}-page budget — resuming next run (incomplete, not silent)"
            );
            return WalkOutcome {
                items,
                cursor,
                complete: false,
                pages,
                error: None,
            };
        }
        let page = match fetch(cursor).await {
            Ok(page) => page,
            Err(e) => {
                return WalkOutcome {
                    items,
                    cursor,
                    complete: false,
                    pages,
                    error: Some(e.to_string()),
                };
            }
        };
        pages += 1;
        let page_len = page.len();
        let mut progressed = false;
        for item in page {
            if item.block_time() > ceiling {
                skipped_future += 1;
                continue; // hostile/corrupt row — never folds, never moves the cursor
            }
            cursor = cursor.max(item.block_time());
            if seen.insert(item.tx_id().to_string()) {
                progressed = true;
                items.push(item);
            }
        }
        if skipped_future > 0 {
            log::warn!(
                "history-fill: {skipped_future} future-dated row(s) skipped (block_time past the skew ceiling)"
            );
        }
        if page_len < PAGE_LIMIT {
            // Short page = drained.
            return WalkOutcome {
                items,
                cursor,
                complete: true,
                pages,
                error: None,
            };
        }
        if !progressed {
            // A FULL page with zero fresh rows: the cursor is wedged against
            // a same-block_time wall (or an all-future-dated page) — rows
            // beyond it are unreachable this run. Honest incomplete.
            return WalkOutcome {
                items,
                cursor,
                complete: false,
                pages,
                error: Some(
                    "page wall: a full page yielded no new rows (same-block_time cluster past the API's reach)"
                        .into(),
                ),
            };
        }
    }
}

// ── Config + cursor persistence (transport dir; public-wire-class data) ────

/// The user's fill posture. Default **OFF** — the §0 lock the founder ruled
/// at the V2b session (2026-07-10): node-only out of the box, zero graph
/// leakage until an explicit opt-in beside the plain-language disclosure.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FillConfig {
    pub enabled: bool,
    pub endpoint: String,
}

impl Default for FillConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            endpoint: DEFAULT_INDEXER.to_string(),
        }
    }
}

/// Resume points: per receive-address for handshakes, per conversation for
/// comms (block times differ per key — one global cursor would strand a
/// quieter key behind a busier one). Block-time domain (unix ms from block
/// headers) — explicitly NOT the store's local-clock `unix_ms` (different
/// clocks; mapping them here is what keeps the fill from re-walking
/// already-folded history). Missing key = 0 = full history on first walk.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FillCursors {
    #[serde(default)]
    pub handshakes: HashMap<String, u64>,
    #[serde(default)]
    pub comms: HashMap<String, u64>,
    /// Per owning address, for the D-138 self-stash sweep. **This is where a
    /// new fill lane's state belongs** — `#[serde(default)]` over JSON means an
    /// older file loads fine and a newer one degrades gracefully, whereas the
    /// borsh conversation log would have `replay()` STOP at the first frame
    /// carrying a field an older build cannot decode (`kvlog.rs`).
    #[serde(default)]
    pub stash: HashMap<String, u64>,
}

/// What the last committed self-stash snapshot covered (D-138).
///
/// **Coverage bookkeeping, never an obligation.** Losing this file costs one
/// redundant snapshot — a network fee — and never costs history. That is
/// precisely why the non-atomic `write_json` below is the right primitive here
/// and would be the wrong one for anything that gates a spend.
///
/// It lives in its OWN file rather than beside [`FillCursors`] because the two
/// have different writers: the fill lane rewrites cursors on every run while
/// the commit lane rewrites this on every backup. One load-modify-save JSON
/// file with two independent writers is a clobber waiting to happen.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct StashState {
    /// When the covering snapshot was built (local clock, ms).
    #[serde(default)]
    pub last_unix_ms: u64,
    #[serde(default)]
    pub last_txid: String,
    /// The conversation ids that snapshot carried.
    #[serde(default)]
    pub covered: Vec<String>,
    /// Set once a fill walk has actually READ [`Self::last_txid`] back under
    /// our own owner.
    ///
    /// Broadcasting a backup is not the same as being able to find it again.
    /// The indexer attributes a stash by input\[0\]'s funder, and that
    /// attribution can fail quietly — leaving a transaction that is on chain,
    /// valid, and permanently invisible to the only query that could restore
    /// it. Until this flag is set the wallet says "sent, not yet confirmed
    /// readable", which is the true state and the one that prompts a retry.
    #[serde(default)]
    pub confirmed_readable: bool,
}

impl StashState {
    /// Infallible: an absent or corrupt file reads as "nothing is backed up",
    /// which is the honest answer and the safe one.
    pub fn load(dir: &Path) -> Self {
        read_json(&dir.join(STASH_STATE_FILE))
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        write_json(&dir.join(STASH_STATE_FILE), self)
    }

    pub fn path(dir: &Path) -> PathBuf {
        dir.join(STASH_STATE_FILE)
    }
}

const CONFIG_FILE: &str = "fill.config";
const CURSORS_FILE: &str = "fill.cursors";
const STASH_STATE_FILE: &str = "stash.state";

fn read_json<T: serde::de::DeserializeOwned + Default>(path: &Path) -> T {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    let bytes = serde_json::to_vec(value)
        .map_err(|e| ChainError::Message(format!("fill state encode failed: {e}")))?;
    std::fs::write(path, bytes)
        .map_err(|e| ChainError::Message(format!("fill state write failed: {e}")))?;
    Ok(())
}

impl FillConfig {
    pub fn load(dir: &Path) -> Self {
        read_json(&dir.join(CONFIG_FILE))
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        // Endpoint sanity at the write side too (IndexerClient re-checks).
        IndexerClient::new(&self.endpoint)?;
        write_json(&dir.join(CONFIG_FILE), self)
    }
}

impl FillCursors {
    pub fn load(dir: &Path) -> Self {
        read_json(&dir.join(CURSORS_FILE))
    }

    pub fn save(&self, dir: &Path) -> Result<()> {
        write_json(&dir.join(CURSORS_FILE), self)
    }

    pub fn path(dir: &Path) -> PathBuf {
        dir.join(CURSORS_FILE)
    }
}

// ── Byte helpers (dependency-free; test-pinned) ────────────────────────────

/// Strict lowercase/uppercase hex → bytes. `None` on odd length or a non-hex
/// byte — the caller skips the row (an indexer can OMIT, never FORGE; a
/// malformed row is just omitted data).
pub fn decode_hex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    fn nibble(b: u8) -> Option<u8> {
        match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        }
    }
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks(2) {
        out.push((nibble(pair[0])? << 4) | nibble(pair[1])?);
    }
    Some(out)
}

/// Bytes → lowercase hex (the alias-string → query-param encoding: the
/// indexer keys comms on the hex of the on-wire alias bytes).
pub fn encode_hex(bytes: &[u8]) -> String {
    const TABLE: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(TABLE[(b >> 4) as usize] as char);
        out.push(TABLE[(b & 0x0F) as usize] as char);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hs(tx: &str, t: u64) -> IndexerHandshake {
        IndexerHandshake {
            tx_id: tx.into(),
            sender: "kaspa:s".into(),
            receiver: "kaspa:r".into(),
            block_time: t,
            message_payload: "aa".into(),
        }
    }

    #[test]
    fn hex_round_trips_and_rejects_garbage() {
        assert_eq!(encode_hex(b"a1"), "6131");
        assert_eq!(decode_hex("6131").unwrap(), b"a1");
        assert_eq!(decode_hex(""), Some(vec![]));
        assert!(decode_hex("abc").is_none(), "odd length");
        assert!(decode_hex("zz").is_none(), "non-hex");
        // The 12-char alias string → 24 hex chars, inside the server's 32 cap.
        assert_eq!(encode_hex(b"a1b2c3d4e5f6").len(), 24);
    }

    #[test]
    fn response_dtos_parse_the_source_pinned_shape() {
        // Field set from the indexer source (handshakes.rs:64-73 /
        // contextual_messages.rs:58-67); unknown fields must be tolerated.
        let hs: Vec<IndexerHandshake> = serde_json::from_str(
            r#"[{"tx_id":"ab","sender":"kaspa:s","receiver":"kaspa:r",
                 "block_time":123,"accepting_block":null,
                 "accepting_daa_score":null,"message_payload":"beef"}]"#,
        )
        .unwrap();
        assert_eq!(hs[0].block_time, 123);
        let cm: Vec<IndexerComm> = serde_json::from_str(
            r#"[{"tx_id":"cd","sender":"kaspa:s","alias":"613162326333",
                 "block_time":456,"accepting_block":"ff","accepting_daa_score":9,
                 "message_payload":"caf3"}]"#,
        )
        .unwrap();
        assert_eq!(cm[0].alias, "613162326333");

        // Self-stash rows: the shape MEASURED against the live endpoint
        // 2026-08-14, including the nullable `owner`/`accepting_*` fields we
        // deliberately do not bind (INV-8: the indexer's claim about whose row
        // this is never decides anything — our own key opening it does).
        let ss: Vec<IndexerSelfStash> = serde_json::from_str(
            r#"[{"tx_id":"ef","owner":"kaspa:o","scope":"73617665645f68616e647368616b65",
                 "block_time":789,"accepting_block":"aa","accepting_daa_score":7,
                 "stashed_data":"d00d"}]"#,
        )
        .unwrap();
        assert_eq!(ss[0].block_time, 789);
        assert_eq!(decode_hex(&ss[0].stashed_data).unwrap(), vec![0xd0, 0x0d]);
    }

    /// Coverage state must degrade to "nothing is backed up" rather than to an
    /// error — an unreadable file is not a reason to refuse a backup, it is a
    /// reason to take one.
    #[test]
    fn stash_state_survives_a_missing_or_corrupt_file() {
        let dir = std::env::temp_dir().join(format!("kv-stash-state-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        assert_eq!(StashState::load(&dir), StashState::default(), "absent");

        std::fs::write(StashState::path(&dir), b"{ not json").unwrap();
        assert_eq!(StashState::load(&dir), StashState::default(), "corrupt");

        // A record written before the readability flag existed loads as
        // UNCONFIRMED — the safe reading, and the one that prompts a check.
        std::fs::write(
            StashState::path(&dir),
            br#"{"last_unix_ms":9,"last_txid":"cd","covered":["c1"]}"#,
        )
        .unwrap();
        let older = StashState::load(&dir);
        assert_eq!(older.last_txid, "cd");
        assert!(!older.confirmed_readable, "unproven until a walk reads it");

        let state = StashState {
            last_unix_ms: 42,
            last_txid: "ab".into(),
            covered: vec!["c1".into(), "c2".into()],
            confirmed_readable: true,
        };
        state.save(&dir).unwrap();
        assert_eq!(StashState::load(&dir), state);

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A cursor file written before the stash lane existed must still load —
    /// the `#[serde(default)]` law that keeps new fill state OFF the borsh
    /// conversation log, where a new field would truncate every replay.
    #[test]
    fn a_cursor_file_written_before_the_stash_field_still_loads() {
        let dir = std::env::temp_dir().join(format!("kv-old-cursors-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            FillCursors::path(&dir),
            br#"{"handshakes":{"kaspa:a":7},"comms":{"c1":9}}"#,
        )
        .unwrap();

        let cursors = FillCursors::load(&dir);
        assert_eq!(cursors.handshakes.get("kaspa:a"), Some(&7));
        assert_eq!(cursors.comms.get("c1"), Some(&9));
        assert!(cursors.stash.is_empty(), "new field defaults, never errors");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The self-stash scope travels HEX-ENCODED. The live endpoint answers a
    /// plain scope with `Invalid alias hex` — it partitions stash rows in the
    /// same column it uses for comm aliases. Pinned so nobody "simplifies" the
    /// encode away and silently gets an empty restore.
    #[test]
    fn the_stash_scope_is_hex_on_the_wire() {
        assert_eq!(
            encode_hex(crate::transport::STASH_SCOPE_SAVED_HANDSHAKE.as_bytes()),
            "73617665645f68616e647368616b65"
        );
    }

    /// Wall-clock anchor for tests — far past every fixture block_time.
    const NOW: u64 = 1_000_000;

    #[tokio::test]
    async fn walk_drains_short_page_and_advances_cursor() {
        let pages = vec![vec![hs("a", 10), hs("b", 20)]];
        let mut served = pages.into_iter();
        let outcome = walk_pages(|_| std::future::ready(Ok(served.next().unwrap())), 0, NOW).await;
        assert!(outcome.complete);
        assert_eq!(outcome.items.len(), 2);
        assert_eq!(outcome.cursor, 20);
        assert_eq!(outcome.pages, 1);
    }

    #[tokio::test]
    async fn walk_pages_through_full_pages_and_dedups_the_boundary_echo() {
        // Page 1 is FULL (50 rows, t=1..=50); page 2 re-serves the boundary
        // row (inclusive start) plus one fresh row, then drains.
        let full: Vec<IndexerHandshake> =
            (1..=50).map(|i| hs(&format!("t{i}"), i as u64)).collect();
        let second = vec![hs("t50", 50), hs("t51", 51)];
        let mut served = vec![full, second].into_iter();
        let outcome = walk_pages(|_| std::future::ready(Ok(served.next().unwrap())), 1, NOW).await;
        assert!(outcome.complete);
        assert_eq!(outcome.items.len(), 51, "boundary echo deduped");
        assert_eq!(outcome.cursor, 51);
        assert_eq!(outcome.pages, 2);
    }

    #[tokio::test]
    async fn walk_stops_without_progress_and_reports_errors_incomplete() {
        // A full page of already-seen txids terminates the walk AND reports
        // incomplete: the cursor is wedged against a same-block_time wall,
        // so rows beyond it are unreachable — truncation, never "drained"
        // (consensus-audit finding, V2b).
        let full: Vec<IndexerHandshake> = (0..50).map(|i| hs(&format!("x{i}"), 7)).collect();
        let mut served = vec![full.clone(), full].into_iter();
        let outcome = walk_pages(|_| std::future::ready(Ok(served.next().unwrap())), 0, NOW).await;
        assert!(!outcome.complete, "a page wall is truncation, not drained");
        assert!(outcome.error.as_deref().unwrap_or("").contains("page wall"));
        assert_eq!(outcome.items.len(), 50);

        // A FULL first page (so the walk continues), then an error: the walk
        // must keep its partial progress and report incomplete.
        let mut calls = 0;
        let outcome: WalkOutcome<IndexerHandshake> = walk_pages(
            |_| {
                calls += 1;
                std::future::ready(if calls == 1 {
                    Ok((1..=50).map(|i| hs(&format!("y{i}"), i as u64)).collect())
                } else {
                    Err(ChainError::Message("boom".into()))
                })
            },
            0,
            NOW,
        )
        .await;
        assert!(!outcome.complete);
        assert!(outcome.error.as_deref().unwrap_or("").contains("boom"));
        assert_eq!(outcome.items.len(), 50, "partial progress kept");
        assert_eq!(outcome.cursor, 50, "cursor advanced to folded progress");
    }

    #[tokio::test]
    async fn walk_skips_future_dated_rows_without_moving_the_cursor() {
        // A hostile row claiming u64::MAX must not fold, must not wedge the
        // cursor, and must not silence honest rows on the same page.
        let page = vec![hs("real", 10), hs("evil", u64::MAX), hs("real2", 20)];
        let mut served = vec![page].into_iter();
        let outcome = walk_pages(|_| std::future::ready(Ok(served.next().unwrap())), 0, NOW).await;
        assert!(outcome.complete, "short page still drains");
        assert_eq!(outcome.items.len(), 2, "future-dated row skipped");
        assert_eq!(outcome.cursor, 20, "cursor never touched the spoof");
    }

    #[test]
    fn config_defaults_off_and_round_trips() {
        let dir = std::env::temp_dir().join(format!("kv_fill_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let config = FillConfig::load(&dir);
        assert!(!config.enabled, "the §0 lock: fill defaults OFF");
        assert_eq!(config.endpoint, DEFAULT_INDEXER);

        let on = FillConfig {
            enabled: true,
            endpoint: "https://example.org/".into(),
        };
        on.save(&dir).unwrap();
        assert_eq!(FillConfig::load(&dir), on);

        let bad = FillConfig {
            enabled: true,
            endpoint: "ftp://nope".into(),
        };
        assert!(bad.save(&dir).is_err(), "non-http endpoint refused");

        let mut cursors = FillCursors::load(&dir);
        assert!(cursors.handshakes.is_empty());
        cursors.handshakes.insert("kaspa:addr".into(), 42);
        cursors.comms.insert("conv".into(), 7);
        cursors.save(&dir).unwrap();
        let reloaded = FillCursors::load(&dir);
        assert_eq!(reloaded.handshakes.get("kaspa:addr"), Some(&42));
        assert_eq!(reloaded.comms.get("conv"), Some(&7));
        std::fs::remove_dir_all(&dir).ok();
    }
}
