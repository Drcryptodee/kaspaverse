//! L1 payload transport — the `ciph_msg:` wire scan (receive) and wire
//! composition (send). P2.1 payload spine, per the ratified P2 §0 (D-062).
//!
//! Wire format authority: `docs/research/kasia_messaging.md` §2 (Gate-R-verified
//! 2026-07-03 against Kasia @ `acd3cf65`, its indexer @ `fd1ba0c`, and one real
//! on-chain message). Namespace `ciph_msg:1:` with kinds `handshake` / `comm` /
//! `payment` / `self_stash` / `bcast`, plus a legacy unversioned form.
//!
//! **Version-neutral by construction (§0.2):** detection reads ONLY
//! `tx.payload` — there is no `tx.version` branch anywhere in this module, so a
//! v1 transaction carrying the same payload matches identically (the live
//! population's own detection is version-neutral, Gate R Fact 2). A test below
//! proves it and guards the law.
//!
//! Custody posture: everything here is PUBLIC on-chain data (INV-3); payload
//! bodies may be third-party ciphertext or plaintext `bcast` text — neither is
//! ours to log. Nothing in this module logs payload contents (§4 watch-out:
//! treat message content like key material for logging purposes).

use kaspa_addresses::Prefix;
use kaspa_consensus_core::tx::Transaction;
use kaspa_txscript::extract_script_pub_key_address;
use kaspa_wrpc_client::prelude::{RpcBlock, RpcTransaction};

use crate::error::{ChainError, Result};
use crate::Rpc;

/// The wire namespace every payload message rides under (ASCII on-wire).
pub const CIPH_MSG_PREFIX: &[u8] = b"ciph_msg:";
/// Protocol version 1 token, as it appears after the namespace.
const WIRE_V1: &[u8] = b"1:";
/// A kind token must terminate with `:` within this many bytes — the longest
/// real kind is `self_stash` (10 bytes); the cap keeps an adversarial payload
/// (all scanned bytes are attacker-controlled) from minting huge "kind" strings.
const KIND_TOKEN_CAP: usize = 16;

/// Kind label for the unversioned legacy form (`ciph_msg:{bytes}`, no `1:`) —
/// still emitted by old clients, parsed as opaque bytes here (P2.3 owns
/// semantics).
pub const KIND_LEGACY: &str = "legacy";
/// Kind label when the version-1 remainder has no parseable kind token —
/// forward-compat opaque handling (mirrors the population's warn-and-skip).
pub const KIND_UNKNOWN: &str = "unknown";

/// A payload-bearing transaction matched by the scan. The exact DTO shape the
/// ratified §3 P2.1 names: txid, kind, raw body bytes, addresses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransportEvent {
    /// Transaction id, hex — the node's own verbose data when present, else
    /// computed from the tx via the pinned conversion + hasher (INV-9). `None`
    /// only if both fail (never fabricated).
    pub txid: Option<String>,
    /// Wire kind token, verbatim (`bcast`, `handshake`, …), or
    /// [`KIND_LEGACY`] / [`KIND_UNKNOWN`]. Unknown kinds still cross — the
    /// forward-compat rule (§0.5): downstream renders them opaque, never drops.
    pub kind: String,
    /// Raw body bytes after `ciph_msg:1:<kind>:` (for legacy/unknown forms, the
    /// whole remainder). Ciphertext or plaintext — passed through untouched.
    pub body: Vec<u8>,
    /// Output addresses (recipients, including change), extracted with the
    /// pinned txscript standard decoder; non-standard outputs are skipped.
    pub addresses: Vec<String>,
}

/// Parse a raw tx payload into `(kind, body)` — pure, version-neutral, shared
/// by the receive scan and the send-side summary decode (B7: the confirm
/// renders what the BUILT tx actually carries, via this same parser).
pub fn parse_payload(payload: &[u8]) -> Option<(String, &[u8])> {
    let rest = payload.strip_prefix(CIPH_MSG_PREFIX)?;
    let Some(v1) = rest.strip_prefix(WIRE_V1) else {
        // Unversioned legacy form: everything after the namespace is body.
        return Some((KIND_LEGACY.to_string(), rest));
    };
    let cap = v1.len().min(KIND_TOKEN_CAP);
    match v1[..cap].iter().position(|&b| b == b':') {
        Some(pos) => {
            let kind = String::from_utf8_lossy(&v1[..pos]).into_owned();
            Some((kind, &v1[pos + 1..]))
        }
        // No kind delimiter within the cap: opaque unknown, nothing dropped.
        None => Some((KIND_UNKNOWN.to_string(), v1)),
    }
}

