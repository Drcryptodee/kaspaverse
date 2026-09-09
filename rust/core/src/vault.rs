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
//! Blob layout **v2 (D-312)** — v1's header with two bytes *appended*, so every
//! offset before them is unchanged and one parser reads both:
//!
//! ```text
//! [4]       version    0x02
//! [58]      input_kind 0x01 passphrase | 0x02 digits
//! [59]      binding    0x00 none       | 0x01 device
//! [60..140) ciphertext ‖ tag
//! ```
//!
//! Appended rather than inserted on purpose: a field wedged in at [18] would
//! move the salt and the nonce and buy nothing, and two layouts that share a
//! prefix are two layouts one function can read.
//!
//! **`input_kind` is what the user TYPES, not how the blob is encrypted.** The
//! founder's ruling (D-312) makes the unlock secret a choice — a six-digit PIN
//! or an any-length passphrase — and the choice has to outlive the install that
//! made it, so it lives in the thing it describes. It is *advisory to the UI and
//! nothing else*: it decides which pad is drawn FIRST, never which characters
//! may be typed. Reading it needs no passphrase (`read_facts`), so it is
//! unauthenticated at the moment it is read — which is exactly why the screen
//! that reads it must always offer the other pad. A flipped bit there shows the
//! wrong keyboard to somebody who can still reach the right one; a flipped bit
//! anywhere fails authentication when the unseal runs.
//!
//! **`binding` is custody, and it is the reason the PIN is offerable at all.**
//! `device` means the KDF ran over `passphrase ‖ pepper`, where the pepper is 32
//! bytes only this phone's Keystore can produce. Without it, a 6-digit PIN is
//! 10^6 candidates at ~679 ms each — hours on rented hardware for anyone who
//! lifts the file, and `vault.lockout` cannot help because those guesses never
//! transit the app. With it, the file is worthless off the phone and every guess
//! must go through the TEE, which is what gives the lockout teeth. A `device`
//! blob whose pepper cannot be produced fails with `DeviceBinding`, never with
//! `WrongPassphraseOrCorrupt`: the user is told this phone cannot open this
//! vault, rather than that they mistyped. Nothing secret leaks by saying so —
//! the byte is plaintext.
//!
//! The header (`[0..HEADER_LEN)`, whichever version) is the AEAD's associated
//! data — any header bit-flip fails authentication. The KDF parameters are
//! *additionally* bounds-checked before the KDF runs: the AAD can only be
//! verified after the key is derived, so without bounds a corrupted or hostile
//! header could demand gigabytes of KDF memory first (memory-DoS). Payload v1 is
//! the seed only — the phrase and the extra word are never persisted
//! (wallet-security item 6). The versioned header makes re-tuning (P1.2) or a
//! payload v2 a re-wrap, not archaeology, and v2 is that promise being kept.

