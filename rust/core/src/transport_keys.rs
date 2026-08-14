//! The vault-scoped transport decrypt seam (P2.3 §0.4/§0.7).
//!
//! [`TransportDecryptor`] is to [`crate::transport_crypto::decrypt`] what
//! [`crate::VaultSigner`] is to signing: a `Weak<KeyChain>` handle the bridge
//! can hold, whose every operation starts with an upgrade that fails
//! `VaultLocked` once the vault drops (the D-031 kill-switch contract,
//! inherited verbatim). The raw 32-byte scalar exists only INSIDE a call, in
//! a `Zeroizing` buffer — the bridge never touches key bytes (INV-1).
//!
//! Two entry points:
//! - [`TransportDecryptor::decrypt_at`] — a conversation's BOUND address key
//!   (§0.7: conversations bind to the key they were established with, so the
//!   carried receive-rotation item can never break existing threads).
//! - [`TransportDecryptor::decrypt_scanning`] — the establishment path: an
//!   inbound envelope's key slot is unknown until one of our watched window's
//!   keys opens it (the counterparty encrypts to whichever of our addresses
//!   it resolved — return-address resolution on their side may land on any
//!   watched slot). First success returns the slot; that slot becomes the
//!   §0.7 binding. Only ever on scan-matched envelopes (sparse by
//!   construction).
//!
//!   **An attempt is a key derivation, not a cheap ECDH.** This doc used to
//!   price the scan at "~60 attempts, microseconds each" off a window that was
//!   a fixed 30+30; since address discovery (2026-08-12) the window is the
//!   *discovered* one and grows with the wallet, so the number is the caller's
//!   and the per-attempt cost is ours. Ours is now one `derive_child` per slot
//!   plus one master expansion and path walk **per branch** — it used to be all
//!   three per slot, which matters beyond CPU: at the pin `ExtendedPrivateKey`
//!   carries no `Drop`, so every intermediate is dropped un-wiped (pin
//!   behaviour; INV-9 says consume it, not fork it), and the only lever we own
//!   is how many we create.
//!
//!   Narrowing the window is NOT the lever, however tempting. A sender resolves
//!   our return address with `get_utxo_return_address`, which answers with the
//!   address behind input[0] of a transaction we broadcast — routinely one of
//!   our CHANGE addresses. `scanning_finds_the_slot_and_becomes_the_binding`
//!   below seals to `change/2` for precisely that reason. A receive-only scan
//!   drops those envelopes silently and the conversation can never open.
//!
//! Decrypted plaintext leaves as `Zeroizing<Vec<u8>>` and is user content
//! post-decrypt (INV-1 as amended D-056) — never logged, never persisted
//! (§0.4; the at-rest form is always the envelope).

use crate::error::{CoreError, Result};
use crate::keychain::{Branch, KeyChain};
use crate::signer::UnlockedVault;
use crate::transport_crypto::{decrypt, Envelope};
use kaspa_bip32::{ExtendedPrivateKey, SecretKey};
use std::fmt;
use std::sync::Weak;
use zeroize::Zeroizing;

/// A derivation slot in the watched window: the §0.7 binding unit.
pub type KeySlot = (Branch, u32);

/// Vault-gated decryptor for transport envelopes. Holds only a weak keychain
/// reference — it cannot keep the vault alive past `lock()`.
pub struct TransportDecryptor {
    keychain: Weak<KeyChain>,
}

impl UnlockedVault {
    /// A transport decryptor holding only a weak reference — same lifecycle
    /// contract as [`UnlockedVault::signer`].
    pub fn transport_decryptor(&self) -> TransportDecryptor {
        TransportDecryptor {
            keychain: self.downgrade_keychain(),
        }
    }
}

impl fmt::Debug for TransportDecryptor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "TransportDecryptor(live: {}, keys redacted)",
            self.is_live()
        )
    }
}

impl TransportDecryptor {
    /// Decrypt with the conversation's bound key slot.
    pub fn decrypt_at(&self, slot: KeySlot, envelope: &Envelope) -> Result<Zeroizing<Vec<u8>>> {
        let keychain = self.keychain.upgrade().ok_or(CoreError::VaultLocked)?;
        let key = keychain.private_key_bytes(slot.0, slot.1)?;
        decrypt(envelope, &key)
    }

