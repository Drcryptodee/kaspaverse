//! Mnemonic ceremonies — generate (create) and restore.
//!
//! Derived from the pinned crate's own implementation and tests (INV-9):
//! `wallet/bip32/src/mnemonic/phrase.rs` at the pin — `WordCount` (:38),
//! `random_impl` (:116), `to_seed` (:232), and the self-zeroizing `Drop`
//! (:240). Policy per D-028: create = 12 words; restore accepts 12 AND 24.

use crate::error::{CoreError, Result};
use crate::seed::SecretSeed;
use chacha20poly1305::aead::OsRng;
use kaspa_bip32::{Language, Mnemonic, WordCount};
use std::fmt;
use zeroize::Zeroizing;

/// A mnemonic alive only for the duration of a create/restore ceremony.
///
/// Wraps the pinned crate's `Mnemonic`, which zeroizes its phrase and entropy
/// on drop. Words are reachable only by borrowing (`words`) — for the P1.4
/// reveal/verify screens — and the only exit is `into_seed`, which consumes
/// the ceremony. Nothing here is ever persisted: the sealed blob stores the
/// derived seed, not the phrase (and never the extra word — the decoy
/// property, vault_architecture §4).
pub struct MnemonicCeremony(Mnemonic);

impl MnemonicCeremony {
    /// Generate a fresh 12-word mnemonic (D-028: create = 12 words —
    /// 128-bit entropy matches secp256k1's effective security level).
    /// Entropy comes straight from the OS CSPRNG (`OsRng`, getrandom-backed —
    /// the same RNG the vault uses for salts/nonces), not a userspace PRNG.
    pub fn generate() -> Result<Self> {
        Ok(Self(Mnemonic::random_impl(
            WordCount::Words12,
            OsRng,
            Language::English,
        )?))
    }

    /// Restore from a phrase. Accepts 12 and 24 words (24 = migration from
    /// Kaspium-class wallets, D-028); any other count is refused before the
    /// checksum runs. Whitespace and case are normalized so transcription
    /// style cannot change the wallet. The caller owns (and wipes) the input
    /// buffer; every transient copy made here zeroizes on drop.
    pub fn restore(phrase: &[u8]) -> Result<Self> {
        let phrase = std::str::from_utf8(phrase).map_err(|_| CoreError::PhraseEncoding)?;
        let words: Vec<Zeroizing<String>> = phrase
            .split_whitespace()
            .map(|w| Zeroizing::new(w.to_lowercase()))
            .collect();
        if words.len() != 12 && words.len() != 24 {
            return Err(CoreError::WordCount(words.len()));
        }
        let mut joined = Zeroizing::new(String::with_capacity(phrase.len()));
        for (i, word) in words.iter().enumerate() {
            if i > 0 {
                joined.push(' ');
            }
            joined.push_str(word);
        }
        Ok(Self(Mnemonic::new(joined.as_str(), Language::English)?))
    }

    /// Number of words (12 or 24).
    pub fn word_count(&self) -> usize {
        self.0.phrase().split(' ').count()
    }

    /// Borrow the words for the reveal/verify ceremony (P1.4). Nothing is
    /// copied out of the zeroizing owner; the borrow dies with the screen.
    pub fn words(&self) -> impl Iterator<Item = &str> {
        self.0.phrase().split(' ')
    }

    /// Consume the ceremony into the root seed. `extra_word` is the optional
    /// 13th/25th word (BIP39 passphrase); empty slice = none. It shapes the
    /// seed and is gone — never persisted, never derivable from anything
    /// stored (wallet-security checklist item 6). Salt convention follows
    /// the pinned `to_seed` exactly (`"mnemonic" + extra`, PBKDF2/2048).
    pub fn into_seed(self, extra_word: &[u8]) -> Result<SecretSeed> {
        let extra = std::str::from_utf8(extra_word).map_err(|_| CoreError::ExtraWordEncoding)?;
        let seed = self.0.to_seed(extra);
        let mut bytes = Box::new([0u8; 64]);
        bytes.copy_from_slice(seed.as_bytes());
        // `seed` (upstream `Seed`) zeroizes itself on drop here.
        Ok(SecretSeed::new(bytes))
    }
}