use crate::error::{CoreError, Result};
use crate::seed::SecretSeed;
use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::aead::rand_core::RngCore;
use chacha20poly1305::aead::{Aead, KeyInit, OsRng, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use zeroize::{Zeroize, Zeroizing};

const MAGIC: &[u8; 4] = b"KVSB";
const VERSION_V1: u8 = 1;
const VERSION_V2: u8 = 2;
const SCHEME_PATH_B: u8 = 2;
const HEADER_LEN_V1: usize = 58;
const HEADER_LEN_V2: usize = 60;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 24;
const SEED_LEN: usize = 64;
const TAG_LEN: usize = 16;
/// Exact v1 blob length: v1 header + seed + tag. Still read, never written.
pub const BLOB_LEN_V1: usize = HEADER_LEN_V1 + SEED_LEN + TAG_LEN;
/// Exact v2 blob length: the length every NEW vault is sealed at.
pub const BLOB_LEN: usize = HEADER_LEN_V2 + SEED_LEN + TAG_LEN;
/// The device pepper is exactly 32 bytes — one HMAC-SHA256 output.
pub const PEPPER_LEN: usize = 32;
/// `O2` draws six wells, and a `Digits` vault is sealed at exactly that length.
/// The number lives here as well as in the screens because a rule that lives
/// only in a screen lives nowhere (`consensus-auditor`, D-312).
pub const PIN_LEN: usize = 6;

const KIND_PASSPHRASE: u8 = 1;
const KIND_DIGITS: u8 = 2;
const BINDING_NONE: u8 = 0;
const BINDING_DEVICE: u8 = 1;

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

/// **What the user types to open this vault** — the founder's D-312 choice,
/// carried by the vault rather than by the app.
///
/// A preference in a side file drifts from the blob it describes and dies with a
/// half-cleared install; a byte inside the AAD cannot do either. It is set at
/// seal time because that is when the AAD is fixed, which makes changing it a
/// re-key (a Settings ceremony), not a toggle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputKind {
    /// Any-length printable secret, typed on the alphanumeric pad.
    Passphrase,
    /// Six digits, typed on the number pad. Offerable only alongside a device
    /// binding — see the module docs.
    Digits,
}

impl InputKind {
    fn to_byte(self) -> u8 {
        match self {
            Self::Passphrase => KIND_PASSPHRASE,
            Self::Digits => KIND_DIGITS,
        }
    }

    fn from_byte(b: u8) -> Result<Self> {
        match b {
            KIND_PASSPHRASE => Ok(Self::Passphrase),
            KIND_DIGITS => Ok(Self::Digits),
            _ => Err(CoreError::MalformedBlob("input kind")),
        }
    }
}

/// What a blob's header says about itself, readable **without the passphrase**.
///
/// Everything here is plaintext in the file, so exposing it leaks nothing an
/// attacker holding the file does not already have. It exists so the unlock
/// screen can draw the right pad before the first keystroke, and so the bridge
/// can decide whether a vault still needs migrating.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlobFacts {
    /// 1 or 2.
    pub version: u8,
    /// Which pad to offer first. v1 blobs read as [`InputKind::Passphrase`].
    pub input_kind: InputKind,
    /// Whether the KDF input included this device's pepper.
    pub device_bound: bool,
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

/// Derive the 32-byte AEAD key. Runs Argon2id with the explicit parameters —
/// callers above the bridge must keep this off the UI thread (§0.3).
///
/// **The pepper is appended to the password, not to the salt.** The salt is
/// public (it is in the header); a secret placed there would be a secret written
/// down beside its own ciphertext. Appended to the password it is a *pepper* in
/// the term's proper sense: an offline attacker must guess it as well as the
/// PIN, and 32 bytes of it is not guessable at all.
///
/// The concatenation buffer is allocated at its exact final size, so the two
/// `extend`s cannot trigger a reallocation — a growth would copy the passphrase
/// into a fresh allocation and leave the old one un-wiped, which is the same
/// defect `SecretByteBuffer::_ensure` handles Dart-side.
fn derive_key(
    passphrase: &[u8],
    pepper: Option<&[u8]>,
    salt: &[u8],
    params: SealParams,
) -> Result<Zeroizing<[u8; 32]>> {
    let argon_params = Params::new(params.m_cost_kib, params.t_cost, params.p_cost, Some(32))?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, argon_params);
    let mut key = Zeroizing::new([0u8; 32]);
    match pepper {
        None => argon.hash_password_into(passphrase, salt, key.as_mut())?,
        Some(pepper) => {
            let mut input = Zeroizing::new(Vec::with_capacity(passphrase.len() + pepper.len()));
            input.extend_from_slice(passphrase);
            input.extend_from_slice(pepper);
            argon.hash_password_into(&input, salt, key.as_mut())?;
        }
    }
    Ok(key)
}

