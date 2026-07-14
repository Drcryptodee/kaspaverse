import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../rust/api/dag.dart';
import '../rust/api/wallet.dart';
import 'format.dart';
import 'theme/kv_page_route.dart';
import 'theme/tokens.dart';
import 'widgets/amount_text.dart';
import 'widgets/entrance.dart';
import 'widgets/glass_panel.dart';
import 'widgets/haptics.dart';
import 'widgets/kv_loader.dart';
import 'widgets/status_beacon.dart';
import 'widgets/tx_status_chip.dart';

/// Group digits in threes for the node-status readout: 458174109 →
/// "458,174,109". Scores arrive as [BigInt] (L3); formatted only here, at
/// render. Delegates to the shared [groupThousands].
String formatScore(BigInt? value) =>
    value == null ? '—' : groupThousands(value.toString());

/// The wallet home — the glass cockpit (design_system §1). One instrument
/// panel: the balance with its freshness truth (DS-1), the link state worn as
/// a compact beacon chip (endpoint detail behind a tap, §12), the two money
/// actions in the thumb zone, and the activity feed. State is injected as
/// listenables so widget tests run without the native library; a 1 s clock
/// notifier advances the freshness age (DS-1) so the beacon goes stale and
/// the balance dims even when no new snapshot arrives.
///
/// V4 scoping: each region listens only to what it renders (derived,
/// value-gated notifiers — see [_Derived]). A balance tick never rebuilds the
/// activity list, a DAA tick repaints only the chain-clock line and the feed,
/// and the 1 s tick lands in the clock notifier, never a whole-screen
/// `setState`. The injected listenables are the test seam and must be stable
/// for the life of the state (asserted in [State.didUpdateWidget]).
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.chain,
    required this.wallet,
    this.onReady,
    this.receiveRoute,
    this.sendRoute,
    this.messagesRoute,
    this.clock = DateTime.now,
    this.floatingActionButton,
  });

  /// Node / link scope (ChainService): the beacon + the live DAA readout +
  /// the manual reconnect. A grouping of the SAME injected listenables the
  /// V4 seam law protects — the scope object may be rebuilt per parent
  /// build; the notifiers inside must stay identical (asserted in
  /// [State.didUpdateWidget]).
  final ChainScope chain;

  /// Wallet scope (WalletService): balance + activity + the pull heal.
  final WalletScope wallet;

  /// Called once on mount (post-unlock) — starts the wallet sync engine.
  final VoidCallback? onReady;

  /// Builds the Receive screen (`null` ⇒ no Receive UI). `main.dart` wires it to
  /// `vaultReceiveAddress` so this consumer never imports it.
  final WidgetBuilder? receiveRoute;

  /// Builds the Send screen (`null` ⇒ no Send UI). `main.dart` wires it to the
  /// wallet service so this consumer never imports it.
  final WidgetBuilder? sendRoute;

  /// Builds the Messages screen (P2.3 transport UI; `null` ⇒ no entry).
  final WidgetBuilder? messagesRoute;

  /// Test seam for "now" (default wall-clock).
  final DateTime Function() clock;

  /// Optional FAB — `main.dart` passes the debug-only dev-panel launchers
  /// here so this product screen never imports the dev panels (D5 caging).
  final Widget? floatingActionButton;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// The chain-facing wiring [HomeScreen] consumes, as ONE parameter (V5 —
/// retires the 18-arg hand-threading in `main.dart`). Pure grouping: the
/// fields ARE the injected listenables/callbacks (the widget-test seam —
/// tests construct this from hand-built [ValueNotifier]s, no native
/// library); identity stability is asserted on the INNER notifiers, so a
/// rebuilt scope object over the same notifiers is fine.
class ChainScope {
  const ChainScope({
    required this.connected,
    required this.endpoint,
    required this.virtualDaaScore,
    required this.error,
    required this.lastUpdate,
    this.reconnecting,
    this.onReconnect,
  });

  final ValueListenable<bool> connected;
  final ValueListenable<String?> endpoint;
  final ValueListenable<BigInt?> virtualDaaScore;
  final ValueListenable<String?> error;

  /// Time of the last fresh node snapshot — the link freshness clock (DS-1).
  final ValueListenable<DateTime?> lastUpdate;

  /// True while a reconnect is in flight (P3) — the sheet's honest indicator.
  final ValueListenable<bool>? reconnecting;

  /// Force a fresh connection — the network sheet's Reconnect action (P3).
  final Future<void> Function()? onReconnect;
}

