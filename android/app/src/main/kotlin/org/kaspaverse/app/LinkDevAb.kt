package org.kaspaverse.app

import android.content.Context
import android.content.pm.ApplicationInfo
import android.net.TrafficStats
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File

/**
 * LINK-Q2's measurement seam, platform half — dev flags only, logs only.
 *
 * Reads the same flags file as the Rust seam (`files/wallet/devab.flags`,
 * `kaspaverse_chain::devab`) every 2 s while the activity is resumed — and only
 * in the side-by-side dev install (`org.kaspaverse.app.dev`, `KV_DEV_INSTALL=1`)
 * on a debuggable build, the same fence the Rust half keeps: the wallet itself
 * never runs an arm. No file, or anything but `on=1`, and this does nothing but
 * look. Two instruments:
 *
 *  - `wifilock=1`: a [WifiManager.WifiLock] in `WIFI_MODE_FULL_LOW_LATENCY`
 *    (API 29+), held only while resumed with the screen on — the framework
 *    honours the mode only then — and released on any pause.
 *  - `on=1`: this app's own bytes in and out every 5 s ([TrafficStats], own
 *    uid), so an arm's wire cost is the kernel's count, not an estimate.
 *
 * Every line is tag `kaspaverse` and starts `devab: `, so it lands in the same
 * capture stream as the Rust seam's lines and partitions by the same `cell=`.
 */
internal class LinkDevAb(private val context: Context) {
    private companion object {
        const val TAG = "kaspaverse"
        const val POLL_MS = 2_000L
        const val BYTES_MS = 5_000L
        const val FLAGS = "wallet/devab.flags"
        // The Rust half's FLAGS_MAX_AGE: a file not rewritten for 12 h is off.
        const val MAX_AGE_MS = 12L * 3600 * 1000
    }

    private val handler = Handler(Looper.getMainLooper())
    private val enabled =
        (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 &&
            context.packageName == "org.kaspaverse.app.dev"
    private var lock: WifiManager.WifiLock? = null
    private var resumed = false
    private var lastBytesAt = 0L

    private val tick = object : Runnable {
        override fun run() {
            if (!resumed) return
            poll()
            handler.postDelayed(this, POLL_MS)
        }
    }

    fun resume() {
        if (!enabled) return
        resumed = true
        handler.removeCallbacks(tick)
        handler.post(tick)
    }

    fun pause() {
        resumed = false
        handler.removeCallbacks(tick)
        release("paused")
    }

    private fun poll() {
        val flags = readFlags()
        if (flags["on"] != "1") {
            release("-")
            return
        }
        val cell = cellOf(flags["cell"])
        if (flags["wifilock"] == "1" && screenOn()) acquire(cell) else release(cell)
        val now = SystemClock.elapsedRealtime()
        if (now - lastBytesAt >= BYTES_MS) {
            lastBytesAt = now
            val uid = Process.myUid()
            Log.i(
                TAG,
                "devab: bytes rx=${TrafficStats.getUidRxBytes(uid)} " +
                    "tx=${TrafficStats.getUidTxBytes(uid)} " +
                    "t=${System.currentTimeMillis()} cell=$cell",
            )
        }
    }

    /** `key=value` lines; unreadable, absent or stale (12 h) reads as empty (all off). */
    private fun readFlags(): Map<String, String> {
        val file = File(context.filesDir, FLAGS)
        // A future stamp is stale too, as `elapsed()` refuses one in the Rust half.
        val age = System.currentTimeMillis() - file.lastModified()
        if (age < 0 || age > MAX_AGE_MS) return emptyMap()
        return try {
            file.readLines()
                .mapNotNull { line ->
                    val at = line.indexOf('=')
                    if (at <= 0) null else line.substring(0, at).trim() to line.substring(at + 1).trim()
                }
                .toMap()
        } catch (e: Exception) {
            emptyMap()
        }
    }

    /** The arm label, kept to the Rust seam's alphabet. */
    private fun cellOf(raw: String?): String {
        val kept = raw.orEmpty()
            .filter { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in "._-" }
            .take(32)
        return kept.ifEmpty { "-" }
    }

    private fun screenOn(): Boolean =
        (context.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isInteractive == true

    private fun acquire(cell: String) {
        if (lock?.isHeld == true) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.i(TAG, "devab: wifilock unavailable sdk=${Build.VERSION.SDK_INT} cell=$cell")
            return
        }
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return
        try {
            val l = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "kaspaverse:linkq2")
            l.setReferenceCounted(false)
            l.acquire()
            lock = l
            Log.i(TAG, "devab: wifilock held=${l.isHeld} mode=low-latency sdk=${Build.VERSION.SDK_INT} cell=$cell")
        } catch (e: SecurityException) {
            // A build without WAKE_LOCK (release carries none): say so, hold nothing.
            Log.i(TAG, "devab: wifilock refused (no WAKE_LOCK) cell=$cell")
        }
    }

    private fun release(cell: String) {
        val l = lock ?: return
        lock = null
        try {
            if (l.isHeld) l.release()
        } catch (e: RuntimeException) {
            // Already released by the framework; nothing to undo.
        }
        Log.i(TAG, "devab: wifilock held=false cell=$cell")
    }
}