    /// Try every slot in `window` until one opens the envelope; returns the
    /// winning slot (the §0.7 binding) with the plaintext. `TransportOpen`
    /// when no watched key opens it — the envelope is not for us.
    pub fn decrypt_scanning(
        &self,
        window: impl IntoIterator<Item = KeySlot>,
        envelope: &Envelope,
    ) -> Result<(KeySlot, Zeroizing<Vec<u8>>)> {
        let keychain = self.keychain.upgrade().ok_or(CoreError::VaultLocked)?;
        // The branch key is derived once per branch, not once per slot: the
        // master-seed expansion and the path walk do not vary with the index,
        // and each one the pin builds is an extended private key it drops
        // un-wiped. A scan over a discovery-sized window used to pay for three
        // of them per slot tried.
        let mut branch_keys: Vec<(Branch, ExtendedPrivateKey<SecretKey>)> = Vec::with_capacity(2);
        for slot in window {
            let branch_key = match branch_keys.iter().find(|(b, _)| *b == slot.0) {
                Some((_, key)) => key,
                None => {
                    let key = keychain.branch_key(slot.0)?;
                    branch_keys.push((slot.0, key));
                    &branch_keys[branch_keys.len() - 1].1
                }
            };
            let key = KeyChain::child_key_bytes(branch_key, slot.1)?;
            match decrypt(envelope, &key) {
                Ok(plaintext) => return Ok((slot, plaintext)),
                // Wrong key — structurally indistinguishable from tamper;
                // keep scanning (the next slot may be the recipient).
                Err(CoreError::TransportOpen) => continue,
                Err(other) => return Err(other),
            }
        }
        Err(CoreError::TransportOpen)
    }

    /// The authorship tag over a self-stash plaintext (D-138).
    ///
    /// **What this exists to prove.** A stash is sealed to our own x-only
    /// PUBLIC key, so anyone who knows our receive address can produce one our
    /// key opens — decryptability is confidentiality, never authorship. Since a
    /// restore CREATES conversations from stash rows, an unauthenticated row
    /// from a hostile archive would become a live conversation carrying the
    /// attacker's address, and every message the user sent in it would be
    /// sealed to them. This tag is keyed by material only the seed holder can
    /// derive, so no archive can mint one.
    ///
    /// Two-step, and the first step is not decoration: the raw derived scalar is
    /// never used directly as a MAC key over attacker-influenced bytes. A fixed
    /// domain label expands it into a purpose-bound key first, so this tag can
    /// never be confused with — or used to attack — any other use of that key.
    ///
    /// **`Hmac`, never `SimpleHmac`, and the difference is a key-retention bug.**
    /// At the pin, `SimpleHmac::new_from_slice` stores `opad_key = key ^ 0x5c`
    /// in the struct, and `hmac` 0.12.1 gives it neither `Drop` nor `Zeroize` —
    /// so keying it with the receive/0 scalar would leave that scalar,
    /// trivially recoverable, in freed memory after every backup, **outliving
    /// `lock()`** and defeating the kill switch that
    /// `lock_is_a_kill_switch_for_outstanding_decryptors` exists to prove. The
    /// eager `Hmac` retains only a SHA-256 midstate, which is one-way. This is
    /// the same choice `transport_crypto::hkdf_sha256_32` already makes; it was
    /// caught here by a re-audit of this very function, whose first version had
    /// the wrong one AND a doc comment claiming otherwise.
    ///
    /// INV-1 posture is [`Self::decrypt_at`]'s: the scalar exists only inside
    /// this call, in a `Zeroizing` buffer, and only 32 bytes of MAC output
    /// leave.
    pub fn stash_tag(&self, plaintext: &[u8]) -> Result<[u8; 32]> {
        use hmac::Mac;
        let mut mac = self.stash_mac()?;
        mac.update(plaintext);
        Ok(mac.finalize().into_bytes().into())
    }

