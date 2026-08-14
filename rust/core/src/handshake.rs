//! Handshake plaintext — the JSON that rides INSIDE a `ciph_msg:1:handshake:`
//! envelope (P2 §0.7, ratified D-062; P2.3 build).
//!
//! ## Shape provenance (grounded 2026-07-04, this session's clone pass)
//!
//! The live population's EMITTER is the Kasia app @ `acd3cf65`
//! (`src/types/messaging.types.ts` `HandshakePayload`;
//! `src/store/messaging.store.ts:1050` initial / `:1229` response) — camelCase
//! fields, `type: "handshake"` discriminator, unix-milliseconds numeric
//! `timestamp`, `version: 1`, `theirAlias` + `isResponse` on the response leg.
//! The RECEIVER contract is `conversation-manager-service.ts`
//! `validateHandshakePayload`: `alias` must be exactly 12 hex chars
//! ([`ALIAS_LEN`] bytes, `ALIAS_LENGTH = 6` in their `config/constants.ts`);
//! `version`, when present, must be ≤ 1; everything else optional.
//!
//! The §0.7 lock's field list (`conversation_id`, `recipient_address`,
//! `send_to_recipient`, `is_response`) came from the indexer's `operation.rs`
//! struct — which this session's read shows is a doc-level shape with no serde
//! derives and no decrypt path (the indexer stores sealed bytes; it never
//! parses this JSON). The wire truth is the app's camelCase emission; serde
//! aliases below keep the snake_case names parseable so no generation is
//! over-fit (§3 P2.3 note). Ledgered at the wrap as a §19 drift fix.
//!
//! Emission is byte-pinned by fixtures: field order matches the app's object
//! literals (initial: `type, alias, timestamp, version`; response: `type,
//! alias, theirAlias, timestamp, version, isResponse`), `serde_json` emits no
//! whitespace exactly like `JSON.stringify`.
//!
//! Custody note: handshake plaintext is conversation METADATA (aliases are
//! public wire data — every `comm:{alias}:` head shows one; timestamps and
//! addresses are on-chain public). It is still §0.4-handled: built here,
//! sealed before it leaves, parsed here from a [`zeroize::Zeroizing`] buffer
//! the caller got from [`crate::transport_crypto::decrypt`].

use crate::error::{CoreError, Result};
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::OsRng;
use serde::{Deserialize, Serialize};

/// Alias length in bytes (12 hex chars on the wire) — the live population's
/// `ALIAS_LENGTH = 6` (`config/constants.ts`, Kasia @ `acd3cf65`).
pub const ALIAS_LEN: usize = 6;

/// The protocol version we emit and the highest we accept — the app's
/// `PROTOCOL_VERSION = 1` (receivers reject `version > 1`).
pub const PROTOCOL_VERSION: u32 = 1;

/// The handshake JSON, in the app's field order (see module docs). One struct
/// serves both legs: the initial handshake leaves `their_alias`/`is_response`
/// unset; the acceptance response sets both.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HandshakePayload {
    /// `"handshake"` on everything the live app emits; tolerated absent on
    /// parse (older generations inside protocol version 1).
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// The sender's own alias for this conversation ("my alias, the one I
    /// write to") — 12 lowercase hex chars.
    pub alias: String,
    /// Response leg only: the initiator's alias echoed back, confirming both
    /// sides. Its presence (+ `is_response`) is what activates a conversation.
    #[serde(
        rename = "theirAlias",
        alias = "their_alias",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub their_alias: Option<String>,
    /// Unix milliseconds (the app writes `Date.now()`).
    pub timestamp: u64,
    /// Protocol version — we emit `1`; absent tolerated on parse (the
    /// receiver's own check is `payload.version && version > 1 ⇒ reject`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u32>,
    /// Present in some generations/local-save shapes; never required.
    #[serde(
        rename = "recipientAddress",
        alias = "recipient_address",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub recipient_address: Option<String>,
    /// Present in some generations; never required.
    #[serde(
        rename = "sendToRecipient",
        alias = "send_to_recipient",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub send_to_recipient: Option<bool>,
    /// `true` on the acceptance response leg.
    #[serde(
        rename = "isResponse",
        alias = "is_response",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub is_response: Option<bool>,
}

