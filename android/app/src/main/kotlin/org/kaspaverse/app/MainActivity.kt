package org.kaspaverse.app

import android.app.Activity
import android.content.Intent
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The platform ceremony surface (P1 §0.5/§0.6). A `MethodChannel` we own
 * (~tens of lines) drives FLAG_SECURE, the accessibility-service gate, and the
 * Path-A biometric ceremony. `FlutterFragmentActivity` (not the plain
 * `FlutterActivity`) is required by `BiometricPrompt`.
 *
 * The seed itself never touches this channel — biometric enroll/unlock route
 * through [KeystoreVault] → [VaultBridge] (the JNI lane). Only booleans and
 * status strings cross the MethodChannel.
 */
class MainActivity : FlutterFragmentActivity() {
    private val channel = "org.kaspaverse.app/ceremony"

    // The pending Dart reply for an in-flight native reveal (D-039). RevealActivity
    // returns RESULT_OK only after the verify quiz passes; RESULT_CANCELED otherwise.
    private var pendingReveal: MethodChannel.Result? = null
    private val revealLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { res ->
        val reply = pendingReveal
        pendingReveal = null
        reply?.success(res.resultCode == Activity.RESULT_OK)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // App-private files dir for the Rust vault store (INV-3).
                    // Keeps path_provider (a plugin on the custody path) out.
                    "getFilesDir" -> result.success(filesDir.absolutePath)

                    // §0.6 FLAG_SECURE: secret screens call setSecure(true) on
                    // enter and setSecure(false) on exit (no screenshots/recents).
                    "setSecure" -> {
                        val on = call.arguments as? Boolean ?: true
                        runOnUiThread {
                            if (on) {
                                window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            } else {
                                window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                            }
                            result.success(null)
                        }
                    }

                    // §0.6 a11y gate: secret screens refuse to render while ANY
                    // accessibility service is enabled. This is the query; the
                    // refuse-to-render + explanation screen is the Dart guard.
                    "isAccessibilityActive" -> result.success(isAccessibilityActive(this))

                    // §0.6 native word reveal + verify (D-037/D-039): launch the
                    // dedicated FLAG_SECURE RevealActivity; it reads the held
                    // ceremony words over the JNI lane (never Dart) and returns true
                    // only once the verify quiz passes. Words never cross this
                    // channel — only the boolean verdict does.
                    "revealAndVerify" -> {
                        if (pendingReveal != null) {
                            result.error("BUSY", "a reveal is already in progress", null)
                        } else {
                            pendingReveal = result
                            revealLauncher.launch(Intent(this, RevealActivity::class.java))
                        }
                    }

                    "biometricAvailable" -> result.success(KeystoreVault.isBiometricAvailable(this))
                    "pathAEnrolled" -> result.success(KeystoreVault.isEnrolled(this))
                    "clearBiometric" -> {
                        KeystoreVault.clearEnrollment(this)
                        result.success(null)
                    }

                    // Async (BiometricPrompt callback) — reply once resolved.
                    "enrollBiometric" -> KeystoreVault.enroll(this) { ok, err ->
                        if (ok) result.success(true) else result.error("ENROLL", err, null)
                    }
                    "unlockBiometric" -> KeystoreVault.unlock(this) { ok, err ->
                        if (ok) result.success(true) else result.error("UNLOCK", err, null)
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