    /// Verify a tag in constant time.
    ///
    /// Separate from [`Self::stash_tag`] so the comparison rides `hmac`'s own
    /// `verify_slice` rather than a `[u8; 32]` `==`, which short-circuits on the
    /// first differing byte. No attacker has a usable timing oracle on this
    /// path — each probe costs an on-chain transaction — but a MAC comparison in
    /// a wallet is not the place to rely on that argument.
    pub fn verify_stash_tag(&self, plaintext: &[u8], tag: &[u8; 32]) -> Result<bool> {
        use hmac::Mac;
        let mut mac = self.stash_mac()?;
        mac.update(plaintext);
        Ok(mac.verify_slice(tag).is_ok())
    }

    /// The keyed MAC state both halves share (see [`Self::stash_tag`]).
    fn stash_mac(&self) -> Result<hmac::Hmac<sha2::Sha256>> {
        use hmac::{Hmac, Mac};
        use sha2::Sha256;

        const DOMAIN: &[u8] = b"kaspaverse/self_stash/v1";

        let keychain = self.keychain.upgrade().ok_or(CoreError::VaultLocked)?;
        // receive/0: the address a restore can derive before anything else
        // exists, and the one the stash is funded from and sealed to.
        let scalar = keychain.private_key_bytes(Branch::Receive, 0)?;

        let mut expand = <Hmac<Sha256> as Mac>::new_from_slice(scalar.as_slice())
            .map_err(|_| CoreError::TransportSeal)?;
        expand.update(DOMAIN);
        let mac_key = Zeroizing::new(expand.finalize().into_bytes());

        <Hmac<Sha256> as Mac>::new_from_slice(mac_key.as_slice())
            .map_err(|_| CoreError::TransportSeal)
    }

