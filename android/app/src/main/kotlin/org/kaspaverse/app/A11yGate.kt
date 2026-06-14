package org.kaspaverse.app

import android.content.Context
import android.provider.Settings

/**
 * The §0.6 accessibility gate — the single canonical check shared by the Flutter
 * secret screens (via [MainActivity]'s `isAccessibilityActive` channel method) and
 * the native [RevealActivity]. Secret-bearing surfaces refuse to render while any
 * accessibility service is enabled (founder call at P1 §0 ratification, D-028): a
 * screen reader could read words aloud, and a hostile service could scrape them.
 *
 * One definition, two callers — so the Flutter and native secret surfaces can
 * never drift on what "an accessibility service is on" means (D-039).
 */
fun isAccessibilityActive(ctx: Context): Boolean {
    val enabled = Settings.Secure.getInt(
        ctx.contentResolver, Settings.Secure.ACCESSIBILITY_ENABLED, 0
    )
    if (enabled != 1) return false
    val services = Settings.Secure.getString(
        ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
    )
    return !services.isNullOrEmpty()
}
