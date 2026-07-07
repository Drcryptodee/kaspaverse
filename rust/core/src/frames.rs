//! `kv:1:` game frames — the KaspaVerse arcade layer that rides INSIDE a
//! decrypted `ciph_msg:1:comm` plaintext (P2.4 §0.5, ratified D-062; the
//! quality-bar/laws sharpening 2026-07-06).
//!
//! ## One comm body, two faces
//!
//! A comm's decrypted plaintext is `<human-readable invite line>\n<kv:1:tail>`.
//! A Kasia/KaChat user (no `kv:1:` awareness) sees the invite line as ordinary
//! text — their client leads with `JSON.parse`, which throws on the first char,
//! so the whole body renders as plain text (Gate KV §K1/§K10, clone @
//! `acd3cf65`). A KaspaVerse user sees a tappable card built from the frame's
//! JSON FIELDS.
//!
//! ## Frames are hints, never truth (§0.3)
//!
//! Nothing here moves value. The stake is a DISPLAY number; real value binds at
//! the P3 covenant, never in a frame. Three laws hold by construction:
//! - **The invite line is GENERATED from the fields** ([`build_challenge`] et
//!   al.), never free-typed, so it can't lie about the card's game/stake — and
//!   [`parse`] renders the card from the JSON, so a tampered line is inert
//!   (personality rides a separate [`FrameKind::Taunt`]).
//! - **Unknown kinds / a future `kv:2:` degrade to the readable line**
//!   ([`Parsed::Unknown`]) — never a broken card (forward-compat, P5).
//! - **`accept` never spends** — a frame only invites; funding runs through the
//!   normal confirm-send ceremony + the P3 covenant (enforced at the bridge/UI).
//!
//! Because [`parse`] is a pure, total `&str -> Parsed` with no side effects and
//! no reach into any value-bearing store, a forged frame can only change pixels.
//!
//! ## Reserved seam
//!
//! The `challenge` body reserves an opaque `params` slot for P3 (a game covenant
//! born from a friend-invite OR a lobby-join). P2.4 neither emits nor reads it;
//! serde ignores unknown keys, so a future challenge carrying `params` still
//! parses here. The schema authority is `tests/vectors/frames_v1.json`.
//!
//! Custody note (§0.4): frame plaintext is decrypted user content (the same
//! class as `comm` text, D-056), not custody material — but it is still never
//! logged or persisted in the clear beyond the ciphertext-at-rest store.

use crate::error::{CoreError, Result};
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::OsRng;
use serde::{Deserialize, Serialize};

/// The frame version we emit and recognize. A different version parses to
/// [`Parsed::Unknown`] (degrade to the readable line).
pub const KV_VERSION: u32 = 1;

/// The P2.4 first game — a fixed Attack & Defend duel (founder call,
/// 2026-07-06; supersedes the P4 stub's "RPS" placeholder). The `game` field
/// stays an open string so P3+ add games without a wire break.
pub const GAME_ATTACK_DEFEND: &str = "attack_defend";

const MARKER_PREFIX: &str = "kv:";
const MAX_FIELD_LEN: usize = 64;

/// The recognized frame kinds (§0.5). Unknown tokens degrade, they never error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameKind {
    /// An invitation to a game — carries the game + a DISPLAY stake + an id.
    Challenge,
    /// A social acceptance of a challenge (references the challenge id). NEVER a
    /// wager: it rides the same self-send comm; funding is the P3 covenant.
    Accept,
    /// A reported outcome — display-only in P2.4 (a CLAIM, never settled truth;
    /// truth binds at the P3 covenant). Built by P3, only parsed here.
    Result,
    /// Personality/trash-talk — free text, makes no machine claim.
    Taunt,
}

impl FrameKind {
    /// The wire token (`kv:1:<token>:…`).
    pub fn as_token(self) -> &'static str {
        match self {
            Self::Challenge => "challenge",
            Self::Accept => "accept",
            Self::Result => "result",
            Self::Taunt => "taunt",
        }
    }

    fn from_token(token: &str) -> Option<Self> {
        match token {
            "challenge" => Some(Self::Challenge),
            "accept" => Some(Self::Accept),
            "result" => Some(Self::Result),
            "taunt" => Some(Self::Taunt),
            _ => None,
        }
    }
}