/// The pepper a caller offered, checked. `None` stays `None`; a wrong-length
/// pepper is refused rather than silently derived from — a truncated or padded
/// device secret would seal a vault this phone could never open again.
fn check_pepper(pepper: Option<&[u8]>) -> Result<Option<&[u8]>> {
    match pepper {
        None => Ok(None),
        Some(p) if p.len() == PEPPER_LEN => Ok(Some(p)),
        Some(_) => Err(CoreError::DeviceBinding("pepper length")),
    }
}

fn build_header(
    params: SealParams,
    salt: &[u8; SALT_LEN],
    nonce: &[u8; NONCE_LEN],
    input_kind: InputKind,
    device_bound: bool,
) -> [u8; HEADER_LEN_V2] {
    let mut header = [0u8; HEADER_LEN_V2];
    header[0..4].copy_from_slice(MAGIC);
    header[4] = VERSION_V2;
    header[5] = SCHEME_PATH_B;
    header[6..10].copy_from_slice(&params.m_cost_kib.to_le_bytes());
    header[10..14].copy_from_slice(&params.t_cost.to_le_bytes());
    header[14..18].copy_from_slice(&params.p_cost.to_le_bytes());
    header[18..34].copy_from_slice(salt);
    header[34..58].copy_from_slice(nonce);
    header[58] = input_kind.to_byte();
    header[59] = if device_bound {
        BINDING_DEVICE
    } else {
        BINDING_NONE
    };
    header
}

