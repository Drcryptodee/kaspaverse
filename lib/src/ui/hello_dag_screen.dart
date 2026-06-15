import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api/wallet.dart';
import 'format.dart';
import 'theme/tokens.dart';
import 'widgets/amount_text.dart';
import 'widgets/status_beacon.dart';

/// Group digits in threes for the node-status readout: 458174109 →
/// "458,174,109". Scores arrive as [BigInt] (L3); formatted only here, at
/// render. Delegates to the shared [groupThousands].
String formatScore(BigInt? value) =>
    value == null ? '—' : groupThousands(value.toString());

/// The wallet home (P1.5): balance hero + activity feed for the unlocked
/// vault's addresses, with node health folded into the [StatusBeacon] and a
/// small live DAA readout. State is injected as listenables so widget tests run
/// without the native library; a 1 s ticker advances the freshness age (DS-1)
/// so the beacon goes stale and the balance dims even when no new snapshot
/// arrives.
class HelloDagScreen extends StatefulWidget {
  const HelloDagScreen({
    super.key,
    // Node / link (ChainService): the beacon + the live DAA readout.
    required this.connected,
    required this.endpoint,
    required this.virtualDaaScore,
    required this.error,
    required this.lastUpdate,
    // Wallet (WalletService): balance + activity.
    required this.mature,
    required this.pending,
    required this.outgoing,
    required this.activity,
    required this.syncing,
    required this.utxoIndexMissing,
    this.onReady,
    this.receiveAddress,
    this.clock = DateTime.now,
    this.floatingActionButton,
  });

  final ValueListenable<bool> connected;
  final ValueListenable<String?> endpoint;
  final ValueListenable<BigInt?> virtualDaaScore;
  final ValueListenable<String?> error;

  /// Time of the last fresh node snapshot — the link freshness clock (DS-1).
  final ValueListenable<DateTime?> lastUpdate;

  final ValueListenable<BigInt?> mature;
  final ValueListenable<BigInt?> pending;
  final ValueListenable<BigInt?> outgoing;
  final ValueListenable<List<ActivityRecord>> activity;
  final ValueListenable<bool> syncing;
  final ValueListenable<bool> utxoIndexMissing;

  /// Called once on mount (post-unlock) — starts the wallet sync engine.
  final VoidCallback? onReady;

  /// Fetches the receive address for the Receive sheet (`null` ⇒ no Receive UI).
  final Future<String> Function()? receiveAddress;

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
    // Start the wallet sync engine now that the vault is unlocked (the shell
    // only mounts this screen when unlocked). Idempotent in the service.
    widget.onReady?.call();
    // Re-evaluate freshness every second so the stale state and "as of N ago"
    // line advance without a new snapshot (DS-1).
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

