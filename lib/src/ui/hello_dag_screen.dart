import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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

/// P0.3 hello-DAG: live virtual DAA score + sink blue score from mainnet,
/// proving the full pipeline (Rust stream → bridge → service singleton →
/// ValueNotifier → UI). State is injected as listenables so widget tests
/// run without the native library.
class HelloDagScreen extends StatelessWidget {
  const HelloDagScreen({
    super.key,
    required this.connected,
    required this.endpoint,
    required this.virtualDaaScore,
    required this.sinkBlueScore,
    required this.error,
  });

  final ValueListenable<bool> connected;
  final ValueListenable<String?> endpoint;
  final ValueListenable<BigInt?> virtualDaaScore;
  final ValueListenable<BigInt?> sinkBlueScore;
  final ValueListenable<String?> error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('KaspaVerse')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: connected,
              builder: (context, isConnected, _) {
                return ValueListenableBuilder<String?>(
                  valueListenable: endpoint,
                  builder: (context, node, _) {
                    return _StatusRow(connected: isConnected, endpoint: node);
                  },
                );
              },
            ),
            ValueListenableBuilder<String?>(
              valueListenable: error,
              builder: (context, message, _) {
                if (message == null) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    message,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                );
              },
            ),
            const Spacer(),
            _ScoreTile(label: 'Virtual DAA score', score: virtualDaaScore),
            const SizedBox(height: 24),
            _ScoreTile(label: 'Sink blue score', score: sinkBlueScore),
            const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.connected, required this.endpoint});

  final bool connected;
  final String? endpoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = connected
        ? theme.colorScheme.primary
        : theme.colorScheme.outline;
    final label = connected
        ? (endpoint ?? 'connected')
        : 'connecting to mainnet…';
    return Row(
      children: [
        Icon(Icons.circle, size: 12, color: color),
        const SizedBox(width: 8),
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

class _ScoreTile extends StatelessWidget {
  const _ScoreTile({required this.label, required this.score});

  final String label;
  final ValueListenable<BigInt?> score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        ValueListenableBuilder<BigInt?>(
          valueListenable: score,
          builder: (context, value, _) {
            return Text(
              formatScore(value),
              style: theme.textTheme.displaySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: theme.colorScheme.primary,
              ),
            );
          },
        ),
      ],
    );
  }
}