/// Parse and validate a blob's header, for either version. Returns the header
/// length, the KDF parameters (bounds-checked) and the plaintext facts.
///
/// Every structural refusal happens here, **before** any KDF runs.
fn parse_header(blob: &[u8]) -> Result<(usize, SealParams, BlobFacts)> {
    if blob.len() < HEADER_LEN_V1 {
        return Err(CoreError::MalformedBlob("too short"));
    }
    if &blob[0..4] != MAGIC {
        return Err(CoreError::MalformedBlob("magic"));
    }
    let (header_len, blob_len) = match blob[4] {
        VERSION_V1 => (HEADER_LEN_V1, BLOB_LEN_V1),
        VERSION_V2 => (HEADER_LEN_V2, BLOB_LEN),
        _ => return Err(CoreError::MalformedBlob("unknown version")),
    };
    if blob[5] != SCHEME_PATH_B {
        return Err(CoreError::MalformedBlob("unknown scheme"));
    }
    if blob.len() != blob_len {
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

    // A v1 vault predates the choice, so it is a passphrase and it is not
    // device-bound. Both are facts about the file, not defaults papering over
    // a missing field.
    let facts = if header_len == HEADER_LEN_V1 {
        BlobFacts {
            version: VERSION_V1,
            input_kind: InputKind::Passphrase,
            device_bound: false,
        }
    } else {
        BlobFacts {
            version: VERSION_V2,
            input_kind: InputKind::from_byte(blob[58])?,
            device_bound: match blob[59] {
                BINDING_NONE => false,
                BINDING_DEVICE => true,
                _ => return Err(CoreError::MalformedBlob("binding")),
            },
        }
    };
    Ok((header_len, params, facts))
}

/// Read a blob's plaintext facts — **no passphrase, no KDF, no authentication**.
///
/// The unlock screen calls this to decide which pad to draw first. That decision
/// is made from an unauthenticated byte on purpose: authenticating it would
/// require the secret the screen is about to ask for. The exposure is bounded by
/// the rule that outranks it — the screen always offers the other pad — so the
/// worst a tampered byte achieves is one wrong keyboard in front of a user who
/// can reach the right one in a tap.
pub fn read_facts(blob: &[u8]) -> Result<BlobFacts> {
    parse_header(blob).map(|(_, _, facts)| facts)
}

/// Seal the seed under a passphrase. Fresh random salt and nonce every call —
/// re-sealing the same seed never reuses either. Always writes **v2**.
///
/// `input_kind` records what the user typed so the unlock screen can offer it
/// again. `pepper`, when present, binds the blob to this device: the same
/// bytes must be supplied to [`unseal_seed`] or the vault does not open.
pub fn seal_seed(
    seed: &SecretSeed,
    passphrase: &[u8],
    params: SealParams,
    input_kind: InputKind,
    pepper: Option<&[u8]>,
) -> Result<Vec<u8>> {
    if passphrase.is_empty() {
        return Err(CoreError::EmptyPassphrase);
    }
    params.check_bounds()?;
    let pepper = check_pepper(pepper)?;
    // **A PIN vault cannot exist unbound, and the refusal lives HERE.**
    //
    // The bridge refuses it too, at the seam where the Keystore answer arrives.
    // But this is the function that writes the file, and a rule enforced only
    // one layer up is a rule the next caller of this layer does not have: an
    // unbound six-digit vault is 10^6 offline candidates at ~679 ms each, which
    // is precisely the attack the binding exists to close. The founder's
    // condition — the PIN and the hardware key ship together or neither ships —
    // is a property of the blob, so it is checked where the blob is made
    // (`consensus-auditor`, D-312).
    //
    // The LENGTH is checked here for the same reason. Both screens enforce six,
    // so a one-digit PIN is unreachable today; "unreachable today" is how a
    // rule that lives in a screen becomes a rule that lives nowhere.
    if input_kind == InputKind::Digits {
        if pepper.is_none() {
            return Err(CoreError::DeviceBinding(
                "a PIN vault needs a device binding",
            ));
        }
        if passphrase.len() != PIN_LEN || !passphrase.iter().all(u8::is_ascii_digit) {
            return Err(CoreError::MalformedBlob("pin shape"));
        }
    }

    let mut salt = [0u8; SALT_LEN];
    OsRng.fill_bytes(&mut salt);
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);
    let header = build_header(params, &salt, &nonce, input_kind, pepper.is_some());

    let key = derive_key(passphrase, pepper, &salt, params)?;
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

    // **Every seal re-opens its own output before returning it, with the key it
    // has already derived.**
    //
    // The migration needed this — a re-seal that cannot be re-opened must never
    // replace a working vault — and the obvious way to get it was to call
    // `unseal_seed` afterwards, which derives the key a SECOND time: another
    // full Argon2id at 192 MiB. On the founder's phone that turned a one-KDF
    // unlock into a three-KDF one, and he felt it (D-312's glass beat).
    //
    // Verifying here costs one XChaCha20 pass over 80 bytes — microseconds —
    // because the key is already in hand. It catches exactly what could go
    // wrong in this function: a header that is not the AAD it claims, an
    // off-by-one in the layout, a nonce written to the wrong offset. It does
    // NOT re-check the key derivation, and it is not claimed to: Argon2id over
    // fixed inputs is deterministic, and a "verification" that repeats a
    // deterministic function is a cost with no finding behind it.
    //
    // Unconditional, so it is the property of a SEAL rather than of the one
    // caller that remembered to ask. A vault this function returns is a vault
    // that has been opened once.
    let reopened = cipher
        .decrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &blob[HEADER_LEN_V2..],
                aad: &header,
            },
        )
        .map_err(|_| CoreError::Seal)?;
    let mut reopened = Zeroizing::new(reopened);
    if reopened.as_slice() != seed.as_bytes() {
        reopened.zeroize();
        return Err(CoreError::Seal);
    }

    Ok(blob)
}

