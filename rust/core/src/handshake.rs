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

/// The self-stash JSON: a handshake payload plus the routing facts that make a
/// conversation restorable, sealed to OUR OWN key and parked on chain (D-138).
///
/// ## Why this is a separate struct
///
/// [`HandshakePayload`]'s serialization is byte-pinned by the parity fixtures —
/// it is what a counterparty parses. This one never leaves our own wallet, so
/// it is free to carry more, and must not be able to perturb that emission.
///
/// ## Field order is the live population's, deliberately
///
/// Kasia's `createSelfStash` builds `{type, alias, timestamp, version,
/// theirAlias?, isResponse?}` and then spreads `{...base, partnerAddress,
/// recipientAddress}`. We emit the same names in the same order so a Kasia
/// client restoring the same seed hydrates from our stash unchanged — the
/// point of D-138's "copy it, and copy it exactly".
///
/// ## The three fields that are ours
///
/// `conversationId`, `boundBranch` and `boundIndex` are extensions their reader
/// ignores (it reads named fields off a parsed object; unknown keys cost it
/// nothing). They are not decoration:
///
/// - **The bound slot is not re-derivable at restore.** A conversation binds to
///   the address key it was established with (§0.7), and for one we ACCEPTED
///   that is whichever slot their handshake sealed to — routinely a change
///   address. Restore has no store to read it from; that is what restore means.
///   Carrying it is how a rebuilt conversation keeps presenting the one identity
///   the counterparty knows us by (D-067).
/// - **`conversationId`** makes a re-restore idempotent instead of minting a
///   duplicate thread with a fresh fill cursor.
///
/// Kasia's own stash carries neither, so a stash we hydrate FROM THEM has to
/// fall back — see [`SavedHandshakePayload::from_plaintext`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedHandshakePayload {
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// OUR alias in this conversation — the field the whole mechanism exists
    /// for. Nothing on chain or at any indexer knows it but us: it rides only
    /// in handshakes we sealed to the counterparty.
    pub alias: String,
    pub timestamp: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<u32>,
    #[serde(
        rename = "theirAlias",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub their_alias: Option<String>,
    /// `true` when this records the leg where we ACCEPTED their invitation.
    #[serde(
        rename = "isResponse",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub is_response: Option<bool>,
    /// The counterparty's address. Kasia writes the same value twice under two
    /// names; we do too, because their reader reads `recipientAddress` and a
    /// future one may read `partnerAddress`.
    #[serde(rename = "partnerAddress")]
    pub partner_address: String,
    #[serde(rename = "recipientAddress")]
    pub recipient_address: String,
    #[serde(
        rename = "conversationId",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub conversation_id: Option<String>,
    /// `"receive"` or `"change"` — the §0.7 bound branch, absent in a stash
    /// written by a client that has no such concept.
    #[serde(
        rename = "boundBranch",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub bound_branch: Option<String>,
    #[serde(
        rename = "boundIndex",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub bound_index: Option<u32>,
}

/// The branch token as it rides in a stash payload.
pub const BOUND_BRANCH_RECEIVE: &str = "receive";
/// The branch token as it rides in a stash payload.
pub const BOUND_BRANCH_CHANGE: &str = "change";

