package org.kaspaverse.app

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
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

    // OS default-network signal (C5/D-089, ruling 3: zero new dependencies).
    // Only a boolean crosses this channel — availability, never identity.
    private val networkChannelName = "org.kaspaverse.app/network"
    private var networkChannel: MethodChannel? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

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

                    // The same question as `biometricAvailable`, but answered with
                    // the REASON. A bool cannot tell "this phone has no fingerprint
                    // sensor" from "you never set one up in Android Settings", and
                    // the second is both the common case and the actionable one —
                    // answered as `false`, the enrolment offer simply never appears
                    // and the user is told nothing at all.
                    "biometricStatus" -> result.success(KeystoreVault.biometricStatus(this))

                    "pathAEnrolled" -> result.success(KeystoreVault.isEnrolled(this))

                    // Version, build and the signing-certificate fingerprint — the
                    // user-side half of RELEASE.md's provenance story, so an install
                    // can be checked against a published fingerprint on the glass.
                    // Public metadata only. Read through the channel we already own
                    // rather than package_info_plus, for the same reason
                    // `getFilesDir` is here: no new plugin on the custody path.
                    "packageInfo" -> result.success(packageInfo())
                    "clearBiometric" -> {
                        KeystoreVault.clearEnrollment(this)
                        result.success(null)
                    }

                    // Async (BiometricPrompt callback) — reply once resolved. The
                    // error CODE crosses as the platform error code, so Dart can
                    // tell a user's own cancel from a lockout from a locked vault
                    // without reading the diagnostic message.
                    "enrollBiometric" -> KeystoreVault.enroll(this) { ok, failure ->
                        if (ok) {
                            result.success(true)
                        } else {
                            result.error(
                                failure?.code ?: KeystoreVault.CODE_FAILED,
                                failure?.message,
                                null,
                            )
                        }
                    }
                    "unlockBiometric" -> KeystoreVault.unlock(this) { ok, failure ->
                        if (ok) {
                            result.success(true)
                        } else {
                            result.error(
                                failure?.code ?: KeystoreVault.CODE_FAILED,
                                failure?.message,
                                null,
                            )
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        // C5 (D-089): relay the OS default-network transitions to Dart → Rust.
        // Callbacks arrive on a ConnectivityManager binder thread — marshal to
        // the main thread before touching the channel (host-side crash class).
        networkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, networkChannelName,
        )
        if (networkCallback == null) {
            val cm = getSystemService(ConnectivityManager::class.java)
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    runOnUiThread { networkChannel?.invokeMethod("networkChanged", true) }
                }

                override fun onLost(network: Network) {
                    runOnUiThread { networkChannel?.invokeMethod("networkChanged", false) }
                }
            }
            cm.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        }
    }

    /**
     * Public build identity: version name, build number, and the SHA-256 of the
     * signing certificate.
     *
     * The fingerprint is lowercase hex with no separators — the exact form
     * `apksigner verify --print-certs` prints, so a user comparing an install
     * against a published fingerprint is comparing like with like. (`keytool`'s
     * colon-separated uppercase is the same bytes in a different dress; the UI
     * chunks for reading and never reformats the value.)
     *
     * Every field degrades to "—" rather than throwing: an About row is not worth
     * a crash, and API 26/27 cannot answer the signing question the modern way.
     */
    private fun packageInfo(): Map<String, String> {
        val version = runCatching {
            val info = packageManager.getPackageInfo(packageName, 0)
            val build = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                info.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toString()
            }
            (info.versionName ?: "—") to build
        }.getOrDefault("—" to "—")

        return mapOf(
            "version" to version.first,
            "build" to version.second,
            "signature" to (signingFingerprint() ?: "—"),
        )
    }

    private fun signingFingerprint(): String? = runCatching {
        val certificate: ByteArray? =
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                val info = packageManager
                    .getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                    .signingInfo
                // A rotated key reports history; a multi-signer APK reports the
                // set. Either way the FIRST entry is the one that signed this
                // install, which is what a fingerprint check is asking about.
                val signers = when {
                    info == null -> emptyArray()
                    info.hasMultipleSigners() -> info.apkContentsSigners
                    else -> info.signingCertificateHistory
                }
                signers?.firstOrNull()?.toByteArray()
            } else {
                @Suppress("DEPRECATION")
                packageManager
                    .getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
                    .signatures
                    ?.firstOrNull()
                    ?.toByteArray()
            }
        certificate?.let {
            java.security.MessageDigest.getInstance("SHA-256")
                .digest(it)
                .joinToString("") { byte -> "%02x".format(byte) }
        }
    }.getOrNull()

    override fun onDestroy() {
        networkCallback?.let {
            getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it)
        }
        networkCallback = null
        networkChannel = null
        super.onDestroy()
    }
}
