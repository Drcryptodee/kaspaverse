//! Transport-message cipher — byte-parity with the live `ciph_msg:1:` wire
//! population (P2 §0.8, ratified D-062).
//!
//! Clean-room construction from wire facts identified at Gate R (ops audit
//! 2026-07-03; oracle: K-Kluster/Kasia `cipher/src/lib.rs` @ `acd3cf65`, read
//! for *facts*, never transcribed) and proven by the committed parity vectors
//! in `tests/vectors/transport_crypto_v1.json`, generated against that crate
//! as a scratchpad oracle. The construction:
//!
//! ```text
//! encrypt(recipient_xonly, plaintext):
//!   R     = lift_x(recipient_xonly, EVEN parity)          — always even (§0.8)
//!   e     = fresh random scalar; E = e·G (SEC1 compressed, 33 B)
//!   x     = X-coordinate of e·R (32 B big-endian; Y discarded)
//!   key   = HKDF-SHA256(salt = ∅, ikm = x, info = "", L = 32)
//!   ct    = ChaCha20-Poly1305(key, nonce = 12 random B, plaintext, no AAD)
//!   wire  = nonce ‖ E ‖ ct+tag
//! ```
//!
//! Decrypt computes the same x from `d·E` with the recipient's raw scalar `d`
//! and needs **no parity branch**: point negation flips only Y, so
//! `x(d·E) = x(±d·E)` — the §0.8 "odd-parity fallback on decrypt" is satisfied
//! *by construction*, and the odd-recipient fixtures prove it byte-level.
//!
//! The KDF is RFC 5869 HKDF-SHA256 at its degenerate single-block point
//! (salt = None ⇒ a zero-filled hash-length key, §2.2; info = "" and L = 32 ⇒
//! exactly one expand round, §2.3): `OKM = HMAC(HMAC(0³², x), 0x01)`. Two HMAC
//! calls over the already-pinned `hmac` + `sha2` crates — implemented against
//! the RFC text and pinned by the oracle vectors, not transcribed.
//!
//! One inherent wire property, shared with the oracle: the ephemeral key's
//! SEC1 parity bit (byte 12, `0x02`↔`0x03`) is not authenticated and does not
//! feed the key — x-only ECDH is negation-invariant — so flipping it yields
//! the *identical* plaintext. It can never alter message content; content
//! integrity is Poly1305's job and sender authenticity the tx signature's.
//!
//! Custody posture: every derived secret here (shared X, PRK, message key) is
//! wiped on drop (INV-2); decrypted plaintext returns as `Zeroizing<Vec<u8>>`
//! and must never be logged or persisted (§0.4 — it leaves Rust only as the
//! post-decrypt display DTO, which P2.3 owns). Sender authenticity comes from
//! the TX SIGNATURE, not this cipher — nothing here authenticates the sender,
//! by design (§4). The transient `secp256k1::SecretKey` copies are upstream
//! types that do not self-zeroize; we call `non_secure_erase()` after use —
//! the same recorded posture as the keychain's transient extended keys
//! (vault_architecture §7).

use crate::error::{CoreError, Result};
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::{Aead, KeyInit, OsRng};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hmac::{Hmac, Mac};
use secp256k1::{ecdh, Parity, PublicKey, SecretKey, XOnlyPublicKey, SECP256K1};
use sha2::Sha256;
use std::fmt;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

/// ChaCha20-Poly1305 nonce — 96 bits on this wire.
pub const NONCE_LEN: usize = 12;
/// Ephemeral public key — SEC1 compressed, `0x02`/`0x03` tag byte.
pub const EPHEMERAL_KEY_LEN: usize = 33;
/// Poly1305 authentication tag appended to the ciphertext.
pub const TAG_LEN: usize = 16;
/// Smallest decryptable envelope: empty plaintext still carries the tag.
pub const MIN_ENVELOPE_LEN: usize = NONCE_LEN + EPHEMERAL_KEY_LEN + TAG_LEN;