/// The wallet-facing wiring [HomeScreen] consumes — same law as [ChainScope].
class WalletScope {
  const WalletScope({
    required this.mature,
    required this.pending,
    required this.activity,
    required this.syncing,
    required this.utxoIndexMissing,
    this.onRefreshActivity,
  });

  final ValueListenable<BigInt?> mature;
  final ValueListenable<BigInt?> pending;
  final ValueListenable<List<ActivityRecord>> activity;
  final ValueListenable<bool> syncing;
  final ValueListenable<bool> utxoIndexMissing;

  /// Swipe-to-refresh heal (founder request, V2 sitting): pulls the latest
  /// folded snapshot directly, bypassing the stream. `null` ⇒ no refresh UI.
  final Future<void> Function()? onRefreshActivity;
}

/// What the beacon chip renders, compared by value — connected steady-state
/// produces ZERO beacon rebuilds; stale walks once per second as the age
/// line advances. Records compare structurally, which is what lets
/// [_Derived] swallow the no-op ticks.
typedef _LinkView = ({BeaconState state, String? error, Duration? age});

/// What the balance panel renders (the DAA line is scoped separately inside
/// the panel — the chain clock must not rebuild the money number).
typedef _BalanceView = ({
  BigInt? mature,
  BigInt? pending,
  bool stale,
  bool syncing,
  bool utxoIndexMissing,
});

/// The V4 scoping primitive: recomputes [_compute] whenever any source
/// notifies, and — because [ValueNotifier] only notifies when the new value
/// differs — swallows every tick that would not change pixels.
class _Derived<T> extends ValueNotifier<T> {
  _Derived(this._sources, this._compute) : super(_compute()) {
    for (final s in _sources) {
      s.addListener(_recompute);
    }
  }

  final List<Listenable> _sources;
  final T Function() _compute;

  void _recompute() => value = _compute();

  @override
  void dispose() {
    for (final s in _sources) {
      s.removeListener(_recompute);
    }
    super.dispose();
  }
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _ticker;

  /// The freshness clock (DS-1) — ticked once per second. Regions that render
  /// time listen to THIS, so the tick never lands as a whole-screen setState.
  late final ValueNotifier<DateTime> _now;

  late final _Derived<_LinkView> _link;
  late final _Derived<bool> _stale;
  late final _Derived<_BalanceView> _balance;

  /// Everything the activity feed reads. The feed rebuilds on activity
  /// snapshots, depth ticks, DAA ticks and the 1 s clock (its counters and
  /// relative ages are live by design) — but never on a balance change.
  late final Listenable _feedInputs;

