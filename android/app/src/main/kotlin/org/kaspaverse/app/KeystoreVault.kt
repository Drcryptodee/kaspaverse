package org.kaspaverse.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Path-A vault (P1 §0.2/§0.5): the seed sealed under a hardware-backed,
 * **non-exportable** Android Keystore AES-256-GCM key, unlocked only by a strong
 * biometric. The Keystore Cipher does the GCM platform-side — the key never
 * leaves hardware; Rust only ever sees the GCM *plaintext* over the JNI lane
 * ([VaultBridge]).
 *
 * Sealing decisions, all auditor-relevant:
 * - `setUserAuthenticationRequired(true)` + a per-use [BiometricPrompt.CryptoObject]
 *   → the key is usable only inside an authenticated cipher.
 * - StrongBox requested, gracefully degraded to TEE on [StrongBoxUnavailableException].
 * - `setInvalidatedByBiometricEnrollment(true)` (the default, kept on purpose): a
 *   newly enrolled fingerprint invalidates the key and forces passphrase re-wrap.
 *   That is a feature (theft-via-enrollment defence), not a bug — §0.5.
 * - Ciphertext + IV live in app-private [Context.getFilesDir] (INV-3 — never
 *   SharedPreferences); backup rules exclude the directory.
 *
 * On-device behaviour (biometric prompt, StrongBox path, enrollment
 * invalidation) is proven on the reference device in P1.2's on-device pass; this
 * file is the compile-proven mechanism.
 */
object KeystoreVault {
    private const val KEY_ALIAS = "kaspaverse_vault_key"
    private const val BLOB_A_FILE = "vault.keystore.blob"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORM = "AES/GCM/NoPadding"
    private const val GCM_TAG_BITS = 128
    private const val SEED_LEN = 64