/// One sealed transport message. All three fields are public wire data — the
/// envelope travels in a transaction payload on a public DAG.
///
/// Wire order (note: NOT the field order the oracle's struct declares):
/// `nonce(12) ‖ ephemeral_public_key(33) ‖ ciphertext+tag`.
#[derive(Clone, PartialEq, Eq)]
pub struct Envelope {
    pub nonce: [u8; NONCE_LEN],
    pub ephemeral_public_key: [u8; EPHEMERAL_KEY_LEN],
    pub ciphertext: Vec<u8>,
}

impl Envelope {
    /// Serialize to the wire layout.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(NONCE_LEN + EPHEMERAL_KEY_LEN + self.ciphertext.len());
        bytes.extend_from_slice(&self.nonce);
        bytes.extend_from_slice(&self.ephemeral_public_key);
        bytes.extend_from_slice(&self.ciphertext);
        bytes
    }

    /// Strict wire parse. The oracle's parser tolerates a 32-byte ephemeral
    /// key when byte 12 is not a SEC1 tag, but that path can never decrypt
    /// (its own SEC1 parse rejects 32 bytes) — a dead tolerance shim, so
    /// strictness here loses no decryptable wire message.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < MIN_ENVELOPE_LEN {
            return Err(CoreError::MalformedEnvelope("too short"));
        }
        let tag = bytes[NONCE_LEN];
        if tag != 0x02 && tag != 0x03 {
            return Err(CoreError::MalformedEnvelope("ephemeral key tag"));
        }
        let mut nonce = [0u8; NONCE_LEN];
        nonce.copy_from_slice(&bytes[..NONCE_LEN]);
        let mut ephemeral_public_key = [0u8; EPHEMERAL_KEY_LEN];
        ephemeral_public_key.copy_from_slice(&bytes[NONCE_LEN..NONCE_LEN + EPHEMERAL_KEY_LEN]);
        Ok(Self {
            nonce,
            ephemeral_public_key,
            ciphertext: bytes[NONCE_LEN + EPHEMERAL_KEY_LEN..].to_vec(),
        })
    }
}

impl fmt::Debug for Envelope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Wire data is public, but envelopes are noisy — log shapes, not bytes.
        write!(f, "Envelope(ciphertext {} bytes)", self.ciphertext.len())
    }
}

/// The derived per-message AEAD key (the HKDF OKM). Never leaves this module;
/// wiped on drop (INV-2).
struct MessageKey([u8; 32]);

impl MessageKey {
    fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl Zeroize for MessageKey {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

impl Drop for MessageKey {
    fn drop(&mut self) {
        self.zeroize();
    }
}

impl ZeroizeOnDrop for MessageKey {}

impl fmt::Debug for MessageKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("MessageKey(32 bytes, redacted)")
    }
}

/// RFC 5869 HKDF-SHA256 at the wire's fixed point: salt = None (zero-filled
/// hash-length key, §2.2), info = "", L = 32 (one expand round, §2.3).
fn hkdf_sha256_32(ikm: &Zeroizing<[u8; 32]>) -> Result<MessageKey> {
    // HMAC accepts any key length — these constructors cannot actually fail,
    // but panics never head toward the FFI (INV-2), so the Results propagate.
    let mut extract =
        <Hmac<Sha256> as Mac>::new_from_slice(&[0u8; 32]).map_err(|_| CoreError::TransportSeal)?;
    extract.update(ikm.as_ref());
    let mut prk = extract.finalize().into_bytes();

    let expand_result = <Hmac<Sha256> as Mac>::new_from_slice(&prk).map(|mut expand| {
        expand.update(&[0x01]);
        expand.finalize().into_bytes()
    });
    prk.as_mut_slice().zeroize();
    let mut okm = expand_result.map_err(|_| CoreError::TransportSeal)?;

    let mut key = MessageKey([0u8; 32]);
    key.0.copy_from_slice(&okm);
    okm.as_mut_slice().zeroize();
    Ok(key)
}

/// ECDH → message key: X-coordinate of `scalar·point` (Y discarded — this is
/// what makes decryption parity-blind, see module docs), then the KDF.
fn message_key(point: &PublicKey, scalar: &SecretKey) -> Result<MessageKey> {
    let mut point_xy = ecdh::shared_secret_point(point, scalar);
    let mut x = Zeroizing::new([0u8; 32]);
    x.copy_from_slice(&point_xy[..32]);
    point_xy.zeroize();
    hkdf_sha256_32(&x)
}

