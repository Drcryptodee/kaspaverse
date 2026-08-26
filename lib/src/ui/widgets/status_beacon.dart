import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_breath.dart';

/// The honest states of a chain link (BG-8, design_system §8). Colour is
/// never the only signal — every state pairs a dot colour with a text label
/// (§11). [offline] is C7's addition (D-089 ruling 6): when the OS says the
/// phone has no network, the glass names the phone instead of blaming a node.
enum BeaconState { connected, connecting, stale, error, offline }

/// Pure state derivation — the testable heart of the P0.3 stale-dimming
/// retrofit, widened at C7 (D-091 ruling 1) to the three truths the engine
/// actually knows.
///
/// Priority, and why:
/// 1. **Churn hold** — a link that drops with fresh data in hand keeps reading
///    live for [churnGrace]. Sub-2 s transitions are Wi-Fi re-association
///    noise, not information (register item 16's ruling on the render side; the
///    engine's twin is `MIN_STRIKE_RUN_SECS`). It can never hold a stale
///    reading live, because [churnGrace] < [staleAfter].
/// 2. **Phone offline** — the OS's own `onLost`, and only while the socket is
///    also down: a live socket is proof of a network whatever a flapping
///    callback claims. Ranked above [error] deliberately — with no network,
///    every downstream error is a *consequence*, and "connection error" would
///    blame the nodes for the user's Wi-Fi.
/// 3. **Error** — an explicit failure we were handed.
/// 4. **Finding a node** — [searching]: a race is hunting. This is the fix for
///    the 2026-07-30 field observation (a 14–28 s weak-link hunt rendered as
///    *"as of 20 s ago"*, which reads as *connected, data slightly stale* —
///    the exact opposite of the truth). That quote is the PRE-C7 glass, kept as
///    history; the stale label has since shortened to *"20 s ago"* so the age
///    survives a narrow header (2026-08-24 — see rule 6's arm below).
/// 5. No data ever ([age] null) is also *finding a node* — honest in the
///    instant between mount and the first race flag.
/// 6. A dropped link or silence past [staleAfter] is `stale`.
/// 7. Otherwise `connected`.
///
/// **Invariant this ordering buys (C7's acceptance bar):** a staleness phrase
/// can never render before the first `wss_connected` of a process. Reaching
/// rule 6 while disconnected requires `age != null`, and only a connected
/// snapshot bearing real chain data ever sets that clock.
///
/// [age] is the time since the last *fresh* snapshot (null ⇒ none ever);
/// [sinceDrop] the time since the link last went down (null ⇒ up, or never up).
BeaconState evaluateBeacon({
  required bool connected,
  required Duration? age,
  required String? error,
  bool searching = false,
  bool osOffline = false,
  Duration? sinceDrop,
  Duration staleAfter = KvFreshness.staleAfter,
  Duration churnGrace = KvFreshness.linkChurnGrace,
}) {
  if (error == null &&
      !connected &&
      sinceDrop != null &&
      sinceDrop < churnGrace &&
      age != null &&
      age < staleAfter) {
    return BeaconState.connected;
  }
  if (!connected && osOffline) return BeaconState.offline;
  if (error != null) return BeaconState.error;
  if (!connected && searching) return BeaconState.connecting;
  if (age == null) return BeaconState.connecting;
  if (!connected || age >= staleAfter) return BeaconState.stale;
  return BeaconState.connected;
}

/// Human age for the stale line: "12 s", "3 m", "2 h". Floors — never
/// overstates freshness.
String formatAge(Duration age) {
  if (age.inSeconds < 60) return '${age.inSeconds} s';
  if (age.inMinutes < 60) return '${age.inMinutes} m';
  return '${age.inHours} h';
}