/// Scan one block's transactions for `ciph_msg:` payloads. Runs on every
/// BlockAdded notification (~10 blocks/s), so the non-match path is one prefix
/// compare per tx; ids/addresses are resolved only for matches (sparse).
pub fn scan_block(block: &RpcBlock, prefix: Prefix) -> Vec<TransportEvent> {
    block
        .transactions
        .iter()
        .filter_map(|tx| scan_transaction(tx, prefix))
        .collect()
}

/// Match one transaction — payload prefix only (never `tx.version`, §0.2).
fn scan_transaction(tx: &RpcTransaction, prefix: Prefix) -> Option<TransportEvent> {
    let (kind, body) = parse_payload(&tx.payload)?;
    Some(TransportEvent {
        txid: resolve_txid(tx),
        kind,
        body: body.to_vec(),
        addresses: output_addresses(tx, prefix),
    })
}

/// The tx id: the node computed it in verbose data (populated on BlockAdded
/// unless its consensus query raced — converter/consensus.rs:704 at the pin);
/// otherwise recompute via the pinned RpcTransaction→Transaction conversion,
/// whose constructor finalizes the id with the pinned hasher (INV-9 — never
/// hand-rolled).
fn resolve_txid(tx: &RpcTransaction) -> Option<String> {
    if let Some(v) = &tx.verbose_data {
        return Some(v.transaction_id.to_string());
    }
    Transaction::try_from(tx.clone())
        .ok()
        .map(|t| t.id().to_string())
}

/// Output addresses via the pinned standard-script decoder; non-standard
/// scripts have no address form and are skipped. De-duplicated, order kept.
fn output_addresses(tx: &RpcTransaction, prefix: Prefix) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for output in &tx.outputs {
        if let Ok(address) = extract_script_pub_key_address(&output.script_public_key, prefix) {
            let address = address.to_string();
            if !seen.contains(&address) {
                seen.push(address);
            }
        }
    }
    seen
}

/// The handshake bond: 0.2 KAS, the live population's norm — THE one
/// provenance-cited economics constant (§0.6, ratified D-062). Provenance
/// (Gate R, ops audit 2026-07-03): enforced in code at Kasia
/// `messaging.store.ts:1456` (min-check) and refunded at `:1240-1251`
/// (`customAmount: kaspaToSompi("0.2")` on the acceptance response); observed
/// on-chain in tx `596eefed…` (20,000,000-sompi bond output). Every OTHER
/// message value is computed by the D-054 floor machinery
/// (`WalletEngine::minimum_sendable`) — never hardcoded (SOT §4).
pub const HANDSHAKE_BOND_SOMPI: u64 = 20_000_000;

/// Minimum sealed-envelope wire size: nonce(12) + SEC1 key(33) + tag(16) —
/// mirrors `kaspaverse-core::transport_crypto::MIN_ENVELOPE_LEN` (this crate
/// deliberately has no core dependency; the constant is wire law, pinned by
/// the P2.2 fixtures).
const MIN_SEALED_LEN: usize = 61;

/// True iff `bytes` has the sealed-envelope wire shape (length + a SEC1 tag
/// at byte 12). The §4 type-separation backstop: the encrypted-kind compose
/// functions refuse anything that does not look sealed, so a plaintext body
/// cannot be routed onto an encrypted kind by accident — and no compose path
/// with a caller-chosen kind token exists at all (`bcast` stays its own
/// dev/broadcast-only function above).
fn is_sealed_envelope(bytes: &[u8]) -> bool {
    bytes.len() >= MIN_SEALED_LEN && (bytes[12] == 0x02 || bytes[12] == 0x03)
}

