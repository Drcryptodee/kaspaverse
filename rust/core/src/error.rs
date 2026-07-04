use std::fmt;

/// Custody-layer error. **Never carries secret material**: variants hold
/// public context only — no key bytes, no phrase fragments, no derived
/// values (INV-2). Display output is safe for logs and FFI error strings.
#[derive(Debug)]
pub enum CoreError {
    /// BIP32/BIP39 failure from the pinned crates (bad checksum, unknown
    /// word, derivation depth, …). Boxed to keep `Result` slim
    /// (clippy::result_large_err — same treatment as `ChainError`).
    Bip32(Box<kaspa_bip32::Error>),
    /// Derivation-manager failure from the pinned wallet-keys crate.
    Keys(Box<kaspa_wallet_keys::error::Error>),
    /// Mnemonic word count not supported (create = 12; restore = 12 or 24,
    /// D-028). Carries the offending count — counts are not secret.
    WordCount(usize),
    /// Restore phrase was not valid UTF-8.
    PhraseEncoding,
    /// Extra word (13th/25th) was not valid UTF-8.
    ExtraWordEncoding,
    /// Vault passphrase must not be empty (Path B fallback always exists).
    EmptyPassphrase,
    /// Argon2id parameter or execution failure.
    Kdf(argon2::Error),
    /// Sealed blob is malformed: wrong magic, version, scheme, or length.
    /// The reason names the field, never its value.
    MalformedBlob(&'static str),
    /// Blob KDF parameters outside sane bounds — possible tampering or
    /// corruption; refused *before* the KDF runs (memory-DoS guard).
    BlobParamBounds,
    /// AEAD open failed: wrong passphrase or corrupted blob — the two are
    /// cryptographically indistinguishable, and the message says so.
    WrongPassphraseOrCorrupt,
    /// AEAD seal failed (should not happen with valid inputs).
    Seal,
    /// Signing was requested for an address never registered with this
    /// signer. Addresses are public data.
    UnknownAddress(String),
    /// The vault has been locked (lifecycle drop) — secrets are gone;
    /// re-unlock to continue.
    VaultLocked,
    /// Transaction signing failed in the pinned consensus crate.
    Signing(String),
    /// Transport envelope failed structural parsing: wrong length or
    /// ephemeral-key tag. The reason names the field, never its value.
    MalformedEnvelope(&'static str),
    /// Key material handed to the transport cipher was invalid (not a curve
    /// point / not a valid scalar). Carries the parameter name only.
    TransportKey(&'static str),
    /// Transport AEAD open failed: wrong key or tampered envelope — the two
    /// are cryptographically indistinguishable, and the message says so.
    TransportOpen,
    /// Transport encrypt/KDF failed (should not happen with valid inputs).
    TransportSeal,
    /// Decrypted handshake plaintext failed the live receiver's shape law
    /// (bad JSON, malformed alias, unsupported version). The reason names the
    /// field, never its value — plaintext never enters an error (§0.4).
    HandshakeShape(&'static str),
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Bip32(e) => write!(f, "bip32: {e}"),
            Self::Keys(e) => write!(f, "derivation: {e}"),
            Self::WordCount(n) => {
                write!(
                    f,
                    "unsupported mnemonic length: {n} words (expected 12 or 24)"
                )
            }
            Self::PhraseEncoding => f.write_str("mnemonic phrase is not valid UTF-8"),
            Self::ExtraWordEncoding => f.write_str("extra word is not valid UTF-8"),
            Self::EmptyPassphrase => f.write_str("vault passphrase must not be empty"),
            Self::Kdf(e) => write!(f, "key derivation (Argon2id): {e}"),
            Self::MalformedBlob(what) => write!(f, "sealed blob malformed: {what}"),
            Self::BlobParamBounds => {
                f.write_str("sealed blob KDF parameters out of bounds (tampered or corrupted)")
            }
            Self::WrongPassphraseOrCorrupt => {
                f.write_str("wrong passphrase or corrupted vault data")
            }
            Self::Seal => f.write_str("vault seal failed"),
            Self::UnknownAddress(addr) => {
                write!(f, "address not registered with this signer: {addr}")
            }
            Self::VaultLocked => f.write_str("vault is locked"),
            Self::Signing(e) => write!(f, "signing: {e}"),
            Self::MalformedEnvelope(what) => write!(f, "transport envelope malformed: {what}"),
            Self::TransportKey(what) => write!(f, "transport cipher key invalid: {what}"),
            Self::TransportOpen => {
                f.write_str("transport decrypt failed: wrong key or tampered envelope")
            }
            Self::TransportSeal => f.write_str("transport encrypt failed"),
            Self::HandshakeShape(what) => write!(f, "handshake payload malformed: {what}"),
        }
    }
}

impl std::error::Error for CoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Bip32(e) => Some(e.as_ref()),
            Self::Keys(e) => Some(e.as_ref()),
            _ => None,
        }
    }
}

impl From<kaspa_bip32::Error> for CoreError {
    fn from(e: kaspa_bip32::Error) -> Self {
        Self::Bip32(Box::new(e))
    }
}

impl From<kaspa_wallet_keys::error::Error> for CoreError {
    fn from(e: kaspa_wallet_keys::error::Error) -> Self {
        Self::Keys(Box::new(e))
    }
}

impl From<argon2::Error> for CoreError {
    fn from(e: argon2::Error) -> Self {
        Self::Kdf(e)
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;
