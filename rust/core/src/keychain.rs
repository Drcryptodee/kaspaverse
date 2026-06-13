//! Account derivation — gen1 `m/44'/111111'/0'`, BIP340 Schnorr addresses.
//!
//! Derived from the pinned crates' own code (INV-9), never re-implemented:
//! account-key construction mirrors `WalletDerivationManager::from_master_xprv`
//! (pin: wallet/keys/src/derivation/gen1/hd.rs:362) minus the string
//! round-trip, and private-key derivation mirrors upstream's
//! `PrivateKeyGenerator` (pin: wallet/keys/src/privkeygen.rs:26-56).
//! Address vectors in the tests are upstream's own (hd.rs:446+).

use crate::error::Result;
use crate::seed::SecretSeed;
use kaspa_addresses::{Address, Prefix};
use kaspa_bip32::{
    AddressType, ChildNumber, ExtendedPrivateKey, ExtendedPublicKey, PrivateKey, SecretKey,
    SecretKeyExt,
};
use kaspa_wallet_keys::derivation::gen1::{PubkeyDerivationManager, WalletDerivationManager};
use kaspa_wallet_keys::derivation::traits::WalletDerivationManagerTrait;
use std::fmt;
use zeroize::Zeroizing;

/// Which derivation branch an address belongs to (the BIP44 change level:
/// receive = 0, change = 1 — kaspium_analysis §6).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Branch {
    Receive,
    Change,
}

impl Branch {
    fn address_type(self) -> AddressType {
        match self {
            Branch::Receive => AddressType::Receive,
            Branch::Change => AddressType::Change,
        }
    }
}

/// The unlocked account: one seed, gen1 account 0, single-sig (P1 §0.2).
///
/// Holds exactly one long-lived secret — the [`SecretSeed`], zeroized on
/// drop. Address derivation runs on the public side (a pubkey-only
/// `WalletDerivationManager`); private keys are derived transiently per
/// signing call and zeroized after. The extended-key values that exist
/// briefly *during* a derivation are upstream types that do not self-zeroize
/// — a property shared by every rusty-kaspa wallet, recorded in the threat
/// model (vault_architecture §7).
pub struct KeyChain {
    seed: SecretSeed,
    derivation: WalletDerivationManager,
    prefix: Prefix,
}

impl KeyChain {
    /// Build from a seed for the given network prefix.
    pub fn from_seed(seed: SecretSeed, prefix: Prefix) -> Result<Self> {
        // Mirror of from_master_xprv (pin: gen1/hd.rs:362-373) without
        // serializing the master key to a string.
        let master = ExtendedPrivateKey::<SecretKey>::new(seed.as_bytes())?;
        let (account_key, attrs) =
            WalletDerivationManager::derive_extended_key_from_master_key(master, false, 0)?;
        let xpub = ExtendedPublicKey {
            public_key: account_key.get_public_key(),
            attrs,
        };
        let derivation = WalletDerivationManager::from_extended_public_key(xpub, None)?;
        Ok(Self {
            seed,
            derivation,
            prefix,
        })
    }

    /// Derive the address at `(branch, index)` — Schnorr x-only payload,
    /// version byte 0x00 (kaspium_analysis §5; `create_address` with
    /// `ecdsa = false`, pin: gen1/hd.rs:63-73).
    pub fn address(&self, branch: Branch, index: u32) -> Result<Address> {
        let manager = match branch {
            Branch::Receive => self.derivation.receive_pubkey_manager(),
            Branch::Change => self.derivation.change_pubkey_manager(),
        };
        let pubkey = manager.derive_pubkey(index)?;
        Ok(PubkeyDerivationManager::create_address(
            &pubkey,
            self.prefix,
            false,
        )?)
    }

    pub fn receive_address(&self, index: u32) -> Result<Address> {
        self.address(Branch::Receive, index)
    }

    pub fn change_address(&self, index: u32) -> Result<Address> {
        self.address(Branch::Change, index)
    }

    /// Account-level extended public key (`kpub…`). Public material — it
    /// cannot spend — but it is privacy-sensitive (reveals all addresses):
    /// for vectors and future watch-only export, not for casual display.
    pub fn account_xpub(&self) -> String {
        self.derivation.to_string(None).to_string()
    }

    /// Network prefix this keychain derives addresses for.
    pub fn prefix(&self) -> Prefix {
        self.prefix
    }

    /// The root seed bytes, for the Path-A enroll export only (P1 §0.4).
    /// Crate-private and routed exclusively through
    /// [`UnlockedVault::with_seed_bytes`], which scopes the borrow to one
    /// closure call so the bytes can never be stored or returned.
    pub(crate) fn seed_bytes(&self) -> &[u8; 64] {
        self.seed.as_bytes()
    }

    /// Derive the raw private key for `(branch, index)`; the returned buffer
    /// zeroizes on drop. Mirror of upstream `PrivateKeyGenerator`
    /// (pin: privkeygen.rs:26-56). Crate-private: only the signer calls this.
    pub(crate) fn private_key_bytes(
        &self,
        branch: Branch,
        index: u32,
    ) -> Result<Zeroizing<[u8; 32]>> {
        let master = ExtendedPrivateKey::<SecretKey>::new(self.seed.as_bytes())?;
        let path = WalletDerivationManager::build_derivate_path(
            false,
            0,
            None,
            Some(branch.address_type()),
        )?;
        let branch_key = master.derive_path(&path)?;
        let child = branch_key.derive_child(ChildNumber::new(index, false)?)?;
        Ok(Zeroizing::new(child.private_key().to_bytes()))
    }
}

impl fmt::Debug for KeyChain {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "KeyChain(account 0, {:?}, secrets redacted)",
            self.prefix
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mnemonic::MnemonicCeremony;

