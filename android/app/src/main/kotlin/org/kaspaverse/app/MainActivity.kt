package org.kaspaverse.app

import android.provider.Settings
import android.view.WindowManager
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
                    "isAccessibilityActive" -> result.success(isAccessibilityActive())

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

    /** True if any accessibility service is currently enabled (§0.6). */
    private fun isAccessibilityActive(): Boolean {
        val enabled = Settings.Secure.getInt(
            contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0
        )
        if (enabled != 1) return false
        val services = Settings.Secure.getString(
            contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        )
        return !services.isNullOrEmpty()
    }
}
