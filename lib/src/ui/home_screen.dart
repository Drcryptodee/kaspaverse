import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../rust/api/wallet.dart';
import 'format.dart';
import 'network_sheet.dart';
import 'theme/kv_page_route.dart';
import 'theme/tokens.dart';
import 'widgets/amount_text.dart';
import 'widgets/entrance.dart';
import 'widgets/glass_panel.dart';
import 'widgets/status_beacon.dart';
import 'widgets/tx_status_chip.dart';

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
    this.settingsRoute,
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

  /// Builds the Settings screen (Track 2; `null` ⇒ no entry). Home is the ONLY
  /// door to it — a setting nobody can reach is a setting that does not exist,
  /// which is precisely how biometric enrolment came to be unreachable after a
  /// restore.
  final WidgetBuilder? settingsRoute;

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
    this.searching,
    this.osOffline,
    this.disconnectedAt,
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

  /// C7 (D-091): the engine's honest link truths, straight from Rust — a race
  /// is hunting / the OS says the phone has no network / when the link last
  /// died (the churn hold's clock). Optional like [reconnecting]: a widget test
  /// that doesn't exercise the hunt states can omit them, and absent reads as
  /// "no hunt, not offline, up" — the pre-C7 behaviour.
  final ValueListenable<bool>? searching;
  final ValueListenable<bool>? osOffline;
  final ValueListenable<DateTime?>? disconnectedAt;
}

/// The wallet-facing wiring [HomeScreen] consumes — same law as [ChainScope].
class WalletScope {
  const WalletScope({
    required this.mature,
    required this.pending,
    required this.activity,
    required this.syncing,
    required this.utxoIndexMissing,
    this.outgoing,
    this.discoveryIncomplete,
    this.onRefreshActivity,
  });

  final ValueListenable<BigInt?> mature;
  final ValueListenable<BigInt?> pending;

  /// Value this wallet has SPENT that the network has not handed back yet —
  /// the pin's `Balance.outgoing`. Optional like [discoveryIncomplete]: absent
  /// reads as "nothing in flight", which is the pre-F20 behaviour.
  ///
  /// Until this was wired, `WalletService.outgoing` was assigned on every
  /// snapshot and read by nothing in `lib/` (F20, product-audit run 3), so a
  /// wallet mid-send rendered a confident `0.00000000 KAS` with no hint that
  /// its own money was in flight.
  final ValueListenable<BigInt?>? outgoing;
  final ValueListenable<List<ActivityRecord>> activity;
  final ValueListenable<bool> syncing;
  final ValueListenable<bool> utxoIndexMissing;