    // Upstream's own end-to-end vectors (pin: gen1/hd.rs:528-545):
    // mnemonic → master kprv → account kpub at m/44'/111111'/0'.
    const MNEMONIC_24W: &str = "fringe ceiling crater inject pilot travel gas nurse bulb bullet horn segment snack harbor dice laugh vital cigar push couple plastic into slender worry";
    const ACCOUNT_KPUB: &str = "kpub2HtoTgsG6e1c7ixJ6JY49otNSzhEKkwnH6bsPHLAXUdYnfEuYw9LnhT7uRzaS4LSeit2rzutV6z8Fs9usdEGKnNe6p1JxfP71mK8rbUfYWo";

    // Upstream's gen1 address vectors (pin: gen1/hd.rs:450-499), first five
    // of each branch, for the master xprv at hd.rs:504.
    const MASTER_XPRV: &str = "kprv5y2qurMHCsXYrNfU3GCihuwG3vMqFji7PZXajMEqyBkNh9UZUJgoHYBLTKu1eM4MvUtomcXPQ3Sw9HZ5ebbM4byoUciHo1zrPJBQfqpLorQ";
    const RECEIVE_ADDRESSES: [&str; 5] = [
        "kaspa:qz7ulu4c25dh7fzec9zjyrmlhnkzrg4wmf89q7gzr3gfrsj3uz6xjellj43pf",
        "kaspa:qzn3qjzf2nzyd3zj303nk4sgv0aae42v3ufutk5xsxckfels57dxjjed4qvlx",
        "kaspa:qpakxqlesqywgkq7rg4wyhjd93kmw7trkl3gpa3vd5flyt59a43yyjp28qsku",
        "kaspa:qz0skffpert8cav6h2c9nfndmhzzfhvkrjexclmwgjjwt0sutysnw6lp55ak0",
        "kaspa:qrmzemw6sm67svltul0qsk3974ema4auhrja3k68f4sfhxe4mxjwx0cj353df",
    ];
    const CHANGE_ADDRESSES: [&str; 5] = [
        "kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692",
        "kaspa:qqx8jlz0hh0wun5ru4glt9za3v8wj3jn7v3w55a0lyud74ppetqfqny4yhw87",
        "kaspa:qzpa69mrh2nj6xk6gq38vcnzu64necp0jwaxxyusr9xcy5udhu2m7uvql8rnd",
        "kaspa:qqxddf76hr39dc7k7lpdzg065ajtvrhlm5p3edm4gyen0waneryss2c0la85t",
        "kaspa:qps4qh9dtskwvf923yl9utl74r8sdm9h2wv3mftuxcfc2cshwswc6txj0k2kl",
    ];

    fn keychain_from_test_mnemonic() -> KeyChain {
        let seed = MnemonicCeremony::restore(MNEMONIC_24W.as_bytes())
            .unwrap()
            .into_seed(b"")
            .unwrap();
        KeyChain::from_seed(seed, Prefix::Mainnet).unwrap()
    }

    /// Test-only construction from upstream's vector xprv (no mnemonic is
    /// published for it); the dummy seed only matters to `private_key_bytes`,
    /// which this path never calls.
    fn keychain_from_vector_xprv() -> KeyChain {
        use std::str::FromStr;
        let master = ExtendedPrivateKey::<SecretKey>::from_str(MASTER_XPRV).unwrap();
        let (account_key, attrs) =
            WalletDerivationManager::derive_extended_key_from_master_key(master, false, 0).unwrap();
        let xpub = ExtendedPublicKey {
            public_key: account_key.get_public_key(),
            attrs,
        };
        let derivation = WalletDerivationManager::from_extended_public_key(xpub, None).unwrap();
        KeyChain {
            seed: SecretSeed::new(Box::new([0u8; 64])),
            derivation,
            prefix: Prefix::Mainnet,
        }
    }

    #[test]
    fn account_kpub_matches_upstream_vector() {
        // Proves mnemonic → seed → master key → m/44'/111111'/0' end to end
        // against the pin's asserted kpub (hd.rs:541).
        assert_eq!(keychain_from_test_mnemonic().account_xpub(), ACCOUNT_KPUB);
    }

    #[test]
    fn addresses_match_upstream_gen1_vectors() {
        let keychain = keychain_from_vector_xprv();
        for (i, expected) in RECEIVE_ADDRESSES.iter().enumerate() {
            let address: String = keychain.receive_address(i as u32).unwrap().into();
            assert_eq!(&address, expected, "receive address {i}");
        }
        for (i, expected) in CHANGE_ADDRESSES.iter().enumerate() {
            let address: String = keychain.change_address(i as u32).unwrap().into();
            assert_eq!(&address, expected, "change address {i}");
        }
    }

    #[test]
    fn private_keys_match_public_addresses() {
        // The custody-critical property: the key the signer derives for
        // (branch, index) must control the address the wallet handed out.
        let keychain = keychain_from_test_mnemonic();
        for branch in [Branch::Receive, Branch::Change] {
            for index in 0..3u32 {
                let key = keychain.private_key_bytes(branch, index).unwrap();
                let secret = SecretKey::from_slice(key.as_ref()).unwrap();
                let pubkey = secret.public_key(kaspa_bip32::secp256k1::SECP256K1);
                let address =
                    PubkeyDerivationManager::create_address(&pubkey, Prefix::Mainnet, false)
                        .unwrap();
                assert_eq!(
                    address,
                    keychain.address(branch, index).unwrap(),
                    "{branch:?}/{index}"
                );
            }
        }
    }

    #[test]
    fn debug_is_opaque() {
        let rendered = format!("{:?}", keychain_from_test_mnemonic());
        assert!(rendered.contains("redacted"));
        assert!(!rendered.contains("kprv") && !rendered.contains("kpub"));
    }
}