  Future<void> _showReceive() async {
    final fetch = widget.receiveAddress;
    if (fetch == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: KvColor.surface,
      showDragHandle: true,
      builder: (context) => _ReceiveSheet(fetch: fetch),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            widget.mature,
            widget.pending,
            widget.outgoing,
            widget.activity,
            widget.syncing,
            widget.utxoIndexMissing,
          ]),
          builder: (context, _) {
            final age = _age();
            final state = evaluateBeacon(
              connected: widget.connected.value,
              age: age,
              error: widget.error.value,
            );
            final stale = state == BeaconState.stale;
            final mature = widget.mature.value;
            final pending = widget.pending.value;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatusBeacon(
                  state: state,
                  endpoint: widget.endpoint.value,
                  error: widget.error.value,
                  age: age,
                ),
                const SizedBox(height: KvSpace.xs),
                // Small live DAA readout — the "it's alive" pulse (kept subtle).
                AnimatedOpacity(
                  opacity: stale ? KvFreshness.opacityStale : 1.0,
                  duration: KvMotion.instant,
                  child: Text(
                    'DAA ${formatScore(widget.virtualDaaScore.value)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: KvColor.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(height: KvSpace.xl),
                // Balance hero.
                AmountText(mature, stale: stale),
                if (pending != null && pending > BigInt.zero) ...[
                  const SizedBox(height: KvSpace.xs),
                  _PendingLine(pending: pending, stale: stale),
                ],
                _StatusCaption(
                  utxoIndexMissing: widget.utxoIndexMissing.value,
                  syncing: widget.syncing.value && mature == null,
                ),
                const SizedBox(height: KvSpace.l),
                if (widget.receiveAddress != null)
                  OutlinedButton.icon(
                    onPressed: _showReceive,
                    icon: const Icon(Icons.south_west, size: 18),
                    label: const Text('Receive'),
                  ),
                const SizedBox(height: KvSpace.xl),
                Text('Activity', style: theme.textTheme.titleMedium),
                const SizedBox(height: KvSpace.s),
                const Divider(height: 1, color: KvColor.border),
                Expanded(
                  child: _ActivityFeed(
                    records: widget.activity.value,
                    now: widget.clock(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The unconfirmed (pending) balance line, dimmed with the link (DS-1).
class _PendingLine extends StatelessWidget {
  const _PendingLine({required this.pending, required this.stale});

  final BigInt pending;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          '+ ',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: KvColor.textSecondary,
          ),
        ),
        AmountText(pending, role: AmountRole.row, stale: stale),
        Text(
          '  pending',
          style: theme.textTheme.labelSmall?.copyWith(
            color: KvColor.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// Honest sub-line under the balance: an INV-8 degrade warning, a transient
/// "syncing…" while the first scan runs, or nothing.
class _StatusCaption extends StatelessWidget {
  const _StatusCaption({required this.utxoIndexMissing, required this.syncing});

  final bool utxoIndexMissing;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (utxoIndexMissing) {
      return Padding(
        padding: const EdgeInsets.only(top: KvSpace.s),
        child: Text(
          'node has no UTXO index — retrying another node',
          style: theme.textTheme.bodySmall?.copyWith(color: KvColor.warning),
        ),
      );
    }
    if (syncing) {
      return Padding(
        padding: const EdgeInsets.only(top: KvSpace.s),
        child: Text(
          'syncing…',
          style: theme.textTheme.bodySmall?.copyWith(
            color: KvColor.textTertiary,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

/// The activity list, or a quiet empty state (live, never a forever-skeleton).
class _ActivityFeed extends StatelessWidget {
  const _ActivityFeed({required this.records, required this.now});

  final List<ActivityRecord> records;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (records.isEmpty) {
      return Center(
        child: Text(
          'No recent activity',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: KvColor.textTertiary,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: KvSpace.s),
      itemCount: records.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: KvColor.border),
      itemBuilder: (context, i) => _ActivityRow(record: records[i], now: now),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.record, required this.now});

  final ActivityRecord record;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final incoming = record.direction == ActivityDirection.incoming;
    final icon = switch (record.direction) {
      ActivityDirection.incoming => Icons.south_west,
      ActivityDirection.outgoing => Icons.north_east,
      ActivityDirection.change => Icons.sync_alt,
    };
    final pending = record.maturity == MaturityState.pending;
    final time = record.unixtimeMsec;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.sm),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: incoming ? KvColor.primaryMuted : KvColor.textSecondary,
          ),
          const SizedBox(width: KvSpace.sm),
          Expanded(child: AmountText(record.valueSompi, role: AmountRole.row)),
          const SizedBox(width: KvSpace.s),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                pending ? 'Pending' : 'Confirmed',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: pending ? KvColor.warning : KvColor.success,
                ),
              ),
              if (time != null)
                Text(
                  _relativeAge(now, time),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: KvColor.textTertiary,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// "2 m ago" / "just now" — floors, never overstates (DS-1).
  static String _relativeAge(DateTime now, BigInt unixtimeMsec) {
    final at = DateTime.fromMillisecondsSinceEpoch(unixtimeMsec.toInt());
    final age = now.difference(at);
    if (age.inSeconds < 5) return 'just now';
    return '${formatAge(age)} ago';
  }
}

/// Modal sheet showing the receive address (public; copy to clipboard is fine —
/// INV-3 forbids secrets, not addresses).
class _ReceiveSheet extends StatelessWidget {
  const _ReceiveSheet({required this.fetch});

  final Future<String> Function() fetch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          0,
          KvSpace.gutter,
          KvSpace.l,
        ),
        child: FutureBuilder<String>(
          future: fetch(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(KvSpace.xl),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Padding(
                padding: const EdgeInsets.all(KvSpace.m),
                child: Text(
                  'Could not load the receive address.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: KvColor.error,
                  ),
                ),
              );
            }
            final address = snapshot.data!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Receive', style: theme.textTheme.titleMedium),
                const SizedBox(height: KvSpace.m),
                Container(
                  padding: const EdgeInsets.all(KvSpace.m),
                  decoration: BoxDecoration(
                    color: KvColor.surfaceAlt,
                    borderRadius: BorderRadius.circular(KvRadius.data),
                  ),
                  child: SelectableText(
                    address,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: KvSpace.m),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: address));
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy address'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
