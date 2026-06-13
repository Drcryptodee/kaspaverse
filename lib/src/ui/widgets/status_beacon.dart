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

/// Dot + label, never colour alone (§11). Value-driven and stateless so widget
/// tests drive it directly; the 1 s age cadence lives in the parent ticker.
class StatusBeacon extends StatelessWidget {
  const StatusBeacon({
    super.key,
    required this.state,
    required this.endpoint,
    required this.error,
    required this.age,
  });

  final BeaconState state;
  final String? endpoint;
  final String? error;
  final Duration? age;

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
      BeaconState.connected => (KvColor.primary, endpoint ?? 'connected'),
    };
    return Row(
      children: [
        Icon(Icons.circle, size: 12, color: color),
        const SizedBox(width: KvSpace.s),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
