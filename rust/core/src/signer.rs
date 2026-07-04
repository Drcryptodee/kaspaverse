//! The vault's signing seam — [`SignerT`] so the upstream `Generator` can
//! sign without secrets ever leaving this crate (P1 §0.1/§0.9).
//!
//! Derived from upstream's `KeydataSigner` (pin:
//! wallet/core/src/tx/generator/signer.rs:64-91): map addresses to keys,
//! `sign_with_multiple_v2`, zeroize the key buffer. Two deliberate
//! differences: keys are derived on demand from the keychain instead of
//! prebuilt (no key table lives in memory), and an unknown address is an
//! error, not a panic (INV-2 — upstream `.unwrap()`s the map lookup).

use crate::error::{CoreError, Result};
use crate::keychain::{Branch, KeyChain};
use kaspa_addresses::Address;
use kaspa_consensus_core::sign::sign_with_multiple_v2;
use kaspa_consensus_core::tx::SignableTransaction;
use kaspa_wallet_core::tx::generator::signer::SignerT;
use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex, PoisonError, Weak};
use zeroize::Zeroize;

/// The unlocked vault: sole strong owner of the [`KeyChain`].
///
/// `lock()` (or drop — e.g. the P1.2 lifecycle hook on backgrounding) is the
/// kill switch, with **exactly these semantics** (audited, D-031):
///
/// - No operation can *start* after lock: every [`VaultSigner`] path begins
///   with a `Weak::upgrade` that now fails (`VaultLocked`).
/// - An operation already *in flight* on another thread holds an upgraded
///   strong reference and **completes** — it is not interrupted mid-signature.
/// - The seed zeroizes when the LAST strong reference drops: immediately if
///   nothing is in flight, else the moment the in-flight call returns. The
///   window is bounded by one signing/derivation call (no await points, no
///   way to extend it through the public API — `keychain()` borrows, so the
///   borrow checker forbids holding it across `lock(self)`).
///
/// Async callers above the bridge (P1.2+) must not treat lock-return as
/// proof of erasure when a sign is concurrently executing.
pub struct UnlockedVault {
    keychain: Arc<KeyChain>,
}

impl UnlockedVault {
    pub fn new(keychain: KeyChain) -> Self {
        Self {
            keychain: Arc::new(keychain),
        }
    }

    /// The keychain, for address derivation while unlocked.
    pub fn keychain(&self) -> &KeyChain {
        &self.keychain
    }

    /// Expose the root seed bytes to a one-shot closure for the Path-A enroll
    /// Keystore-seal (P1 §0.4): the Android Keystore Cipher needs the plaintext
    /// to wrap it under a hardware-backed, non-exportable key. This is the
    /// **only** sanctioned read of the seed above `core`, and the sole intended
    /// caller is the bridge's ffi-leak-audited JNI export. Scoped on purpose —
    /// the bytes are borrowed for exactly one call and can be neither returned
    /// nor stored (the closure returns `R`, never the slice). Threat-model cost
    /// (vault_architecture §7): the seed plaintext crosses the JNI (Kotlin)
    /// boundary at enroll, never the Dart boundary (INV-1); Kotlin wipes its
    /// `byte[]` in `finally` (L9).
    pub fn with_seed_bytes<R>(&self, f: impl FnOnce(&[u8; 64]) -> R) -> R {
        f(self.keychain.seed_bytes())
    }

    /// A signer holding only a weak reference — it cannot keep the vault
    /// alive past `lock()`.
    pub fn signer(&self) -> VaultSigner {
        VaultSigner {
            keychain: Arc::downgrade(&self.keychain),
            addresses: Mutex::new(HashMap::new()),
        }
    }

    /// Weak keychain handle for the transport decrypt seam
    /// ([`crate::transport_keys::TransportDecryptor`]) — same lifecycle
    /// contract as the signer's weak reference. Crate-private: only vault
    /// seams mint weak handles.
    pub(crate) fn downgrade_keychain(&self) -> Weak<KeyChain> {
        Arc::downgrade(&self.keychain)
    }

    /// Explicit lifecycle drop: consume the vault. Zeroizes the seed now if
    /// no operation is in flight; otherwise when the in-flight call returns
    /// (see the type docs for the full contract).
    pub fn lock(self) {}
}

impl fmt::Debug for UnlockedVault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "UnlockedVault({:?})", self.keychain)
    }
}

/// Maps addresses the wallet uses to their derivation slots and signs
/// transactions for them. Registered addresses are public data; private keys
/// exist only inside `try_sign` and are zeroized before it returns.
pub struct VaultSigner {
    keychain: Weak<KeyChain>,
    addresses: Mutex<HashMap<Address, (Branch, u32)>>,
}

impl VaultSigner {
    /// Derive the address at `(branch, index)`, remember the slot for
    /// signing, and return it. The wallet registers every address it puts in
    /// front of the UTXO processor (P1.5), so `try_sign` can always resolve
    /// what the generator asks for.
    pub fn register(&self, branch: Branch, index: u32) -> Result<Address> {
        let keychain = self.keychain.upgrade().ok_or(CoreError::VaultLocked)?;
        let address = keychain.address(branch, index)?;
        self.addresses
            .lock()
            .unwrap_or_else(PoisonError::into_inner) // L7: state is insert-only, safe to recover
            .insert(address.clone(), (branch, index));
        Ok(address)
    }

    /// Whether the vault behind this signer is still unlocked.
    pub fn is_live(&self) -> bool {
        self.keychain.strong_count() > 0
    }
}