/// A recognized, parsed `kv:1:` frame. The card renders from the typed fields
/// (authoritative); [`line`](Self::line) is the readable text a Kasia user sees
/// and the KaspaVerse fallback.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KvFrame {
    pub kind: FrameKind,
    /// The readable invite/status line (everything before the `kv:1:` marker).
    pub line: String,
    /// `challenge`: the game slug (e.g. [`GAME_ATTACK_DEFEND`]).
    pub game: Option<String>,
    /// `challenge`: the DISPLAY stake in KAS (absent ⇒ a friendly, no-stake
    /// duel). Never a value that binds — P3 owns the real stake.
    pub stake: Option<String>,
    /// `challenge`: a short id so an `accept`/`result` can reference it.
    pub id: Option<String>,
    /// `accept`/`result`: the challenge id being referenced.
    pub ref_id: Option<String>,
    /// `result`: the reported outcome (a claim). `taunt`: the personality text.
    pub detail: Option<String>,
}

/// The outcome of parsing a decrypted comm plaintext.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Parsed {
    /// No `kv:1:` frame — an ordinary comm message. Carries the full text.
    Plain(String),
    /// A recognized frame — render its card.
    Frame(KvFrame),
    /// A `kv:`-shaped tail we don't recognize (unknown kind or a future
    /// version). Degrade to the readable line; never a card (P5).
    Unknown { line: String },
}

// ── JSON bodies (the `<json>` after `kv:1:<kind>:`) ──────────────────────────

#[derive(Serialize, Deserialize)]
struct ChallengeBody {
    game: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    stake: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    id: Option<String>,
    // NOTE: the reserved `params` covenant slot (P3) is intentionally NOT
    // modeled — serde ignores it on parse, so a future challenge carrying it
    // still reads here. P2.4 never emits it.
}

#[derive(Serialize, Deserialize)]
struct AcceptBody {
    #[serde(rename = "ref")]
    ref_id: String,
}

#[derive(Serialize, Deserialize)]
struct ResultBody {
    #[serde(rename = "ref", default, skip_serializing_if = "Option::is_none")]
    ref_id: Option<String>,
    outcome: String,
}

#[derive(Serialize, Deserialize)]
struct TauntBody {
    text: String,
}

// ── Build (emission) ─────────────────────────────────────────────────────────

/// Build a `challenge` frame plaintext: `<generated line>\n<kv:1:challenge:…>`.
/// The line is generated from the fields (law: it can't misrepresent the card).
/// `stake` is a DISPLAY value in KAS; `None` ⇒ a friendly, no-stake duel.
pub fn build_challenge(game: &str, stake: Option<&str>, id: &str) -> Result<String> {
    validate_slug(game)?;
    if let Some(stake) = stake {
        validate_stake(stake)?;
    }
    validate_id(id)?;
    let body = ChallengeBody {
        game: game.to_string(),
        stake: stake.map(str::to_string),
        id: Some(id.to_string()),
    };
    let (emoji, name) = game_label(game);
    let stake_part = match stake {
        Some(s) => format!("{s} KAS"),
        None => "friendly".to_string(),
    };
    let line = format!("{emoji} {name} challenge — {stake_part}. Open in KaspaVerse to play.");
    assemble(&line, FrameKind::Challenge, &body)
}

/// Build an `accept` frame plaintext referencing a challenge `id`. `game` names
/// the game for the readable line only; the frame binds nothing.
pub fn build_accept(game: &str, ref_id: &str) -> Result<String> {
    validate_slug(game)?;
    validate_id(ref_id)?;
    let body = AcceptBody {
        ref_id: ref_id.to_string(),
    };
    let (emoji, name) = game_label(game);
    let line = format!("✓ Accepted the {emoji} {name} challenge.");
    assemble(&line, FrameKind::Accept, &body)
}

/// Build a `taunt` frame plaintext — free personality text. The text IS the
/// readable line (a taunt makes no machine claim, so free text is honest here).
pub fn build_taunt(text: &str) -> Result<String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(CoreError::FrameShape("empty taunt"));
    }
    let body = TauntBody {
        text: trimmed.to_string(),
    };
    assemble(trimmed, FrameKind::Taunt, &body)
}

