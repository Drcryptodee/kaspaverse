//! Sealed-seed blob — Path B (P1 §0.2): Argon2id → XChaCha20-Poly1305.
//!
//! Crypto crates and versions are exactly the pinned tree's own storage AEAD
//! stack (pin: wallet/core/src/encryption.rs uses `argon2` +
//! `chacha20poly1305`); the sealing *policy* here is ours — upstream's
//! storage KDF (`argon2_sha256iv_hash`, default params, deterministic salt)
//! is deliberately not reused: the vault lock (§0.3) requires explicit
//! Argon2id parameters and a random salt.
//!
//! Blob layout v1 (integers little-endian):
//!
//! ```text
//! [0..4)    magic   "KVSB"
//! [4]       version 0x01
//! [5]       scheme  0x02   (0x01 reserved for Path A platform-AEAD, P1.2)
//! [6..10)   Argon2id m_cost (KiB)
//! [10..14)  Argon2id t_cost
//! [14..18)  Argon2id p_cost
//! [18..34)  salt  (16 B)
//! [34..58)  nonce (24 B, XChaCha20)
//! [58..138) ciphertext ‖ tag (64 B seed + 16 B tag)
//! ```
//!
//! The header `[0..58)` is the AEAD's associated data — any header bit-flip
//! fails authentication. The KDF parameters are *additionally* bounds-checked
//! before the KDF runs: the AAD can only be verified after the key is
//! derived, so without bounds a corrupted or hostile header could demand
//! gigabytes of KDF memory first (memory-DoS). Payload v1 is the seed only —
//! the phrase and the extra word are never persisted (wallet-security item 6;
//! re-reveal-after-creation is deliberately absent, D-008). The versioned
//! header makes re-tuning (P1.2) or a payload v2 a re-wrap, not archaeology.

use crate::error::{CoreError, Result};
use crate::seed::SecretSeed;
use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::{Aead, KeyInit, OsRng, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use zeroize::{Zeroize, Zeroizing};

const MAGIC: &[u8; 4] = b"KVSB";
const VERSION_V1: u8 = 1;
const SCHEME_PATH_B: u8 = 2;
const HEADER_LEN: usize = 58;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 24;
const SEED_LEN: usize = 64;
const TAG_LEN: usize = 16;
/// Exact v1 blob length: header + seed + tag.
pub const BLOB_LEN: usize = HEADER_LEN + SEED_LEN + TAG_LEN;

// Sanity bounds enforced on both seal and unseal (see module docs). Generous:
// real parameters come from on-device tuning against PERFORMANCE_BUDGET.md
// and sit far inside these.
// 8 MiB floor — below the v1 grid is suspicious.
const MIN_M_COST_KIB: u32 = 8 * 1024;
// 256 MiB ceiling (D-031, audit remediation): the bound must be survivable on
// the REFERENCE DEVICE, not merely "not absurd" — a corrupted header demanding
// 1 GiB would OOM-kill the app before authentication fails, which is exactly
// the DoS this guard exists to stop. P1.2's tuned value must sit well below.
const MAX_M_COST_KIB: u32 = 256 * 1024;
const MIN_T_COST: u32 = 1;
const MAX_T_COST: u32 = 64;
const MIN_P_COST: u32 = 1;
const MAX_P_COST: u32 = 8;

/// Argon2id cost parameters carried in the blob header.
///
/// `Default` is the v1 starting grid (P1 §0.3: m = 64 MiB, t = 3, p = 1);
/// P1.2 tunes on the reference device against the ≤1.0 s unlock budget and
/// records the result in PERFORMANCE_BUDGET.md.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SealParams {
    pub m_cost_kib: u32,
    pub t_cost: u32,
    pub p_cost: u32,
}

impl Default for SealParams {
    fn default() -> Self {
        Self {
            m_cost_kib: 64 * 1024,
            t_cost: 3,
            p_cost: 1,
        }
    }
}

impl SealParams {
    fn check_bounds(&self) -> Result<()> {
        let ok = (MIN_M_COST_KIB..=MAX_M_COST_KIB).contains(&self.m_cost_kib)
            && (MIN_T_COST..=MAX_T_COST).contains(&self.t_cost)
            && (MIN_P_COST..=MAX_P_COST).contains(&self.p_cost);
        if ok {
            Ok(())
        } else {
            Err(CoreError::BlobParamBounds)
        }
    }
}

