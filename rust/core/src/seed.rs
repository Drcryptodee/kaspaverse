use std::fmt;
use zeroize::{Zeroize, ZeroizeOnDrop};

/// The BIP39 root seed (64 bytes) — the wallet's single canonical secret.
///
/// Heap-boxed so a move copies a pointer, never the secret; zeroized on drop
/// (INV-2). `Debug` is opaque. The bytes are reachable only inside this crate
/// (`as_bytes` is `pub(crate)`) — nothing above `core` can see them (INV-1).
pub struct SecretSeed(Box<[u8; 64]>);

impl SecretSeed {
    pub(crate) fn new(bytes: Box<[u8; 64]>) -> Self {
        Self(bytes)
    }

    pub(crate) fn as_bytes(&self) -> &[u8; 64] {
        &self.0
    }
}

impl Zeroize for SecretSeed {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

impl Drop for SecretSeed {
    fn drop(&mut self) {
        self.zeroize();
    }
}

impl ZeroizeOnDrop for SecretSeed {}

impl fmt::Debug for SecretSeed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SecretSeed(64 bytes, redacted)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Compile-time proof that the drop path zeroizes (the marker trait's
    // contract); the runtime test below proves the zeroize impl actually
    // clears the buffer.
    fn assert_zeroize_on_drop<T: ZeroizeOnDrop>() {}

    #[test]
    fn zeroize_clears_all_bytes() {
        assert_zeroize_on_drop::<SecretSeed>();
        let mut seed = SecretSeed::new(Box::new([0x7Au8; 64]));
        seed.zeroize();
        assert_eq!(seed.as_bytes(), &[0u8; 64]);
    }

    #[test]
    fn debug_is_opaque() {
        let seed = SecretSeed::new(Box::new([0x7Au8; 64]));
        let rendered = format!("{seed:?}");
        assert_eq!(rendered, "SecretSeed(64 bytes, redacted)");
        assert!(!rendered.contains("7a") && !rendered.contains("7A") && !rendered.contains("122"));
    }
}