/// Fresh random scalar from the OS RNG. Rejection-sampled: `from_slice`
/// refuses 0 and ≥ the group order, each with probability ≈ 2⁻¹²⁸ — the
/// bounded loop exists for INV-2's no-panic law, not because it recurs.
fn random_secret_key() -> Result<SecretKey> {
    for _ in 0..64 {
        let mut candidate = Zeroizing::new([0u8; 32]);
        OsRng.fill_bytes(candidate.as_mut());
        if let Ok(secret) = SecretKey::from_slice(candidate.as_ref()) {
            return Ok(secret);
        }
    }
    Err(CoreError::TransportSeal)
}

/// Encrypt `plaintext` to the holder of `recipient_x_only` (an address
/// payload — the 32-byte x-only pubkey). Fresh ephemeral key and nonce every
/// call; the recipient key is lifted to EVEN parity, always (§0.8).
pub fn encrypt(recipient_x_only: &[u8; 32], plaintext: &[u8]) -> Result<Envelope> {
    let mut ephemeral = random_secret_key()?;
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    let envelope = encrypt_with(recipient_x_only, plaintext, &ephemeral, nonce);
    ephemeral.non_secure_erase();
    envelope
}

/// Deterministic core of [`encrypt`] — the seam the parity fixtures pin
/// byte-exactly (`tests/vectors/transport_crypto_v1.json`, oracle-verified).
/// Crate-visible for the fixture tests only; product callers get the
/// fresh-randomness guarantee of [`encrypt`].
pub(crate) fn encrypt_with(
    recipient_x_only: &[u8; 32],
    plaintext: &[u8],
    ephemeral: &SecretKey,
    nonce: [u8; NONCE_LEN],
) -> Result<Envelope> {
    let x_only = XOnlyPublicKey::from_slice(recipient_x_only)
        .map_err(|_| CoreError::TransportKey("recipient x-only key"))?;
    let recipient = PublicKey::from_x_only_public_key(x_only, Parity::Even);

    let key = message_key(&recipient, ephemeral)?;
    let cipher = ChaCha20Poly1305::new(key.as_bytes().into());
    let ciphertext = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .map_err(|_| CoreError::TransportSeal)?;

    Ok(Envelope {
        nonce,
        ephemeral_public_key: ephemeral.public_key(SECP256K1).serialize(),
        ciphertext,
    })
}

