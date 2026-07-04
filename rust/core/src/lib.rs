//! kaspaverse-core — keys, vault, signing.
//!
//! The custody engine (P1.1). Every secret type is `ZeroizeOnDrop`, signing
//! never leaves this crate, and nothing secret crosses the FFI boundary in
//! either direction (INV-1/2/3). The flow:
//!
//! ```text
//! create:  MnemonicCeremony::generate() ─┐
//! restore: MnemonicCeremony::restore()  ─┴─ into_seed(extra_word) → SecretSeed
//!          SecretSeed ─ seal_seed() → blob (at rest)         [vault.rs]
//!          blob ─ unseal_seed() → SecretSeed                 [vault.rs]
//!          SecretSeed → KeyChain → UnlockedVault → VaultSigner (SignerT)
//! ```
//!
//! Consensus and derivation logic comes from the pinned rusty-kaspa crates
//! (INV-9); this crate adds custody policy only. No FFI exposure here —
//! `rust/bridge` consumes the public API from P1.2 on.

// Keys and signing are pure Rust; if a dependency ever demands unsafe here,
// that is a design smell to escalate, not a lint to relax.
#![forbid(unsafe_code)]

pub mod error;
pub mod keychain;
pub mod mnemonic;
pub mod seed;
pub mod signer;
pub mod transport_crypto;
pub mod vault;

pub use error::{CoreError, Result};
pub use keychain::{Branch, KeyChain};
pub use mnemonic::MnemonicCeremony;
pub use seed::SecretSeed;
pub use signer::{UnlockedVault, VaultSigner};
pub use vault::{seal_seed, unseal_seed, SealParams, BLOB_LEN};

// Re-exported so callers name the network without depending on the kaspa
// crates directly.
pub use kaspa_addresses::Prefix;
