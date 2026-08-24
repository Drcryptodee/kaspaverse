package org.kaspaverse.app

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
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
import javax.crypto.SecretKeyFactory
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
 * - StrongBox requested on API 28+, gracefully degraded to TEE on
 *   [StrongBoxUnavailableException] — and simply not requested below 28, where
 *   neither the setter nor that exception type exists (minSdk is 26).
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
    /**
     * A ceremony that did not complete: a stable [code] Dart maps to copy, and a
     * [message] that is diagnostic only.
     *
     * Two fields rather than one string because the caller has to make a decision
     * the string cannot support — chiefly "was this a failure at all?". Parsing
     * `"biometric error 13: ..."` in Dart would put a user-visible branch on an
     * OEM- and locale-dependent sentence.
     */
    data class Failure(val code: String, val message: String)

    private const val KEY_ALIAS = "kaspaverse_vault_key"
    private const val BLOB_A_FILE = "vault.keystore.blob"
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val TRANSFORM = "AES/GCM/NoPadding"
    private const val GCM_TAG_BITS = 128
    private const val SEED_LEN = 64

    /** A biometric capable of [BiometricManager.Authenticators.BIOMETRIC_STRONG] is enrolled. */
    fun isBiometricAvailable(ctx: Context): Boolean =
        biometricStatus(ctx) == STATUS_READY

    /**
     * Why Path A is or is not offerable, as a stable string Dart maps to copy.
     *
     * [isBiometricAvailable] collapses all of this to `false`, and that collapse
     * is the defect: `NONE_ENROLLED` — no fingerprint registered in Android
     * Settings — is by far the most common answer on a fresh phone, it is the
     * only one the user can *act* on, and it is indistinguishable from "this
     * hardware cannot" once it becomes a bool. The create flow read that bool,
     * skipped the enrolment offer in silence, and left the user believing the
     * feature did not exist.
     */
    fun biometricStatus(ctx: Context): String =
        when (
            BiometricManager.from(ctx)
                .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        ) {
            BiometricManager.BIOMETRIC_SUCCESS -> STATUS_READY
            // Hardware is present and capable — the user simply has not set a
            // fingerprint up yet. Actionable, and the one worth a real prompt.
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "no_hardware"
            // Transient: sensor busy, or disabled by device policy. Retrying is
            // the right advice, unlike the two above.
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "unavailable"
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED ->
                "security_update_required"
            else -> "unknown"
        }

    const val STATUS_READY = "ready"

    // Stable error codes for the enroll/unlock ceremonies. Dart renders copy from
    // these, never from the platform's message — the message is diagnostic text
    // that varies by OEM and locale, and one of these outcomes is not an error at
    // all (see [CODE_CANCELLED]).
    const val CODE_CANCELLED = "cancelled"
    const val CODE_LOCKOUT = "lockout"
    const val CODE_NO_ENROLLMENT = "no_enrollment"
    const val CODE_KEY_INVALIDATED = "key_invalidated"
    const val CODE_KEYSTORE = "keystore"
    const val CODE_VAULT = "vault"
    const val CODE_FAILED = "failed"

    /**
     * Map a [BiometricPrompt] error code to one of ours.
     *
     * The three cancel codes matter most: the user pressing back, the system
     * cancelling the prompt, and the user tapping "Use passphrase" are all
     * *choices*, not failures, and a wallet that shows an error banner for them is
     * lying about what happened.
     */
    private fun promptErrorCode(code: Int): String = when (code) {
        BiometricPrompt.ERROR_USER_CANCELED,
        BiometricPrompt.ERROR_CANCELED,
        BiometricPrompt.ERROR_NEGATIVE_BUTTON,
        -> CODE_CANCELLED
        BiometricPrompt.ERROR_LOCKOUT, BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> CODE_LOCKOUT
        else -> CODE_FAILED
    }

    /**
     * A Path-A blob is enrolled **and the key it is sealed against still works**.
     *
     * File existence alone is not enrolment. A fingerprint enrolment change
     * permanently invalidates the Keystore key (§0.5, deliberately) and leaves
     * the blob untouched on disk, so the old `blobFile(ctx).exists()` kept
     * reporting "On" for a lane that could no longer open anything — which is
     * how Settings came to show a healthy control over a dead path and the
     * unlock button came to stick on "Unlocking…" (product-audit run 1, F4).
     */
    fun isEnrolled(ctx: Context): Boolean = pathAState(ctx) == PATH_A_READY

    // Path-A enrolment states, as a stable string Dart maps to copy. Three, not a
    // bool, for the same reason [biometricStatus] is three: "never set up" and
    // "set up, then invalidated by a new fingerprint" need different sentences
    // and different remedies, and a bool cannot carry either.
    const val PATH_A_NONE = "none"
    const val PATH_A_READY = "ready"
    const val PATH_A_INVALIDATED = "invalidated"

    /**
     * Whether Path A is usable, absent, or invalidated by an enrolment change.
     *
     * The probe is an ENCRYPT-mode `Cipher.init`, because that is where the
     * platform actually raises [KeyPermanentlyInvalidatedException] —
     * `KeyStore.getKey` provably cannot, it declares only `KeyStoreException`,
     * `NoSuchAlgorithmException` and `UnrecoverableKeyException`. The key is
     * per-use-authenticated with no validity window, so `init` succeeds without
     * a prompt: this costs a Keystore round-trip and shows the user nothing.
     */
    fun pathAState(ctx: Context): String {
        if (!blobFile(ctx).exists()) return PATH_A_NONE
        val key = try {
            loadKey() ?: return PATH_A_NONE
        } catch (e: Exception) {
            return PATH_A_NONE
        }
        return try {
            probeCipher.init(Cipher.ENCRYPT_MODE, key)
            PATH_A_READY
        } catch (e: KeyPermanentlyInvalidatedException) {
            PATH_A_INVALIDATED
        } catch (e: Exception) {
            // Some other Keystore fault — we cannot claim the lane works.
            PATH_A_NONE
        }
    }

    /**
     * ONE reusable Cipher for [pathAState]'s probe, never a fresh instance.
     *
     * `Cipher.init` on a Keystore key BEGINS a keystore operation, and this probe
     * has no `doFinal` to end it — a fresh Cipher per call would leave one
     * dangling per probe, released only by its finalizer. Keystore operation
     * slots are bounded (few on StrongBox) and the keystore PRUNES when they run
     * out, with an in-flight `BiometricPrompt.CryptoObject` a prime candidate:
     * "fingerprint accepted, then the unseal failed" — the dead-lane symptom F4
     * exists to end, re-created by F4's own fix. Re-initing one instance aborts
     * its predecessor, so outstanding probe operations stay bounded at one.
     * (`isEnrolled` delegates here, so this runs on every locked-screen probe and
     * on every Settings resume.) Main-thread only, like every MethodChannel
     * handler that reaches it.
     */
    private val probeCipher: Cipher by lazy { Cipher.getInstance(TRANSFORM) }

    /** Forget the Path-A enrollment (key + blob). Path B remains the recovery. */
    fun clearEnrollment(ctx: Context) = deleteKeyAndBlob(ctx)

    /**
     * Enroll Path A: prompt for biometric, then seal the live seed (pulled from
     * Rust over JNI) under a freshly created Keystore key. The vault must already
     * be unlocked (created via Path B) so the seed export succeeds.
     */
    fun enroll(activity: FragmentActivity, onResult: (Boolean, Failure?) -> Unit) {
        // `Cipher.init` is INSIDE the try. It — not `KeyStore.getKey` — is the
        // call that raises [KeyPermanentlyInvalidatedException], and sitting
        // outside every try it threw straight through the MethodChannel handler,
        // where Flutter's DartMessenger swallows it and simply never replies:
        // the Dart future hung forever and the button stuck (run 1, F4).
        val cipher = try {
            encryptCipher(activity)
        } catch (e: Throwable) {
            // Throwable, not Exception: this is the path that reaches createKey, and
            // a java.lang.Error escaping here is process death rather than a failed
            // enrolment (F10). Every catch on the two CEREMONY paths — export,
            // seal, unseal — is Throwable for the same reason. The narrower
            // `Exception` catches that remain are the pre-ceremony reads
            // (readBlob/loadKey/Cipher.init), where a java.lang.Error is not a
            // recoverable enrolment failure and must not be dressed as one.
            onResult(false, Failure(CODE_KEYSTORE, "keystore key creation failed: ${e.message}"))
            return
        }
        authenticate(activity, cipher, "Set up biometric unlock") { authedCipher, failure ->
            if (authedCipher == null) {
                onResult(false, failure ?: Failure(CODE_FAILED, "authentication failed"))
                return@authenticate
            }
            val seed = try {
                VaultBridge.nativeExportSeedForKeystore()
            } catch (e: Throwable) {
                // Overwhelmingly "vault is locked": the §0.11 lifecycle lock fired
                // while the prompt held the foreground. Its own code, because the
                // user CAN act on it (unlock and try again) and because a swallowed
                // one is precisely what made enrolment look like it did nothing.
                onResult(false, Failure(CODE_VAULT, "seed export failed: ${e.message}"))
                return@authenticate
            }
            // Throwable, like the export above it: this is the LAST beat of the
            // ceremony, and a java.lang.Error escaping here is F10's outcome —
            // process death — one statement after the one F10 fixed.
            //
            // `onResult(true, null)` sits OUTSIDE the try on purpose: inside, a
            // throw from the success reply itself would fall into the catch and
            // reply a second time, which is the un-replied class's twin.
            val sealed = try {
                val ciphertext = authedCipher.doFinal(seed)
                writeBlob(activity, authedCipher.iv, ciphertext)
                true
            } catch (e: Throwable) {
                onResult(false, Failure(CODE_KEYSTORE, "seal failed: ${e.message}"))
                false
            } finally {
                seed.fill(0) // L9 — wipe the plaintext seed copy
            }
            if (sealed) onResult(true, null)
        }
    }

    /**
     * Unlock Path A: prompt for biometric, decrypt the blob, hand the plaintext
     * seed to Rust over JNI, and wipe it. Returns success once the vault is
     * loaded native-side.
     */
    fun unlock(activity: FragmentActivity, onResult: (Boolean, Failure?) -> Unit) {
        val (iv, ciphertext) = try {
            readBlob(activity)
        } catch (e: Exception) {
            onResult(
                false,
                Failure(CODE_NO_ENROLLMENT, "no enrollment or unreadable blob: ${e.message}")
            )
            return
        }
        val key = try {
            loadKey() ?: run {
                onResult(
                    false,
                    Failure(CODE_NO_ENROLLMENT, "keystore key missing (re-enroll required)")
                )
                return
            }
        } catch (e: Exception) {
            // NOT the invalidation path — `KeyStore.getKey` cannot raise
            // KeyPermanentlyInvalidatedException (it declares only
            // KeyStoreException / NoSuchAlgorithmException /
            // UnrecoverableKeyException, and the invalidation exception is a
            // CHECKED InvalidKeyException). The old comment here claimed
            // otherwise, which is why the real throw site went unguarded for a
            // whole phase. Invalidation is caught at the `init` below.
            onResult(false, Failure(CODE_KEYSTORE, "keystore key unreadable: ${e.message}"))
            return
        }
        val cipher = try {
            Cipher.getInstance(TRANSFORM).apply {
                init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            // Enrolment changed. §0.5 makes that deliberate (a newly enrolled
            // fingerprint must not inherit the old key), so it is a re-enrol
            // prompt, not a fault — and the seed is NOT lost: Path B still holds
            // the vault, and "Set up again" now rebuilds the key.
            onResult(
                false,
                Failure(CODE_KEY_INVALIDATED, "keystore key invalidated: ${e.message}")
            )
            return
        } catch (e: Exception) {
            onResult(false, Failure(CODE_KEYSTORE, "cipher init failed: ${e.message}"))
            return
        }
        authenticate(activity, cipher, "Unlock your wallet") { authedCipher, failure ->
            if (authedCipher == null) {
                onResult(false, failure ?: Failure(CODE_FAILED, "authentication failed"))
                return@authenticate
            }
            var plaintext: ByteArray? = null
            // Same shape as `enroll`'s seal, and for the same reason: the success
            // reply sits OUTSIDE the try, so a throw from the reply itself cannot
            // fall into the catch and reply a second time.
            val unsealed = try {
                plaintext = authedCipher.doFinal(ciphertext)
                VaultBridge.nativeUnlockWithSeed(plaintext)
                true
            } catch (e: Throwable) {
                onResult(false, Failure(CODE_VAULT, "unseal/load failed: ${e.message}"))
                false
            } finally {
                plaintext?.fill(0) // L9
            }
            if (unsealed) onResult(true, null)
        }
    }

    // ── Keystore key lifecycle ────────────────────────────────────────────

    private fun loadKey(): SecretKey? {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        return ks.getKey(KEY_ALIAS, null) as? SecretKey
    }

    /**
     * An ENCRYPT-mode cipher under a key that is proven live, replacing the key
     * first if an enrolment change has killed it.
     *
     * The old `getOrCreateKey()` returned whatever `loadKey()` found, so an
     * invalidated key was reused forever: Settings' "Set up again" — the one
     * remedy the app offers for this exact state — re-entered the same dead
     * path, and only the destructive "Turn off" could repair it (run 1, F4).
     * Re-enrolment is precisely the moment a stale key SHOULD be replaced; the
     * blob it sealed is about to be overwritten anyway, and Path B holds the
     * vault throughout, so nothing is at risk in the swap.
     */
    private fun encryptCipher(ctx: Context): Cipher {
        val cipher = Cipher.getInstance(TRANSFORM)
        val existing = try {
            loadKey()
        } catch (e: Exception) {
            null
        }
        if (existing != null) {
            try {
                cipher.init(Cipher.ENCRYPT_MODE, existing)
                return cipher // the live-key path: nothing is discarded
            } catch (e: KeyPermanentlyInvalidatedException) {
                android.util.Log.i(
                    "KeystoreVault",
                    "key invalidated by an enrolment change — recreating"
                )
            }
        }
        // We are about to mint a key the existing blob was NOT sealed under, so
        // the pair dies together. Leaving the blob would desync it from the key:
        // `pathAState` would probe the healthy NEW key, report READY, and offer a
        // fingerprint button that authenticates fine and then fails the GCM tag —
        // the exact "healthy control over a dead lane" F4 exists to end, in a
        // window the pre-fix code did not have (it never deleted a key at all).
        // Every abort between here and `writeBlob` lands in that window: a
        // cancelled prompt, the §0.11 lifecycle race, a failed seal.
        //
        // Nothing is lost. The blob is provably unopenable the moment its key is
        // gone, and Path B holds the vault throughout. Reads as "Off" until a
        // re-enrolment writes a fresh matched pair — a value the code could not
        // have written coherently must read as absent, never as healthy (L86).
        deleteKeyAndBlob(ctx)
        cipher.init(Cipher.ENCRYPT_MODE, createKey(strongBox = true))
        return cipher
    }

    private fun deleteKeyAndBlob(ctx: Context) {
        runCatching {
            KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }.deleteEntry(KEY_ALIAS)
        }
        blobFile(ctx).delete()
    }

    private fun createKey(strongBox: Boolean): SecretKey {
        // StrongBox is an API-28 feature, and so is the exception that reports its
        // absence. minSdk is 26 (build.gradle.kts:66), and an unguarded call on
        // 26/27 raises NoSuchMethodError — a java.lang.Error, NOT an Exception, so
        // no `catch (e: Exception)` on the path stops it and DartMessenger hands it
        // to the thread's uncaught handler: the process dies on the last beat of the
        // create/restore ceremony, and again on every later "Enable fingerprint
        // unlock" (F10, product-audit run 3). The enrol affordance really is offered
        // there — androidx.biometric returns BIOMETRIC_SUCCESS on 26/27.
        //
        // Guarded rather than answered by raising minSdk: without StrongBox the key
        // is TEE-backed, which is exactly the tier the fallback below already
        // produces on 28+ hardware that has no StrongBox — a tier this vault already
        // accepts as sound. Every other constraint in this builder works from API 24
        // (setUserAuthenticationRequired 23, setInvalidatedByBiometricEnrollment 24).
        // Raising the floor would discard users for no security gain.
        val strongBoxRequested =
            strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(strongBoxRequested)
        }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE
        )
        return try {
            generator.init(builder.build())
            generator.generateKey().also {
                // Non-sensitive: which hardware tier holds the key (§2 evidence).
                // Reports the tier actually ASKED FOR, never the caller's wish — on
                // 26/27 `strongBox = true` arrives but no StrongBox is requested,
                // and a log claiming strongbox=true there would be evidence of a
                // guarantee the key does not carry.
                android.util.Log.i(
                    "KeystoreVault",
                    "key created (requested strongbox=$strongBoxRequested, " +
                        "observed tier=${observedTier(it)})"
                )
            }
        } catch (e: Exception) {
            if (strongBoxRequested && isStrongBoxUnavailable(e)) {
                android.util.Log.i("KeystoreVault", "StrongBox unavailable — TEE fallback")
                createKey(strongBox = false)
            } else throw e
        }
    }

    /**
     * The tier the key ACTUALLY landed on, read back from the Keystore — not the
     * tier we asked for.
     *
     * Asking is not getting: `AndroidKeyStore` silently produces a SOFTWARE-backed
     * key on a device with no secure hardware, and until this was read back, a real
     * TEE key and a software key logged the identical line and both reported
     * `PATH_A_READY`. This file's header calls the seal "hardware-backed", and a
     * custody claim the code cannot substantiate is the kind INV-4 exists to stop
     * (wallet-security-auditor, 2026-08-24 fix wave). The guard that routes 26/27
     * onto the non-StrongBox path widened the population landing on the unverified
     * tier, which is why it is read back here rather than later.
     *
     * Observation only — it does NOT refuse a software key. Whether a device with no
     * secure hardware may hold a Path-A vault at all is a product call about who is
     * locked out, and it belongs to the founder, not to this function.
     *
     * `getSecurityLevel()` is API 31; below that only the coarse
     * `isInsideSecureHardware` exists, which cannot tell StrongBox from TEE. Failure
     * to read the tier is reported as `unknown`, never as a tier.
     */
    private fun observedTier(key: SecretKey): String = try {
        val info = SecretKeyFactory
            .getInstance(key.algorithm, ANDROID_KEYSTORE)
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "tee"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "SOFTWARE"
                else -> "unknown"
            }
        } else {
            @Suppress("DEPRECATION")
            if (info.isInsideSecureHardware) "hardware" else "SOFTWARE"
        }
    } catch (e: Throwable) {
        // Never let a diagnostic kill an enrolment that otherwise succeeded —
        // this whole function is evidence, not control flow.
        "unknown"
    }

    /**
     * [StrongBoxUnavailableException] is itself API 28, so even naming the type has
     * to sit behind the same version gate as the call that can raise it — which is
     * why this is an `is` check inside a guard rather than a `catch` clause. Below
     * 28 nothing requests StrongBox, so nothing can report it unavailable.
     */
    private fun isStrongBoxUnavailable(e: Exception): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            e is StrongBoxUnavailableException

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
        onDone: (Cipher?, Failure?) -> Unit,
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
                    onDone(null, Failure(promptErrorCode(code), "biometric error $code: $msg"))
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
        // The prompt launch is GUARDED, and the failure it guards is silence,
        // not an exception (ffi-leak-auditor, 2026-08-24 fix wave).
        //
        // `BiometricPrompt.authenticateInternal` in the pinned androidx.biometric
        // 1.1.0 **logs and returns** — no throw, no AuthenticationCallback — when
        // the fragment manager is null or the activity's state is already saved
        // (an `authenticate()` reaching here after `onSaveInstanceState`). This
        // call sits outside every try in both ceremonies, and `onDone` lives only
        // inside the callback, so nothing replied: `MainActivity` never called
        // `result.success`/`result.error` and the Dart future never completed.
        //
        // That is worse than a hang on the glass. `VaultService.runCeremony`
        // decrements `_ceremonyDepth` in the `finally` of `await body()`, so a
        // future that never completes leaves `_ceremonyHandoffActive` true for the
        // rest of the process — and `didChangeAppLifecycleState` then skips
        // `_armLock()` on EVERY later background. **The vault stays unlocked
        // indefinitely, past the maxLockGraceSecs ceiling** (§0.11 / D-133). In
        // `enroll` it is worse still: `encryptCipher()` has already deleted the old
        // key and blob by the time we get here, so a silent return destroys the
        // user's Path A and wedges the UI at once.
        //
        // A callback is therefore invoked on every exit from this function.
        if (activity.supportFragmentManager.isStateSaved) {
            onDone(null, Failure(CODE_FAILED, "prompt not shown: activity state already saved"))
            return
        }
        try {
            prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
        } catch (e: Throwable) {
            onDone(null, Failure(CODE_FAILED, "prompt failed to launch: ${e.message}"))
        }
    }
}
