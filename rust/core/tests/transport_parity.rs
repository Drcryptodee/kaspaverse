//! Parity-fixture harness — the committed proof that `transport_crypto` is
//! byte-compatible with the live `ciph_msg:1:` population (P2 §0.8).
//!
//! Vectors: `tests/vectors/transport_crypto_v1.json`, generated 2026-07-04
//! against the Kasia cipher crate @ `acd3cf65` as a scratchpad oracle (L43 —
//! the oracle never enters this tree). `decrypt` covers their-encrypt→our-
//! decrypt AND oracle-verified our-encrypt envelopes, both recipient
//! parities; `tamper` covers §0.8's flip-a-byte rejections. The deterministic
//! encrypt pins live in the module's unit tests (crate-private seam).
//!
//! This JSON-vectors-plus-harness shape is deliberately the seed pattern for
//! the P3 contract-vectors harness (§0.10).

use kaspaverse_core::transport_crypto::{decrypt, Envelope};

const VECTORS: &str = include_str!("vectors/transport_crypto_v1.json");

fn hex_bytes(hex: &str) -> Vec<u8> {
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("fixture hex"))
        .collect()
}

fn hex_32(hex: &str) -> [u8; 32] {
    hex_bytes(hex).try_into().expect("fixture 32-byte hex")
}

fn vectors() -> serde_json::Value {
    serde_json::from_str(VECTORS).expect("fixture JSON parses")
}

#[test]
fn every_decrypt_vector_round_trips() {
    let fixture = vectors();
    let decrypt_vectors = fixture["decrypt"].as_array().expect("decrypt section");
    assert!(
        decrypt_vectors.len() >= 18,
        "fixture shrank: {} decrypt vectors",
        decrypt_vectors.len()
    );
    let mut oracle_encrypted = 0;
    let mut odd_parity = 0;
    for vector in decrypt_vectors {
        let name = vector["name"].as_str().unwrap();
        let envelope = Envelope::from_bytes(&hex_bytes(vector["envelope_hex"].as_str().unwrap()))
            .unwrap_or_else(|e| panic!("{name}: envelope parse failed: {e}"));
        let secret = hex_32(vector["recipient_secret_hex"].as_str().unwrap());
        let plaintext =
            decrypt(&envelope, &secret).unwrap_or_else(|e| panic!("{name}: decrypt failed: {e}"));
        assert_eq!(
            plaintext.as_slice(),
            vector["plaintext_utf8"].as_str().unwrap().as_bytes(),
            "{name}: plaintext mismatch"
        );
        assert!(vector["oracle_verified"].as_bool().unwrap(), "{name}");
        if vector["encrypted_by"].as_str().unwrap() == "oracle" {
            oracle_encrypted += 1;
        }
        if vector["recipient_parity"].as_str().unwrap() == "odd" {
            odd_parity += 1;
        }
    }
    // The parity claims the suite must actually contain, not just tolerate:
    // real oracle ciphertexts, and odd-parity recipients (§0.8).
    assert!(
        oracle_encrypted >= 8,
        "only {oracle_encrypted} oracle-encrypted vectors"
    );
    assert!(odd_parity >= 8, "only {odd_parity} odd-parity vectors");
}

#[test]
fn every_tamper_vector_is_rejected() {
    let fixture = vectors();
    let decrypt_vectors = fixture["decrypt"].as_array().unwrap();
    let tamper_vectors = fixture["tamper"].as_array().expect("tamper section");
    assert!(
        tamper_vectors.len() >= 12,
        "fixture shrank: {} tamper vectors",
        tamper_vectors.len()
    );
    for case in tamper_vectors {
        let name = case["name"].as_str().unwrap();
        assert_eq!(case["expect"].as_str().unwrap(), "reject", "{name}");
        let base_name = case["base"].as_str().unwrap();
        let base = decrypt_vectors
            .iter()
            .find(|v| v["name"].as_str() == Some(base_name))
            .unwrap_or_else(|| panic!("{name}: base vector {base_name} missing"));
        let mut wire = hex_bytes(base["envelope_hex"].as_str().unwrap());
        let offset = case["flip_byte_offset"].as_u64().unwrap() as usize;
        wire[offset] ^= 0x01;
        let secret = hex_32(base["recipient_secret_hex"].as_str().unwrap());
        let survived = Envelope::from_bytes(&wire)
            .and_then(|envelope| decrypt(&envelope, &secret))
            .is_ok();
        assert!(!survived, "{name}: tampered envelope decrypted");
    }
}
