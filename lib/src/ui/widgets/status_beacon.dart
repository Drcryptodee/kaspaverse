import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The four honest states of a chain link (DS-1, design_system §8). Colour is
/// never the only signal — every state pairs a dot colour with a text label
/// (§11).
enum BeaconState { connected, connecting, stale, error }

/// Pure state derivation — the testable heart of the P0.3 stale-dimming
/// retrofit. Priority: an error outranks everything; no data yet is
/// `connecting`; a dropped link OR a silence past [staleAfter] is `stale`
/// (last-known data must never read at full brightness — DS-1); otherwise
/// `connected`.
///
/// [age] is the time since the last *fresh* snapshot (null ⇒ none ever).
BeaconState evaluateBeacon({
  required bool connected,
  required Duration? age,
  required String? error,
  Duration staleAfter = KvFreshness.staleAfter,
}) {
  if (error != null) return BeaconState.error;
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
/// The live dot breathes on [pulsePhase] — flipped by the parent's existing
/// 1 s freshness ticker, so the pulse IS the freshness clock made visible
/// (§6 attention-guidance; honest under DS-1: it stops the moment the link
/// stops being live). Value-driven and stateless so widget tests drive it
/// directly.
class StatusBeacon extends StatelessWidget {
  const StatusBeacon({
    super.key,
    required this.state,
    required this.endpoint,
    required this.error,
    required this.age,
    this.pulsePhase = true,
    this.onTap,
  });

  final BeaconState state;
  final String? endpoint;
  final String? error;
  final Duration? age;

  /// Alternates each freshness tick; drives the live breath.
  final bool pulsePhase;

  /// Opens the network details (endpoint, DAA, age) — plain chip if null.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Color color, String label) = switch (state) {
      BeaconState.error => (KvColor.error, error ?? 'connection error'),
      BeaconState.connecting => (
        KvColor.textTertiary,
        'connecting to mainnet…',
      ),
      // Degraded link = warning (§3: warning means exactly "stale link").
      BeaconState.stale => (
        KvColor.warning,
        age == null ? 'no recent update' : 'as of ${formatAge(age!)} ago',
      ),
      BeaconState.connected => (KvColor.primary, 'Mainnet'),
    };

    final live = state == BeaconState.connected;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final dot = AnimatedOpacity(
      // The breath: full ↔ dimmed with each tick; static when motion is
      // reduced or the link is not live.
      opacity: (!live || reduced || pulsePhase) ? 1.0 : 0.45,
      duration: KvMotion.slow,
      curve: KvMotion.out,
      child: Container(
        width: KvSpace.s,
        height: KvSpace.s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          // Glow is rationed to live-data emphasis (§3) — a live link only.
          boxShadow: live
              ? const [BoxShadow(color: KvColor.glow, blurRadius: 8)]
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