/// Derive the 32-byte AEAD key. Runs Argon2id with the explicit parameters —
/// callers above the bridge must keep this off the UI thread (§0.3).
fn derive_key(passphrase: &[u8], salt: &[u8], params: SealParams) -> Result<Zeroizing<[u8; 32]>> {
    let argon_params = Params::new(params.m_cost_kib, params.t_cost, params.p_cost, Some(32))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, argon_params);
    let mut key = Zeroizing::new([0u8; 32]);
    argon.hash_password_into(passphrase, salt, key.as_mut())?;
    Ok(key)
}

fn build_header(
    params: SealParams,
    salt: &[u8; SALT_LEN],
    nonce: &[u8; NONCE_LEN],
) -> [u8; HEADER_LEN] {
    let mut header = [0u8; HEADER_LEN];
    header[0..4].copy_from_slice(MAGIC);
    header[4] = VERSION_V1;
    header[5] = SCHEME_PATH_B;
    header[6..10].copy_from_slice(&params.m_cost_kib.to_le_bytes());
    header[10..14].copy_from_slice(&params.t_cost.to_le_bytes());
    header[14..18].copy_from_slice(&params.p_cost.to_le_bytes());
    header[18..34].copy_from_slice(salt);
    header[34..58].copy_from_slice(nonce);
    header
}

/// Seal the seed under a passphrase. Fresh random salt and nonce every call —
/// re-sealing the same seed never reuses either.
pub fn seal_seed(seed: &SecretSeed, passphrase: &[u8], params: SealParams) -> Result<Vec<u8>> {
    if passphrase.is_empty() {
        return Err(CoreError::EmptyPassphrase);
    }
    params.check_bounds()?;

    let mut salt = [0u8; SALT_LEN];
    OsRng.fill_bytes(&mut salt);
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    let header = build_header(params, &salt, &nonce);

    let key = derive_key(passphrase, &salt, params)?;
    let cipher = XChaCha20Poly1305::new(key.as_ref().into());
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: seed.as_bytes(),
                aad: &header,
            },
        )
        .map_err(|_| CoreError::Seal)?;

    let mut blob = Vec::with_capacity(BLOB_LEN);
    blob.extend_from_slice(&header);
    blob.extend_from_slice(&ciphertext);
    Ok(blob)
}