/// Dot + label, never colour alone (§11), worn as a compact chip. Connected
/// reads the plain-English network name (§12 — the endpoint URL is power-user
/// detail and lives behind [onTap], the network details sheet); the other
/// states keep their honest lines verbatim.
///
/// The live dot breathes via [KvBreath] (§8 v2.2) — a self-animated sine,
/// honest under BG-8: it stops the moment the link stops being live, and
/// freezes to a static dot under reduced motion. The beacon itself stays
/// value-driven and stateless so widget tests drive it directly.
class StatusBeacon extends StatelessWidget {
  const StatusBeacon({
    super.key,
    required this.state,
    required this.error,
    required this.age,
    this.onTap,
  });

  final BeaconState state;
  final String? error;

  /// Consumed only by the stale label ("as of N ago") — a connected beacon
  /// may pass null so its subtree stays rebuild-free between state changes.
  final Duration? age;

  /// Opens the network details (endpoint, DAA, age) — plain chip if null.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color color, String label) = switch (state) {
      BeaconState.error => (KvColor.error, error ?? 'connection error'),
      // The phone's own network, stated plainly — tertiary, not warning:
      // warning means exactly "stale link" (§3), and this is not a link fault
      // at all. Nothing for the user to distrust, something for them to fix.
      BeaconState.offline => (KvColor.textTertiary, 'phone offline'),
      // C7 copy (D-089 ruling 6): what the engine is ACTUALLY doing. "finding
      // a node" is the truth for both the first connect and every later hunt;
      // "connecting to mainnet" implied a single destination we were already
      // talking to.
      BeaconState.connecting => (KvColor.textTertiary, 'finding a node…'),
      // Degraded link = warning (§3: warning means exactly "stale link").
      // The age WITHOUT the "as of" framing, and that is a layout invariant,
      // not a copy preference (ux-auditor, 2026-08-24 fix wave). Once the
      // header made this pill yield so the Settings gear could survive a
      // squeeze (F5), the pill is the child that gets ellipsized — and BG-8
      // requires stale to be dimming PLUS a visible age. At 320 dp / textScale
      // 1.30 the old 14-character label was cut to `as of…`, losing the one
      // thing BG-8 asks for; the 8-character form fits every geometry the F5
      // table covers. `NetworkSheet` keeps the fuller phrasing — it is the
      // detail surface and has the room.
      BeaconState.stale => (
        KvColor.warning,
        age == null ? 'no recent update' : '${formatAge(age!)} ago',
      ),
      // Live mainnet = success GREEN (founder directive 2026-07-11, V2b wrap:
      // "green, not kaspa teal" — a healthy link reads as the universal
      // all-good colour; teal stays the brand/CTA voice).
      BeaconState.connected => (KvColor.success, 'Mainnet'),
    };

    final live = state == BeaconState.connected;
    // The breath means "something is happening", so a hunt breathes too (C7:
    // *finding a node…* must read as visible search activity, not as a frozen
    // label) — reusing the existing component rather than inventing a spinner
    // for the chip (D-064: no new visual language). The GLOW stays rationed to
    // live data below, so a hunt never looks like a healthy link.
    final animate = live || state == BeaconState.connecting;
    final dot = KvBreath(
      active: animate,
      child: Container(
        width: KvSpace.s,
        height: KvSpace.s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          // Glow is rationed to live-data emphasis (§3) — a live link only;
          // tinted to match the live dot (green since the founder call).
          boxShadow: live
              ? const [BoxShadow(color: KvColor.successGlow, blurRadius: 8)]
              : null,
        ),
      ),
    );

    // The pill is visually compact but the tap area honours the 48 dp law
    // (§9): the InkWell spans the full target height, the pill centres in it.
    return Semantics(
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Container(
          constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
          alignment: Alignment.center,
          child: Container(
            decoration: const ShapeDecoration(
              color: KvColor.surfaceAlt,
              shape: StadiumBorder(side: BorderSide(color: KvColor.border)),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: KvSpace.sm,
              vertical: KvSpace.s,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(child: dot),
                const SizedBox(width: KvSpace.s),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: KvColor.textSecondary,
                      fontFamily: KvFont.ui,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
