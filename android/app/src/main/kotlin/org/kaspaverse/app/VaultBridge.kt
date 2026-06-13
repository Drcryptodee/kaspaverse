package org.kaspaverse.app

/**
 * The Path-A seed lane (P1 §0.4) — the Kotlin half of the direct JNI bridge
 * into the same native `.so` (`libkaspaverse_bridge.so`). Seed plaintext crosses
 * here as a `ByteArray` that the **caller wipes in `finally`** (L9); it is never
 * a Dart object (INV-1) and never logged.
 *
 * The native side (`rust/bridge/src/jni_seed.rs`) wraps every entry in
 * `catch_unwind` and throws a Java exception on error — so a failure surfaces as
 * a Kotlin exception, never a panic across the boundary (INV-2).
 */
object VaultBridge {
    init {
        // The same library Dart loads via FRB; loading it into the JVM resolves
        // the `Java_org_kaspaverse_app_VaultBridge_*` symbols. Double-load is
        // refcounted by the dynamic linker — safe.
        System.loadLibrary("kaspaverse_bridge")
    }

    /**
     * Load the vault from a decrypted seed (Path-A unlock). Returns 0 on
     * success; throws [RuntimeException] (from native) on any error.
     * @param seed exactly 64 bytes; the caller owns wiping it afterwards.
     */
    external fun nativeUnlockWithSeed(seed: ByteArray): Int

    /**
     * Export the live seed for the Keystore Cipher to wrap (Path-A enroll).
     * Returns a fresh 64-byte array the caller MUST wipe after sealing; throws
     * if the vault is locked.
     */
    external fun nativeExportSeedForKeystore(): ByteArray

    /**
     * Reveal the in-progress create ceremony's 12 words for the native
     * FLAG_SECURE reveal/verify surface to render (P1.4, D-037). Returns the
     * words space-joined as UTF-8 bytes; the caller MUST wipe the array after
     * rendering. The words never become a Dart object (INV-1). Throws if no
     * ceremony is in progress.
     */
    external fun nativeRevealCeremonyWords(): ByteArray
}