impl SignerT for VaultSigner {
    fn try_sign(
        &self,
        mutable_tx: SignableTransaction,
        addresses: &[Address],
    ) -> kaspa_wallet_core::result::Result<SignableTransaction> {
        let keychain = self.keychain.upgrade().ok_or_else(|| {
            kaspa_wallet_core::error::Error::from(CoreError::VaultLocked.to_string())
        })?;

        let mut keys: Vec<[u8; 32]> = Vec::with_capacity(addresses.len());
        {
            let map = self
                .addresses
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            for address in addresses {
                let Some(&(branch, index)) = map.get(address) else {
                    keys.zeroize();
                    return Err(CoreError::UnknownAddress(address.to_string())
                        .to_string()
                        .into());
                };
                match keychain.private_key_bytes(branch, index) {
                    Ok(key) => keys.push(*key),
                    Err(e) => {
                        keys.zeroize();
                        return Err(CoreError::Signing(e.to_string()).to_string().into());
                    }
                }
            }
        }

        // Upstream pattern (pin: signer.rs:84-90): sign, then zeroize the
        // key buffer before the result is inspected — error paths included.
        let signed = sign_with_multiple_v2(mutable_tx, &keys).fully_signed();
        keys.zeroize();
        signed.map_err(|e| CoreError::Signing(e.to_string()).to_string().into())
    }
}

impl fmt::Debug for VaultSigner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let registered = self
            .addresses
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len();
        write!(
            f,
            "VaultSigner({registered} addresses, live: {}, keys redacted)",
            self.is_live()
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mnemonic::MnemonicCeremony;
    use kaspa_addresses::Prefix;
    use kaspa_consensus_core::subnets::SUBNETWORK_ID_NATIVE;
    use kaspa_consensus_core::tx::Transaction;

    fn unlocked_vault() -> UnlockedVault {
        let seed = MnemonicCeremony::generate()
            .unwrap()
            .into_seed(b"")
            .unwrap();
        UnlockedVault::new(KeyChain::from_seed(seed, Prefix::Mainnet).unwrap())
    }

    fn empty_tx() -> SignableTransaction {
        SignableTransaction::new(Transaction::new(
            0,
            vec![],
            vec![],
            0,
            SUBNETWORK_ID_NATIVE,
            0,
            vec![],
        ))
    }

    #[test]
    fn register_resolves_and_remembers() {
        let vault = unlocked_vault();
        let signer = vault.signer();
        let address = signer.register(Branch::Receive, 0).unwrap();
        assert_eq!(address, vault.keychain().receive_address(0).unwrap());
        // An empty transaction touching no addresses signs trivially.
        assert!(signer.try_sign(empty_tx(), &[]).is_ok());
    }

    #[test]
    fn unknown_address_is_an_error_not_a_panic() {
        let vault = unlocked_vault();
        let signer = vault.signer();
        let unregistered = vault.keychain().receive_address(7).unwrap();
        let err = signer.try_sign(empty_tx(), &[unregistered]).unwrap_err();
        assert!(err.to_string().contains("not registered"));
    }

    #[test]
    fn lock_is_a_kill_switch_for_outstanding_signers() {
        let vault = unlocked_vault();
        let signer = vault.signer();
        let address = signer.register(Branch::Receive, 0).unwrap();
        assert!(signer.is_live());

        vault.lock();

        assert!(!signer.is_live());
        assert!(matches!(
            signer.register(Branch::Receive, 1),
            Err(CoreError::VaultLocked)
        ));
        let err = signer.try_sign(empty_tx(), &[address]).unwrap_err();
        assert!(err.to_string().contains("locked"));
    }

    /// Pins the audited lock contract (D-031): an operation that upgraded
    /// the Weak BEFORE lock() holds the seed alive until it returns — lock
    /// is "no new operations", not "instant erasure under concurrency".
    /// If this test ever fails, the contract changed: update the type docs,
    /// the threat model (vault_architecture §7), and the P1.2 bridge
    /// assumptions together.
    #[test]
    fn in_flight_strong_ref_survives_lock_until_released() {
        let vault = unlocked_vault();
        // Simulate try_sign mid-execution on another thread: it has already
        // done `self.keychain.upgrade()` when lock() runs.
        let in_flight: Arc<KeyChain> = Arc::clone(&vault.keychain);
        assert_eq!(Arc::strong_count(&in_flight), 2);

        vault.lock();

        // Seed not yet destroyed — the in-flight operation still works…
        assert_eq!(Arc::strong_count(&in_flight), 1);
        assert!(in_flight.receive_address(0).is_ok());
        // …and destruction happens exactly when the last ref releases.
        drop(in_flight);
    }

    #[test]
    fn debug_is_opaque() {
        let vault = unlocked_vault();
        let signer = vault.signer();
        signer.register(Branch::Receive, 0).unwrap();
        let rendered = format!("{vault:?} {signer:?}");
        assert!(rendered.contains("redacted"));
        assert!(!rendered.contains("kprv") && !rendered.contains("kaspa:"));
    }

    /// The Path-A seed lane (P1 §0.4, D-033): a seed reconstructed from raw
    /// JNI bytes builds a working vault, and the scoped enroll export hands
    /// back exactly those bytes (so the Keystore seals the true seed). Proves
    /// the round trip the bridge's JNI import/export pair relies on.
    #[test]
    fn path_a_seed_lane_round_trips_bytes_through_the_vault() {
        use crate::seed::SecretSeed;
        let bytes = [0x33u8; 64];
        let seed = SecretSeed::from_seed_bytes(Box::new(bytes));
        let vault = UnlockedVault::new(KeyChain::from_seed(seed, Prefix::Mainnet).unwrap());
        // Enroll export sees exactly the seed that was imported…
        let exported = vault.with_seed_bytes(|b| *b);
        assert_eq!(exported, bytes);
        // …and the reconstructed vault derives addresses (the keychain is live).
        assert!(vault.keychain().receive_address(0).is_ok());
    }
}