/// Unseal a blob. Errors distinguish *structure* problems (`MalformedBlob`,
/// `BlobParamBounds` — checked before the KDF runs) from *authentication*
/// failure (`WrongPassphraseOrCorrupt` — wrong passphrase and corrupted data
/// are cryptographically indistinguishable, and the error says so).
pub fn unseal_seed(blob: &[u8], passphrase: &[u8]) -> Result<SecretSeed> {
    if passphrase.is_empty() {
        return Err(CoreError::EmptyPassphrase);
    }
    if blob.len() < HEADER_LEN {
        return Err(CoreError::MalformedBlob("too short"));
    }
    if &blob[0..4] != MAGIC {
        return Err(CoreError::MalformedBlob("magic"));
    }
    if blob[4] != VERSION_V1 {
        return Err(CoreError::MalformedBlob("unknown version"));
    }
    if blob[5] != SCHEME_PATH_B {
        return Err(CoreError::MalformedBlob("unknown scheme"));
    }
    if blob.len() != BLOB_LEN {
        return Err(CoreError::MalformedBlob("length"));
    }

    let le_u32 =
        |at: usize| u32::from_le_bytes([blob[at], blob[at + 1], blob[at + 2], blob[at + 3]]);
    let params = SealParams {
        m_cost_kib: le_u32(6),
        t_cost: le_u32(10),
        p_cost: le_u32(14),
    };
    params.check_bounds()?;

    let header = &blob[..HEADER_LEN];
    let salt = &blob[18..34];
    let nonce = XNonce::from_slice(&blob[34..58]);

    let key = derive_key(passphrase, salt, params)?;
    let cipher = XChaCha20Poly1305::new(key.as_ref().into());
    let mut plaintext = cipher
        .decrypt(
            nonce,
            Payload {
                msg: &blob[HEADER_LEN..],
                aad: header,
            },
        )
        .map_err(|_| CoreError::WrongPassphraseOrCorrupt)?;

    if plaintext.len() != SEED_LEN {
        plaintext.zeroize();
        return Err(CoreError::MalformedBlob("payload length"));
    }
    let mut bytes = Box::new([0u8; SEED_LEN]);
    bytes.copy_from_slice(&plaintext);
    plaintext.zeroize();
    Ok(SecretSeed::new(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tiny-but-in-bounds parameters so the suite stays fast; the default
    // grid is exercised once in `default_params_are_the_v1_grid`.
    const TEST_PARAMS: SealParams = SealParams {
        m_cost_kib: 8 * 1024,
        t_cost: 1,
        p_cost: 1,
    };

    fn test_seed() -> SecretSeed {
        SecretSeed::new(Box::new([0x42u8; 64]))
    }

    #[test]
    fn default_params_are_the_v1_grid() {
        // §0.3 starting grid: 64 MiB / 3 / 1. Changing this is a re-tune —
        // it must come with a PERFORMANCE_BUDGET.md entry (P1.2).
        assert_eq!(
            SealParams::default(),
            SealParams {
                m_cost_kib: 65536,
                t_cost: 3,
                p_cost: 1
            }
        );
    }

    #[test]
    fn seal_unseal_round_trip() {
        let blob = seal_seed(&test_seed(), b"correct horse", TEST_PARAMS).unwrap();
        assert_eq!(blob.len(), BLOB_LEN);
        let seed = unseal_seed(&blob, b"correct horse").unwrap();
        assert_eq!(seed.as_bytes(), &[0x42u8; 64]);
    }

    #[test]
    fn fresh_salt_and_nonce_every_seal() {
        let a = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();
        let b = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();
        assert_ne!(a[18..34], b[18..34], "salt reused");
        assert_ne!(a[34..58], b[34..58], "nonce reused");
        assert_ne!(a[58..], b[58..], "ciphertext identical");
    }

    #[test]
    fn wrong_passphrase_fails_authentication() {
        let blob = seal_seed(&test_seed(), b"correct horse", TEST_PARAMS).unwrap();
        match unseal_seed(&blob, b"incorrect horse") {
            Err(CoreError::WrongPassphraseOrCorrupt) => {}
            other => panic!("expected WrongPassphraseOrCorrupt, got {other:?}"),
        }
    }

    #[test]
    fn corrupted_header_fails_authentication() {
        let mut blob = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();
        blob[20] ^= 0x01; // flip a salt bit — header is AAD
        match unseal_seed(&blob, b"pw") {
            // Salt feeds the KDF too, so this surfaces as an auth failure.
            Err(CoreError::WrongPassphraseOrCorrupt) => {}
            other => panic!("expected WrongPassphraseOrCorrupt, got {other:?}"),
        }
    }

    #[test]
    fn corrupted_ciphertext_fails_authentication() {
        let mut blob = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 0x01;
        assert!(matches!(
            unseal_seed(&blob, b"pw"),
            Err(CoreError::WrongPassphraseOrCorrupt)
        ));
    }

    #[test]
    fn truncated_and_malformed_blobs_are_rejected_before_the_kdf() {
        let blob = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();

        assert!(matches!(
            unseal_seed(&blob[..30], b"pw"),
            Err(CoreError::MalformedBlob("too short"))
        ));
        assert!(matches!(
            unseal_seed(&blob[..BLOB_LEN - 1], b"pw"),
            Err(CoreError::MalformedBlob("length"))
        ));

        let mut bad_magic = blob.clone();
        bad_magic[0] = b'X';
        assert!(matches!(
            unseal_seed(&bad_magic, b"pw"),
            Err(CoreError::MalformedBlob("magic"))
        ));

        let mut bad_version = blob.clone();
        bad_version[4] = 9;
        assert!(matches!(
            unseal_seed(&bad_version, b"pw"),
            Err(CoreError::MalformedBlob("unknown version"))
        ));

        let mut bad_scheme = blob;
        bad_scheme[5] = 0x01; // Path A is reserved, not unsealable here
        assert!(matches!(
            unseal_seed(&bad_scheme, b"pw"),
            Err(CoreError::MalformedBlob("unknown scheme"))
        ));
    }

    #[test]
    fn hostile_kdf_params_are_refused_before_the_kdf_runs() {
        use std::time::Instant;
        let mut blob = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();
        blob[6..10].copy_from_slice(&u32::MAX.to_le_bytes()); // m_cost = 4 TiB
        let started = Instant::now();
        assert!(matches!(
            unseal_seed(&blob, b"pw"),
            Err(CoreError::BlobParamBounds)
        ));
        // The guard's whole point: rejection must not have attempted the KDF.
        assert!(
            started.elapsed().as_millis() < 100,
            "bounds check ran the KDF"
        );
    }

    #[test]
    fn empty_passphrase_is_refused() {
        assert!(matches!(
            seal_seed(&test_seed(), b"", TEST_PARAMS),
            Err(CoreError::EmptyPassphrase)
        ));
        let blob = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();
        assert!(matches!(
            unseal_seed(&blob, b""),
            Err(CoreError::EmptyPassphrase)
        ));
    }

    #[test]
    fn out_of_bounds_seal_params_are_refused() {
        let too_small = SealParams {
            m_cost_kib: 1024,
            t_cost: 1,
            p_cost: 1,
        };
        assert!(matches!(
            seal_seed(&test_seed(), b"pw", too_small),
            Err(CoreError::BlobParamBounds)
        ));
    }

    #[test]
    fn m_cost_ceiling_is_mobile_survivable_and_edges_hold() {
        // D-031: the guard must reject costs that would OOM the reference
        // device — 1 GiB passed the old bound and is fatal there.
        assert_eq!(MAX_M_COST_KIB, 256 * 1024);
        let just_over = SealParams {
            m_cost_kib: MAX_M_COST_KIB + 1,
            t_cost: 1,
            p_cost: 1,
        };
        assert!(matches!(
            seal_seed(&test_seed(), b"pw", just_over),
            Err(CoreError::BlobParamBounds)
        ));
        let one_gib = SealParams {
            m_cost_kib: 1024 * 1024,
            t_cost: 1,
            p_cost: 1,
        };
        assert!(matches!(
            seal_seed(&test_seed(), b"pw", one_gib),
            Err(CoreError::BlobParamBounds)
        ));
        // Boundary inclusivity proven on the bounds function directly —
        // sealing at MAX would pay a 256 MiB KDF in CI for no extra truth.
        let at_max = SealParams {
            m_cost_kib: MAX_M_COST_KIB,
            t_cost: MAX_T_COST,
            p_cost: MAX_P_COST,
        };
        assert!(at_max.check_bounds().is_ok());
        let at_min = SealParams {
            m_cost_kib: MIN_M_COST_KIB,
            t_cost: MIN_T_COST,
            p_cost: MIN_P_COST,
        };
        assert!(at_min.check_bounds().is_ok());
    }

    // ── Adversarial property tests (D-031, audit remediation) ─────────────
    // Hand-rolled deterministic PRNG: no new dev-dependencies, reproducible
    // failures (a failing case is recoverable from its iteration index).

    fn lcg(state: &mut u64) -> u64 {
        // Knuth MMIX constants — statistical quality is irrelevant here;
        // determinism and coverage spread are the point.
        *state = state
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        *state
    }

    /// Every single-byte corruption of a valid blob, at every offset, must
    /// fail clean: no panic, never Ok. Offsets 0..6 fail structurally
    /// (magic/version/scheme); 6..18 at bounds or auth (params); 18..58 at
    /// auth via KDF/nonce (salt, nonce); 58.. at auth (ciphertext, tag) —
    /// the first test that exercises the AAD binding at every position.
    #[test]
    fn every_single_byte_corruption_fails_clean() {
        let blob = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();
        for at in 0..blob.len() {
            let mut corrupt = blob.clone();
            corrupt[at] ^= 0x01;
            assert!(
                unseal_seed(&corrupt, b"pw").is_err(),
                "corruption at byte {at} unsealed successfully"
            );
        }
    }

    /// Random structural garbage must never panic the parser and never
    /// unseal: random lengths and bytes, valid-magic prefixes with garbage
    /// tails, and truncations of a valid blob at every length.
    #[test]
    fn unseal_survives_garbage_and_truncation_without_panicking() {
        let mut rng: u64 = 0x4B56_5342; // "KVSB"
        for i in 0..512 {
            let len = (lcg(&mut rng) % 200) as usize;
            let mut bytes: Vec<u8> = (0..len).map(|_| lcg(&mut rng) as u8).collect();
            if i % 3 == 0 && len >= 6 {
                bytes[..4].copy_from_slice(MAGIC); // force past the magic check
                bytes[4] = VERSION_V1;
                bytes[5] = SCHEME_PATH_B;
            }
            assert!(
                unseal_seed(&bytes, b"pw").is_err(),
                "garbage case {i} unsealed"
            );
        }
        let blob = seal_seed(&test_seed(), b"pw", TEST_PARAMS).unwrap();
        for cut in 0..blob.len() {
            assert!(
                unseal_seed(&blob[..cut], b"pw").is_err(),
                "truncation at {cut} unsealed"
            );
        }
    }

    /// Round-trip must hold across the cheap corners of the legal parameter
    /// lattice (large-m corners are P1.2 device-tuning's job, not CI's).
    #[test]
    fn round_trip_holds_at_cheap_param_corners() {
        for (t, p) in [(1, 1), (1, 2), (2, 1), (2, 2)] {
            let params = SealParams {
                m_cost_kib: MIN_M_COST_KIB,
                t_cost: t,
                p_cost: p,
            };
            let blob = seal_seed(&test_seed(), b"pw", params).unwrap();
            let seed = unseal_seed(&blob, b"pw").unwrap();
            assert_eq!(seed.as_bytes(), &[0x42u8; 64], "corner t={t} p={p}");
        }
    }
}