  @override
  void initState() {
    super.initState();
    // Start the wallet sync engine now that the vault is unlocked (the shell
    // only mounts this screen when unlocked). Idempotent in the service.
    widget.onReady?.call();
    _now = ValueNotifier(widget.clock());
    _link = _Derived([
      widget.chain.connected,
      widget.chain.error,
      widget.chain.lastUpdate,
      _now,
    ], _computeLink);
    _stale = _Derived([_link], () => _link.value.state == BeaconState.stale);
    _balance = _Derived(
      [
        widget.wallet.mature,
        widget.wallet.pending,
        widget.wallet.syncing,
        widget.wallet.utxoIndexMissing,
        _stale,
      ],
      () => (
        mature: widget.wallet.mature.value,
        pending: widget.wallet.pending.value,
        stale: _stale.value,
        syncing: widget.wallet.syncing.value,
        utxoIndexMissing: widget.wallet.utxoIndexMissing.value,
      ),
    );
    _feedInputs = Listenable.merge([
      widget.wallet.activity,
      widget.chain.virtualDaaScore,
      _stale,
      _now,
    ]);
    // Re-evaluate freshness every second so the stale state and "as of N ago"
    // line advance without a new snapshot (DS-1).
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _now.value = widget.clock();
    });
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The derived notifiers subscribed at mount; silently swapping a seam
    // would leave them wired to the old one.
    assert(
      identical(oldWidget.chain.connected, widget.chain.connected) &&
          identical(oldWidget.chain.error, widget.chain.error) &&
          identical(oldWidget.chain.lastUpdate, widget.chain.lastUpdate) &&
          identical(oldWidget.wallet.mature, widget.wallet.mature) &&
          identical(oldWidget.wallet.pending, widget.wallet.pending) &&
          identical(oldWidget.wallet.syncing, widget.wallet.syncing) &&
          identical(
            oldWidget.wallet.utxoIndexMissing,
            widget.wallet.utxoIndexMissing,
          ) &&
          identical(oldWidget.wallet.activity, widget.wallet.activity) &&
          identical(
            oldWidget.chain.virtualDaaScore,
            widget.chain.virtualDaaScore,
          ),
      'HomeScreen listenables must stay identical for the life of the state',
    );
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // Chained deriveds unhook in reverse dependency order.
    _balance.dispose();
    _stale.dispose();
    _link.dispose();
    _now.dispose();
    super.dispose();
  }

  Duration? _age() {
    final last = widget.chain.lastUpdate.value;
    return last == null ? null : _now.value.difference(last);
  }

  _LinkView _computeLink() {
    final age = _age();
    final state = evaluateBeacon(
      connected: widget.chain.connected.value,
      age: age,
      error: widget.chain.error.value,
    );
    return (
      state: state,
      error: widget.chain.error.value,
      // Only the stale label renders an age; floored to the second it shows,
      // so record equality gates out every sub-label tick.
      age: state == BeaconState.stale && age != null
          ? Duration(seconds: age.inSeconds)
          : null,
    );
  }

  void _openSend() {
    final builder = widget.sendRoute;
    if (builder == null) return;
    Navigator.of(context).push(KvPageRoute<void>(builder: builder));
  }

  void _openReceive() {
    final builder = widget.receiveRoute;
    if (builder == null) return;
    Navigator.of(context).push(KvPageRoute<void>(builder: builder));
  }

  void _openMessages() {
    final builder = widget.messagesRoute;
    if (builder == null) return;
    Navigator.of(context).push(KvPageRoute<void>(builder: builder));
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
        connected: widget.chain.connected,
        endpoint: widget.chain.endpoint,
        virtualDaaScore: widget.chain.virtualDaaScore,
        error: widget.chain.error,
        lastUpdate: widget.chain.lastUpdate,
        clock: widget.clock,
        reconnecting: widget.chain.reconnecting,
        onReconnect: widget.chain.onReconnect,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasActions =
        widget.sendRoute != null ||
        widget.receiveRoute != null ||
        widget.messagesRoute != null;

    return Scaffold(
      floatingActionButton: widget.floatingActionButton,
      body: SafeArea(
        child: Column(
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
                      // Scoped: connected steady-state never rebuilds here —
                      // the breath animates itself (KvBreath).
                      ValueListenableBuilder<_LinkView>(
                        valueListenable: _link,
                        builder: (context, link, _) => StatusBeacon(
                          state: link.state,
                          error: link.error,
                          age: link.age,
                          onTap: _openNetworkSheet,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: KvSpace.l),
                  Entrance(
                    child: ValueListenableBuilder<_BalanceView>(
                      valueListenable: _balance,
                      builder: (context, b, _) => _BalancePanel(
                        mature: b.mature,
                        pending: b.pending,
                        stale: b.stale,
                        daa: widget.chain.virtualDaaScore,
                        utxoIndexMissing: b.utxoIndexMissing,
                        syncing: b.syncing && b.mature == null,
                      ),
                    ),
                  ),
                  if (hasActions) ...[
                    const SizedBox(height: KvSpace.m),
                    Entrance(
                      index: 1,
                      // Static — the money actions listen to nothing.
                      child: Column(
                        children: [
                          // Send + Receive share the row; Message gets its
                          // own full-width line so no label ever wraps
                          // (three-across broke on the V60 — sitting note).
                          Row(
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
                          if (widget.messagesRoute != null) ...[
                            const SizedBox(height: KvSpace.sm),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.tonalIcon(
                                onPressed: _openMessages,
                                icon: const Icon(
                                  Icons.forum_outlined,
                                  size: 18,
                                  color: KvColor.primaryMuted,
                                ),
                                label: const Text('Message'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: KvSpace.xl),
                  Entrance(
                    index: 2,
                    child: Text('Activity', style: theme.textTheme.titleMedium),
                  ),
                  const SizedBox(height: KvSpace.s),
                ],
              ),
            ),
            const Divider(),
            Expanded(
              // The feed's counters and relative ages are live by design, so
              // it listens to the clock and the chain — but a balance tick
              // never lands here (and the feed never rebuilds the panel).
              child: ListenableBuilder(
                listenable: _feedInputs,
                builder: (context, _) => _ActivityFeed(
                  records: widget.wallet.activity.value,
                  now: _now.value,
                  virtualDaaScore: widget.chain.virtualDaaScore.value,
                  stale: _stale.value,
                  onRefresh: widget.wallet.onRefreshActivity,
                ),
              ),
            ),
          ],
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
    required this.daa,
    required this.utxoIndexMissing,
    required this.syncing,
  });

  final BigInt? mature;
  final BigInt? pending;
  final bool stale;

  /// Listened to INSIDE the panel — the chain clock ticks ~10×/s and must
  /// repaint only its own line, never the money number above it (V4 scoping).
  final ValueListenable<BigInt?> daa;

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
            child: ValueListenableBuilder<BigInt?>(
              valueListenable: daa,
              builder: (context, score, _) => Text(
                'DAA ${formatScore(score)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: KvColor.textTertiary,
                ),
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
  const _ActivityFeed({
    required this.records,
    required this.now,
    this.virtualDaaScore,
    this.stale = false,
    this.onRefresh,
  });

  final List<ActivityRecord> records;
  final DateTime now;

  /// DS-1: a stale link must not stream a frozen counter at full presence —
  /// counters fall back to their static words until the link is live again
  /// (ux-audit counter finding 1; the P0.3 scar class).
  final bool stale;

  /// Pull-the-truth heal; `null` ⇒ plain list (tests, reduced wiring).
  final Future<void> Function()? onRefresh;

  /// Live DAA — the streaming counter for both directions is a DAA-distance:
  /// a deposit counts from its inclusion DAA (`blockDaaScore`), a send from its
  /// DAG-acceptance DAA (`acceptedDaaScore`). Both node-read and cosmetic (the
  /// number dies with wallet-core's own maturity truth; finding 18 replaced the
  /// send's laggy 1 Hz tracker-depth poll with this synchronous path so it
  /// streams as fluidly as a deposit).
  final BigInt? virtualDaaScore;

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
    final list = ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.gutter,
        KvSpace.s,
        KvSpace.gutter,
        KvSpace.xl,
      ),
      // A refreshable list must scroll even when short, or the gesture dies.
      physics: onRefresh == null ? null : const AlwaysScrollableScrollPhysics(),
      itemCount: records.length,
      // Txid-keyed so a row keeps its chip's transition state across
      // reconciles (the list is rebuilt on every snapshot).
      itemBuilder: (context, i) => _ActivityRow(
        key: ValueKey(records[i].txid),
        record: records[i],
        now: now,
        confirmations: _confirmations(records[i]),
      ),
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(
      onRefresh: onRefresh!,
      color: KvColor.primary,
      backgroundColor: KvColor.surfaceAlt,
      child: list,
    );
  }

  /// The chip's streaming counter for one row — a DAA-distance depth, node-read
  /// and cosmetic (it dies with wallet-core's own maturity truth; the depth
  /// gate quiets it once deep). `null` ⇒ static label. A stale link never
  /// counts (a frozen last-known DAA must not read live — DS-1).
  ///
  /// A SEND counts from the DAG-ACCEPTANCE DAA (`acceptedDaaScore`) — the honest
  /// anchor. Its `blockDaaScore` is only submit time and would overstate the
  /// depth (finding 18: the old path polled the tracker's blue-depth at 1 Hz,
  /// which stuttered — the async gap plus wallet-core's Pending→Confirmed
  /// collapse meant the count often never rendered). A DEPOSIT counts its own
  /// inclusion-DAA distance (its maturity clock).
  int? _confirmations(ActivityRecord record) {
    if (stale) return null;
    final daa = virtualDaaScore;
    if (daa == null) return null;
    if (record.direction == ActivityDirection.outgoing) {
      final accepted = record.acceptedDaaScore;
      if (accepted == null || daa < accepted) return null;
      return (daa - accepted).toInt();
    }
    if (record.maturity == MaturityState.pending &&
        record.direction == ActivityDirection.incoming) {
      if (daa < record.blockDaaScore) return null;
      return (daa - record.blockDaaScore).toInt();
    }
    return null;
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    super.key,
    required this.record,
    required this.now,
    this.confirmations,
  });

  final ActivityRecord record;
  final DateTime now;
  final int? confirmations;

  /// The chip state, with the finding-18 revival: a send whose base state is
  /// the quiet terminal (`none` — wallet-core confirmed it at acceptance) but
  /// which still has a live sub-ceiling acceptance-depth counts as `accepted`
  /// (green, streaming), exactly like a maturing deposit; the depth gate quiets
  /// it once deep. Every other row keeps its base state. Pure display; the
  /// underlying maturity truth is untouched.
  TxChipState _chipState() {
    final base = gateByDepth(
      chipStateOf(record.maturity, stalled: record.stalled),
      confirmations,
    );
    if (base == TxChipState.none &&
        confirmations != null &&
        record.direction == ActivityDirection.outgoing) {
      return gateByDepth(TxChipState.accepted, confirmations);
    }
    return base;
  }

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
              // The chip rides V1's acceptance overlay: Pending (breathing) →
              // Accepted → quiet; a stalled submit escalates honestly. A SEND,
              // once accepted, keeps STREAMING its acceptance-depth counter
              // (green) until the depth gate quiets it — parity with a maturing
              // deposit, and the fix for finding 18 (wallet-core collapses a
              // send straight to Confirmed, so its base chip is `none`; a live
              // sub-ceiling depth on an outgoing row revives the counting
              // state). The depth gate (finding 13) extinguishes any row at or
              // above the ceiling, so a settled/cold-start row streams nothing.
              TxStatusChip(state: _chipState(), confirmations: confirmations),
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
class _NetworkSheet extends StatefulWidget {
  const _NetworkSheet({
    required this.connected,
    required this.endpoint,
    required this.virtualDaaScore,
    required this.error,
    required this.lastUpdate,
    required this.clock,
    this.reconnecting,
    this.onReconnect,
  });

  final ValueListenable<bool> connected;
  final ValueListenable<String?> endpoint;
  final ValueListenable<BigInt?> virtualDaaScore;
  final ValueListenable<String?> error;
  final ValueListenable<DateTime?> lastUpdate;
  final DateTime Function() clock;
  final ValueListenable<bool>? reconnecting;
  final Future<void> Function()? onReconnect;

  @override
  State<_NetworkSheet> createState() => _NetworkSheetState();
}

class _NetworkSheetState extends State<_NetworkSheet> {
  Timer? _poll;
  int? _blockAgeSecs;
  bool _haveStatus = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
    // Poll the honest block-age while the sheet is open (P3): the precise
    // scan-liveness signal, straight from the monitor's heartbeat.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await dagStatus();
      if (!mounted) return;
      setState(() {
        _blockAgeSecs = status.lastBlockAgeSecs?.toInt();
        _haveStatus = true;
      });
    } catch (_) {
      // A failed pull just leaves the last-known age; never crash the sheet.
    }
  }

  /// The transport-scan liveness line: the scan runs on every block, so the
  /// block-age IS its freshness. Honest about "never" before the first block.
  String get _scanLine {
    if (!_haveStatus || _blockAgeSecs == null) {
      return 'waiting for first block…';
    }
    final age = _blockAgeSecs!;
    if (age <= 5) return 'live — scanning every block';
    return '$age s since last block';
  }

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
            widget.connected,
            widget.endpoint,
            widget.virtualDaaScore,
            widget.error,
            widget.lastUpdate,
            if (widget.reconnecting != null) widget.reconnecting!,
          ]),
          builder: (context, _) {
            final last = widget.lastUpdate.value;
            final age = last == null ? null : widget.clock().difference(last);
            final state = evaluateBeacon(
              connected: widget.connected.value,
              age: age,
              error: widget.error.value,
            );
            final status = switch (state) {
              BeaconState.error => widget.error.value ?? 'connection error',
              BeaconState.connecting => 'connecting to mainnet…',
              BeaconState.stale =>
                age == null
                    ? 'no recent update'
                    : 'as of ${formatAge(age)} ago',
              BeaconState.connected => 'live',
            };
            final busy = widget.reconnecting?.value ?? false;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Network', style: theme.textTheme.titleMedium),
                const SizedBox(height: KvSpace.m),
                _DetailRow(label: 'Status', value: status),
                _DetailRow(
                  label: 'DAA score',
                  value: formatScore(widget.virtualDaaScore.value),
                  mono: true,
                ),
                _DetailRow(label: 'Transport scan', value: _scanLine),
                _DetailRow(
                  label: 'Node',
                  value: widget.endpoint.value ?? '—',
                  mono: true,
                ),
                const SizedBox(height: KvSpace.m),
                if (widget.onReconnect != null)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () {
                              KvHaptic.selection();
                              widget.onReconnect!();
                            },
                      icon: busy
                          ? const KvLoader.inline()
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(busy ? 'Reconnecting…' : 'Reconnect'),
                    ),
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
