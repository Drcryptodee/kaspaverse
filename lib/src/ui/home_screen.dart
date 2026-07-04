import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../rust/api/wallet.dart';
import 'format.dart';
import 'theme/tokens.dart';
import 'widgets/amount_text.dart';
import 'widgets/entrance.dart';
import 'widgets/glass_panel.dart';
import 'widgets/status_beacon.dart';

/// Group digits in threes for the node-status readout: 458174109 →
/// "458,174,109". Scores arrive as [BigInt] (L3); formatted only here, at
/// render. Delegates to the shared [groupThousands].
String formatScore(BigInt? value) =>
    value == null ? '—' : groupThousands(value.toString());

/// The wallet home — the glass cockpit (design_system §1). One instrument
/// panel: the balance with its freshness truth (DS-1), the link state worn as
/// a compact beacon chip (endpoint detail behind a tap, §12), the two money
/// actions in the thumb zone, and the activity feed. State is injected as
/// listenables so widget tests run without the native library; a 1 s ticker
/// advances the freshness age (DS-1) so the beacon goes stale and the balance
/// dims even when no new snapshot arrives — the same tick drives the live
/// dot's breath.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
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
    this.receiveRoute,
    this.sendRoute,
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

  /// Builds the Receive screen (`null` ⇒ no Receive UI). `main.dart` wires it to
  /// `vaultReceiveAddress` so this consumer never imports it.
  final WidgetBuilder? receiveRoute;

  /// Builds the Send screen (`null` ⇒ no Send UI). `main.dart` wires it to the
  /// wallet service so this consumer never imports it.
  final WidgetBuilder? sendRoute;

  /// Test seam for "now" (default wall-clock).
  final DateTime Function() clock;

  /// Optional FAB — `main.dart` passes the debug-only dev-panel launchers
  /// here so this product screen never imports the dev panels (D5 caging).
  final Widget? floatingActionButton;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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

  void _openSend() {
    final builder = widget.sendRoute;
    if (builder == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
  }

  void _openReceive() {
    final builder = widget.receiveRoute;
    if (builder == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: builder));
  }

  /// The §12 power-user tap: endpoint, DAA and freshness in plain sight —
  /// the ONE frosted panel this screen ever spends (§8 budget; a sheet
  /// overlays live content, so the blur has something honest to refract).
  void _openNetworkSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (_) => _NetworkSheet(
        connected: widget.connected,
        endpoint: widget.endpoint,
        virtualDaaScore: widget.virtualDaaScore,
        error: widget.error,
        lastUpdate: widget.lastUpdate,
        clock: widget.clock,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      floatingActionButton: widget.floatingActionButton,
      body: SafeArea(
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
            final now = widget.clock();
            final age = _age();
            final state = evaluateBeacon(
              connected: widget.connected.value,
              age: age,
              error: widget.error.value,
            );
            final stale = state == BeaconState.stale;
            final mature = widget.mature.value;
            final pending = widget.pending.value;
            final hasActions =
                widget.sendRoute != null || widget.receiveRoute != null;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    KvSpace.gutter,
                    KvSpace.m,
                    KvSpace.gutter,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            'KaspaVerse',
                            style: theme.textTheme.titleMedium?.copyWith(
                              letterSpacing: 0.2,
                            ),
                          ),
                          const Spacer(),
                          StatusBeacon(
                            state: state,
                            endpoint: widget.endpoint.value,
                            error: widget.error.value,
                            age: age,
                            pulsePhase: now.second.isEven,
                            onTap: _openNetworkSheet,
                          ),
                        ],
                      ),
                      const SizedBox(height: KvSpace.l),
                      Entrance(
                        child: _BalancePanel(
                          mature: mature,
                          pending: pending,
                          stale: stale,
                          daaLine:
                              'DAA ${formatScore(widget.virtualDaaScore.value)}',
                          utxoIndexMissing: widget.utxoIndexMissing.value,
                          syncing: widget.syncing.value && mature == null,
                        ),
                      ),
                      if (hasActions) ...[
                        const SizedBox(height: KvSpace.m),
                        Entrance(
                          index: 1,
                          child: Row(
                            children: [
                              if (widget.sendRoute != null)
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: _openSend,
                                    icon: const Icon(
                                      Icons.north_east,
                                      size: 18,
                                    ),
                                    label: const Text('Send'),
                                  ),
                                ),
                              if (widget.sendRoute != null &&
                                  widget.receiveRoute != null)
                                const SizedBox(width: KvSpace.sm),
                              if (widget.receiveRoute != null)
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: _openReceive,
                                    icon: const Icon(
                                      Icons.south_west,
                                      size: 18,
                                      color: KvColor.primaryMuted,
                                    ),
                                    label: const Text('Receive'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: KvSpace.xl),
                      Entrance(
                        index: 2,
                        child: Text(
                          'Activity',
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(height: KvSpace.s),
                    ],
                  ),
                ),
                const Divider(),
                Expanded(
                  child: _ActivityFeed(
                    records: widget.activity.value,
                    now: now,
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

/// The balance instrument: one solid panel (the §8 fallback — no blur budget
/// spent over flat abyss), reading top to bottom as label → the number →
/// its caveats → the chain clock.
class _BalancePanel extends StatelessWidget {
  const _BalancePanel({
    required this.mature,
    required this.pending,
    required this.stale,
    required this.daaLine,
    required this.utxoIndexMissing,
    required this.syncing,
  });

  final BigInt? mature;
  final BigInt? pending;
  final bool stale;
  final String daaLine;
  final bool utxoIndexMissing;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Total balance',
            style: theme.textTheme.labelSmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
          const SizedBox(height: KvSpace.s),
          AmountText(mature, stale: stale),
          if (pending != null && pending! > BigInt.zero) ...[
            const SizedBox(height: KvSpace.xs),
            _PendingLine(pending: pending!, stale: stale),
          ],
          _StatusCaption(utxoIndexMissing: utxoIndexMissing, syncing: syncing),
          const SizedBox(height: KvSpace.m),
          // The chain clock — quiet proof the cockpit is live, dimmed with
          // the link (DS-1).
          AnimatedOpacity(
            opacity: stale ? KvFreshness.opacityStale : 1.0,
            duration: KvMotion.instant,
            child: Text(
              daaLine,
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textTertiary,
              ),
            ),
          ),
        ],
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
        AmountText(pending, role: AmountRole.row, stale: stale, prefix: '+ '),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'No recent activity',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: KvColor.textTertiary,
              ),
            ),
            const SizedBox(height: KvSpace.xs),
            Text(
              'Payments you send and receive appear here.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: KvColor.textDisabled,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.gutter,
        KvSpace.s,
        KvSpace.gutter,
        KvSpace.xl,
      ),
      itemCount: records.length,
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
    final icon = switch (record.direction) {
      ActivityDirection.incoming => Icons.south_west,
      ActivityDirection.outgoing => Icons.north_east,
      ActivityDirection.change => Icons.sync_alt,
    };
    // Direction semantics (§3): a deposit is green, a withdrawal is red — the
    // universal money convention, felt at a glance (founder directive). Never
    // colour alone (§11): the title and the sign say it too.
    final tint = switch (record.direction) {
      ActivityDirection.incoming => KvColor.success,
      ActivityDirection.outgoing => KvColor.error,
      ActivityDirection.change => KvColor.textSecondary,
    };
    final title = switch (record.direction) {
      ActivityDirection.incoming => record.isCoinbase ? 'Mined' : 'Received',
      ActivityDirection.outgoing => 'Sent',
      ActivityDirection.change => 'Consolidated',
    };
    final sign = switch (record.direction) {
      ActivityDirection.incoming => '+ ',
      ActivityDirection.outgoing => '− ',
      ActivityDirection.change => null,
    };
    final pending = record.maturity == MaturityState.pending;
    final time = record.unixtimeMsec;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.sm),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(KvRadius.data),
            ),
            child: Icon(icon, size: 20, color: tint),
          ),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                if (time != null)
                  Text(
                    _relativeAge(now, time),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: KvColor.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: KvSpace.s),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              AmountText(record.valueSompi, role: AmountRole.row, prefix: sign),
              // Confirmed is the normal state and stays quiet (Rams #5);
              // only the exception is labelled.
              if (pending)
                Text(
                  'Pending',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: KvColor.warning,
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

/// The network details sheet — sovereignty made visible: which public node,
/// how fresh, what the chain clock reads. Frosted (§8: the screen's one blur,
/// over real content). Values stay live via the same listenables the home
/// watches.
class _NetworkSheet extends StatelessWidget {
  const _NetworkSheet({
    required this.connected,
    required this.endpoint,
    required this.virtualDaaScore,
    required this.error,
    required this.lastUpdate,
    required this.clock,
  });

  final ValueListenable<bool> connected;
  final ValueListenable<String?> endpoint;
  final ValueListenable<BigInt?> virtualDaaScore;
  final ValueListenable<String?> error;
  final ValueListenable<DateTime?> lastUpdate;
  final DateTime Function() clock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: GlassPanel(
        frosted: true,
        radius: const BorderRadius.vertical(
          top: Radius.circular(KvRadius.card),
        ),
        padding: const EdgeInsets.all(KvSpace.gutter),
        child: AnimatedBuilder(
          animation: Listenable.merge([
            connected,
            endpoint,
            virtualDaaScore,
            error,
            lastUpdate,
          ]),
          builder: (context, _) {
            final last = lastUpdate.value;
            final age = last == null ? null : clock().difference(last);
            final state = evaluateBeacon(
              connected: connected.value,
              age: age,
              error: error.value,
            );
            final status = switch (state) {
              BeaconState.error => error.value ?? 'connection error',
              BeaconState.connecting => 'connecting to mainnet…',
              BeaconState.stale =>
                age == null
                    ? 'no recent update'
                    : 'as of ${formatAge(age)} ago',
              BeaconState.connected => 'live',
            };
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Network', style: theme.textTheme.titleMedium),
                const SizedBox(height: KvSpace.m),
                _DetailRow(label: 'Status', value: status),
                _DetailRow(
                  label: 'DAA score',
                  value: formatScore(virtualDaaScore.value),
                  mono: true,
                ),
                _DetailRow(
                  label: 'Node',
                  value: endpoint.value ?? '—',
                  mono: true,
                ),
                const SizedBox(height: KvSpace.m),
                Text(
                  'KaspaVerse talks to public Kaspa nodes directly — '
                  'no middlemen, no trackers.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: KvColor.textTertiary,
                    fontFamily: KvFont.ui,
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
                fontFamily: KvFont.ui,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? theme.textTheme.bodySmall
                  : theme.textTheme.bodySmall?.copyWith(fontFamily: KvFont.ui),
            ),
          ),
        ],
      ),
    );
  }
}