impl SavedHandshakePayload {
    /// Build the stash for one conversation. `their_alias` is `None` on a
    /// conversation still awaiting their acceptance; `is_response` marks the
    /// leg where we accepted theirs.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        my_alias: &str,
        their_alias: Option<&str>,
        partner_address: &str,
        conversation_id: &str,
        bound_branch: &str,
        bound_index: u32,
        is_response: bool,
        timestamp_ms: u64,
    ) -> Result<Self> {
        validate_alias(my_alias)?;
        if let Some(their_alias) = their_alias {
            validate_alias(their_alias)?;
        }
        if partner_address.is_empty() {
            return Err(CoreError::HandshakeShape("partner address"));
        }
        if bound_branch != BOUND_BRANCH_RECEIVE && bound_branch != BOUND_BRANCH_CHANGE {
            return Err(CoreError::HandshakeShape("bound branch"));
        }
        Ok(Self {
            kind: Some("handshake".to_string()),
            alias: my_alias.to_string(),
            timestamp: timestamp_ms,
            version: Some(PROTOCOL_VERSION),
            their_alias: their_alias.map(std::string::ToString::to_string),
            is_response: is_response.then_some(true),
            partner_address: partner_address.to_string(),
            recipient_address: partner_address.to_string(),
            conversation_id: Some(conversation_id.to_string()),
            bound_branch: Some(bound_branch.to_string()),
            bound_index: Some(bound_index),
        })
    }

    /// Serialize to the bytes that get sealed.
    pub fn to_plaintext(&self) -> Result<Vec<u8>> {
        serde_json::to_vec(self).map_err(|_| CoreError::HandshakeShape("serialize"))
    }

    /// Parse a stash plaintext, in the same read-by-hand style and for the same
    /// reason as [`HandshakePayload::from_plaintext`] (D-141): a client in this
    /// family can emit both spellings of one field, and a derived parser fails
    /// the whole object on the duplicate.
    ///
    /// **This one is stricter about the address and looser about nothing else.**
    /// A stash with no counterparty address restores a conversation that can
    /// never send, so it is refused rather than half-restored.
    pub fn from_plaintext(plaintext: &[u8]) -> Result<Self> {
        let value: serde_json::Value =
            serde_json::from_slice(plaintext).map_err(|_| CoreError::HandshakeShape("json"))?;
        let map = value
            .as_object()
            .ok_or(CoreError::HandshakeShape("not an object"))?;

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
        let timestamp = map
            .get("timestamp")
            .and_then(|v| v.as_u64().or_else(|| v.as_str()?.parse().ok()))
            .ok_or(CoreError::HandshakeShape("timestamp"))?;
        // Either spelling names the same counterparty. Kasia writes both; a
        // stash carrying only one is still complete.
        let partner_address = text(pick(map, "partnerAddress", "partner_address"))
            .or_else(|| text(pick(map, "recipientAddress", "recipient_address")))
            .filter(|a| !a.is_empty())
            .ok_or(CoreError::HandshakeShape("partner address"))?;

        let payload = Self {
            kind: text(map.get("type")),
            alias,
            timestamp,
            // Present-but-unreadable FAILS, never reads as absent — the same
            // law as the handshake parser, for the same reason: this is the one
            // field whose job is to refuse things.
            version: match map.get("version") {
                None | Some(serde_json::Value::Null) => None,
                Some(v) => Some(
                    v.as_u64()
                        .and_then(|n| u32::try_from(n).ok())
                        .ok_or(CoreError::HandshakeShape("version"))?,
                ),
            },
            their_alias: text(pick(map, "theirAlias", "their_alias")),
            is_response: pick(map, "isResponse", "is_response")
                .and_then(serde_json::Value::as_bool),
            recipient_address: partner_address.clone(),
            partner_address,
            conversation_id: text(pick(map, "conversationId", "conversation_id")),
            bound_branch: text(pick(map, "boundBranch", "bound_branch"))
                .filter(|b| b == BOUND_BRANCH_RECEIVE || b == BOUND_BRANCH_CHANGE),
            bound_index: pick(map, "boundIndex", "bound_index")
                .and_then(serde_json::Value::as_u64)
                .and_then(|n| u32::try_from(n).ok()),
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

    /// The §0.7 bound slot, when the stash carries one. A stash from a client
    /// with no slot concept (Kasia's) yields `None`, and the caller must decide
    /// a default rather than guess one here.
    ///
    /// A half-specified slot is refused: a branch with no index, or an index
    /// with no branch, would silently bind to the wrong address — the D-067
    /// failure this field exists to prevent.
    pub fn bound_slot(&self) -> Option<(&str, u32)> {
        match (self.bound_branch.as_deref(), self.bound_index) {
            (Some(branch), Some(index)) => Some((branch, index)),
            _ => None,
        }
    }
}

/// Parse bound on a snapshot's array. Every byte here came off a public chain
/// and an attacker can post one for the price of dust, so the array length is
/// never trusted to be sane.
pub const MAX_SNAPSHOT_ROWS: usize = 128;

/// A self-stash carrying EVERY conversation at once, with Kasia's exact
/// single-conversation object still at the top level.
///
/// ## Why one payload instead of one per conversation
///
/// Kasia writes one stash per handshake leg. We cannot, and the reason is
/// structural rather than aesthetic: our stash is funded from one address, so
/// the second stash in a row finds that address's change still unconfirmed and
/// has nothing mature to spend. Per-conversation stashing would need one user
/// action per conversation, spread across confirmation intervals.
///
/// So the head of this object is a complete, ordinary Kasia stash — a client
/// that has never heard of us hydrates it and gets a real conversation — and
/// the `conversations` array beside it carries the full set for our own
/// restore. Their reader takes named fields off a parsed object and never
/// enumerates it, so the extra key costs them nothing.
///
/// **The head is duplicated inside the array on purpose.** It makes
/// [`Self::rows`] a single slice that cannot disagree with what was written;
/// the alternative saves ~250 bytes of mass and buys a class of bug where the
/// head is silently dropped from the restore.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedHandshakeSnapshot {
    /// A complete Kasia-shaped stash — what a foreign client sees.
    pub head: SavedHandshakePayload,
    /// Every conversation, head included.
    pub conversations: Vec<SavedHandshakePayload>,
}