/// Unseal a blob of either version. Errors distinguish *structure* problems
/// (`MalformedBlob`, `BlobParamBounds` — checked before the KDF runs) from
/// *authentication* failure (`WrongPassphraseOrCorrupt` — wrong passphrase and
/// corrupted data are cryptographically indistinguishable, and the error says
/// so) from a *missing device binding* (`DeviceBinding`, which is neither: the
/// secret may be perfectly correct and this phone still cannot open the file).
///
/// A `pepper` offered for a blob that is not device-bound is **ignored**, not
/// mixed in — otherwise every pre-D-312 vault would stop opening on the update
/// that introduced the pepper.
pub fn unseal_seed(blob: &[u8], passphrase: &[u8], pepper: Option<&[u8]>) -> Result<SecretSeed> {
    if passphrase.is_empty() {
        return Err(CoreError::EmptyPassphrase);
    }
    let (header_len, params, facts) = parse_header(blob)?;
    let pepper = check_pepper(pepper)?;
    let pepper = if facts.device_bound {
        Some(pepper.ok_or(CoreError::DeviceBinding("this vault is bound to its phone"))?)
    } else {
        None
    };

    let header = &blob[..header_len];
    let salt = &blob[18..34];
    let nonce = XNonce::from_slice(&blob[34..58]);

    let key = derive_key(passphrase, pepper, salt, params)?;
    let cipher = XChaCha20Poly1305::new(key.as_ref().into());
    let mut plaintext = cipher
        .decrypt(
            nonce,
            Payload {
                msg: &blob[header_len..],
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
        let blob = seal_seed(
            &test_seed(),
            b"correct horse",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        assert_eq!(blob.len(), BLOB_LEN);
        let seed = unseal_seed(&blob, b"correct horse", None).unwrap();
        assert_eq!(seed.as_bytes(), &[0x42u8; 64]);
    }

    #[test]
    fn fresh_salt_and_nonce_every_seal() {
        let a = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        let b = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        assert_ne!(a[18..34], b[18..34], "salt reused");
        assert_ne!(a[34..58], b[34..58], "nonce reused");
        assert_ne!(a[58..], b[58..], "ciphertext identical");
    }

    #[test]
    fn wrong_passphrase_fails_authentication() {
        let blob = seal_seed(
            &test_seed(),
            b"correct horse",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        match unseal_seed(&blob, b"incorrect horse", None) {
            Err(CoreError::WrongPassphraseOrCorrupt) => {}
            other => panic!("expected WrongPassphraseOrCorrupt, got {other:?}"),
        }
    }

    #[test]
    fn corrupted_header_fails_authentication() {
        let mut blob = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        blob[20] ^= 0x01; // flip a salt bit — header is AAD
        match unseal_seed(&blob, b"pw", None) {
            // Salt feeds the KDF too, so this surfaces as an auth failure.
            Err(CoreError::WrongPassphraseOrCorrupt) => {}
            other => panic!("expected WrongPassphraseOrCorrupt, got {other:?}"),
        }
    }

    #[test]
    fn corrupted_ciphertext_fails_authentication() {
        let mut blob = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 0x01;
        assert!(matches!(
            unseal_seed(&blob, b"pw", None),
            Err(CoreError::WrongPassphraseOrCorrupt)
        ));
    }

    #[test]
    fn truncated_and_malformed_blobs_are_rejected_before_the_kdf() {
        let blob = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();

        assert!(matches!(
            unseal_seed(&blob[..30], b"pw", None),
            Err(CoreError::MalformedBlob("too short"))
        ));
        assert!(matches!(
            unseal_seed(&blob[..BLOB_LEN - 1], b"pw", None),
            Err(CoreError::MalformedBlob("length"))
        ));

        let mut bad_magic = blob.clone();
        bad_magic[0] = b'X';
        assert!(matches!(
            unseal_seed(&bad_magic, b"pw", None),
            Err(CoreError::MalformedBlob("magic"))
        ));

        let mut bad_version = blob.clone();
        bad_version[4] = 9;
        assert!(matches!(
            unseal_seed(&bad_version, b"pw", None),
            Err(CoreError::MalformedBlob("unknown version"))
        ));

        let mut bad_scheme = blob;
        bad_scheme[5] = 0x01; // Path A is reserved, not unsealable here
        assert!(matches!(
            unseal_seed(&bad_scheme, b"pw", None),
            Err(CoreError::MalformedBlob("unknown scheme"))
        ));
    }

    #[test]
    fn hostile_kdf_params_are_refused_before_the_kdf_runs() {
        use std::time::Instant;
        let mut blob = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        blob[6..10].copy_from_slice(&u32::MAX.to_le_bytes()); // m_cost = 4 TiB
        let started = Instant::now();
        assert!(matches!(
            unseal_seed(&blob, b"pw", None),
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
            seal_seed(&test_seed(), b"", TEST_PARAMS, InputKind::Passphrase, None),
            Err(CoreError::EmptyPassphrase)
        ));
        let blob = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        assert!(matches!(
            unseal_seed(&blob, b"", None),
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
            seal_seed(&test_seed(), b"pw", too_small, InputKind::Passphrase, None),
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
            seal_seed(&test_seed(), b"pw", just_over, InputKind::Passphrase, None),
            Err(CoreError::BlobParamBounds)
        ));
        let one_gib = SealParams {
            m_cost_kib: 1024 * 1024,
            t_cost: 1,
            p_cost: 1,
        };
        assert!(matches!(
            seal_seed(&test_seed(), b"pw", one_gib, InputKind::Passphrase, None),
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
        let blob = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        for at in 0..blob.len() {
            let mut corrupt = blob.clone();
            corrupt[at] ^= 0x01;
            assert!(
                unseal_seed(&corrupt, b"pw", None).is_err(),
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
                unseal_seed(&bytes, b"pw", None).is_err(),
                "garbage case {i} unsealed"
            );
        }
        let blob = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        for cut in 0..blob.len() {
            assert!(
                unseal_seed(&blob[..cut], b"pw", None).is_err(),
                "truncation at {cut} unsealed"
            );
        }
    }

    // ── v2: the pad choice, and the device binding (D-312) ────────────────

    /// Seal a blob in the **v1 layout**, exactly as the pre-D-312 builder did.
    ///
    /// This is the only honest way to prove the migration read: a v1 blob
    /// produced by the current code is not evidence about the blobs already on
    /// people's phones. Fifty-eight header bytes, no input-kind, no binding.
    fn seal_v1(seed: &SecretSeed, passphrase: &[u8], params: SealParams) -> Vec<u8> {
        let mut salt = [0u8; SALT_LEN];
        OsRng.fill_bytes(&mut salt);
        let mut nonce = [0u8; NONCE_LEN];
        OsRng.fill_bytes(&mut nonce);
        let mut header = [0u8; HEADER_LEN_V1];
        header[0..4].copy_from_slice(MAGIC);
        header[4] = VERSION_V1;
        header[5] = SCHEME_PATH_B;
        header[6..10].copy_from_slice(&params.m_cost_kib.to_le_bytes());
        header[10..14].copy_from_slice(&params.t_cost.to_le_bytes());
        header[14..18].copy_from_slice(&params.p_cost.to_le_bytes());
        header[18..34].copy_from_slice(&salt);
        header[34..58].copy_from_slice(&nonce);
        let key = derive_key(passphrase, None, &salt, params).unwrap();
        let cipher = XChaCha20Poly1305::new(key.as_ref().into());
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: seed.as_bytes(),
                    aad: &header,
                },
            )
            .unwrap();
        let mut blob = Vec::with_capacity(BLOB_LEN_V1);
        blob.extend_from_slice(&header);
        blob.extend_from_slice(&ciphertext);
        blob
    }

    const TEST_PEPPER: [u8; PEPPER_LEN] = [0x5Au8; PEPPER_LEN];

    #[test]
    fn new_vaults_are_sealed_at_v2() {
        let blob = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        assert_eq!(blob.len(), BLOB_LEN);
        assert_eq!(blob[4], VERSION_V2);
        assert_eq!(
            read_facts(&blob).unwrap(),
            BlobFacts {
                version: VERSION_V2,
                input_kind: InputKind::Passphrase,
                device_bound: false,
            }
        );
    }

    /// **The whole point of putting the choice in the header.** The unlock
    /// screen has to know which pad to draw *before* it has the secret, so the
    /// kind must be readable with no passphrase and no KDF.
    #[test]
    fn the_pad_choice_is_readable_without_the_secret() {
        let blob = seal_seed(
            &test_seed(),
            b"123456",
            TEST_PARAMS,
            InputKind::Digits,
            Some(&TEST_PEPPER),
        )
        .unwrap();
        let facts = read_facts(&blob).unwrap();
        assert_eq!(facts.input_kind, InputKind::Digits);
        assert!(facts.device_bound);
        // …and it survives the round trip, so the byte describes the blob it
        // is inside rather than whatever the app last remembered.
        assert!(unseal_seed(&blob, b"123456", Some(&TEST_PEPPER)).is_ok());
    }

    /// **The migration read.** A vault sealed before D-312 — the one on the
    /// founder's own phone — must open unchanged on the binary that introduced
    /// v2, with the same passphrase and nothing else.
    #[test]
    fn a_v1_blob_still_opens_with_its_own_passphrase() {
        let blob = seal_v1(&test_seed(), b"correct horse", TEST_PARAMS);
        assert_eq!(blob.len(), BLOB_LEN_V1);
        assert_eq!(blob[4], VERSION_V1);
        assert_eq!(
            read_facts(&blob).unwrap(),
            BlobFacts {
                version: VERSION_V1,
                input_kind: InputKind::Passphrase,
                device_bound: false,
            }
        );
        let seed = unseal_seed(&blob, b"correct horse", None).unwrap();
        assert_eq!(seed.as_bytes(), &[0x42u8; 64]);
    }

    /// **A pepper offered to a blob that is not bound must be IGNORED.**
    ///
    /// This is the migration's second half and the subtler one. The update that
    /// introduces the pepper will have it in hand at every unlock; if it were
    /// mixed in unconditionally, every vault sealed before D-312 would stop
    /// opening on the update that shipped it — a silent, total lockout of every
    /// existing user, indistinguishable from a wrong passphrase.
    #[test]
    fn a_pepper_does_not_change_an_unbound_vault() {
        let v1 = seal_v1(&test_seed(), b"pw", TEST_PARAMS);
        assert!(unseal_seed(&v1, b"pw", Some(&TEST_PEPPER)).is_ok());
        let v2 = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();
        assert!(unseal_seed(&v2, b"pw", Some(&TEST_PEPPER)).is_ok());
    }

    /// The binding, doing its job: the file alone is not enough.
    #[test]
    fn a_pin_vault_cannot_be_sealed_unbound_or_at_the_wrong_length() {
        // The rule the bridge also enforces, kept HERE because this is the
        // function that writes the file — and an unbound 6-digit vault is the
        // exact attack the binding exists to close (`consensus-auditor`).
        assert!(matches!(
            seal_seed(
                &test_seed(),
                b"481902",
                TEST_PARAMS,
                InputKind::Digits,
                None
            ),
            Err(CoreError::DeviceBinding(_))
        ));
        for bad in [b"48190".as_slice(), b"4819023", b"48190a"] {
            assert!(
                matches!(
                    seal_seed(
                        &test_seed(),
                        bad,
                        TEST_PARAMS,
                        InputKind::Digits,
                        Some(&TEST_PEPPER)
                    ),
                    Err(CoreError::MalformedBlob("pin shape"))
                ),
                "{:?} sealed as a PIN",
                String::from_utf8_lossy(bad)
            );
        }
        // A passphrase is subject to neither rule — any length, any bytes, and
        // the binding is a bonus rather than a precondition.
        assert!(seal_seed(&test_seed(), b"x", TEST_PARAMS, InputKind::Passphrase, None).is_ok());
    }

    #[test]
    fn a_bound_vault_will_not_open_without_its_pepper() {
        let blob = seal_seed(
            &test_seed(),
            b"123456",
            TEST_PARAMS,
            InputKind::Digits,
            Some(&TEST_PEPPER),
        )
        .unwrap();
        // Not `WrongPassphraseOrCorrupt`: the PIN is right and the file is
        // intact. Saying "wrong passphrase" here would send a user to retype a
        // secret that was never the problem.
        match unseal_seed(&blob, b"123456", None) {
            Err(CoreError::DeviceBinding(_)) => {}
            other => panic!("expected DeviceBinding, got {other:?}"),
        }
        // A different phone's pepper IS an authentication failure — it is
        // cryptographically indistinguishable from a wrong secret, and the
        // error does not pretend otherwise.
        let other_phone = [0xA5u8; PEPPER_LEN];
        assert!(matches!(
            unseal_seed(&blob, b"123456", Some(&other_phone)),
            Err(CoreError::WrongPassphraseOrCorrupt)
        ));
    }

    /// A truncated or padded pepper is refused rather than derived from — a
    /// wrong-length device secret would seal a vault this phone could never
    /// open again, and the KDF would happily accept it.
    #[test]
    fn a_wrong_length_pepper_is_refused_on_both_paths() {
        assert!(matches!(
            seal_seed(
                &test_seed(),
                b"481902",
                TEST_PARAMS,
                InputKind::Digits,
                Some(&[0u8; 16])
            ),
            Err(CoreError::DeviceBinding("pepper length"))
        ));
        let blob = seal_seed(
            &test_seed(),
            b"481902",
            TEST_PARAMS,
            InputKind::Digits,
            Some(&TEST_PEPPER),
        )
        .unwrap();
        assert!(matches!(
            unseal_seed(&blob, b"481902", Some(&[0u8; 33])),
            Err(CoreError::DeviceBinding("pepper length"))
        ));
    }

    /// The two new header bytes are parsed, not assumed — an unknown value in
    /// either is a structural refusal before the KDF, like every other header
    /// field.
    #[test]
    fn unknown_input_kind_or_binding_is_malformed() {
        let good = seal_seed(
            &test_seed(),
            b"pw",
            TEST_PARAMS,
            InputKind::Passphrase,
            None,
        )
        .unwrap();

        let mut bad_kind = good.clone();
        bad_kind[58] = 9;
        assert!(matches!(
            unseal_seed(&bad_kind, b"pw", None),
            Err(CoreError::MalformedBlob("input kind"))
        ));

        let mut bad_binding = good;
        bad_binding[59] = 9;
        assert!(matches!(
            unseal_seed(&bad_binding, b"pw", None),
            Err(CoreError::MalformedBlob("binding"))
        ));
    }

    /// A v1 blob padded to v2's length, and a v2 blob truncated to v1's, are
    /// both refused: the version byte decides the length, and the length is
    /// checked against it.
    #[test]
    fn the_version_byte_decides_the_length() {
        let v1 = seal_v1(&test_seed(), b"pw", TEST_PARAMS);
        let mut padded = v1.clone();
        padded.extend_from_slice(&[0u8, 0u8]);
        assert!(matches!(
            unseal_seed(&padded, b"pw", None),
            Err(CoreError::MalformedBlob("length"))
        ));

        let mut claims_v2 = v1;
        claims_v2[4] = VERSION_V2;
        assert!(matches!(
            unseal_seed(&claims_v2, b"pw", None),
            Err(CoreError::MalformedBlob("length"))
        ));
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
            let blob = seal_seed(&test_seed(), b"pw", params, InputKind::Passphrase, None).unwrap();
            let seed = unseal_seed(&blob, b"pw", None).unwrap();
            assert_eq!(seed.as_bytes(), &[0x42u8; 64], "corner t={t} p={p}");
        }
    }
}