impl HandshakePayload {
    /// The initial handshake leg (conversation request), exactly as the live
    /// app builds it (`messaging.store.ts:1050`).
    pub fn initial(my_alias: &str, timestamp_ms: u64) -> Result<Self> {
        validate_alias(my_alias)?;
        Ok(Self {
            kind: Some("handshake".to_string()),
            alias: my_alias.to_string(),
            their_alias: None,
            timestamp: timestamp_ms,
            version: Some(PROTOCOL_VERSION),
            recipient_address: None,
            send_to_recipient: None,
            is_response: None,
        })
    }

    /// The acceptance-response leg (`messaging.store.ts:1229`): our fresh
    /// alias plus the initiator's alias echoed back, flagged as a response.
    pub fn response(my_alias: &str, their_alias: &str, timestamp_ms: u64) -> Result<Self> {
        validate_alias(my_alias)?;
        validate_alias(their_alias)?;
        Ok(Self {
            kind: Some("handshake".to_string()),
            alias: my_alias.to_string(),
            their_alias: Some(their_alias.to_string()),
            timestamp: timestamp_ms,
            version: Some(PROTOCOL_VERSION),
            recipient_address: None,
            send_to_recipient: None,
            is_response: Some(true),
        })
    }

    /// Serialize to the exact wire plaintext (the bytes that get sealed).
    pub fn to_plaintext(&self) -> Result<Vec<u8>> {
        serde_json::to_vec(self).map_err(|_| CoreError::HandshakeShape("serialize"))
    }

    /// Parse decrypted plaintext into a handshake, enforcing the live
    /// receiver's law: `alias` = 12 hex chars, `version` ≤ 1 when present.
    /// Tolerant everywhere else (kind-level generations, §0.7).
    ///
    /// ## Why this reads fields by hand instead of deriving `Deserialize`
    ///
    /// Measured on the founder's device, 2026-08-14. A third-generation
    /// client emits **both spellings of the same field in one object**:
    /// `conversationId` *and* `conversation_id`, `recipientAddress` *and*
    /// `recipient_address`, `sendToRecipient` *and* `send_to_recipient`. The
    /// derived path declared those as one field via `rename` + `alias`, so
    /// serde saw the field twice and failed the WHOLE payload as a duplicate.
    ///
    /// The result was the worst class of bug this lane can have: a genuine
    /// handshake — AEAD-authenticated, bond paid on chain, sealed to our own
    /// key — silently refused, while the tolerance shim that caused it had
    /// been added precisely so that no generation would be over-fit.
    ///
    /// So: read each field, prefer the camelCase spelling the live app emits,
    /// fall back to snake_case, ignore anything unknown, and never let the
    /// presence of an extra field reject a payload. A parser on this lane is
    /// the last thing that should be strict — the envelope already proved the
    /// sender holds the key.
    pub fn from_plaintext(plaintext: &[u8]) -> Result<Self> {
        let value: serde_json::Value =
            serde_json::from_slice(plaintext).map_err(|_| CoreError::HandshakeShape("json"))?;
        let map = value
            .as_object()
            .ok_or(CoreError::HandshakeShape("not an object"))?;

        /// Prefer the camelCase spelling; accept snake_case; ignore a
        /// duplicate rather than failing on it.
        fn pick<'a>(
            map: &'a serde_json::Map<String, serde_json::Value>,
            camel: &str,
            snake: &str,
        ) -> Option<&'a serde_json::Value> {
            map.get(camel).or_else(|| map.get(snake))
        }
        let text = |v: Option<&serde_json::Value>| {
            v.and_then(|v| v.as_str())
                .map(std::string::ToString::to_string)
        };

        let alias = text(map.get("alias")).ok_or(CoreError::HandshakeShape("alias missing"))?;
        // Milliseconds. Accept a numeric string too: it costs three lines and
        // this whole entry exists because we were not tolerant enough.
        let timestamp = map
            .get("timestamp")
            .and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok()))
            .ok_or(CoreError::HandshakeShape("timestamp"))?;

        let payload = Self {
            kind: text(map.get("type")),
            alias,
            their_alias: text(pick(map, "theirAlias", "their_alias")),
            timestamp,
            // Present-but-unreadable must FAIL, never read as absent.
            // `as_u64()` alone returns `None` for `"2"`, `2.0` and `-1`, which
            // would skip the `> PROTOCOL_VERSION` check entirely and accept a
            // payload the derived parser refused — failing open on the one
            // field that exists to refuse things. `try_from`, never `as`, for
            // the same reason: a lossy cast turns 4294967296 into 0.
            // Tolerance is for SPELLING, not for the receiver law.
            version: match map.get("version") {
                None | Some(serde_json::Value::Null) => None,
                Some(v) => Some(
                    v.as_u64()
                        .and_then(|n| u32::try_from(n).ok())
                        .ok_or(CoreError::HandshakeShape("version"))?,
                ),
            },
            recipient_address: text(pick(map, "recipientAddress", "recipient_address")),
            send_to_recipient: pick(map, "sendToRecipient", "send_to_recipient")
                .and_then(serde_json::Value::as_bool),
            is_response: pick(map, "isResponse", "is_response")
                .and_then(serde_json::Value::as_bool),
        };

        validate_alias(&payload.alias)?;
        if let Some(their_alias) = &payload.their_alias {
            validate_alias(their_alias)?;
        }
        if let Some(version) = payload.version {
            if version > PROTOCOL_VERSION {
                return Err(CoreError::HandshakeShape("unsupported version"));
            }
        }
        Ok(payload)
    }

    /// True when this payload completes a conversation we initiated (both
    /// aliases present + the response flag — the live app's "active" rule).
    pub fn is_acceptance(&self) -> bool {
        self.is_response == Some(true) && self.their_alias.is_some()
    }
}