/// A fresh challenge id: 4 random bytes as 8 lowercase hex chars (same entropy
/// class as [`crate::handshake::fresh_alias`], smaller — an id, not a key).
pub fn fresh_challenge_id() -> String {
    let mut bytes = [0u8; 4];
    OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn assemble<T: Serialize>(line: &str, kind: FrameKind, body: &T) -> Result<String> {
    let json = serde_json::to_string(body).map_err(|_| CoreError::FrameShape("serialize"))?;
    Ok(format!(
        "{line}\n{MARKER_PREFIX}{KV_VERSION}:{}:{json}",
        kind.as_token()
    ))
}

// ── Parse (receive) ──────────────────────────────────────────────────────────

/// Parse a decrypted comm plaintext into [`Parsed`]. Pure and total: any input
/// is valid (non-frame text ⇒ [`Parsed::Plain`]); it never errors and never
/// touches value-bearing state. The frame marker is anchored to a line start
/// (position 0 or just after a `\n`) — the shape we emit — which keeps a `kv:`
/// substring inside a taunt/plain body from being mistaken for a frame.
pub fn parse(plaintext: &str) -> Parsed {
    for start in line_starts(plaintext) {
        let seg = &plaintext[start..];
        if !is_marker_shaped(seg) {
            continue;
        }
        let line = plaintext[..start].trim_end();
        match classify(seg) {
            Some((kind, frame)) => {
                return Parsed::Frame(KvFrame {
                    kind,
                    line: line.to_string(),
                    ..frame
                });
            }
            None => {
                // Marker-shaped but not a recognized frame (unknown kind or a
                // future version) — degrade to the readable line (P5). Fall
                // back to the raw body if no line preceded the marker.
                let shown = if line.is_empty() { plaintext } else { line };
                return Parsed::Unknown {
                    line: shown.to_string(),
                };
            }
        }
    }
    Parsed::Plain(plaintext.to_string())
}

/// Classify a marker-shaped segment (`kv:<v>:<kind>:<json>`). `Some` for a
/// recognized `kv:1:` frame whose JSON parses; `None` for a different version,
/// an unknown kind, or a malformed body (→ degrade to the line).
fn classify(seg: &str) -> Option<(FrameKind, KvFrame)> {
    let rest = seg.strip_prefix(MARKER_PREFIX)?;
    let (ver, rest) = rest.split_once(':')?;
    if ver.parse::<u32>().ok()? != KV_VERSION {
        return None;
    }
    let (token, json) = rest.split_once(':')?;
    let kind = FrameKind::from_token(token)?;
    let frame = match kind {
        FrameKind::Challenge => {
            let b: ChallengeBody = serde_json::from_str(json).ok()?;
            KvFrame {
                kind,
                line: String::new(),
                game: Some(b.game),
                stake: b.stake,
                id: b.id,
                ref_id: None,
                detail: None,
            }
        }
        FrameKind::Accept => {
            let b: AcceptBody = serde_json::from_str(json).ok()?;
            blank(kind, |f| f.ref_id = Some(b.ref_id))
        }
        FrameKind::Result => {
            let b: ResultBody = serde_json::from_str(json).ok()?;
            blank(kind, |f| {
                f.ref_id = b.ref_id;
                f.detail = Some(b.outcome);
            })
        }
        FrameKind::Taunt => {
            let b: TauntBody = serde_json::from_str(json).ok()?;
            blank(kind, |f| f.detail = Some(b.text))
        }
    };
    Some((kind, frame))
}

fn blank(kind: FrameKind, set: impl FnOnce(&mut KvFrame)) -> KvFrame {
    let mut f = KvFrame {
        kind,
        line: String::new(),
        game: None,
        stake: None,
        id: None,
        ref_id: None,
        detail: None,
    };
    set(&mut f);
    f
}

/// Line-start byte offsets: 0, then every index just after a `\n`.
fn line_starts(s: &str) -> impl Iterator<Item = usize> + '_ {
    std::iter::once(0).chain(
        s.bytes()
            .enumerate()
            .filter_map(|(i, b)| (b == b'\n').then_some(i + 1)),
    )
}

/// True when `seg` begins with `kv:<digits>:<nonempty-token>:` (ASCII-only,
/// byte-safe). Does NOT validate version/kind/json — that is [`classify`].
fn is_marker_shaped(seg: &str) -> bool {
    let Some(rest) = seg.strip_prefix(MARKER_PREFIX) else {
        return false;
    };
    let bytes = rest.as_bytes();
    let mut i = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i == 0 || bytes.get(i) != Some(&b':') {
        return false; // need ≥1 digit then ':'
    }
    i += 1;
    let token_start = i;
    while i < bytes.len() && bytes[i] != b':' {
        i += 1;
    }
    i > token_start && bytes.get(i) == Some(&b':') // ≥1 kind char then ':'
}

// ── Field generation / validation ────────────────────────────────────────────

/// Human label for a game slug, for the generated line. Known slug ⇒ its emoji
/// + name; unknown ⇒ a neutral swords glyph + the slug (forward-compat).
fn game_label(game: &str) -> (&'static str, String) {
    match game {
        GAME_ATTACK_DEFEND => ("⚔️", "Attack & Defend".to_string()),
        other => ("⚔️", other.to_string()),
    }
}

