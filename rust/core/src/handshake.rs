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
    pub fn from_plaintext(plaintext: &[u8]) -> Result<Self> {
        let payload: Self =
            serde_json::from_slice(plaintext).map_err(|_| CoreError::HandshakeShape("json"))?;
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