/// Describe the SHAPE of a plaintext [`HandshakePayload::from_plaintext`]
/// refused: the field names present and the JSON type of each — **never a
/// value**.
///
/// Why this exists. A rejection here is always an interop divergence, because
/// the envelope AEAD-authenticated before we ever got here: the bytes are
/// genuinely from a counterparty who holds the conversation. When our parser
/// refuses one, the only thing that closes the gap is knowing which field
/// list the other client actually emits — and a field list is protocol
/// schema, the same class as the `ciph_msg:1:<kind>:` token that already
/// rides the wire in clear. Values stay unrendered (§4).
/// Every receive address we publish is an open inbox: anyone can seal an
/// envelope one of our keys opens, and making this parser fail is as easy as
/// omitting `timestamp`. So the field names reaching a log line are
/// **stranger-chosen bytes**, and rendering them verbatim would let a stranger
/// forge lines — with newlines — inside the very diagnostic record this
/// function exists to be. Names are therefore emitted only when they look like
/// identifiers, and the whole description is bounded.
const MAX_SHAPE_FIELDS: usize = 24;
const MAX_NAME_LEN: usize = 32;

pub fn describe_shape(plaintext: &[u8]) -> String {
    match serde_json::from_slice::<serde_json::Value>(plaintext) {
        Ok(serde_json::Value::Object(map)) => {
            let total = map.len();
            let mut parts: Vec<String> = map
                .iter()
                .take(MAX_SHAPE_FIELDS)
                .map(|(name, value)| format!("{}:{}", safe_name(name), json_type_name(value)))
                .collect();
            if total > MAX_SHAPE_FIELDS {
                parts.push(format!("…+{} more", total - MAX_SHAPE_FIELDS));
            }
            parts.join(",")
        }
        Ok(other) => format!("not-an-object({})", json_type_name(&other)),
        Err(_) => "not-json".to_string(),
    }
}

/// A field name, but only if it looks like one: ASCII alphanumerics and
/// underscores, bounded length. Anything else becomes a fixed placeholder, so
/// no caller-chosen byte — control character, newline, or script — is ever
/// rendered.
fn safe_name(name: &str) -> String {
    if !name.is_empty()
        && name.len() <= MAX_NAME_LEN
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
    {
        name.to_string()
    } else {
        format!("<unprintable:{}>", name.len().min(999))
    }
}

/// The NAME of a JSON value's type — never the value itself.
fn json_type_name(value: &serde_json::Value) -> &'static str {
    match value {
        serde_json::Value::Null => "null",
        serde_json::Value::Bool(_) => "bool",
        serde_json::Value::Number(_) => "number",
        serde_json::Value::String(_) => "string",
        serde_json::Value::Array(_) => "array",
        serde_json::Value::Object(_) => "object",
    }
}