/// A wire-safe slug: non-empty ASCII `[a-z0-9_]`, bounded — never a `:` (which
/// would corrupt the marker) or a `\n`.
fn validate_slug(slug: &str) -> Result<()> {
    if slug.is_empty()
        || slug.len() > MAX_FIELD_LEN
        || !slug
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
    {
        return Err(CoreError::FrameShape("game slug"));
    }
    Ok(())
}

/// A display stake: a plain decimal (`digits` with at most one `.`), bounded —
/// so it can never inject arbitrary text into the generated line.
fn validate_stake(stake: &str) -> Result<()> {
    let ok = !stake.is_empty()
        && stake.len() <= MAX_FIELD_LEN
        && stake.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        && stake.bytes().filter(|&b| b == b'.').count() <= 1
        && stake != ".";
    if !ok {
        return Err(CoreError::FrameShape("stake"));
    }
    Ok(())
}

/// A frame id/ref: non-empty lowercase hex, bounded.
fn validate_id(id: &str) -> Result<()> {
    if id.is_empty()
        || id.len() > MAX_FIELD_LEN
        || !id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(CoreError::FrameShape("id"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn challenge(frame: &Parsed) -> &KvFrame {
        match frame {
            Parsed::Frame(f) => f,
            other => panic!("expected a frame, got {other:?}"),
        }
    }

    /// (c1) The line is GENERATED from the fields — deterministic bytes, and it
    /// names the game + stake it carries.
    #[test]
    fn build_challenge_line_is_generated_from_fields() {
        let wire = build_challenge(GAME_ATTACK_DEFEND, Some("10"), "a1b2c3d4").unwrap();
        assert_eq!(
            wire,
            "⚔️ Attack & Defend challenge — 10 KAS. Open in KaspaVerse to play.\n\
             kv:1:challenge:{\"game\":\"attack_defend\",\"stake\":\"10\",\"id\":\"a1b2c3d4\"}"
        );
        // Rebuilding the same inputs is byte-identical (no free-typed drift).
        assert_eq!(
            wire,
            build_challenge(GAME_ATTACK_DEFEND, Some("10"), "a1b2c3d4").unwrap()
        );
    }

    #[test]
    fn friendly_challenge_omits_the_stake() {
        let wire = build_challenge(GAME_ATTACK_DEFEND, None, "00ff00ff").unwrap();
        assert!(wire
            .starts_with("⚔️ Attack & Defend challenge — friendly. Open in KaspaVerse to play.\n"));
        assert!(!wire.contains("\"stake\""), "friendly carries no stake key");
    }

    #[test]
    fn round_trip_all_built_kinds() {
        let cases = [
            build_challenge(GAME_ATTACK_DEFEND, Some("2.5"), "deadbeef").unwrap(),
            build_challenge(GAME_ATTACK_DEFEND, None, "cafef00d").unwrap(),
            build_accept(GAME_ATTACK_DEFEND, "deadbeef").unwrap(),
            build_taunt("you're going down 😤").unwrap(),
        ];
        for wire in cases {
            assert!(matches!(parse(&wire), Parsed::Frame(_)), "{wire}");
        }

        let c = build_challenge(GAME_ATTACK_DEFEND, Some("2.5"), "deadbeef").unwrap();
        let f = parse(&c);
        let f = challenge(&f);
        assert_eq!(f.kind, FrameKind::Challenge);
        assert_eq!(f.game.as_deref(), Some("attack_defend"));
        assert_eq!(f.stake.as_deref(), Some("2.5"));
        assert_eq!(f.id.as_deref(), Some("deadbeef"));
        assert!(f.line.contains("2.5 KAS"));

        let a = parse(&build_accept(GAME_ATTACK_DEFEND, "deadbeef").unwrap());
        assert_eq!(challenge(&a).ref_id.as_deref(), Some("deadbeef"));

        let t = parse(&build_taunt("git gud").unwrap());
        assert_eq!(challenge(&t).detail.as_deref(), Some("git gud"));
    }

    /// (c2) The card is rendered from the JSON, so a tampered readable line
    /// cannot misrepresent the stake/game.
    #[test]
    fn parse_takes_the_card_from_json_not_the_tampered_line() {
        let honest = build_challenge(GAME_ATTACK_DEFEND, Some("10"), "a1b2c3d4").unwrap();
        // Attacker rewrites ONLY the human line to claim a bigger stake.
        let tampered = honest.replacen("10 KAS", "9999 KAS", 1);
        let f = parse(&tampered);
        let f = challenge(&f);
        assert_eq!(f.stake.as_deref(), Some("10"), "stake comes from JSON");
        assert_eq!(f.game.as_deref(), Some("attack_defend"));
    }

    #[test]
    fn plain_text_is_not_a_frame() {
        for text in [
            "just a normal message",
            "check kv:1 later",     // marker-ish but no kind:json
            "email me at a:kv:1:x", // no valid version/kind shape
            "⚔️ nice emoji, no frame",
        ] {
            assert_eq!(parse(text), Parsed::Plain(text.to_string()), "{text}");
        }
    }

    #[test]
    fn unknown_kind_and_future_version_degrade_to_the_line() {
        // Unknown kind (kv:1:duel:) — degrade, keep the line, no card.
        let unknown_kind = "⚔️ some new game\nkv:1:duel:{\"x\":1}";
        assert_eq!(
            parse(unknown_kind),
            Parsed::Unknown {
                line: "⚔️ some new game".to_string()
            }
        );
        // Future version (kv:2:) — degrade.
        let future = "future thing\nkv:2:challenge:{\"game\":\"x\"}";
        assert_eq!(
            parse(future),
            Parsed::Unknown {
                line: "future thing".to_string()
            }
        );
        // A known kind with malformed JSON also degrades (never a broken card).
        let bad_json = "hi\nkv:1:challenge:{not json}";
        assert!(matches!(parse(bad_json), Parsed::Unknown { .. }));
    }

    #[test]
    fn marker_only_body_falls_back_to_raw_not_blank() {
        let raw = "kv:1:duel:{}"; // unknown kind, no preceding line
        assert_eq!(
            parse(raw),
            Parsed::Unknown {
                line: raw.to_string()
            }
        );
    }

    #[test]
    fn a_kv_substring_inside_a_taunt_does_not_hijack_the_parse() {
        // The taunt text literally contains a marker-shaped string; because the
        // real marker is line-anchored and the JSON has no literal newline, the
        // parse still resolves to the real taunt.
        let wire = build_taunt("try typing kv:1:challenge:{} lol").unwrap();
        let f = parse(&wire);
        assert_eq!(challenge(&f).kind, FrameKind::Taunt);
        assert_eq!(
            challenge(&f).detail.as_deref(),
            Some("try typing kv:1:challenge:{} lol")
        );
    }

    #[test]
    fn multiline_taunt_finds_the_real_marker() {
        let wire = build_taunt("line one\nline two").unwrap();
        let f = parse(&wire);
        assert_eq!(challenge(&f).kind, FrameKind::Taunt);
        assert_eq!(challenge(&f).detail.as_deref(), Some("line one\nline two"));
    }

    #[test]
    fn result_is_parsed_but_carries_no_value() {
        // Built by P3, only parsed here — a display claim.
        let wire = "🏁 they say they won\nkv:1:result:{\"ref\":\"deadbeef\",\"outcome\":\"win\"}";
        let f = parse(wire);
        let f = challenge(&f);
        assert_eq!(f.kind, FrameKind::Result);
        assert_eq!(f.ref_id.as_deref(), Some("deadbeef"));
        assert_eq!(f.detail.as_deref(), Some("win"));
    }

    #[test]
    fn challenge_tolerates_reserved_params_and_missing_optional_fields() {
        // A future P3 challenge carrying the reserved covenant `params` slot and
        // omitting the display stake still parses (forward-compat, ignore-unknown).
        let wire =
            "⚔️ later\nkv:1:challenge:{\"game\":\"attack_defend\",\"id\":\"aa\",\"params\":{\"x\":1}}";
        let f = parse(wire);
        let f = challenge(&f);
        assert_eq!(f.game.as_deref(), Some("attack_defend"));
        assert_eq!(f.stake, None);
        assert_eq!(f.id.as_deref(), Some("aa"));
    }

    #[test]
    fn build_rejects_wire_breaking_inputs() {
        assert!(build_challenge("bad:slug", Some("1"), "aa").is_err());
        assert!(build_challenge("attack_defend", Some("1e9"), "aa").is_err()); // not decimal
        assert!(build_challenge("attack_defend", Some("1"), "NOTHEX").is_err());
        assert!(build_taunt("   ").is_err());
        // Valid boundaries.
        assert!(build_challenge("attack_defend", Some("0.5"), "00").is_ok());
        assert!(build_challenge("attack_defend", None, "ff").is_ok());
    }

    #[test]
    fn fresh_challenge_id_is_eight_lowercase_hex() {
        let id = fresh_challenge_id();
        assert_eq!(id.len(), 8);
        validate_id(&id).unwrap();
        assert_ne!(fresh_challenge_id(), id, "ids must not repeat");
    }
}