impl SavedHandshakeSnapshot {
    /// `rows[0]` becomes the head. Refuses an empty set — a stash that names no
    /// conversation is a fee spent on nothing.
    pub fn new(rows: Vec<SavedHandshakePayload>) -> Result<Self> {
        let head = rows
            .first()
            .cloned()
            .ok_or(CoreError::HandshakeShape("empty snapshot"))?;
        Ok(Self {
            head,
            conversations: rows,
        })
    }

    /// Serialize by SPLICING the array into the head's own bytes, rather than
    /// deriving over a wrapper.
    ///
    /// This is deliberate. `#[serde(flatten)]` buffers through a map, and
    /// `serde_json`'s default map is a `BTreeMap` — it would alphabetize every
    /// key and silently stop the head from being byte-identical to what the
    /// live population emits. Splicing keeps [`SavedHandshakePayload`]'s own
    /// pinned emission as a literal prefix of ours.
    pub fn to_plaintext(&self) -> Result<Vec<u8>> {
        let head = self.head.to_plaintext()?;
        // `serde_json` over a struct always yields a `{…}` object; if that ever
        // stopped being true the splice below would corrupt the payload, so it
        // is checked rather than assumed.
        if head.last() != Some(&b'}') {
            return Err(CoreError::HandshakeShape("serialize"));
        }
        let rows = serde_json::to_vec(&self.conversations)
            .map_err(|_| CoreError::HandshakeShape("serialize"))?;
        let mut out = Vec::with_capacity(head.len() + rows.len() + 18);
        out.extend_from_slice(&head[..head.len() - 1]);
        out.extend_from_slice(br#","conversations":"#);
        out.extend_from_slice(&rows);
        out.push(b'}');
        Ok(out)
    }

    /// Parse a stash plaintext, snapshot or plain.
    ///
    /// **A bad row never costs the good ones.** Elements that fail to parse are
    /// skipped, not fatal: a partly corrupt snapshot must still restore what it
    /// can, and the alternative is one malformed conversation destroying every
    /// other conversation the user has.
    pub fn from_plaintext(plaintext: &[u8]) -> Result<Self> {
        // The head parse also does the version/alias law; a payload that fails
        // it is not a stash at all.
        let head = SavedHandshakePayload::from_plaintext(plaintext)?;
        let value: serde_json::Value =
            serde_json::from_slice(plaintext).map_err(|_| CoreError::HandshakeShape("json"))?;
        let conversations = value
            .get("conversations")
            .and_then(serde_json::Value::as_array)
            .map(|rows| {
                rows.iter()
                    .take(MAX_SNAPSHOT_ROWS)
                    .filter_map(|row| {
                        let bytes = serde_json::to_vec(row).ok()?;
                        SavedHandshakePayload::from_plaintext(&bytes).ok()
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        Ok(Self {
            head,
            conversations,
        })
    }

    /// Every conversation this stash restores. A stash written by a client with
    /// no snapshot concept — Kasia's — reads as a one-row snapshot.
    pub fn rows(&self) -> &[SavedHandshakePayload] {
        if self.conversations.is_empty() {
            std::slice::from_ref(&self.head)
        } else {
            &self.conversations
        }
    }
}

/// The authorship tag's field name — the LAST key in a tagged stash.
pub const STASH_TAG_FIELD: &str = "kvTag";

/// Attach the authorship tag to a serialized stash, as the final key.
///
/// ## Why a stash needs authenticating at all — the reasoning that was wrong
///
/// A stash is sealed with [`crate::transport_crypto::encrypt`], which is ECIES
/// to an x-only **public** key — and a Kaspa address IS that public key. So
/// **anyone who knows our receive address can produce a stash our key opens.**
/// Decryptability proves confidentiality; it has never proved authorship.
///
/// The first cut of this lane argued the read route supplied the missing proof:
/// the indexer files a stash under an owner derived from input\[0\]'s funder, an
/// attacker cannot fund from our address, so a forged row is filed elsewhere and
/// our query never returns it. **That argument trusts the indexer to apply its
/// own rule honestly, which is exactly what INV-8 forbids.** A hostile or
/// compromised archive simply answers our by-owner query with whatever it likes.
///
/// The consequence was not cosmetic: a restore creates conversations from these
/// rows, so a hostile archive could inject a fully-formed Active conversation
/// carrying ITS address, and every message the user then sent in it would be
/// sealed to the attacker. The handshake fill lane already refuses this class by
/// writing no contact address for indexer-sourced rows; this lane wrote one.
///
/// So the tag makes "ours" provable. It is keyed by material only the seed
/// holder can derive, so no archive can mint one — and because it rides as an
/// unknown JSON key, a client that has never heard of it (Kasia's) still reads
/// the head exactly as before.
///
/// Placed last and spliced, rather than serialized as a field, so verification
/// never has to re-serialize: the untagged bytes are a literal prefix.
pub fn attach_stash_tag(untagged: &[u8], tag: &[u8; 32]) -> Result<Vec<u8>> {
    if untagged.last() != Some(&b'}') {
        return Err(CoreError::HandshakeShape("serialize"));
    }
    let mut out = Vec::with_capacity(untagged.len() + 80);
    out.extend_from_slice(&untagged[..untagged.len() - 1]);
    out.extend_from_slice(format!(r#","{STASH_TAG_FIELD}":"{}"}}"#, hex_lower(tag)).as_bytes());
    Ok(out)
}

/// Split a tagged stash back into `(untagged bytes, tag)`.
///
/// `None` when the trailing tag is absent or malformed — which is the Kasia
/// case, and the caller must treat it as "not provably ours", never as "fine".
pub fn split_stash_tag(plaintext: &[u8]) -> Option<(Vec<u8>, [u8; 32])> {
    // Derived from the head we actually write, never a hand-counted constant:
    // `,"kvTag":"` + 64 hex + `"}`.
    let head = format!(r#","{STASH_TAG_FIELD}":""#);
    let suffix_len = head.len() + 64 + 2;
    if plaintext.len() <= suffix_len {
        return None;
    }
    let (body, suffix) = plaintext.split_at(plaintext.len() - suffix_len);
    let hex = suffix
        .strip_prefix(head.as_bytes())?
        .strip_suffix(br#""}"#)?;
    let mut tag = [0u8; 32];
    for (i, byte) in tag.iter_mut().enumerate() {
        let pair = std::str::from_utf8(hex.get(i * 2..i * 2 + 2)?).ok()?;
        *byte = u8::from_str_radix(pair, 16).ok()?;
    }
    // [`attach_stash_tag`] replaced the object's closing brace with the tag, so
    // the bytes the tag was computed over are this prefix plus that brace back.
    // Reconstructing here — rather than returning the prefix and leaving the
    // caller to remember — is what keeps the two functions provably symmetric.
    let mut untagged = Vec::with_capacity(body.len() + 1);
    untagged.extend_from_slice(body);
    untagged.push(b'}');
    // It must still look like an object; a tag spliced onto anything else is
    // not a stash we wrote.
    if !untagged.starts_with(b"{") {
        return None;
    }
    Some((untagged, tag))
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

    /// THE D-138 INTEROP LAW: our stash carries the live population's field
    /// NAMES in their ORDER, so a Kasia client restoring the same seed hydrates
    /// from it. The literal below is Kasia's `createSelfStash` object as their
    /// source builds it (`{type, alias, timestamp, version, theirAlias?,
    /// isResponse?}` then spread with `{partnerAddress, recipientAddress}`),
    /// with our three extensions trailing where their reader ignores them.
    #[test]
    fn saved_handshake_emission_matches_the_live_populations_field_order() {
        let stash = SavedHandshakePayload::new(
            "fa6d1afa79e1",
            Some("90b4a1b640eb"),
            "kaspa:partner",
            "c0ffee",
            BOUND_BRANCH_CHANGE,
            7,
            true,
            1_751_600_000_123,
        )
        .unwrap();
        let json = String::from_utf8(stash.to_plaintext().unwrap()).unwrap();
        assert_eq!(
            json,
            r#"{"type":"handshake","alias":"fa6d1afa79e1","timestamp":1751600000123,"version":1,"theirAlias":"90b4a1b640eb","isResponse":true,"partnerAddress":"kaspa:partner","recipientAddress":"kaspa:partner","conversationId":"c0ffee","boundBranch":"change","boundIndex":7}"#
        );

        // The initiation leg: no theirAlias, no isResponse — omitted, never null
        // (their reader tests presence, and `"theirAlias":null` would read as
        // present-but-empty in a client that only checks the key).
        let initiation = SavedHandshakePayload::new(
            "fa6d1afa79e1",
            None,
            "kaspa:partner",
            "c0ffee",
            BOUND_BRANCH_RECEIVE,
            0,
            false,
            1_751_600_000_123,
        )
        .unwrap();
        let json = String::from_utf8(initiation.to_plaintext().unwrap()).unwrap();
        assert!(!json.contains("theirAlias"), "omitted, not null");
        assert!(!json.contains("isResponse"), "omitted, not null");

        assert_eq!(
            SavedHandshakePayload::from_plaintext(&stash.to_plaintext().unwrap()).unwrap(),
            stash,
            "round trip"
        );
    }

    /// A stash written by KASIA — their exact field set, none of our
    /// extensions — must hydrate. This is the half of interop that is easy to
    /// forget: we test our own emission constantly and their emission never.
    #[test]
    fn a_kasia_written_stash_parses_without_our_extensions() {
        let theirs = br#"{"type":"handshake","alias":"fa6d1afa79e1","timestamp":1751600000123,
             "version":1,"theirAlias":"90b4a1b640eb","isResponse":true,
             "partnerAddress":"kaspa:partner","recipientAddress":"kaspa:partner"}"#;
        let parsed = SavedHandshakePayload::from_plaintext(theirs).unwrap();
        assert_eq!(parsed.alias, "fa6d1afa79e1");
        assert_eq!(parsed.their_alias.as_deref(), Some("90b4a1b640eb"));
        assert_eq!(parsed.partner_address, "kaspa:partner");
        // No slot to be had — the caller must choose a default, not guess here.
        assert_eq!(parsed.bound_slot(), None);

        // Only `recipientAddress` (an older generation) still names the partner.
        let older = br#"{"alias":"fa6d1afa79e1","timestamp":1,"recipientAddress":"kaspa:p"}"#;
        assert_eq!(
            SavedHandshakePayload::from_plaintext(older)
                .unwrap()
                .partner_address,
            "kaspa:p"
        );
    }

    /// The refusals. A stash that cannot name the counterparty restores a
    /// conversation that can never send — refuse it rather than half-restore.
    /// A half-specified slot is worse than none: it would bind to the wrong
    /// address and present an identity the counterparty does not know (D-067).
    #[test]
    fn saved_handshake_refuses_what_it_cannot_restore() {
        let no_address = br#"{"alias":"fa6d1afa79e1","timestamp":1}"#;
        assert!(SavedHandshakePayload::from_plaintext(no_address).is_err());

        let empty_address =
            br#"{"alias":"fa6d1afa79e1","timestamp":1,"partnerAddress":"","recipientAddress":""}"#;
        assert!(SavedHandshakePayload::from_plaintext(empty_address).is_err());

        let bad_alias = br#"{"alias":"nothex","timestamp":1,"partnerAddress":"kaspa:p"}"#;
        assert!(SavedHandshakePayload::from_plaintext(bad_alias).is_err());

        let future =
            br#"{"alias":"fa6d1afa79e1","timestamp":1,"version":2,"partnerAddress":"kaspa:p"}"#;
        assert!(SavedHandshakePayload::from_plaintext(future).is_err());

        // Half a slot is discarded, not half-applied.
        let half = br#"{"alias":"fa6d1afa79e1","timestamp":1,"partnerAddress":"kaspa:p","boundBranch":"change"}"#;
        assert_eq!(
            SavedHandshakePayload::from_plaintext(half)
                .unwrap()
                .bound_slot(),
            None
        );
        // An unknown branch token is discarded rather than trusted.
        let bogus = br#"{"alias":"fa6d1afa79e1","timestamp":1,"partnerAddress":"kaspa:p","boundBranch":"treasury","boundIndex":3}"#;
        assert_eq!(
            SavedHandshakePayload::from_plaintext(bogus)
                .unwrap()
                .bound_slot(),
            None
        );

        // Construction refuses the same things at the write side.
        assert!(SavedHandshakePayload::new(
            "fa6d1afa79e1",
            None,
            "",
            "id",
            BOUND_BRANCH_RECEIVE,
            0,
            false,
            1
        )
        .is_err());
        assert!(SavedHandshakePayload::new(
            "fa6d1afa79e1",
            None,
            "kaspa:p",
            "id",
            "treasury",
            0,
            false,
            1
        )
        .is_err());
    }

    fn row(alias: &str, partner: &str, id: &str) -> SavedHandshakePayload {
        SavedHandshakePayload::new(
            alias,
            None,
            partner,
            id,
            BOUND_BRANCH_RECEIVE,
            0,
            false,
            1_751_600_000_123,
        )
        .unwrap()
    }

    /// A foreign client must still find a whole, ordinary Kasia stash at the
    /// top level of our snapshot — that is the entire interop claim.
    #[test]
    fn snapshot_keeps_the_kasia_object_at_the_top_level() {
        let rows = vec![
            row("aaaaaaaaaaaa", "kaspa:one", "id1"),
            row("bbbbbbbbbbbb", "kaspa:two", "id2"),
        ];
        let snapshot = SavedHandshakeSnapshot::new(rows.clone()).unwrap();
        let bytes = snapshot.to_plaintext().unwrap();
        let json = String::from_utf8(bytes.clone()).unwrap();

        // The head is a LITERAL PREFIX of the snapshot — byte-for-byte the same
        // emission a single-conversation stash produces, minus its closing
        // brace. If this breaks, our head stopped being a Kasia object.
        let head_bytes = rows[0].to_plaintext().unwrap();
        let head_json = String::from_utf8(head_bytes).unwrap();
        assert!(
            json.starts_with(&head_json[..head_json.len() - 1]),
            "head must lead, unreordered"
        );
        assert!(json.ends_with(r#"]}"#));
        assert!(json.contains(r#","conversations":["#));

        // And their reader's four fields are readable straight off the head.
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["alias"], "aaaaaaaaaaaa");
        assert_eq!(value["recipientAddress"], "kaspa:one");
        assert_eq!(value["timestamp"], 1_751_600_000_123u64);
    }

    #[test]
    fn snapshot_round_trips_every_conversation() {
        let rows = vec![
            SavedHandshakePayload::new(
                "aaaaaaaaaaaa",
                Some("cccccccccccc"),
                "kaspa:one",
                "id1",
                BOUND_BRANCH_CHANGE,
                7,
                true,
                111,
            )
            .unwrap(),
            row("bbbbbbbbbbbb", "kaspa:two", "id2"),
            row("dddddddddddd", "kaspa:three", "id3"),
        ];
        let snapshot = SavedHandshakeSnapshot::new(rows.clone()).unwrap();
        let parsed =
            SavedHandshakeSnapshot::from_plaintext(&snapshot.to_plaintext().unwrap()).unwrap();
        assert_eq!(parsed.rows().len(), 3);
        assert_eq!(parsed.rows(), rows.as_slice());
        assert_eq!(
            parsed.rows()[0].bound_slot(),
            Some((BOUND_BRANCH_CHANGE, 7))
        );
        assert_eq!(parsed.rows()[0].is_response, Some(true));
    }

    /// Kasia's own stash — no `conversations` key at all — reads as a one-row
    /// snapshot, so the restore path needs no second shape.
    #[test]
    fn a_kasia_written_stash_parses_as_a_one_row_snapshot() {
        let theirs = br#"{"type":"handshake","alias":"fa6d1afa79e1","timestamp":1751600000123,
             "version":1,"partnerAddress":"kaspa:p","recipientAddress":"kaspa:p"}"#;
        let parsed = SavedHandshakeSnapshot::from_plaintext(theirs).unwrap();
        assert_eq!(parsed.rows().len(), 1);
        assert_eq!(parsed.rows()[0].partner_address, "kaspa:p");
        assert_eq!(parsed.rows()[0].bound_slot(), None);
    }

    /// One corrupt conversation must never destroy the others. The whole value
    /// of a snapshot is that it is the user's only copy.
    #[test]
    fn a_corrupt_row_inside_a_snapshot_never_costs_the_others() {
        let mut snapshot = SavedHandshakeSnapshot::new(vec![
            row("aaaaaaaaaaaa", "kaspa:one", "id1"),
            row("bbbbbbbbbbbb", "kaspa:two", "id2"),
        ])
        .unwrap();
        // Corrupt the second row's alias after construction (the wire can carry
        // anything; only our constructor validates).
        snapshot.conversations[1].alias = "not-hex".to_string();
        let parsed =
            SavedHandshakeSnapshot::from_plaintext(&snapshot.to_plaintext().unwrap()).unwrap();
        assert_eq!(parsed.rows().len(), 1, "the good row survives");
        assert_eq!(parsed.rows()[0].alias, "aaaaaaaaaaaa");
    }

    /// The array length is stranger-chosen. Bound it.
    #[test]
    fn snapshot_parse_is_bounded() {
        let rows: Vec<_> = (0..300)
            .map(|i| row("aaaaaaaaaaaa", &format!("kaspa:{i}"), &format!("id{i}")))
            .collect();
        let snapshot = SavedHandshakeSnapshot::new(rows).unwrap();
        let parsed =
            SavedHandshakeSnapshot::from_plaintext(&snapshot.to_plaintext().unwrap()).unwrap();
        assert_eq!(parsed.rows().len(), MAX_SNAPSHOT_ROWS);
    }

    #[test]
    fn an_empty_snapshot_is_refused_rather_than_spent_on() {
        assert!(SavedHandshakeSnapshot::new(vec![]).is_err());
    }

    /// THE AUTHORSHIP TAG. A stash is sealed to our own PUBLIC key, so anyone
    /// who knows our receive address can produce one our key opens — and a
    /// restore CREATES conversations from these rows. The tag is what makes
    /// "ours" provable instead of asserted.
    #[test]
    fn the_tag_rides_last_and_leaves_the_untagged_bytes_a_literal_prefix() {
        let snapshot =
            SavedHandshakeSnapshot::new(vec![row("aaaaaaaaaaaa", "kaspa:one", "id1")]).unwrap();
        let untagged = snapshot.to_plaintext().unwrap();
        let tag = [0xABu8; 32];
        let tagged = attach_stash_tag(&untagged, &tag).unwrap();

        assert!(
            tagged.starts_with(&untagged[..untagged.len() - 1]),
            "the untagged bytes are a prefix — verification never re-serializes"
        );
        assert!(String::from_utf8(tagged.clone())
            .unwrap()
            .ends_with(&format!(r#","kvTag":"{}"}}"#, "ab".repeat(32))));

        let (recovered, recovered_tag) = split_stash_tag(&tagged).unwrap();
        assert_eq!(
            recovered, untagged,
            "the split reconstructs exactly the bytes the tag was computed over"
        );
        assert_eq!(recovered_tag, tag);

        // A tagged stash still PARSES — the tag is just an unknown key, which
        // is what keeps a foreign client (Kasia's) reading the head unchanged.
        let parsed = SavedHandshakeSnapshot::from_plaintext(&tagged).unwrap();
        assert_eq!(parsed.rows().len(), 1);
        assert_eq!(parsed.rows()[0].alias, "aaaaaaaaaaaa");
    }

    /// Anything that is not one of OUR tags must read as absent, so the caller
    /// refuses rather than half-trusts.
    #[test]
    fn an_absent_or_malformed_tag_is_never_mistaken_for_a_valid_one() {
        // The Kasia case: no tag at all.
        let theirs = br#"{"alias":"fa6d1afa79e1","timestamp":1,"partnerAddress":"kaspa:p"}"#;
        assert!(split_stash_tag(theirs).is_none());

        // Right shape, non-hex body.
        let bad_hex = format!(r#"{{"a":1,"kvTag":"{}"}}"#, "zz".repeat(32));
        assert!(split_stash_tag(bad_hex.as_bytes()).is_none());

        // Right name, wrong length.
        let short = br#"{"a":1,"kvTag":"abcd"}"#;
        assert!(split_stash_tag(short).is_none());

        // A tag on something that is not an object.
        let not_object = format!(r#"[1,2],"kvTag":"{}"}}"#, "ab".repeat(32));
        assert!(split_stash_tag(not_object.as_bytes()).is_none());

        // Truncating the tag by one character must not shift the split into a
        // silent success on the wrong bytes.
        let snapshot =
            SavedHandshakeSnapshot::new(vec![row("aaaaaaaaaaaa", "kaspa:one", "id1")]).unwrap();
        let tagged = attach_stash_tag(&snapshot.to_plaintext().unwrap(), &[7u8; 32]).unwrap();
        let mut clipped = tagged.clone();
        clipped.remove(clipped.len() - 3);
        assert!(split_stash_tag(&clipped).is_none());

        // Empty / tiny inputs never index out of bounds.
        assert!(split_stash_tag(b"").is_none());
        assert!(split_stash_tag(b"{}").is_none());

        // A tag is refused on a body that does not close an object.
        assert!(attach_stash_tag(b"not json", &[0u8; 32]).is_err());
    }

    /// One flipped byte anywhere in the payload must invalidate the tag — that
    /// is the whole point, and the splice must not accidentally exclude the
    /// bytes an attacker would change (the counterparty address).
    #[test]
    fn the_tag_covers_every_byte_an_attacker_would_want_to_change() {
        let snapshot =
            SavedHandshakeSnapshot::new(vec![row("aaaaaaaaaaaa", "kaspa:victim", "id1")]).unwrap();
        let untagged = snapshot.to_plaintext().unwrap();
        assert!(
            String::from_utf8(untagged.clone())
                .unwrap()
                .contains("kaspa:victim"),
            "the counterparty address is inside the tagged bytes"
        );

        let swapped =
            SavedHandshakeSnapshot::new(vec![row("aaaaaaaaaaaa", "kaspa:attacker", "id1")])
                .unwrap()
                .to_plaintext()
                .unwrap();
        assert_ne!(
            untagged, swapped,
            "swapping the counterparty changes the bytes the tag is computed over"
        );
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