/// Compose `ciph_msg:1:handshake:<raw envelope bytes>` — the live emission
/// shape (the app hex-encodes prefix + envelope into one payload; on-wire
/// that is ASCII prefix + RAW envelope, confirmed by the Gate-R decode of tx
/// `596eefed…`). Refuses non-sealed bodies (§4 type separation).
pub fn compose_handshake_wire(sealed_envelope: &[u8]) -> Result<Vec<u8>> {
    if !is_sealed_envelope(sealed_envelope) {
        return Err(ChainError::Message(
            "handshake body must be a sealed envelope".into(),
        ));
    }
    let mut wire =
        Vec::with_capacity(CIPH_MSG_PREFIX.len() + WIRE_V1.len() + 10 + sealed_envelope.len());
    wire.extend_from_slice(CIPH_MSG_PREFIX);
    wire.extend_from_slice(WIRE_V1);
    wire.extend_from_slice(b"handshake:");
    wire.extend_from_slice(sealed_envelope);
    Ok(wire)
}

/// Compose `ciph_msg:1:comm:<alias>:<base64 envelope text>`. We emit the
/// envelope as **base64 text — the live emitter's shape** (`btoa` at Kasia
/// `account-service.ts:801-804`; Gate K row K2, D-068 amending D-066: emit
/// what the emitter emits, not merely what the tolerance shim accepts). The
/// +33% body mass is priced by the D-054 floor machinery automatically (the
/// Generator masses these exact wire bytes). We PARSE both encodings forever
/// ([`decode_envelope_body`]). The alias head sits OUTSIDE the envelope by
/// wire law. Refuses non-sealed bodies (§4 type separation — validated on
/// the RAW envelope before encoding).
pub fn compose_comm_wire(alias: &str, sealed_envelope: &[u8]) -> Result<Vec<u8>> {
    if alias.is_empty() || alias.as_bytes().contains(&b':') {
        return Err(ChainError::Message(
            "conversation alias must be non-empty without ':'".into(),
        ));
    }
    if !is_sealed_envelope(sealed_envelope) {
        return Err(ChainError::Message(
            "comm body must be a sealed envelope".into(),
        ));
    }
    let body = encode_base64(sealed_envelope);
    let mut wire = Vec::with_capacity(
        CIPH_MSG_PREFIX.len() + WIRE_V1.len() + 5 + alias.len() + 1 + body.len(),
    );
    wire.extend_from_slice(CIPH_MSG_PREFIX);
    wire.extend_from_slice(WIRE_V1);
    wire.extend_from_slice(b"comm:");
    wire.extend_from_slice(alias.as_bytes());
    wire.push(b':');
    wire.extend_from_slice(body.as_bytes());
    Ok(wire)
}

/// Standard-alphabet padded base64 ENCODER — the exact `btoa` output shape the
/// live population emits for comm bodies (K2). Hand-rolled mirror of
/// [`decode_base64`] below (same INV-7 posture: one call site, test-pinned
/// against RFC 4648 vectors and round-tripped through the decoder).
fn encode_base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let mut acc = 0u32;
        for (i, &b) in chunk.iter().enumerate() {
            acc |= (b as u32) << (16 - 8 * i);
        }
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[((acc >> (18 - 6 * i)) & 0x3F) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Split a `comm` kind body into `(alias, envelope bytes)` — the alias head
/// sits OUTSIDE the envelope and MUST be split off before any envelope parse
/// (P2.2 handover note; the committed parity fixtures carry pure envelopes).
pub fn split_comm_body(body: &[u8]) -> Option<(String, &[u8])> {
    let delimiter = body.iter().position(|&b| b == b':')?;
    let alias = std::str::from_utf8(&body[..delimiter]).ok()?;
    if alias.is_empty() {
        return None;
    }
    Some((alias.to_string(), &body[delimiter + 1..]))
}

/// Normalise an envelope body to raw bytes across the wire generations:
/// the current app emits base64 TEXT for comm bodies (`btoa` at
/// `account-service.ts:801`), while handshakes, the VNone legacy form and the
/// indexer's native handling are RAW bytes. Mirrors the population's own
/// tolerance shim (`tryParseBase64AsHexToHex`): a body whose every byte is
/// base64-alphabet text decodes; anything else passes through untouched. The
/// two cases cannot collide: base64 text never carries a 0x02/0x03 at byte 12
/// (ASCII alphabet), and a 61+-byte raw envelope that is all base64-alphabet
/// ASCII has probability ≈ (65/256)^61 — vanishing.
pub fn decode_envelope_body(body: &[u8]) -> Vec<u8> {
    if !body.is_empty() && body.len().is_multiple_of(4) && body.iter().all(|&b| is_base64_char(b)) {
        if let Some(decoded) = decode_base64(body) {
            return decoded;
        }
    }
    body.to_vec()
}

fn is_base64_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'='
}