  /// No address-discovery pass has reached a node this session, so the balance
  /// is computed over the last known-good address window and **may be short**.
  ///
  /// Optional like the C7 link truths: absent reads as "proven", the pre-Track-2
  /// behaviour. Its sibling is [utxoIndexMissing] and it exists for the same
  /// reason — without it the panel paints a confidently wrong number, which this
  /// project treats as worse than a visible unknown.
  final ValueListenable<bool>? discoveryIncomplete;

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
  BigInt? outgoing,
  bool stale,
  bool syncing,
  bool utxoIndexMissing,
  bool discoveryIncomplete,
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
  late final _Derived<bool> _dimmed;
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
      if (widget.chain.searching != null) widget.chain.searching!,
      if (widget.chain.osOffline != null) widget.chain.osOffline!,
      if (widget.chain.disconnectedAt != null) widget.chain.disconnectedAt!,
      if (widget.chain.reconnecting != null) widget.chain.reconnecting!,
      _now,
    ], _computeLink);
    // DS-1 dimming is "not live", not "stale" specifically: since C7 a dark
    // link can read *finding a node…* or *phone offline* instead of stale, and
    // last-known data must never sit at full brightness through any of them.
    _dimmed = _Derived([
      _link,
    ], () => _link.value.state != BeaconState.connected);
    _balance = _Derived(
      [
        widget.wallet.mature,
        widget.wallet.pending,
        if (widget.wallet.outgoing != null) widget.wallet.outgoing!,
        widget.wallet.syncing,
        widget.wallet.utxoIndexMissing,
        if (widget.wallet.discoveryIncomplete != null)
          widget.wallet.discoveryIncomplete!,
        _dimmed,
      ],
      () => (
        mature: widget.wallet.mature.value,
        pending: widget.wallet.pending.value,
        outgoing: widget.wallet.outgoing?.value,
        stale: _dimmed.value,
        syncing: widget.wallet.syncing.value,
        utxoIndexMissing: widget.wallet.utxoIndexMissing.value,
        discoveryIncomplete: widget.wallet.discoveryIncomplete?.value ?? false,
      ),
    );
    _feedInputs = Listenable.merge([
      widget.wallet.activity,
      widget.chain.virtualDaaScore,
      _dimmed,
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
          identical(oldWidget.chain.searching, widget.chain.searching) &&
          identical(oldWidget.chain.osOffline, widget.chain.osOffline) &&
          identical(
            oldWidget.chain.disconnectedAt,
            widget.chain.disconnectedAt,
          ) &&
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
    _dimmed.dispose();
    _link.dispose();
    _now.dispose();
    super.dispose();
  }

  Duration? _age() {
    final last = widget.chain.lastUpdate.value;
    return last == null ? null : _now.value.difference(last);
  }

  /// Time since the link died — the churn hold's clock (null ⇒ up/never up).
  Duration? _sinceDrop() {
    final at = widget.chain.disconnectedAt?.value;
    return at == null ? null : _now.value.difference(at);
  }

  _LinkView _computeLink() {
    final age = _age();
    final state = evaluateBeacon(
      connected: widget.chain.connected.value,
      age: age,
      error: widget.chain.error.value,
      // A tap counts as searching from the frame it lands (≤200 ms ack, C7):
      // the Dart flag flips synchronously, so the beacon reads *finding a
      // node…* before the bridge call has even been dispatched.
      searching:
          (widget.chain.searching?.value ?? false) ||
          (widget.chain.reconnecting?.value ?? false),
      osOffline: widget.chain.osOffline?.value ?? false,
      sinceDrop: _sinceDrop(),
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

  void _openSettings() {
    final builder = widget.settingsRoute;
    if (builder == null) return;
    Navigator.of(context).push(KvPageRoute<void>(builder: builder));
  }

  /// The §12 power-user tap: endpoint, DAA and freshness in plain sight —
  /// the ONE frosted panel this screen ever spends (§8 budget; a sheet
  /// overlays live content, so the blur has something honest to refract).
  ///
  /// Settings' Network row shows this same widget rather than a copy of it, so
  /// the two surfaces can never disagree about the link.
  void _openNetworkSheet() {
    NetworkSheet.show(
      context,
      NetworkSheet(
        connected: widget.chain.connected,
        endpoint: widget.chain.endpoint,
        virtualDaaScore: widget.chain.virtualDaaScore,
        error: widget.chain.error,
        lastUpdate: widget.chain.lastUpdate,
        clock: widget.clock,
        reconnecting: widget.chain.reconnecting,
        onReconnect: widget.chain.onReconnect,
        searching: widget.chain.searching,
        osOffline: widget.chain.osOffline,
        disconnectedAt: widget.chain.disconnectedAt,
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
                      // The beacon is the ONLY flex child, and that is the
                      // whole layout decision (F5, product-audit run 3).
                      //
                      // It used to be a non-flex child after a `Spacer()`.
                      // Flutter lays non-flex children out first with UNBOUNDED
                      // main-axis constraints and hands the remainder to the
                      // flex ones — so the pill took its intrinsic width, the
                      // `Flexible`+ellipsis inside StatusBeacon never clamped,
                      // and the gear was pushed past the Row's clip. Measured
                      // at dpr 3.0 with the real fonts, in the cold-launch
                      // `finding a node…` state, the settings door — the app's
                      // ONLY door to biometric enrolment, the lock-grace
                      // picker, address scanning and merge — became untappable
                      // at 320 dp from textScale 1.15, and at 360 dp (the LG
                      // V60's bucket) at 1.30, which is AOSP's stock maximum.
                      //
                      // `Expanded` + right `Align` reproduces the Spacer's
                      // visual result exactly when there is room — the pill
                      // still sits hard right against the gear — while giving
                      // the beacon a BOUNDED constraint so its own ellipsis can
                      // finally do the job it was written for.
                      //
                      // Not `Flexible` on the beacon beside the Spacer: that
                      // makes two flex children at flex 1 each, so the beacon
                      // would get half the free space and ellipsize even on a
                      // wide screen with room to spare — a new defect wearing
                      // the fix's clothes.
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          // Scoped: connected steady-state never rebuilds here —
                          // the breath animates itself (KvBreath).
                          child: ValueListenableBuilder<_LinkView>(
                            valueListenable: _link,
                            builder: (context, link, _) => StatusBeacon(
                              state: link.state,
                              error: link.error,
                              age: link.age,
                              onTap: _openNetworkSheet,
                            ),
                          ),
                        ),
                      ),
                      // Understated and last: the header's job is the wordmark
                      // and the link, and a settings door that shouted would
                      // compete with the balance for the first glance (§1 —
                      // the cockpit has one instrument). Static; listens to
                      // nothing.
                      if (widget.settingsRoute != null) ...[
                        const SizedBox(width: KvSpace.s),
                        // `iconSize: 20` keeps it visually quiet; the TAP area
                        // stays the full 48 dp (§9), which is the same split
                        // StatusBeacon makes. `visualDensity: compact` was
                        // shaving it to 40 dp, 4 dp from the beacon's own
                        // target — on the app's only door to every custody
                        // control (ux-auditor, Track 2).
                        IconButton(
                          onPressed: _openSettings,
                          iconSize: 20,
                          color: KvColor.textSecondary,
                          tooltip: 'Settings',
                          icon: const Icon(Icons.tune_rounded),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: KvSpace.l),
                  Entrance(
                    child: ValueListenableBuilder<_BalanceView>(
                      valueListenable: _balance,
                      builder: (context, b, _) => _BalancePanel(
                        mature: b.mature,
                        pending: b.pending,
                        outgoing: b.outgoing,
                        stale: b.stale,
                        daa: widget.chain.virtualDaaScore,
                        utxoIndexMissing: b.utxoIndexMissing,
                        discoveryIncomplete: b.discoveryIncomplete,
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
                    child: Text(
                      // §0.10's own words, and the empty state's ('No recent
                      // activity'): the feed is bounded, so the header must not
                      // promise full history. F29, product-audit run 3.
                      'Recent activity',
                      style: theme.textTheme.titleMedium,
                    ),
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
                  stale: _dimmed.value,
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
    required this.outgoing,
    required this.stale,
    required this.daa,
    required this.utxoIndexMissing,
    required this.discoveryIncomplete,
    required this.syncing,
  });

  final BigInt? mature;
  final BigInt? pending;
  final BigInt? outgoing;
  final bool stale;

  /// Listened to INSIDE the panel — the chain clock ticks ~10×/s and must
  /// repaint only its own line, never the money number above it (V4 scoping).
  final ValueListenable<BigInt?> daa;

  final bool utxoIndexMissing;
  final bool discoveryIncomplete;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // NOT "Total balance". The figure below is the MATURE balance, and
            // the pending line sits directly under it — so the label was wrong
            // by exactly the amount printed beneath it, and disagreed with the
            // send screen, which calls the identical value "Available"
            // (product-audit run 1, F9). One value, one name, both surfaces.
            'Available balance',
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
          // Money we have spent that the network has not handed back yet. It
          // matters most at exactly the moment it is easiest to miss: a wallet
          // that just spent everything reads `0.00000000 KAS`, and without
          // this line that zero is indistinguishable from an empty wallet
          // (F4/F20, product-audit run 3). Signless on purpose — the balance
          // above is already net of it; see [_SettlingLine].
          if (outgoing != null && outgoing! > BigInt.zero) ...[
            const SizedBox(height: KvSpace.xs),
            _SettlingLine(outgoing: outgoing!, stale: stale),
          ],
          _StatusCaption(
            utxoIndexMissing: utxoIndexMissing,
            discoveryIncomplete: discoveryIncomplete,
            syncing: syncing,
          ),
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

/// Value in flight: spent, and not yet handed back by the network.
///
/// **It carries NO sign, and that is the whole design.** It looks like
/// [_PendingLine] and it is NOT its mirror — the two have opposite arithmetic
/// under identical grammar, which is exactly the trap (consensus-auditor, this
/// sitting). At the pin the hero figure is already NET of the send:
/// `mature = (mature_utxos + consumed).saturating_sub(fees + payment)`
/// (`wallet/core/src/utxo/context.rs:506-547 @ cfafeb4`), while `pending` is a
/// set DISJOINT from `mature`. So `+ N pending` is money the hero does not yet
/// contain, and this value is money the hero has already lost. A `− ` prefix
/// here would invite a second subtraction: a partial send of 30 from 100 would
/// read `70.00 KAS` over `− 30.00000000`, and 70 − 30 is wrong.
///
/// The sign would also be a lie outright on `SignableKind::SelfSendFrame` — the
/// KaChat message path — where `payment_value()` is `Some`, so the frame's own
/// amount lands in `outgoing_without_batch_tx` and is rendered here while
/// travelling straight back to this wallet.
///
/// So it is a memo, not a term in a sum: the amount and what it is doing.
class _SettlingLine extends StatelessWidget {
  const _SettlingLine({required this.outgoing, required this.stale});

  final BigInt outgoing;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // ONE focus stop, and the signless design is exactly why it is needed
    // (ux-auditor, this sitting): `_PendingLine` carries its direction in-band
    // through the `+`, but here the label is the only thing separating this
    // amount from the balance above it — unmerged, a screen reader announces
    // two bare KAS amounts back to back and the qualifier only on the next
    // swipe. Merged it reads "16.36694716 KAS in flight".
    return MergeSemantics(
      child: Row(
        children: [
          AmountText(outgoing, role: AmountRole.row, stale: stale),
          Text(
            '  in flight',
            style: theme.textTheme.labelSmall?.copyWith(
              color: KvColor.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Honest sub-line under the balance: an INV-8 degrade warning, the short-window
/// notice, a transient "syncing…" while the first scan runs, or nothing.
///
/// One caption at a time, most-consequential first. Both degrade states are
/// `KvColor.warning`, never `error` — red is rationed to fund risk and
/// destruction (§3/§4), and neither of these is either: the funds are exactly
/// where they were, it is our *view* of them that is admitted to be partial.
class _StatusCaption extends StatelessWidget {
  const _StatusCaption({
    required this.utxoIndexMissing,
    required this.discoveryIncomplete,
    required this.syncing,
  });

  final bool utxoIndexMissing;
  final bool discoveryIncomplete;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (utxoIndexMissing) {
      return Padding(
        padding: const EdgeInsets.only(top: KvSpace.s),
        child: Text(
          'node has no UTXO index — retrying another node',
          // Prose is Inter (§4 role map) — bare `bodySmall` is the mono data
          // face, which these captions are not (ux-auditor, Track 2).
          style: theme.textTheme.bodySmall?.copyWith(
            color: KvColor.warning,
            fontFamily: KvFont.ui,
          ),
        ),
      );
    }
    if (discoveryIncomplete) {
      // Names the CHECK, not the link. The flag means "no pass has read both
      // branches yet", and a pass can fail in milliseconds against a socket
      // that is live but still dialling — so the first wording, "haven't
      // reached a node yet", could sit under a beacon reading *live*: two
      // truths on one screen, which is the disagreement DS-1 and C7 both
      // forbid (ux-auditor, Track 2).
      //
      // Says what is true and what it means for the number above it — never
      // "your balance is wrong", which we do not know.
      return Padding(
        padding: const EdgeInsets.only(top: KvSpace.s),
        child: Text(
          'still checking your addresses — this may not be your whole balance',
          style: theme.textTheme.bodySmall?.copyWith(
            color: KvColor.warning,
            fontFamily: KvFont.ui,
          ),
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

/// How many rows the feed can hold — the Rust-side bound, mirrored.
///
/// **Source of truth is `ACTIVITY_CAP` in `rust/chain/src/wallet_sync.rs`**; the
/// list crosses the bridge already truncated, so the glass cannot derive the
/// number and has to carry it. `test/activity_cap_test.dart` reads that Rust
/// constant and fails if the two ever drift — the mirror is pinned, not trusted.
const int kActivityFeedCap = 100;

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
    // The list arrives already truncated by Rust, so "full" is the only signal
    // the glass gets that anything was cut (F29).
    final atCap = records.length >= kActivityFeedCap;
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
      // +1 for the bound's own caption when the feed is full (F29).
      itemCount: records.length + (atCap ? 1 : 0),
      // Txid-keyed so a row keeps its chip's transition state across
      // reconciles (the list is rebuilt on every snapshot).
      itemBuilder: (context, i) {
        if (i == records.length) {
          // Only a user the bound actually binds ever reads this. Quiet tier
          // (§1 — the cockpit has one instrument, and this is not it): it
          // states the bound, it does not offer to lift it. Paging is a
          // deliberate non-feature (D-175).
          return Padding(
            padding: const EdgeInsets.only(top: KvSpace.sm),
            child: Text(
              'Showing the $kActivityFeedCap most recent.',
              textAlign: TextAlign.center,
              // textTertiary, NOT textDisabled: this is the app's only
              // disclosure that the user's history has been cut, and
              // design_system.md:179 reserves `text-disabled` (2.7:1, exempt
              // from the contrast law) for "disabled controls and decoration
              // only — never information-bearing text".
              style: theme.textTheme.labelSmall?.copyWith(
                color: KvColor.textTertiary,
              ),
            ),
          );
        }
        return _ActivityRow(
          key: ValueKey(records[i].txid),
          record: records[i],
          now: now,
          confirmations: _confirmations(records[i]),
        );
      },
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