impl fmt::Debug for MnemonicCeremony {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "MnemonicCeremony({} words, redacted)", self.word_count())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // BIP39 reference vector #1 (Trezor test vectors, the published standard
    // set): 16 zero bytes of entropy → "abandon ×11 about"; with passphrase
    // "TREZOR" the seed is the constant below. Cross-checks the pinned
    // `to_seed` end to end, including the extra-word (passphrase) lane.
    const V1_PHRASE: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const V1_SEED_TREZOR: &str = "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04";

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[test]
    fn bip39_reference_vector_with_extra_word() {
        let ceremony = MnemonicCeremony::restore(V1_PHRASE.as_bytes()).unwrap();
        assert_eq!(ceremony.word_count(), 12);
        let seed = ceremony.into_seed(b"TREZOR").unwrap();
        assert_eq!(hex(seed.as_bytes()), V1_SEED_TREZOR);
    }

    #[test]
    fn extra_word_changes_the_wallet() {
        let a = MnemonicCeremony::restore(V1_PHRASE.as_bytes())
            .unwrap()
            .into_seed(b"")
            .unwrap();
        let b = MnemonicCeremony::restore(V1_PHRASE.as_bytes())
            .unwrap()
            .into_seed(b"x")
            .unwrap();
        assert_ne!(
            a.as_bytes(),
            b.as_bytes(),
            "extra word must derive a different wallet"
        );
        // …and deterministically: same words + same extra word = same seed.
        let c = MnemonicCeremony::restore(V1_PHRASE.as_bytes())
            .unwrap()
            .into_seed(b"x")
            .unwrap();
        assert_eq!(b.as_bytes(), c.as_bytes());
    }

    #[test]
    fn generate_is_12_words_and_unique() {
        let a = MnemonicCeremony::generate().unwrap();
        assert_eq!(a.word_count(), 12);
        assert_eq!(a.words().count(), 12);
        let b = MnemonicCeremony::generate().unwrap();
        // 128-bit entropy: a collision here means the CSPRNG is broken.
        assert!(a.words().ne(b.words()));
    }

    #[test]
    fn generate_round_trips_through_restore() {
        let a = MnemonicCeremony::generate().unwrap();
        let phrase = a.words().collect::<Vec<_>>().join(" ");
        let b = MnemonicCeremony::restore(phrase.as_bytes()).unwrap();
        let seed_a = a.into_seed(b"").unwrap();
        let seed_b = b.into_seed(b"").unwrap();
        assert_eq!(seed_a.as_bytes(), seed_b.as_bytes());
    }

    #[test]
    fn restore_normalizes_case_and_whitespace() {
        let messy = "  Abandon\tabandon abandon ABANDON abandon abandon\n abandon abandon abandon abandon  abandon aBout ";
        let a = MnemonicCeremony::restore(messy.as_bytes())
            .unwrap()
            .into_seed(b"")
            .unwrap();
        let b = MnemonicCeremony::restore(V1_PHRASE.as_bytes())
            .unwrap()
            .into_seed(b"")
            .unwrap();
        assert_eq!(a.as_bytes(), b.as_bytes());
    }

    #[test]
    fn restore_accepts_24_words() {
        // Upstream's own 24-word test mnemonic (pin: gen1/hd.rs:533).
        let phrase = "fringe ceiling crater inject pilot travel gas nurse bulb bullet horn segment snack harbor dice laugh vital cigar push couple plastic into slender worry";
        let ceremony = MnemonicCeremony::restore(phrase.as_bytes()).unwrap();
        assert_eq!(ceremony.word_count(), 24);
    }

    #[test]
    fn restore_rejects_unsupported_word_counts() {
        let eighteen = ["abandon"; 18].join(" ");
        match MnemonicCeremony::restore(eighteen.as_bytes()) {
            Err(CoreError::WordCount(18)) => {}
            other => panic!("expected WordCount(18), got {other:?}"),
        }
    }

    #[test]
    fn restore_rejects_bad_checksum_and_unknown_words() {
        // 12 × "abandon" has an invalid checksum.
        let bad_checksum = ["abandon"; 12].join(" ");
        assert!(MnemonicCeremony::restore(bad_checksum.as_bytes()).is_err());
        // "kaspa" is not a BIP39 word.
        let unknown = ["kaspa"; 12].join(" ");
        assert!(MnemonicCeremony::restore(unknown.as_bytes()).is_err());
    }

    #[test]
    fn debug_is_opaque() {
        let ceremony = MnemonicCeremony::restore(V1_PHRASE.as_bytes()).unwrap();
        let rendered = format!("{ceremony:?}");
        assert_eq!(rendered, "MnemonicCeremony(12 words, redacted)");
        assert!(!rendered.contains("abandon"));
    }
}