/// Strict standard-alphabet base64 (the `btoa` output shape: padded, no
/// whitespace). `None` on any structural violation — the caller then treats
/// the body as raw. Hand-checked table decode over the already-validated
/// alphabet; ~20 lines beats a new dependency for one call site (INV-7
/// posture: `base64` the crate exists in the lock only as a transitive).
fn decode_base64(text: &[u8]) -> Option<Vec<u8>> {
    fn value(b: u8) -> Option<u32> {
        match b {
            b'A'..=b'Z' => Some((b - b'A') as u32),
            b'a'..=b'z' => Some((b - b'a' + 26) as u32),
            b'0'..=b'9' => Some((b - b'0' + 52) as u32),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let chunks: Vec<&[u8]> = text.chunks(4).collect();
    for (i, chunk) in chunks.iter().enumerate() {
        if chunk.len() != 4 {
            return None;
        }
        let pad = chunk.iter().filter(|&&b| b == b'=').count();
        // Padding is only legal as the last 1–2 bytes of the FINAL chunk.
        if pad > 2 || (pad > 0 && i != chunks.len() - 1) || chunk[..4 - pad].contains(&b'=') {
            return None;
        }
        let mut acc: u32 = 0;
        for &b in &chunk[..4 - pad] {
            acc = (acc << 6) | value(b)?;
        }
        acc <<= 6 * pad as u32;
        let bytes = acc.to_be_bytes();
        out.extend_from_slice(&bytes[1..4 - pad]);
    }
    Some(out)
}

/// Resolve who SENT a transaction: the node's own `get_utxo_return_address`
/// (pin `rpc/core/src/api/rpc.rs:455` — the address of input[0]'s previous
/// output at the accepting chain block). This is the live population's own
/// sender-resolution primitive (Kasia's acceptance/VCC service calls the same
/// RPC) and node truth, not a frame (§0.3: the accept flow COMMITS VALUE — the
/// bond refund — so its destination comes from consensus data, never from
/// payload content). `accepting_daa_score` comes from the P1.5 activity
/// record of the bond that paid us ([`crate::WalletEngine::activity_daa_score`]).
/// INV-8 holds: same untrusted node, same one socket, no indexer.
pub async fn resolve_return_address(
    rpc: &Rpc,
    txid: &str,
    accepting_daa_score: u64,
) -> Result<String> {
    let txid = txid
        .parse::<kaspa_consensus_core::Hash>()
        .map_err(|_| ChainError::Message("malformed txid".into()))?;
    let address = rpc
        .rpc_api()
        .get_utxo_return_address(txid, accepting_daa_score)
        .await
        .map_err(|e| ChainError::Message(format!("sender lookup failed: {e}")))?;
    Ok(address.to_string())
}

/// Compose the plaintext broadcast wire form `ciph_msg:1:bcast:<channel>:<text>`.
///
/// `bcast` is **plaintext by design** on the live protocol (kasia_messaging §2)
/// and is the one kind the spine can device-prove before any cryptography
/// exists (P2.1 leverage insight). LAW (§4 watch-out): no DM may ever route
/// through this — encrypted-kind compose paths arrive in P2.3 as separate
/// functions, type-incapable of emitting `bcast`; this stays the dev/broadcast
/// path only.
pub fn compose_bcast(channel: &str, text: &str) -> Result<Vec<u8>> {
    if channel.is_empty() {
        return Err(ChainError::Message(
            "broadcast channel must not be empty".into(),
        ));
    }
    if channel.as_bytes().contains(&b':') {
        return Err(ChainError::Message(
            "broadcast channel must not contain ':' (it delimits the wire fields)".into(),
        ));
    }
    let mut wire = Vec::with_capacity(
        CIPH_MSG_PREFIX.len() + WIRE_V1.len() + 6 + channel.len() + 1 + text.len(),
    );
    wire.extend_from_slice(CIPH_MSG_PREFIX);
    wire.extend_from_slice(WIRE_V1);
    wire.extend_from_slice(b"bcast:");
    wire.extend_from_slice(channel.as_bytes());
    wire.push(b':');
    wire.extend_from_slice(text.as_bytes());
    Ok(wire)
}

#[cfg(test)]
mod tests {
    use super::*;
    use kaspa_addresses::Address;
    use kaspa_consensus_core::subnets::SUBNETWORK_ID_NATIVE;
    use kaspa_txscript::pay_to_address_script;
    use kaspa_wrpc_client::prelude::{RpcHeader, RpcTransactionOutput, RpcTransactionVerboseData};

    // Upstream gen1 mainnet vectors (keychain.rs / hd.rs) — valid, distinct.
    const DEST: &str = "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf";
    const CHANGE: &str = "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692";

    fn addr(s: &str) -> Address {
        Address::try_from(s).unwrap()
    }

    fn output_to(address: &str) -> RpcTransactionOutput {
        RpcTransactionOutput {
            value: 20_000_000,
            script_public_key: pay_to_address_script(&addr(address)),
            verbose_data: None,
            covenant: None,
        }
    }

    /// A minimal RpcTransaction carrying `payload` at `version` — inputs empty
    /// (the scan never reads them).
    fn tx_with(version: u16, payload: &[u8]) -> RpcTransaction {
        RpcTransaction {
            version,
            inputs: vec![],
            outputs: vec![output_to(DEST), output_to(CHANGE)],
            lock_time: 0,
            subnetwork_id: SUBNETWORK_ID_NATIVE,
            gas: 0,
            payload: payload.to_vec(),
            storage_mass: 0,
            verbose_data: None,
        }
    }

    /// A zeroed header — the scan never reads it; only `transactions` matter.
    fn zero_header() -> RpcHeader {
        RpcHeader {
            hash: kaspa_consensus_core::Hash::from_bytes([0u8; 32]),
            version: 0,
            parents_by_level: vec![],
            hash_merkle_root: kaspa_consensus_core::Hash::from_bytes([0u8; 32]),
            accepted_id_merkle_root: kaspa_consensus_core::Hash::from_bytes([0u8; 32]),
            utxo_commitment: kaspa_consensus_core::Hash::from_bytes([0u8; 32]),
            timestamp: 0,
            bits: 0,
            nonce: 0,
            daa_score: 0,
            blue_work: Default::default(),
            blue_score: 0,
            pruning_point: kaspa_consensus_core::Hash::from_bytes([0u8; 32]),
        }
    }

    fn block_of(transactions: Vec<RpcTransaction>) -> RpcBlock {
        RpcBlock {
            header: zero_header(),
            transactions,
            verbose_data: None,
        }
    }

    #[test]
    fn versioned_kinds_parse_to_kind_and_raw_body() {
        let (kind, body) = parse_payload(b"ciph_msg:1:bcast:kv-dev:hello there").unwrap();
        assert_eq!(kind, "bcast");
        assert_eq!(body, b"kv-dev:hello there");

        let (kind, body) = parse_payload(b"ciph_msg:1:handshake:\x00\x01\xffraw envelope").unwrap();
        assert_eq!(kind, "handshake");
        assert_eq!(body, b"\x00\x01\xffraw envelope");

        let (kind, body) = parse_payload(b"ciph_msg:1:comm:alias9:\x02\x03").unwrap();
        assert_eq!(kind, "comm");
        assert_eq!(body, b"alias9:\x02\x03");
    }

    #[test]
    fn legacy_and_unknown_forms_stay_opaque_and_lossless() {
        // Legacy unversioned: whole remainder is body.
        let (kind, body) = parse_payload(b"ciph_msg:\x10legacy-bytes").unwrap();
        assert_eq!(kind, KIND_LEGACY);
        assert_eq!(body, b"\x10legacy-bytes");

        // Version 1 but no kind delimiter within the cap: unknown, no bytes lost.
        let raw = b"ciph_msg:1:no-delimiter-anywhere-in-this-run";
        let (kind, body) = parse_payload(raw).unwrap();
        assert_eq!(kind, KIND_UNKNOWN);
        assert_eq!(body, &raw[b"ciph_msg:1:".len()..]);

        // A future kind we don't know still crosses verbatim (§0.5 rule).
        let (kind, body) = parse_payload(b"ciph_msg:1:zap:xyz").unwrap();
        assert_eq!(kind, "zap");
        assert_eq!(body, b"xyz");
    }

    #[test]
    fn non_matching_payloads_are_skipped() {
        assert_eq!(parse_payload(b""), None);
        assert_eq!(parse_payload(b"nothing to see"), None);
        assert_eq!(parse_payload(b"ciph_msgX1:bcast:c:t"), None);
        // Prefix must match from byte 0, not merely appear somewhere.
        assert_eq!(parse_payload(b"xciph_msg:1:bcast:c:t"), None);
    }

    /// THE §0.2 LAW TEST: a v1-shaped transaction matches the scan identically
    /// to a v0 one — detection never branches on `tx.version`. If this test
    /// fails, someone added a version filter to the scan path; that one line
    /// silently breaks the phase's whole point (phase file §4).
    #[test]
    fn scan_is_version_neutral() {
        let payload = b"ciph_msg:1:bcast:kv-dev:version neutrality";
        let v0 = tx_with(0, payload);
        let v1 = tx_with(1, payload);
        let events = scan_block(&block_of(vec![v0, v1]), Prefix::Mainnet);
        assert_eq!(events.len(), 2, "both versions must match");
        assert_eq!(events[0].kind, events[1].kind);
        assert_eq!(events[0].body, events[1].body);
        assert_eq!(events[0].addresses, events[1].addresses);
    }

    #[test]
    fn scan_extracts_addresses_and_skips_non_matches() {
        let noise = tx_with(0, b"");
        let matching = tx_with(0, b"ciph_msg:1:bcast:kv-dev:hi");
        let block = block_of(vec![noise, matching]);
        let events = scan_block(&block, Prefix::Mainnet);
        assert_eq!(events.len(), 1, "only the ciph_msg tx crosses");
        assert_eq!(
            events[0].addresses,
            vec![DEST.to_string(), CHANGE.to_string()]
        );
        assert_eq!(events[0].kind, "bcast");
    }

    #[test]
    fn txid_prefers_node_verbose_data_and_computes_otherwise() {
        let mut tx = tx_with(0, b"ciph_msg:1:bcast:kv-dev:id me");
        // No verbose data: the id is computed via the pinned conversion.
        let computed = resolve_txid(&tx).expect("computable");
        assert_eq!(computed.len(), 64, "hex tx id");

        // Node-provided verbose data wins (it is the node's own id).
        let node_id = kaspa_consensus_core::tx::TransactionId::from_bytes([7u8; 32]);
        tx.verbose_data = Some(RpcTransactionVerboseData {
            transaction_id: node_id,
            hash: kaspa_consensus_core::Hash::from_bytes([8u8; 32]),
            compute_mass: 0,
            block_hash: kaspa_consensus_core::Hash::from_bytes([9u8; 32]),
            block_time: 0,
        });
        assert_eq!(resolve_txid(&tx).unwrap(), node_id.to_string());
    }

    #[test]
    fn compose_bcast_emits_the_exact_wire_form_and_round_trips() {
        let wire = compose_bcast("kv-dev", "hello 🚀").unwrap();
        assert_eq!(wire, "ciph_msg:1:bcast:kv-dev:hello 🚀".as_bytes());

        // Round-trip through the same parser the receive scan uses.
        let (kind, body) = parse_payload(&wire).unwrap();
        assert_eq!(kind, "bcast");
        assert_eq!(body, "kv-dev:hello 🚀".as_bytes());
    }

    #[test]
    fn compose_bcast_rejects_channel_forms_that_break_the_wire() {
        assert!(compose_bcast("", "x").is_err());
        assert!(compose_bcast("kv:dev", "x").is_err());
    }

    /// A sealed-envelope-shaped body for wire tests: correct minimum length
    /// with a SEC1 tag at byte 12. Never a real envelope — the crypto lives
    /// in core; this crate only carries the bytes.
    fn sealed_shape(len: usize) -> Vec<u8> {
        let mut bytes = vec![0xA5u8; len.max(MIN_SEALED_LEN)];
        bytes[12] = 0x02;
        bytes
    }

    #[test]
    fn handshake_wire_round_trips_through_the_scan_parser() {
        let envelope = sealed_shape(100);
        let wire = compose_handshake_wire(&envelope).unwrap();
        assert!(wire.starts_with(b"ciph_msg:1:handshake:"));
        let (kind, body) = parse_payload(&wire).unwrap();
        assert_eq!(kind, "handshake");
        assert_eq!(body, envelope.as_slice(), "raw envelope bytes, untouched");
    }

    /// THE K2 EMISSION LAW (D-068 amending D-066): comm bodies leave here as
    /// base64 TEXT — byte-identical to the live emitter's `btoa` shape — and
    /// round-trip through our own tolerance decoder back to the envelope.
    #[test]
    fn comm_wire_emits_base64_and_round_trips_via_the_tolerance_decoder() {
        let envelope = sealed_shape(80);
        let wire = compose_comm_wire("fa6d1afa79e1", &envelope).unwrap();
        let (kind, body) = parse_payload(&wire).unwrap();
        assert_eq!(kind, "comm");
        // The alias head sits OUTSIDE the envelope (P2.2 handover law).
        let (alias, encoded) = split_comm_body(body).unwrap();
        assert_eq!(alias, "fa6d1afa79e1");
        // The body on the wire is base64 text (the live emitter's shape),
        // never the raw envelope…
        assert!(encoded.iter().all(|&b| is_base64_char(b)));
        assert_ne!(encoded, envelope.as_slice());
        // …and the tolerance decoder recovers the exact envelope bytes.
        assert_eq!(decode_envelope_body(encoded), envelope);
    }

    /// Raw comm bodies (our own P2.3-era emission, already live on mainnet)
    /// must keep parsing forever — tolerate what the population ever emitted.
    #[test]
    fn raw_comm_bodies_stay_parseable_forever() {
        let envelope = sealed_shape(80);
        let mut wire = b"ciph_msg:1:comm:fa6d1afa79e1:".to_vec();
        wire.extend_from_slice(&envelope);
        let (kind, body) = parse_payload(&wire).unwrap();
        assert_eq!(kind, "comm");
        let (_, raw) = split_comm_body(body).unwrap();
        assert_eq!(decode_envelope_body(raw), envelope);
    }

    /// §4 type separation: the encrypted-kind composers refuse anything that
    /// does not have the sealed-envelope wire shape, so a plaintext DM can
    /// never ride an encrypted kind — and neither function takes a kind
    /// token, so nothing can be routed onto `bcast` from here.
    #[test]
    fn encrypted_kind_composers_refuse_plaintext_shaped_bodies() {
        assert!(compose_handshake_wire(b"hello, definitely not sealed").is_err());
        assert!(compose_comm_wire("fa6d1afa79e1", b"short").is_err());
        // Length right, tag wrong — still refused.
        let mut wrong_tag = sealed_shape(70);
        wrong_tag[12] = b'x';
        assert!(compose_handshake_wire(&wrong_tag).is_err());
        // Alias forms that break the wire are refused.
        let envelope = sealed_shape(70);
        assert!(compose_comm_wire("", &envelope).is_err());
        assert!(compose_comm_wire("a:b", &envelope).is_err());
    }

    #[test]
    fn split_comm_body_handles_malformed_heads() {
        assert_eq!(split_comm_body(b"no-delimiter"), None);
        assert_eq!(split_comm_body(b":leading-empty-alias"), None);
        // Non-UTF-8 alias bytes: not a valid head.
        assert_eq!(split_comm_body(b"\xff\xfe:body"), None);
    }

    /// The generation-tolerance law (mirrors the population's own shim,
    /// `utils/payload-encoding.ts`): base64 TEXT bodies (the current app's
    /// comm emission — btoa, padded standard alphabet) decode to raw bytes;
    /// raw bodies pass through untouched.
    #[test]
    fn envelope_body_decoding_spans_the_generations() {
        // A raw envelope (the emission WE produce + the VNone legacy form —
        // the real on-chain legacy payload in Kasia's own repo is raw too).
        let raw = sealed_shape(75);
        assert_eq!(decode_envelope_body(&raw), raw);

        // The app's btoa output for those same bytes decodes back to them —
        // and our own encoder IS that shape (encoder/decoder round-trip).
        let b64 = encode_base64(&raw);
        assert_eq!(decode_envelope_body(b64.as_bytes()), raw);
        // RFC 4648 vectors pin the ENCODER too (the decoder's are below).
        assert_eq!(encode_base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(encode_base64(b"foob"), "Zm9vYg==");
        assert_eq!(encode_base64(b"fooba"), "Zm9vYmE=");
        assert_eq!(encode_base64(b""), "");

        // Known vectors (RFC 4648 test strings, padded standard alphabet).
        assert_eq!(decode_envelope_body(b"Zm9vYmFy"), b"foobar");
        assert_eq!(decode_envelope_body(b"Zm9vYg=="), b"foob");
        assert_eq!(decode_envelope_body(b"Zm9vYmE="), b"fooba");

        // Structural violations fall back to raw pass-through.
        assert_eq!(decode_envelope_body(b"Zm9v!mFy"), b"Zm9v!mFy"); // alphabet
        assert_eq!(decode_envelope_body(b"Zm9vY"), b"Zm9vY"); // length % 4
        assert_eq!(decode_envelope_body(b"Zm==9vYmFy"), b"Zm==9vYmFy"); // mid-pad
        assert_eq!(decode_envelope_body(b""), b"");
    }

    /// The REAL legacy VNone payload from the population's own repo
    /// (`src/tests/legacy-cases.ts` @ `acd3cf65`) — a genuine on-chain
    /// message. Pins: the unversioned form parses as `legacy` kind; the body
    /// is RAW envelope bytes (odd-parity SEC1 tag 0x03 at byte 12) that the
    /// tolerance decoder passes through untouched.
    #[test]
    fn real_legacy_vnone_payload_parses_as_raw_envelope() {
        let payload_hex = "636970685f6d73673a7803145984c9f2b2cc540a39030cf21af1c488d0db01c5d12842054e663c7bd90f6c63a15e6b8bbc9d9ce31b989b9e14c46f75af65a7a41f6f86f24a5354dc7d723a2aa4237404320308b1b37f4e39264c4db1b3e57e65d059434e892c46690e27";
        let payload: Vec<u8> = (0..payload_hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&payload_hex[i..i + 2], 16).unwrap())
            .collect();
        let (kind, body) = parse_payload(&payload).unwrap();
        assert_eq!(kind, KIND_LEGACY);
        let envelope = decode_envelope_body(body);
        assert_eq!(envelope, body, "legacy body is raw, not base64");
        assert!(is_sealed_envelope(&envelope));
        assert_eq!(envelope[12], 0x03, "real odd-parity ephemeral tag");
        // 12 nonce + 33 key + 52 ciphertext/tag.
        assert_eq!(envelope.len(), 97);
    }

    #[test]
    fn the_bond_constant_is_the_gate_r_observed_value() {
        // 0.2 KAS — the ONE provenance-cited constant (§0.6). If this ever
        // changes, the live population's norm changed: re-run the Gate-R
        // observation before shipping.
        assert_eq!(HANDSHAKE_BOND_SOMPI, 20_000_000);
    }
}