    /** A biometric capable of [BiometricManager.Authenticators.BIOMETRIC_STRONG] is enrolled. */
    fun isBiometricAvailable(ctx: Context): Boolean =
        BiometricManager.from(ctx).canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG
        ) == BiometricManager.BIOMETRIC_SUCCESS

    /** A Path-A blob has been enrolled on this device. */
    fun isEnrolled(ctx: Context): Boolean = blobFile(ctx).exists()

    /** Forget the Path-A enrollment (key + blob). Path B remains the recovery. */
    fun clearEnrollment(ctx: Context) {
        runCatching {
            KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }.deleteEntry(KEY_ALIAS)
        }
        blobFile(ctx).delete()
    }

    /**
     * Enroll Path A: prompt for biometric, then seal the live seed (pulled from
     * Rust over JNI) under a freshly created Keystore key. The vault must already
     * be unlocked (created via Path B) so the seed export succeeds.
     */
    fun enroll(activity: FragmentActivity, onResult: (Boolean, String?) -> Unit) {
        val key = try {
            getOrCreateKey()
        } catch (e: Exception) {
            onResult(false, "keystore key creation failed: ${e.message}")
            return
        }
        val cipher = Cipher.getInstance(TRANSFORM).apply { init(Cipher.ENCRYPT_MODE, key) }
        authenticate(activity, cipher, "Set up biometric unlock") { authedCipher, error ->
            if (authedCipher == null) {
                onResult(false, error ?: "authentication failed")
                return@authenticate
            }
            val seed = try {
                VaultBridge.nativeExportSeedForKeystore()
            } catch (e: Throwable) {
                onResult(false, "seed export failed: ${e.message}")
                return@authenticate
            }
            try {
                val ciphertext = authedCipher.doFinal(seed)
                writeBlob(activity, authedCipher.iv, ciphertext)
                onResult(true, null)
            } catch (e: Exception) {
                onResult(false, "seal failed: ${e.message}")
            } finally {
                seed.fill(0) // L9 — wipe the plaintext seed copy
            }
        }
    }

    /**
     * Unlock Path A: prompt for biometric, decrypt the blob, hand the plaintext
     * seed to Rust over JNI, and wipe it. Returns success once the vault is
     * loaded native-side.
     */
    fun unlock(activity: FragmentActivity, onResult: (Boolean, String?) -> Unit) {
        val (iv, ciphertext) = try {
            readBlob(activity)
        } catch (e: Exception) {
            onResult(false, "no enrollment or unreadable blob: ${e.message}")
            return
        }
        val key = try {
            loadKey() ?: run {
                onResult(false, "keystore key missing (re-enroll required)")
                return
            }
        } catch (e: Exception) {
            // KeyPermanentlyInvalidatedException lands here: enrollment changed.
            onResult(false, "keystore key invalidated (use passphrase): ${e.message}")
            return
        }
        val cipher = Cipher.getInstance(TRANSFORM).apply {
            init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
        }
        authenticate(activity, cipher, "Unlock your wallet") { authedCipher, error ->
            if (authedCipher == null) {
                onResult(false, error ?: "authentication failed")
                return@authenticate
            }
            var plaintext: ByteArray? = null
            try {
                plaintext = authedCipher.doFinal(ciphertext)
                VaultBridge.nativeUnlockWithSeed(plaintext)
                onResult(true, null)
            } catch (e: Throwable) {
                onResult(false, "unseal/load failed: ${e.message}")
            } finally {
                plaintext?.fill(0) // L9
            }
        }
    }

    // ── Keystore key lifecycle ────────────────────────────────────────────

    private fun loadKey(): SecretKey? {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        return ks.getKey(KEY_ALIAS, null) as? SecretKey
    }

    private fun getOrCreateKey(): SecretKey {
        loadKey()?.let { return it }
        return createKey(strongBox = true)
    }

    private fun createKey(strongBox: Boolean): SecretKey {
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            // Default true; stated explicitly so an auditor sees the intent
            // (a new fingerprint invalidates the key — §0.5).
            .setInvalidatedByBiometricEnrollment(true)
            .setIsStrongBoxBacked(strongBox)
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE
        )
        return try {
            generator.init(builder.build())
            generator.generateKey().also {
                // Non-sensitive: which hardware tier holds the key (§2 evidence).
                android.util.Log.i("KeystoreVault", "key created (strongbox=$strongBox)")
            }
        } catch (e: StrongBoxUnavailableException) {
            if (strongBox) {
                android.util.Log.i("KeystoreVault", "StrongBox unavailable — TEE fallback")
                createKey(strongBox = false)
            } else throw e
        }
    }

    // ── Blob A persistence (app-private; format: [ivLen][iv][ciphertext]) ──

    private fun blobFile(ctx: Context): File = File(ctx.filesDir, BLOB_A_FILE)

    private fun writeBlob(ctx: Context, iv: ByteArray, ciphertext: ByteArray) {
        val out = ByteArray(1 + iv.size + ciphertext.size)
        out[0] = iv.size.toByte()
        iv.copyInto(out, 1)
        ciphertext.copyInto(out, 1 + iv.size)
        // Atomic-ish: write temp then rename so a crash can't leave a torn blob.
        val tmp = File(ctx.filesDir, "$BLOB_A_FILE.tmp")
        tmp.writeBytes(out)
        if (!tmp.renameTo(blobFile(ctx))) {
            blobFile(ctx).writeBytes(out)
            tmp.delete()
        }
    }

    private fun readBlob(ctx: Context): Pair<ByteArray, ByteArray> {
        val bytes = blobFile(ctx).readBytes()
        val ivLen = bytes[0].toInt()
        require(ivLen in 1..16 && bytes.size > 1 + ivLen) { "malformed Path-A blob" }
        val iv = bytes.copyOfRange(1, 1 + ivLen)
        val ciphertext = bytes.copyOfRange(1 + ivLen, bytes.size)
        return iv to ciphertext
    }

    // ── BiometricPrompt (BIOMETRIC_STRONG, cipher-bound) ──────────────────

    private fun authenticate(
        activity: FragmentActivity,
        cipher: Cipher,
        title: String,
        onDone: (Cipher?, String?) -> Unit,
    ) {
        val executor = androidx.core.content.ContextCompat.getMainExecutor(activity)
        val prompt = BiometricPrompt(
            activity,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    onDone(result.cryptoObject?.cipher, null)
                }

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    onDone(null, "biometric error $code: $msg")
                }

                override fun onAuthenticationFailed() {
                    // A single non-match — the prompt stays up; nothing to do.
                }
            }
        )
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle("KaspaVerse vault")
            .setNegativeButtonText("Use passphrase")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .setConfirmationRequired(false)
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }
}
