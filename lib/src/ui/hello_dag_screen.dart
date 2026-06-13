import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme/tokens.dart';
import 'widgets/status_beacon.dart';

/// Group digits in threes for display: 458174109 → "458,174,109".
/// Scores arrive as [BigInt] (L3) and are only formatted here, at render.
String formatScore(BigInt? value) {
  if (value == null) {
    return '—';
  }
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// The home screen: live virtual DAA + sink blue score from mainnet, behind the
/// StatusBeacon. State is injected as listenables so widget tests run without
/// the native library. A 1 s ticker advances the freshness age (DS-1) so the
/// beacon goes stale and the scores dim even when no new snapshot arrives.
class HelloDagScreen extends StatefulWidget {
  const HelloDagScreen({
    super.key,
    required this.connected,
    required this.endpoint,
    required this.virtualDaaScore,
    required this.sinkBlueScore,
    required this.error,
    required this.lastUpdate,
    this.clock = DateTime.now,
    this.floatingActionButton,
  });

  final ValueListenable<bool> connected;
  final ValueListenable<String?> endpoint;
  final ValueListenable<BigInt?> virtualDaaScore;
  final ValueListenable<BigInt?> sinkBlueScore;
  final ValueListenable<String?> error;

  /// Time of the last fresh snapshot — the freshness clock (DS-1).
  final ValueListenable<DateTime?> lastUpdate;

  /// Test seam for "now" (default wall-clock).
  final DateTime Function() clock;

  /// Optional FAB — `main.dart` passes the debug-only DevVaultPanel launcher
  /// here so this product screen never imports the dev panel (D5 caging).
  final Widget? floatingActionButton;

  @override
  State<HelloDagScreen> createState() => _HelloDagScreenState();
}

class _HelloDagScreenState extends State<HelloDagScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-evaluate freshness every second so the stale state and "as of N ago"
    // line advance without a new snapshot (DS-1). Cached truth dimmed beats a
    // shimmer (§6).
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Duration? _age() {
    final last = widget.lastUpdate.value;
    return last == null ? null : widget.clock().difference(last);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('KaspaVerse')),
      floatingActionButton: widget.floatingActionButton,
      body: Padding(
        padding: const EdgeInsets.all(KvSpace.gutter),
        child: AnimatedBuilder(
          animation: Listenable.merge([
            widget.connected,
            widget.endpoint,
            widget.error,
            widget.lastUpdate,
            widget.virtualDaaScore,
            widget.sinkBlueScore,
          ]),
          builder: (context, _) {
            final age = _age();
            final state = evaluateBeacon(
              connected: widget.connected.value,
              age: age,
              error: widget.error.value,
            );
            final stale = state == BeaconState.stale;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatusBeacon(
                  state: state,
                  endpoint: widget.endpoint.value,
                  error: widget.error.value,
                  age: age,
                ),
                const Spacer(),
                _ScoreTile(
                  label: 'Virtual DAA score',
                  score: widget.virtualDaaScore.value,
                  stale: stale,
                ),
                const SizedBox(height: KvSpace.l),
                _ScoreTile(
                  label: 'Sink blue score',
                  score: widget.sinkBlueScore.value,
                  stale: stale,
                ),
                const Spacer(flex: 2),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ScoreTile extends StatelessWidget {
  const _ScoreTile({
    required this.label,
    required this.score,
    required this.stale,
  });

  final String label;
  final BigInt? score;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: theme.textTheme.titleMedium),
        const SizedBox(height: KvSpace.s),
        // Stale chain data dims to opacity-stale (DS-1); the beacon carries the
        // age. displaySmall is mono + tabular from the theme so digits never
        // jiggle as values tick (DS-2/§4). FittedBox shrinks an oversized
        // number to fit rather than wrap or ellipsize it — the number is never
        // truncated, even at 1.3× text scale (DS-2).
        AnimatedOpacity(
          opacity: stale ? KvFreshness.opacityStale : 1.0,
          duration: KvMotion.instant,
          curve: KvMotion.out,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatScore(score),
              maxLines: 1,
              style: theme.textTheme.displaySmall?.copyWith(
                color: KvColor.primary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