    /// Whether the vault behind this decryptor is still unlocked.
    pub fn is_live(&self) -> bool {
        self.keychain.strong_count() > 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mnemonic::MnemonicCeremony;
    use crate::transport_crypto::encrypt;
    use kaspa_addresses::Prefix;

    fn unlocked_vault() -> UnlockedVault {
        let seed = MnemonicCeremony::generate()
            .unwrap()
            .into_seed(b"")
            .unwrap();
        UnlockedVault::new(KeyChain::from_seed(seed, Prefix::Mainnet).unwrap())
    }

    /// The x-only pubkey of a derived address IS its payload (Schnorr
    /// version-0 addresses) — the property the whole encrypt side rests on.
    fn x_only_of(vault: &UnlockedVault, slot: KeySlot) -> [u8; 32] {
        let address = vault.keychain().address(slot.0, slot.1).unwrap();
        address.payload.as_ref().try_into().unwrap()
    }

    #[test]
    fn decrypt_at_opens_what_was_sealed_to_the_bound_address() {
        let vault = unlocked_vault();
        let slot: KeySlot = (Branch::Receive, 0);
        let envelope = encrypt(&x_only_of(&vault, slot), b"bound-slot message").unwrap();
        let plaintext = vault
            .transport_decryptor()
            .decrypt_at(slot, &envelope)
            .unwrap();
        assert_eq!(plaintext.as_slice(), b"bound-slot message");
    }

    #[test]
    fn scanning_finds_the_slot_and_becomes_the_binding() {
        let vault = unlocked_vault();
        // Sealed to change/2 — an establishment path where the counterparty
        // resolved one of our change addresses as the return address.
        let target: KeySlot = (Branch::Change, 2);
        let envelope = encrypt(&x_only_of(&vault, target), b"establish me").unwrap();

        let window = (0..5)
            .map(|i| (Branch::Receive, i))
            .chain((0..5).map(|i| (Branch::Change, i)));
        let (slot, plaintext) = vault
            .transport_decryptor()
            .decrypt_scanning(window, &envelope)
            .unwrap();
        assert_eq!(slot, target);
        assert_eq!(plaintext.as_slice(), b"establish me");
    }

    #[test]
    fn scanning_reports_not_ours_when_no_key_opens() {
        let vault = unlocked_vault();
        let stranger = unlocked_vault();
        let envelope = encrypt(&x_only_of(&stranger, (Branch::Receive, 0)), b"not ours").unwrap();
        assert!(matches!(
            vault
                .transport_decryptor()
                .decrypt_scanning((0..3).map(|i| (Branch::Receive, i)), &envelope),
            Err(CoreError::TransportOpen)
        ));
    }

    #[test]
    fn lock_is_a_kill_switch_for_outstanding_decryptors() {
        let vault = unlocked_vault();
        let slot: KeySlot = (Branch::Receive, 0);
        let envelope = encrypt(&x_only_of(&vault, slot), b"locked away").unwrap();
        let decryptor = vault.transport_decryptor();
        assert!(decryptor.is_live());

        vault.lock();

        assert!(!decryptor.is_live());
        assert!(matches!(
            decryptor.decrypt_at(slot, &envelope),
            Err(CoreError::VaultLocked)
        ));
        assert!(matches!(
            decryptor.decrypt_scanning([slot], &envelope),
            Err(CoreError::VaultLocked)
        ));
    }

    /// THE D-138 AUTHORSHIP PROPERTY, stated as a test.
    ///
    /// A stranger who knows our receive address can seal a stash our key opens
    /// — that is what public-key encryption means, and it is why the first cut
    /// of this lane was wrong to treat a successful decrypt as proof we wrote
    /// the row. The tag is what a stranger cannot produce.
    #[test]
    fn a_stranger_cannot_forge_our_stash_tag() {
        let ours = unlocked_vault();
        let stranger = unlocked_vault();
        let payload = br#"{"alias":"fa6d1afa79e1","partnerAddress":"kaspa:attacker"}"#;

        let our_tag = ours.transport_decryptor().stash_tag(payload).unwrap();
        let their_tag = stranger.transport_decryptor().stash_tag(payload).unwrap();
        assert_ne!(
            our_tag, their_tag,
            "a different seed must never produce our tag"
        );

        // Deterministic for us — a restore of the same seed re-derives it.
        assert_eq!(
            ours.transport_decryptor().stash_tag(payload).unwrap(),
            our_tag
        );

        // One flipped byte invalidates it.
        let tampered = br#"{"alias":"fa6d1afa79e1","partnerAddress":"kaspa:attackeR"}"#;
        assert_ne!(
            ours.transport_decryptor().stash_tag(tampered).unwrap(),
            our_tag
        );

        // And the constant-time verifier agrees with the computed tag both ways.
        let decryptor = ours.transport_decryptor();
        assert!(decryptor.verify_stash_tag(payload, &our_tag).unwrap());
        assert!(!decryptor.verify_stash_tag(tampered, &our_tag).unwrap());
        assert!(!decryptor.verify_stash_tag(payload, &their_tag).unwrap());
    }

    /// The MAC must NOT retain the receive/0 scalar in recoverable form.
    ///
    /// `hmac`'s `SimpleHmac` stores `key ^ 0x5c` with no `Drop` and no
    /// `Zeroize`, so keying it with the wallet's identity scalar would leave
    /// that scalar in freed memory after every backup — surviving `lock()` and
    /// defeating the kill switch the test above proves. The eager `Hmac`
    /// retains only a one-way SHA-256 midstate. This pins the choice, because
    /// the two types are one identifier apart and swap silently.
    #[test]
    fn the_stash_mac_keeps_no_recoverable_copy_of_the_key() {
        let vault = unlocked_vault();
        // A TYPE PIN, and it is load-bearing. `hmac`'s `SimpleHmac` retains
        // `key ^ 0x5c` with neither `Drop` nor `Zeroize`, so keying it with the
        // receive/0 scalar would leave that scalar recoverable in freed memory
        // after every backup — surviving `lock()` and defeating the kill switch
        // the test above proves. The eager `Hmac` keeps only a one-way SHA-256
        // midstate. The two are one identifier apart and swap silently, so the
        // choice is asserted by the compiler rather than by a comment.
        let _pinned: hmac::Hmac<sha2::Sha256> = vault.transport_decryptor().stash_mac().unwrap();
    }

    /// The tag is a vault operation, so a locked vault must refuse it rather
    /// than return anything — the same kill-switch contract as decrypt.
    #[test]
    fn the_stash_tag_dies_with_the_vault() {
        let vault = unlocked_vault();
        let decryptor = vault.transport_decryptor();
        assert!(decryptor.stash_tag(b"x").is_ok());
        vault.lock();
        assert!(matches!(
            decryptor.stash_tag(b"x"),
            Err(CoreError::VaultLocked)
        ));
    }

    #[test]
    fn debug_is_opaque() {
        let rendered = format!("{:?}", unlocked_vault().transport_decryptor());
        assert!(rendered.contains("redacted"));
    }
}