/// The live alias law (`validateHandshakePayload` + `isAlias`): exactly
/// `ALIAS_LEN * 2` hex characters. We additionally emit lowercase only (their
/// generator does too — bytes → `toString(16)`).
pub fn validate_alias(alias: &str) -> Result<()> {
    if alias.len() != ALIAS_LEN * 2 || !alias.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(CoreError::HandshakeShape("alias"));
    }
    Ok(())
}

/// A fresh conversation alias: [`ALIAS_LEN`] random bytes as lowercase hex —
/// the live population's own construction (`generateAlias`, 6 bytes of
/// `crypto.getRandomValues` → hex).
pub fn fresh_alias() -> String {
    let mut bytes = [0u8; ALIAS_LEN];
    OsRng.fill_bytes(&mut bytes);
    hex_lower(&bytes)
}

/// A fresh LOCAL conversation id (never on the wire — the app uses uuidv4;
/// ours is 16 random bytes hex, same entropy class, no new dependency).
pub fn fresh_conversation_id() -> String {
    let mut bytes = [0u8; 16];
    OsRng.fill_bytes(&mut bytes);
    hex_lower(&bytes)
}

fn hex_lower(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// THE 2026-08-14 INTEROP REGRESSION, pinned.
    ///
    /// A third-generation client on mainnet emits BOTH spellings of three
    /// fields in one object. The field list below is the one measured on the
    /// founder's device from a real, bond-paying handshake
    /// (`31dcf952d78ede0f…`) that our parser refused as a serde duplicate
    /// field — values here are synthetic; only the SHAPE is evidence.
    ///
    /// If this test ever fails, a payload a counterparty genuinely sent is
    /// being dropped again, and the conversation it belongs to will hang at
    /// "awaiting their accept" forever with no log line to explain it.
    #[test]
    fn dual_spelled_fields_parse_instead_of_failing_as_duplicates() {
        let wire = br#"{"alias":"5431d40d179c","conversationId":"c1","conversation_id":"c1",
            "recipientAddress":"kaspa:qz5","recipient_address":"kaspa:qz5",
            "sendToRecipient":true,"send_to_recipient":true,
            "timestamp":1786659235086,"type":"handshake","version":1}"#;
        let parsed = HandshakePayload::from_plaintext(wire).expect("dual spellings must parse");
        assert_eq!(parsed.alias, "5431d40d179c");
        assert_eq!(parsed.timestamp, 1_786_659_235_086);
        assert_eq!(parsed.send_to_recipient, Some(true));
        assert_eq!(parsed.recipient_address.as_deref(), Some("kaspa:qz5"));
        // No `isResponse` on this generation — it is NOT an acceptance by the
        // alias-echo rule, which is why address-keyed matching (D-139) is
        // what actually completes the conversation.
        assert!(!parsed.is_acceptance());
    }

    /// Tolerance must not become laxity: the receiver's law still holds.
    #[test]
    fn tolerant_parsing_still_enforces_the_receiver_law() {
        // A snake_case-only generation still parses (nothing over-fit).
        let snake = br#"{"alias":"5431d40d179c","timestamp":1,"their_alias":"fa6d1afa79e1","is_response":true}"#;
        let parsed = HandshakePayload::from_plaintext(snake).unwrap();
        assert!(
            parsed.is_acceptance(),
            "snake_case response still activates"
        );

        // Unknown fields are ignored, never fatal (§0.5 forward-compat).
        let future = br#"{"alias":"5431d40d179c","timestamp":1,"somethingNew":{"a":[1,2]}}"#;
        assert!(HandshakePayload::from_plaintext(future).is_ok());

        // A numeric-string timestamp is accepted.
        let stringy = br#"{"alias":"5431d40d179c","timestamp":"1786659235086"}"#;
        assert_eq!(
            HandshakePayload::from_plaintext(stringy).unwrap().timestamp,
            1_786_659_235_086
        );

        // But a bad alias, a missing timestamp and a future version all fail.
        assert!(HandshakePayload::from_plaintext(br#"{"alias":"nothex","timestamp":1}"#).is_err());
        assert!(HandshakePayload::from_plaintext(br#"{"alias":"5431d40d179c"}"#).is_err());
        assert!(HandshakePayload::from_plaintext(
            br#"{"alias":"5431d40d179c","timestamp":1,"version":2}"#
        )
        .is_err());
        assert!(HandshakePayload::from_plaintext(b"[1,2,3]").is_err());
    }

    /// A published receive address is an open inbox, so the field names that
    /// reach a log line are a STRANGER'S bytes. If they were rendered raw, a
    /// stranger could forge lines — newlines and all — inside the diagnostic
    /// record the wallet's own forensics depend on. (ffi-leak-auditor,
    /// 2026-08-14.)
    #[test]
    fn a_stranger_cannot_write_arbitrary_lines_into_our_log() {
        let hostile = "{\"al\\nias\":1,\"ok_name\":2,\"\":3}";
        let shape = describe_shape(hostile.as_bytes());
        assert!(!shape.contains('\n'), "no newline may survive: {shape}");
        assert!(
            shape.contains("ok_name:number"),
            "honest names still render"
        );
        assert!(
            shape.contains("<unprintable:"),
            "hostile names are replaced"
        );

        // Length and count are both bounded.
        let long = format!(r#"{{"{}":1}}"#, "a".repeat(500));
        assert!(describe_shape(long.as_bytes()).contains("<unprintable:500>"));
        let many: String = (0..80).map(|i| format!("\"f{i}\":1,")).collect();
        let wide = describe_shape(format!("{{{}\"last\":1}}", many).as_bytes());
        assert!(wide.contains("more"), "field count is capped: {wide}");
        assert!(wide.len() < 800, "output stays bounded: {}", wide.len());

        // Non-objects and non-JSON stay fixed tokens.
        assert_eq!(describe_shape(b"[1,2]"), "not-an-object(array)");
        assert_eq!(describe_shape(b"not json at all"), "not-json");
    }

    /// Tolerance is for SPELLING, not for the receiver law: a lossy `as u32`
    /// truncated `version: 4294967296` to `0` and accepted it, where the
    /// derived parser had refused outright. (ffi-leak-auditor, 2026-08-14.)
    #[test]
    fn an_out_of_range_version_cannot_truncate_into_a_legal_one() {
        let wire = br#"{"alias":"5431d40d179c","timestamp":1,"version":4294967296}"#;
        assert!(
            HandshakePayload::from_plaintext(wire).is_err(),
            "a version above u32 must be refused, not wrapped to 0"
        );
    }

    /// Byte-pins our emission to the live app's `JSON.stringify` output for
    /// both legs (field order = the object-literal order at
    /// `messaging.store.ts:1050`/`1229`; no whitespace; ms timestamp).
    #[test]
    fn emission_matches_the_live_apps_bytes() {
        let initial = HandshakePayload::initial("fa6d1afa79e1", 1_751_600_000_123).unwrap();
        assert_eq!(
            String::from_utf8(initial.to_plaintext().unwrap()).unwrap(),
            r#"{"type":"handshake","alias":"fa6d1afa79e1","timestamp":1751600000123,"version":1}"#
        );

        let response =
            HandshakePayload::response("a1e1b60b5fca", "fa6d1afa79e1", 1_751_600_000_456).unwrap();
        assert_eq!(
            String::from_utf8(response.to_plaintext().unwrap()).unwrap(),
            r#"{"type":"handshake","alias":"a1e1b60b5fca","theirAlias":"fa6d1afa79e1","timestamp":1751600000456,"version":1,"isResponse":true}"#
        );
    }

    #[test]
    fn round_trip_both_legs() {
        for payload in [
            HandshakePayload::initial("fa6d1afa79e1", 1).unwrap(),
            HandshakePayload::response("a1e1b60b5fca", "fa6d1afa79e1", 2).unwrap(),
        ] {
            let parsed =
                HandshakePayload::from_plaintext(&payload.to_plaintext().unwrap()).unwrap();
            assert_eq!(parsed, payload);
        }
    }

    #[test]
    fn acceptance_rule_matches_the_live_active_flip() {
        // The receiver flips a conversation active only when BOTH the response
        // flag and the echoed alias are present (processNewHandshake).
        let response = HandshakePayload::response("a1e1b60b5fca", "fa6d1afa79e1", 2).unwrap();
        assert!(response.is_acceptance());
        let initial = HandshakePayload::initial("fa6d1afa79e1", 1).unwrap();
        assert!(!initial.is_acceptance());
        let mut flag_only = initial;
        flag_only.is_response = Some(true);
        assert!(!flag_only.is_acceptance(), "flag without echoed alias");
    }

    /// Generation tolerance (§0.7: pin kind-level shapes, don't over-fit one):
    /// minimal payloads, absent version/type, snake_case field names.
    #[test]
    fn parse_tolerates_older_generations() {
        // Bare minimum a validating receiver accepts: alias + timestamp.
        let minimal = HandshakePayload::from_plaintext(
            br#"{"alias":"fa6d1afa79e1","timestamp":1750000000000}"#,
        )
        .unwrap();
        assert_eq!(minimal.alias, "fa6d1afa79e1");
        assert_eq!(minimal.version, None);
        assert!(!minimal.is_acceptance());

        // The §0.7 lock's snake_case names (indexer doc shape) parse too.
        let snake = HandshakePayload::from_plaintext(
            br#"{"alias":"fa6d1afa79e1","their_alias":"a1e1b60b5fca","timestamp":1,"version":1,"recipient_address":"kaspa:q","send_to_recipient":true,"is_response":true}"#,
        )
        .unwrap();
        assert!(snake.is_acceptance());
        assert_eq!(snake.recipient_address.as_deref(), Some("kaspa:q"));

        // Unknown extra fields never break the parse (forward-compat rule).
        let extra = HandshakePayload::from_plaintext(
            br#"{"type":"handshake","alias":"fa6d1afa79e1","timestamp":1,"version":1,"futureField":{"x":1}}"#,
        )
        .unwrap();
        assert_eq!(extra.alias, "fa6d1afa79e1");
    }

    #[test]
    fn parse_enforces_the_live_receivers_law() {
        // Alias: exactly 12 hex chars (their validateHandshakePayload).
        for bad in [
            br#"{"alias":"tooshort","timestamp":1}"#.as_slice(),
            br#"{"alias":"fa6d1afa79e1ff","timestamp":1}"#.as_slice(),
            br#"{"alias":"zz6d1afa79e1","timestamp":1}"#.as_slice(),
        ] {
            assert!(matches!(
                HandshakePayload::from_plaintext(bad),
                Err(CoreError::HandshakeShape("alias"))
            ));
        }
        // Version above ours: reject (their receiver throws too).
        assert!(matches!(
            HandshakePayload::from_plaintext(
                br#"{"alias":"fa6d1afa79e1","timestamp":1,"version":2}"#
            ),
            Err(CoreError::HandshakeShape("unsupported version"))
        ));
        // A response carrying a malformed echoed alias is refused.
        assert!(matches!(
            HandshakePayload::from_plaintext(
                br#"{"alias":"fa6d1afa79e1","theirAlias":"bad","timestamp":1,"isResponse":true}"#
            ),
            Err(CoreError::HandshakeShape("alias"))
        ));
        // Not JSON at all.
        assert!(matches!(
            HandshakePayload::from_plaintext(b"\x00\x01\x02"),
            Err(CoreError::HandshakeShape("json"))
        ));
    }

    #[test]
    fn seal_round_trip_through_the_p22_cipher() {
        // The full P2.3 inner loop: build → seal → open → parse. Synthetic
        // keys from the transport_crypto test walk (never custody material).
        use crate::transport_crypto::{decrypt, encrypt};
        use secp256k1::{Parity, SecretKey, SECP256K1};

        let (secret, x_only) = (1u8..=64)
            .find_map(|i| {
                let bytes = [i; 32];
                let secret = SecretKey::from_slice(&bytes).ok()?;
                let (x_only, parity) = secret.public_key(SECP256K1).x_only_public_key();
                (parity == Parity::Even).then(|| (bytes, x_only.serialize()))
            })
            .expect("test key");

        let payload = HandshakePayload::initial("fa6d1afa79e1", 1_751_600_000_123).unwrap();
        let envelope = encrypt(&x_only, &payload.to_plaintext().unwrap()).unwrap();
        let plaintext = decrypt(&envelope, &secret).unwrap();
        let parsed = HandshakePayload::from_plaintext(&plaintext).unwrap();
        assert_eq!(parsed, payload);
    }

    #[test]
    fn fresh_alias_and_id_have_the_wire_shape() {
        let alias = fresh_alias();
        validate_alias(&alias).unwrap();
        assert!(alias.bytes().all(|b| !b.is_ascii_uppercase()));
        assert_ne!(fresh_alias(), alias, "aliases must not repeat");

        let id = fresh_conversation_id();
        assert_eq!(id.len(), 32);
        assert!(id.bytes().all(|b| b.is_ascii_hexdigit()));
    }
}