/// Decrypt an envelope with the recipient's raw private key (32 bytes, as the
/// keychain derives them). Works for both parities of the recipient's real
/// public key with no fallback branch — see the module docs for why, and the
/// odd-parity fixtures for proof.
///
/// The returned plaintext is user content, not custody material (INV-1 as
/// amended D-056) — but it still never touches a log line or disk here; it
/// crosses to Dart only as P2.3's display DTO (§0.4).
pub fn decrypt(envelope: &Envelope, recipient_secret: &[u8; 32]) -> Result<Zeroizing<Vec<u8>>> {
    let mut secret = SecretKey::from_slice(recipient_secret)
        .map_err(|_| CoreError::TransportKey("recipient secret key"))?;
    let ephemeral = match PublicKey::from_slice(&envelope.ephemeral_public_key) {
        Ok(pk) => pk,
        Err(_) => {
            secret.non_secure_erase();
            return Err(CoreError::MalformedEnvelope("ephemeral key point"));
        }
    };
    let key = message_key(&ephemeral, &secret);
    secret.non_secure_erase();

    let cipher = ChaCha20Poly1305::new(key?.as_bytes().into());
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(&envelope.nonce),
            envelope.ciphertext.as_slice(),
        )
        .map_err(|_| CoreError::TransportOpen)?;
    Ok(Zeroizing::new(plaintext))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// First secret whose public key has the requested parity, from a
    /// deterministic candidate walk — synthetic test keys, never custody
    /// material.
    fn test_secret_with_parity(want: Parity) -> ([u8; 32], [u8; 32]) {
        for i in 1u8..=64 {
            let bytes = [i; 32];
            let Ok(secret) = SecretKey::from_slice(&bytes) else {
                continue;
            };
            let (x_only, parity) = secret.public_key(SECP256K1).x_only_public_key();
            if parity == want {
                return (bytes, x_only.serialize());
            }
        }
        panic!("no test key with parity {want:?} in the candidate walk");
    }

    #[test]
    fn round_trip_even_parity_recipient() {
        let (secret, x_only) = test_secret_with_parity(Parity::Even);
        let envelope = encrypt(&x_only, b"even-parity round trip").unwrap();
        let plaintext = decrypt(&envelope, &secret).unwrap();
        assert_eq!(plaintext.as_slice(), b"even-parity round trip");
    }

    #[test]
    fn round_trip_odd_parity_recipient_no_fallback_branch() {
        // The §0.8 odd-parity case: the sender lifts the address key to EVEN,
        // the recipient's real key is ODD — decrypt must still work with the
        // raw scalar (x-coordinate ECDH is negation-invariant).
        let (secret, x_only) = test_secret_with_parity(Parity::Odd);
        let envelope = encrypt(&x_only, b"odd-parity round trip").unwrap();
        let plaintext = decrypt(&envelope, &secret).unwrap();
        assert_eq!(plaintext.as_slice(), b"odd-parity round trip");
    }

    #[test]
    fn round_trip_survives_wire_serialization() {
        let (secret, x_only) = test_secret_with_parity(Parity::Even);
        let envelope = encrypt(&x_only, "⚔️ frame ‖ bytes".as_bytes()).unwrap();
        let reparsed = Envelope::from_bytes(&envelope.to_bytes()).unwrap();
        assert_eq!(reparsed, envelope);
        let plaintext = decrypt(&reparsed, &secret).unwrap();
        assert_eq!(plaintext.as_slice(), "⚔️ frame ‖ bytes".as_bytes());
    }

    #[test]
    fn empty_plaintext_is_a_tag_only_envelope() {
        let (secret, x_only) = test_secret_with_parity(Parity::Even);
        let envelope = encrypt(&x_only, b"").unwrap();
        assert_eq!(envelope.ciphertext.len(), TAG_LEN);
        assert_eq!(envelope.to_bytes().len(), MIN_ENVELOPE_LEN);
        assert_eq!(decrypt(&envelope, &secret).unwrap().len(), 0);
    }

    #[test]
    fn fresh_ephemeral_and_nonce_every_encrypt() {
        let (_, x_only) = test_secret_with_parity(Parity::Even);
        let a = encrypt(&x_only, b"same plaintext").unwrap();
        let b = encrypt(&x_only, b"same plaintext").unwrap();
        assert_ne!(a.nonce, b.nonce, "nonce reused");
        assert_ne!(
            a.ephemeral_public_key, b.ephemeral_public_key,
            "ephemeral key reused"
        );
        assert_ne!(a.ciphertext, b.ciphertext, "ciphertext identical");
    }

    /// Every single-byte corruption of a valid envelope must fail clean —
    /// no panic, never Ok (the vault-blob pattern, D-031) — with ONE
    /// documented exception: the SEC1 tag's parity bit (byte 12, 0x02↔0x03)
    /// negates the ephemeral point, and x-only ECDH is negation-invariant,
    /// so that flip decrypts to the IDENTICAL plaintext. The oracle shares
    /// this malleability (its DH is x-only too); it can never alter message
    /// content, and sender authenticity is the tx signature's job (§4).
    #[test]
    fn every_single_byte_corruption_fails_clean() {
        let (secret, x_only) = test_secret_with_parity(Parity::Even);
        let envelope = encrypt(&x_only, b"tamper target").unwrap();
        let wire = envelope.to_bytes();
        for at in 0..wire.len() {
            let mut corrupt = wire.clone();
            corrupt[at] ^= 0x01;
            let outcome = Envelope::from_bytes(&corrupt).and_then(|e| decrypt(&e, &secret));
            if at == NONCE_LEN {
                // The malleable parity bit: same plaintext, never different.
                assert_eq!(
                    outcome.expect("parity-bit flip must decrypt").as_slice(),
                    b"tamper target",
                    "parity-bit flip changed the plaintext"
                );
            } else {
                assert!(
                    outcome.is_err(),
                    "corruption at byte {at} decrypted successfully"
                );
            }
        }
    }

    #[test]
    fn wrong_recipient_key_fails_authentication() {
        let (_, x_only) = test_secret_with_parity(Parity::Even);
        let (other_secret, _) = test_secret_with_parity(Parity::Odd);
        let envelope = encrypt(&x_only, b"not for you").unwrap();
        assert!(matches!(
            decrypt(&envelope, &other_secret),
            Err(CoreError::TransportOpen)
        ));
    }

    #[test]
    fn malformed_envelopes_are_rejected_structurally() {
        assert!(matches!(
            Envelope::from_bytes(&[0u8; MIN_ENVELOPE_LEN - 1]),
            Err(CoreError::MalformedEnvelope("too short"))
        ));
        // Byte 12 must be a SEC1 compressed tag (the oracle's 32-byte
        // tolerance path can never decrypt — we refuse it at parse).
        let mut bad_tag = [0u8; MIN_ENVELOPE_LEN];
        bad_tag[NONCE_LEN] = 0x04;
        assert!(matches!(
            Envelope::from_bytes(&bad_tag),
            Err(CoreError::MalformedEnvelope("ephemeral key tag"))
        ));
        // A well-tagged key that is not a curve point fails at decrypt.
        let mut not_a_point = [0u8; MIN_ENVELOPE_LEN + 5];
        not_a_point[NONCE_LEN] = 0x02;
        let envelope = Envelope::from_bytes(&not_a_point).unwrap();
        let (secret, _) = test_secret_with_parity(Parity::Even);
        assert!(matches!(
            decrypt(&envelope, &secret),
            Err(CoreError::MalformedEnvelope("ephemeral key point"))
        ));
    }

    #[test]
    fn invalid_recipient_key_material_is_refused() {
        // Not a valid x coordinate (≥ field prime).
        let not_on_curve = [0xFFu8; 32];
        assert!(matches!(
            encrypt(&not_on_curve, b"x"),
            Err(CoreError::TransportKey("recipient x-only key"))
        ));
        // Zero is not a valid scalar.
        let (_, x_only) = test_secret_with_parity(Parity::Even);
        let envelope = encrypt(&x_only, b"x").unwrap();
        assert!(matches!(
            decrypt(&envelope, &[0u8; 32]),
            Err(CoreError::TransportKey("recipient secret key"))
        ));
    }

    // ── Secret lifecycle (INV-2, the P1.1 leak-shaped pattern) ────────────

    fn assert_zeroize_on_drop<T: ZeroizeOnDrop>() {}

    #[test]
    fn message_key_zeroizes_and_stays_opaque() {
        assert_zeroize_on_drop::<MessageKey>();
        let mut key = MessageKey([0x5Au8; 32]);
        key.zeroize();
        assert_eq!(key.as_bytes(), &[0u8; 32]);
        let rendered = format!("{:?}", MessageKey([0x5Au8; 32]));
        assert_eq!(rendered, "MessageKey(32 bytes, redacted)");
        assert!(!rendered.contains("5a") && !rendered.contains("5A"));
    }

    #[test]
    fn envelope_debug_shows_shape_not_bytes() {
        let (_, x_only) = test_secret_with_parity(Parity::Even);
        let envelope = encrypt(&x_only, b"secret-adjacent").unwrap();
        let rendered = format!("{envelope:?}");
        assert_eq!(rendered, "Envelope(ciphertext 31 bytes)");
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn hex_bytes(hex: &str) -> Vec<u8> {
        (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("fixture hex"))
            .collect()
    }

    /// Byte-pins `encrypt_with` to the oracle-verified fixture envelopes:
    /// each expected envelope was decrypted by the Kasia cipher crate at
    /// generation (our-encrypt→their-decrypt), so any construction drift —
    /// KDF, parity lift, wire order, AEAD — fails this test byte-exactly.
    #[test]
    fn deterministic_encrypt_matches_oracle_verified_vectors() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/vectors/transport_crypto_v1.json"))
                .expect("fixture JSON parses");
        let vectors = fixture["encrypt_deterministic"]
            .as_array()
            .expect("encrypt_deterministic section");
        assert!(
            vectors.len() >= 8,
            "fixture shrank: {} vectors",
            vectors.len()
        );
        for vector in vectors {
            let name = vector["name"].as_str().unwrap();
            assert!(vector["oracle_decrypted"].as_bool().unwrap(), "{name}");
            let x_only: [u8; 32] = hex_bytes(vector["recipient_x_only_hex"].as_str().unwrap())
                .try_into()
                .unwrap();
            let ephemeral =
                SecretKey::from_slice(&hex_bytes(vector["ephemeral_secret_hex"].as_str().unwrap()))
                    .unwrap();
            let nonce: [u8; NONCE_LEN] = hex_bytes(vector["nonce_hex"].as_str().unwrap())
                .try_into()
                .unwrap();
            let plaintext = vector["plaintext_utf8"].as_str().unwrap();
            let envelope = encrypt_with(&x_only, plaintext.as_bytes(), &ephemeral, nonce).unwrap();
            assert_eq!(
                hex(&envelope.to_bytes()),
                vector["expected_envelope_hex"].as_str().unwrap(),
                "{name}: envelope bytes drifted from the oracle-verified vector"
            );
        }
    }

    /// Fixture-candidate emitter — NOT a test of anything. Prints deterministic
    /// our-encrypt envelopes (plus two fresh random ones) as JSON for the
    /// scratchpad oracle harness to verify with the Kasia cipher crate
    /// (@ `acd3cf65`); verified candidates get blessed into
    /// `tests/vectors/transport_crypto_v1.json`. All keys are synthetic.
    ///
    /// Run: `cargo test -p kaspaverse-core --lib emit_fixture_candidates -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn emit_fixture_candidates() {
        let plaintexts: [&str; 4] = [
            "KaspaVerse parity vector 001 — plain ASCII body",
            "⚔️ RPS challenge — open in KaspaVerse · kv:1:challenge:{\"g\":\"rps\",\"stake\":\"0.2\"}",
            "",
            &"long-body ".repeat(40),
        ];
        let mut candidates = Vec::new();
        for (parity, parity_name) in [(Parity::Even, "even"), (Parity::Odd, "odd")] {
            let (secret, x_only) = test_secret_with_parity(parity);
            for (i, plaintext) in plaintexts.iter().enumerate() {
                let ephemeral_bytes =
                    [0xA1 + (i as u8) + if parity == Parity::Odd { 0x10 } else { 0 }; 32];
                let ephemeral = SecretKey::from_slice(&ephemeral_bytes).unwrap();
                let nonce: [u8; NONCE_LEN] =
                    std::array::from_fn(|j| 0x20 + (i as u8) * 16 + j as u8);
                let envelope =
                    encrypt_with(&x_only, plaintext.as_bytes(), &ephemeral, nonce).unwrap();
                candidates.push(serde_json::json!({
                    "name": format!("det-{parity_name}-{:03}", i + 1),
                    "kind": "deterministic",
                    "recipient_parity": parity_name,
                    "recipient_secret_hex": hex(&secret),
                    "recipient_x_only_hex": hex(&x_only),
                    "ephemeral_secret_hex": hex(&ephemeral_bytes),
                    "nonce_hex": hex(&nonce),
                    "plaintext_utf8": plaintext,
                    "envelope_hex": hex(&envelope.to_bytes()),
                }));
            }
            // One fresh-randomness envelope per parity — exercises the real
            // RNG path end to end under the oracle's decrypt.
            let envelope = encrypt(&x_only, b"random-path cross-check").unwrap();
            candidates.push(serde_json::json!({
                "name": format!("rand-{parity_name}-001"),
                "kind": "random",
                "recipient_parity": parity_name,
                "recipient_secret_hex": hex(&secret),
                "recipient_x_only_hex": hex(&x_only),
                "plaintext_utf8": "random-path cross-check",
                "envelope_hex": hex(&envelope.to_bytes()),
            }));
        }
        println!(
            "FIXTURE_CANDIDATES_JSON {}",
            serde_json::json!({ "candidates": candidates })
        );
    }

    #[test]
    fn error_display_never_carries_material() {
        // The variants name fields, never values (INV-2).
        for error in [
            CoreError::MalformedEnvelope("too short"),
            CoreError::TransportKey("recipient secret key"),
            CoreError::TransportOpen,
            CoreError::TransportSeal,
        ] {
            let rendered = format!("{error}");
            assert!(!rendered.contains("0x"), "material-shaped text: {rendered}");
        }
    }
}
