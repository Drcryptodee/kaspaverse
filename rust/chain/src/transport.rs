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
}
