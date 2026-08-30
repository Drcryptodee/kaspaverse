import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../rust/api/wallet.dart';
import '../services/rate_service.dart' show KvRateQuote, RateService;
import 'format.dart';
import 'theme/kv_page_route.dart';
import 'theme/tokens.dart';
import 'widgets/entrance.dart';
import 'widgets/kv_amount.dart';
import 'widgets/kv_breath.dart';
import 'widgets/kv_burial_mark.dart';
import 'widgets/kv_cadence.dart';
import 'widgets/kv_chrome.dart';
import 'widgets/kv_empty_state.dart';
import 'widgets/kv_glyph.dart';
import 'widgets/kv_status_chip.dart';
import 'widgets/kv_surface.dart';
import 'widgets/status_beacon.dart';
import 'widgets/tx_status_chip.dart';

/// **Money** — the surface a user opens every day, and the first one wired to
/// real funds (design_system §5, D-191…D-194).
///
/// The screen *is* the instrument. The balance is **plated** — an earned
/// container (BG-1: this one is earned), sentence case, the unit *with* the
/// figure, and the statements that vouch for the number sitting inside it
/// beside the number they vouch for. The plate is **pinned** and the ledger
/// scrolls under it: what you own is not something you should have to scroll
/// back up to see. **Pull-to-refresh is hosted by the whole scroll view**, not
/// by the list, so the gesture works from the balance too — which is where a
/// hand reaches for it first (D-194).
///
/// **Silence is the healthy state** (BG-8 as amended at D-192). The trust line
/// earns its place by appearing: it shows up when the link is not live or a
/// first scan is running, and is absent otherwise. The cadence is the one
/// loading indicator and it never animates on a settled screen.
///
/// State is injected as listenables so widget tests run without the native
/// library; a 1 s clock notifier advances the freshness age (BG-8) so the
/// trust line goes stale and the balance dims even when no new snapshot
/// arrives.
///
/// V4 scoping is unchanged: each region listens only to what it renders
/// (derived, value-gated notifiers — see [_Derived]). A balance tick never
/// rebuilds the activity list, a DAA tick repaints only the chain-clock line
/// and the feed, and the 1 s tick lands in the clock notifier, never a
/// whole-screen `setState`. The injected listenables are the test seam and
/// must be stable for the life of the state (asserted in
/// [State.didUpdateWidget]).
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
    this.nodeRoute,
    this.fiat,
    this.clock = DateTime.now,
    this.floatingActionButton,
  });

  /// Node / link scope (ChainService): the network chip's lamp, the trust
  /// line, the live DAA readout and the node surface behind the chip. A
  /// grouping of the SAME injected listenables the V4 seam law protects — the
  /// scope object may be rebuilt per parent build; the notifiers inside must
  /// stay identical (asserted in [State.didUpdateWidget]).
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
  ///
  /// It is handed **this screen's own `_dimmed` bit**, not a fresh derivation
  /// of its own: Send quotes the spendable balance back at the user (*"you are
  /// N KAS short"*), so it owes BG-8's live/stale/unknown exactly as the plate
  /// does — and two independent foldings of the link state are how a screen
  /// and the screen behind it start disagreeing about whether the wallet is
  /// connected (P0.3's shape; L133's warning about which bit an arm needs).
  final Widget Function(BuildContext, ValueListenable<bool> balanceStale)?
  sendRoute;

  /// Builds the Messages screen (P2.3 transport UI; `null` ⇒ no entry).
  ///
  /// It sits in the top rail rather than the thumb arc: **the thumb arc is for
  /// money** (§5), and Messages is a destination, not a money action. With the
  /// navigation panel withdrawn (D-190) the rail is the only place a
  /// destination can live, and home is still the app's only door to it.
  final WidgetBuilder? messagesRoute;

  /// Builds the Settings screen (Track 2; `null` ⇒ no entry). Home is the ONLY
  /// door to it — a setting nobody can reach is a setting that does not exist,
  /// which is precisely how biometric enrolment came to be unreachable after a
  /// restore.
  final WidgetBuilder? settingsRoute;

  /// Builds **the** node surface — who serves you, the explorer choice and the
  /// price source (`null` ⇒ the network chip is a plain reading rather than a
  /// control). Built once in `main.dart` and reached from two places: this
  /// chip and the Settings row.
  final WidgetBuilder? nodeRoute;

  /// The fiat restatement under the balance (`null` ⇒ no restatement line).
  ///
  /// Its lifecycle is this screen's: [FiatScope.attach] on mount and
  /// [FiatScope.detach] on dispose, so a price is fetched only while a surface
  /// that renders one is alive. A locked wallet discards this screen at 0ms
  /// (BG-13) and stops talking to the price source with it.
  final FiatScope? fiat;

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
    required this.virtualDaaScore,
    required this.error,
    required this.lastUpdate,
    this.reconnecting,
    this.searching,
    this.osOffline,
    this.disconnectedAt,
  });

  final ValueListenable<bool> connected;
  final ValueListenable<BigInt?> virtualDaaScore;
  final ValueListenable<String?> error;

  /// Time of the last fresh node snapshot — the link freshness clock (BG-8).
  final ValueListenable<DateTime?> lastUpdate;

  /// True while a reconnect is in flight (P3) — the honest hunt indicator.
  final ValueListenable<bool>? reconnecting;

  /// C7 (D-091): the engine's honest link truths, straight from Rust — a race
  /// is hunting / the OS says the phone has no network / when the link last
  /// died (the churn hold's clock). Optional like [reconnecting]: a widget test
  /// that doesn't exercise the hunt states can omit them, and absent reads as
  /// "no hunt, not offline, up" — the pre-C7 behaviour.
  final ValueListenable<bool>? searching;
  final ValueListenable<bool>? osOffline;
  final ValueListenable<DateTime?>? disconnectedAt;
}

/// The fiat restatement's wiring: what to show, whether to show it, and the
/// two lifecycle hooks that keep the fetch tied to a mounted surface.
///
/// Deliberately NOT the node surface's `RateScope`: this one cannot change the
/// setting. The money plate reads a price; the place a price is chosen is the
/// place it can be switched off (D-193), and a read-only seam is how that stays
/// true by construction rather than by discipline.
class FiatScope {
  const FiatScope({
    required this.enabled,
    required this.quote,
    this.attach,
    this.detach,
  });

  /// `null` until the stored posture has been read — rendered as nothing,
  /// never as an optimistic `≈ —` (`wallet-security-auditor`).
  final ValueListenable<bool?> enabled;
  final ValueListenable<KvRateQuote?> quote;

  final VoidCallback? attach;
  final VoidCallback? detach;
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
  /// reason — without it the plate paints a confidently wrong number, which this
  /// project treats as worse than a visible unknown.
  final ValueListenable<bool>? discoveryIncomplete;

  /// Swipe-to-refresh heal (founder request, V2 sitting): pulls the latest
  /// folded snapshot directly, bypassing the stream. `null` ⇒ no refresh UI.
  final Future<void> Function()? onRefreshActivity;
}

/// The link, as the plate renders it. Records compare structurally, which is
/// what lets [_Derived] swallow the no-op ticks.
typedef _LinkView = ({
  BeaconState state,
  String? error,
  Duration? age,
  bool hunting,

  /// The SOCKET, not [state]. `evaluateBeacon` reports `connected` for up to
  /// `linkChurnGrace` after a drop (the churn hold), so `state` cannot answer
  /// "is there a node right now" — and one arm below has to ask exactly that.
  bool live,
});

/// The trust line, as one value: `words == null` is **silence**, which is what
/// a healthy screen looks like (D-192).
typedef _TrustView = ({String? words, bool running, KvLampTone tone});

/// What the balance region renders (the DAA line is scoped separately inside
/// the plate — the chain clock must not rebuild the money number).
typedef _BalanceView = ({
  BigInt? mature,
  BigInt? pending,
  BigInt? outgoing,
  bool stale,
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

  /// The freshness clock (BG-8) — ticked once per second. Regions that render
  /// time listen to THIS, so the tick never lands as a whole-screen setState.
  late final ValueNotifier<DateTime> _now;

  late final _Derived<_LinkView> _link;
  late final _Derived<bool> _dimmed;
  late final _Derived<_TrustView> _trust;
  late final _Derived<_BalanceView> _balance;

  /// Everything the activity feed reads. The feed rebuilds on activity
  /// snapshots, depth ticks, DAA ticks and the 1 s clock (its counters and
  /// relative ages are live by design) — but never on a balance change.
  late final Listenable _feedInputs;

  /// The pinned plate's extent, and the section rule's.
  ///
  /// **Both are measured, never stated.** A [SliverPersistentHeader] demands a
  /// height it cannot work out for itself, and a hand-written number under a
  /// comment claiming it was measured is exactly what cost `L121` — it goes
  /// stale on the next padding change and nothing reddens. So the real
  /// subtree lays out under a relaxed height constraint, reports its natural
  /// height through [_MeasuredHeight], and the header adopts it. It cannot be
  /// wrong and it cannot drift: change the plate, or the text scale, and the
  /// number follows.
  ///
  /// Seeded at **1dp, and 1dp is not a claim about anything** — it is the
  /// smallest value that makes the measurement possible at all. A pinned
  /// `SliverPersistentHeader` whose extent is zero never builds its child, so
  /// a zero seed is a deadlock rather than a cautious start: nothing lays out,
  /// nothing reports, and the header stays at zero forever. That deadlock is
  /// what the C7 link-state tests caught within a minute of the rewrite, which
  /// is the argument for measuring in a test rather than by eye.
  ///
  /// The real number lands on the next frame, behind [Entrance]'s own fade —
  /// so the bootstrap frame is not one a user can see.
  double _plateExtent = 1;
  double _ruleExtent = 1;

  /// The height of the plate's **sheddable tail** — the rule, the chain clock
  /// and the link's own sentence. Subtracted from the plate to get the block
  /// that must survive a squeeze, so the pinned floor is a measurement rather
  /// than a fraction somebody liked the look of.
  ///
  /// **The fiat line is NOT in it**, and both halves of that matter. It
  /// renders inside `_Figure`, above the measured block, so it survives a
  /// squeeze — which is the cost D-193's shed order recorded when the founder
  /// moved it up beside the figure on glass. Two comments here said otherwise
  /// while it was a placeholder; UX-3 gave it a real height, at which point a
  /// stale comment about which things shed becomes a wrong claim about a
  /// measurement (`ux-auditor`, L121).
  double _tailExtent = 0;

  @override
  void initState() {
    super.initState();
    // Start the wallet sync engine now that the vault is unlocked (the shell
    // only mounts this screen when unlocked). Idempotent in the service.
    widget.onReady?.call();
    // The price clock runs while a surface that renders a price is mounted,
    // and not one moment longer (L5's ref-counted attach/detach).
    widget.fiat?.attach?.call();
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
    // BG-8 dimming is "not live", not "stale" specifically: since C7 a dark
    // link can read *finding a node…* or *phone offline* instead of stale, and
    // last-known data must never sit at full brightness through any of them.
    _dimmed = _Derived([
      _link,
    ], () => _link.value.state != BeaconState.connected);
    _trust = _Derived([
      _link,
      widget.wallet.syncing,
      widget.wallet.utxoIndexMissing,
      if (widget.wallet.discoveryIncomplete != null)
        widget.wallet.discoveryIncomplete!,
    ], _computeTrust);
    _balance = _Derived(
      [
        widget.wallet.mature,
        widget.wallet.pending,
        if (widget.wallet.outgoing != null) widget.wallet.outgoing!,
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
    // line advance without a new snapshot (BG-8).
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
    widget.fiat?.detach?.call();
    // Chained deriveds unhook in reverse dependency order.
    _balance.dispose();
    _trust.dispose();
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
    // A tap counts as searching from the frame it lands (≤200 ms ack, C7):
    // the Dart flag flips synchronously, so the link reads *finding a node…*
    // before the bridge call has even been dispatched.
    final hunting =
        (widget.chain.searching?.value ?? false) ||
        (widget.chain.reconnecting?.value ?? false);
    final state = evaluateBeacon(
      connected: widget.chain.connected.value,
      age: age,
      error: widget.chain.error.value,
      searching: hunting,
      osOffline: widget.chain.osOffline?.value ?? false,
      sinceDrop: _sinceDrop(),
    );
    return (
      state: state,
      error: widget.chain.error.value,
      // **Every non-live state carries the age**, not only `stale`.
      //
      // BG-8's clause is "dimmed to 45% WITH a visible age", and the balance
      // dims for `offline`, `error` and `connecting` too — so those three sat
      // above a 45% number with no indication whether it was twenty seconds or
      // two hours old (`ux-auditor`, this sitting). C7's ruling was that the
      // age must not stand ALONE, because "as of 20 s ago" reads as connected;
      // as a clause under the state word it says the opposite. Floored to the
      // second it shows, so record equality gates out every sub-label tick.
      age: state == BeaconState.connected || age == null
          ? null
          : Duration(seconds: age.inSeconds),
      hunting: hunting,
      live: widget.chain.connected.value,
    );
  }

  /// The trust line, in one place and in one order.
  ///
  /// **It speaks only when something is not settled** (D-192): a permanent
  /// "all fine" beside a permanently animating meter reports that nothing
  /// changed, twice, and becomes wallpaper. The link outranks the scan because
  /// a scan that cannot reach a node is a consequence, not a second fault —
  /// the same ordering `evaluateBeacon` uses internally, for the same reason.
  ///
  /// The copy is the shipped copy, verbatim (D-196): the network sheet's
  /// fuller phrasings, because a plate has the room a 320dp header did not.
  _TrustView _computeTrust() {
    final link = _link.value;
    final syncing = widget.wallet.syncing.value;
    final link_ = switch (link.state) {
      BeaconState.error => link.error ?? 'connection error',
      // The phone's own network, stated plainly — nothing for the user to
      // distrust, something for them to fix.
      BeaconState.offline => 'phone offline — no network',
      BeaconState.connecting => 'finding a node…',
      BeaconState.stale =>
        link.age == null
            ? 'no recent update'
            : 'as of ${formatAge(link.age!)} ago',
      // Silence is the healthy state. A live link says nothing at all — with
      // one exception since P0b: `searching` may now be true WHILE the socket
      // is up (the find-then-swap hunt), and a swap the user asked for should
      // be nameable on the money surface, in the node surface's vocabulary.
      //
      // It BRINGS the meter rather than explaining one: the trust chip is this
      // plate's only `KvCadence` call site, so the state silence used to
      // suppress rendered nothing at all — no motion was going unexplained.
      //
      // **Gated on the raw socket bit, not on `state`.** `evaluateBeacon`
      // returns `connected` for up to `linkChurnGrace` while the socket is
      // DOWN — the churn hold, whose whole contract is that a blip flips
      // nothing — and `hunting` folds in `reconnecting`, which a tap sets on
      // the frame it lands. Reading `state` alone therefore painted *"looking
      // for a different node…"* over a wallet that had NO node: on every 2 s
      // Wi-Fi blip, and on every PINNED redial — a wallet that by definition
      // will never look for a different one.
      BeaconState.connected =>
        syncing
            ? 'syncing…'
            : (link.hunting && link.live
                  ? 'looking for a different node…'
                  : null),
    };
    // What is wrong with the NUMBER, as distinct from what is wrong with the
    // LINK. Most consequential first: a balance that may be short outranks a
    // link that is merely old, because one of them changes what the user
    // believes they own.
    final String? number;
    if (widget.wallet.utxoIndexMissing.value) {
      number = 'node has no UTXO index — retrying another node';
    } else if (widget.wallet.discoveryIncomplete?.value ?? false) {
      // Names the CHECK, not the link. The flag means "no pass has read both
      // branches yet", and a pass can fail in milliseconds against a socket
      // that is live but still dialling — so a wording that named the link
      // could sit beside a chip reading live: two truths on one screen, which
      // is the disagreement BG-8 and C7 both forbid (ux-auditor, Track 2).
      //
      // Says what is true and what it means for the number above it — never
      // "your balance is wrong", which we do not know.
      number =
          'still checking your addresses — this may not be your whole '
          'balance';
    } else {
      number = null;
    }
    // The age rides the link sentence as a trailing clause. `stale` already
    // IS the age, so it never doubles.
    final age = link.age;
    final linkSaid =
        link_ == null || age == null || link.state == BeaconState.stale
        ? link_
        : '$link_ · last update ${formatAge(age)} ago';
    // **One indicator, however many facts it has.** These used to be two
    // stacked amber lamps on one plate, which is BG-2's cap spent on saying
    // "something is amber" twice and D-192's redundancy in miniature. The lamp
    // comes on once; the sentences queue under it, most consequential first.
    final said = <String>[?number, ?linkSaid];
    // **A swap is not a fault, and this plate may not colour it as one**
    // (founder call, this sitting). The node surface already ruled on this
    // exact pair: `connected && hunting` renders `KvLampTone.ok` there, on the
    // reasoning that amber "would understate a wallet that can spend right
    // now". A hardcoded amber here made the money plate disagree with it — and
    // with the plate's OWN network lamp, which is green on the same link
    // twelve pixels above, the P0.3 scar `_NetworkChip` still carries a
    // comment about.
    //
    // Green only when the swap sentence stands ALONE. A balance that may be
    // short keeps the lamp, because that is the more consequential fact, and
    // this arm must never launder it.
    final swapOnly =
        number == null &&
        !syncing &&
        link.state == BeaconState.connected &&
        link.hunting &&
        link.live;
    return (
      words: said.isEmpty ? null : said.join('\n'),
      // **Motion means something is happening.** A hunt and a first scan are
      // both happening; a dead or stale link is not, and the meter freezing is
      // exactly what makes "live" a felt thing rather than a claimed one.
      running: link.hunting || link.state == BeaconState.connecting || syncing,
      tone: swapOnly ? KvLampTone.ok : KvLampTone.warn,
    );
  }

  void _push(WidgetBuilder? builder) {
    if (builder == null) return;
    Navigator.of(context).push(KvPageRoute<void>(builder: builder));
  }

  /// The network chip's destination: **who is serving you, how fresh it is,
  /// where a link out of the wallet goes, and whether a price is fetched**.
  ///
  /// It is a builder rather than a scope this screen assembles, because UX-3
  /// gave that screen two more sections and Settings a door to the same
  /// screen. Two construction sites would have been two chances to forget one
  /// — and a Settings door that opened a node surface with no explorer on it
  /// is precisely the C7 disagreement the retired network sheet caused. One
  /// builder, in `main.dart`; two callers.
  void _openNode() {
    final builder = widget.nodeRoute;
    if (builder == null) return;
    Navigator.of(context).push(KvPageRoute<void>(builder: builder));
  }

  @override
  Widget build(BuildContext context) {
    final plate = Padding(
      // Wider than the gutter the ledger keeps: the money is the reason the
      // screen exists, so its container runs nearer the edge than the rows
      // beneath it (founder, on glass). Responsiveness on larger screens is
      // explicitly deferred.
      padding: const EdgeInsets.fromLTRB(
        KvSpace.sm,
        KvSpace.s,
        KvSpace.sm,
        KvSpace.sm,
      ),
      child: _MoneyPlate(
        balance: _balance,
        trust: _trust,
        dimmed: _dimmed,
        daa: widget.chain.virtualDaaScore,
        fiat: widget.fiat,
        now: _now,
        onNetwork: widget.nodeRoute == null ? null : _openNode,
        onTailMeasured: (h) {
          if (_tailExtent != h) setState(() => _tailExtent = h);
        },
      ),
    );

    return Scaffold(
      backgroundColor: KvColor.abyss,
      floatingActionButton: widget.floatingActionButton,
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // BG-14: the top 52dp belongs to the real system status bar and
            // nothing is painted there.
            const SizedBox(height: KvSpace.statusBarReserve),
            _TopRail(
              onMessages: widget.messagesRoute == null
                  ? null
                  : () => _push(widget.messagesRoute),
              onSettings: widget.settingsRoute == null
                  ? null
                  : () => _push(widget.settingsRoute),
            ),
            Expanded(child: _scroller(plate)),
            _ThumbActions(
              balance: _balance,
              onSend: widget.sendRoute == null
                  ? null
                  : () => Navigator.of(context).push(
                      KvPageRoute<void>(
                        builder: (c) => widget.sendRoute!(c, _dimmed),
                      ),
                    ),
              onReceive: widget.receiveRoute == null
                  ? null
                  : () => _push(widget.receiveRoute),
            ),
          ],
        ),
      ),
    );
  }

  /// The plate is pinned INSIDE the scroll view rather than sitting above it,
  /// and that is what makes D-194 true: a drag that starts on the balance is a
  /// drag on the scrollable, so the refresh gesture is reachable from the one
  /// place a hand goes first. A plate outside the viewport would emit no
  /// scroll notification and the gesture would die on it.
  Widget _scroller(Widget plate) {
    // The viewport's own height is what bounds the pinned plate, so the scroll
    // view is built inside a `LayoutBuilder` rather than beside one.
    return LayoutBuilder(
      builder: (context, box) => _viewport(plate, box.maxHeight),
    );
  }

  Widget _viewport(Widget plate, double viewportHeight) {
    final refresh = widget.wallet.onRefreshActivity;
    // **What the plate keeps when it cannot keep everything.**
    //
    // `minExtent` was the measured plate, unbounded — and at 320x568 with 1.3x
    // text in the degraded state the plate measures 446.8dp against a 406.0dp
    // viewport, so the header pinned at the FULL viewport at every scroll
    // offset and the ledger became unreachable (`ux-auditor`). 360x640 at 1.3x
    // measured 437.6 against 478.0, one caption line from the same failure on
    // the founder's own device.
    //
    // The floor is **measured, not chosen**: the plate reports the height of
    // its sheddable tail — the rule, the chain clock and the trust line — and
    // what is left is the part that must survive a squeeze, which is the
    // number and the sentence that vouches for it. The order of the plate was
    // rebuilt around that, because shedding bottom-first previously shed the
    // honesty line before the fiat line and inverted BG-8's priority.
    //
    // Half the viewport is the one POLICY number here, and **it is the floor
    // that actually binds on a small screen** — not a rare backstop. Measured
    // in the degraded state: it is what pins at 320x568 and 360x640 at 1.3x
    // and at 360x640 at 1.0x, while the measured essential binds only on a
    // roomy 393x852. An earlier version of this comment called it a backstop,
    // which was a claim about geometry nobody had measured — the same class of
    // wrong as a stated extent (`ux-auditor`, item 0 / L121).
    //
    // A header that owns most of the screen has stopped being a header, and
    // the whole plate is one scroll-to-top away regardless. Never below the
    // 1dp bootstrap — a pinned sliver at zero extent does not build its child,
    // so a degenerate viewport would deadlock the measurement rather than
    // squeeze it.
    // **The plate sheds ONLY under pressure.** An earlier version made
    // `minExtent` the essential block unconditionally, so the tail scrolled
    // away on every screen whether or not there was room — and dragged the
    // Activity header up with it before it stuck (founder, on glass). If the
    // whole plate fits inside the cap, the whole plate pins and nothing moves.
    final cap = viewportHeight / 2;
    final essential = _plateExtent - _tailExtent;
    final pinned = _plateExtent <= cap
        ? _plateExtent
        : math.max(1.0, math.min(essential, cap));
    final scroll = CustomScrollView(
      // Always scrollable, so the pull gesture exists even when the ledger is
      // short or empty.
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedHeader(
            extent: _plateExtent,
            minimum: pinned,
            onMeasured: (h) => setState(() => _plateExtent = h),
            child: Entrance(child: plate),
          ),
        ),
        ValueListenableBuilder<List<ActivityRecord>>(
          valueListenable: widget.wallet.activity,
          builder: (context, records, _) => records.isEmpty
              ? const SliverToBoxAdapter(child: SizedBox.shrink())
              : SliverPersistentHeader(
                  pinned: true,
                  delegate: _PinnedHeader(
                    extent: _ruleExtent,
                    minimum: _ruleExtent,
                    onMeasured: (h) => setState(() => _ruleExtent = h),
                    // Shortened to `Activity` at the founder's call on glass.
                    // F29's concern — that the header must not promise a full
                    // history the bound does not deliver — is unaffected: one
                    // word promises less than two, and the cap's own caption
                    // still discloses the bound where it binds.
                    child: const _SectionRule('Activity'),
                  ),
                ),
        ),
        // The feed's counters and relative ages are live by design, so it
        // listens to the clock and the chain — but a balance tick never lands
        // here (and the feed never rebuilds the plate).
        ListenableBuilder(
          listenable: _feedInputs,
          builder: (context, _) => _Feed(
            records: widget.wallet.activity.value,
            now: _now.value,
            virtualDaaScore: widget.chain.virtualDaaScore.value,
            stale: _dimmed.value,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: KvSpace.l)),
      ],
    );
    if (refresh == null) return scroll;
    return RefreshIndicator(
      onRefresh: refresh,
      // Not teal: a refresh is a mechanism, not the one primary action (BG-2).
      // RefreshIndicator resolves colorScheme.primary by default and no
      // component theme covers it.
      color: KvColor.ink,
      backgroundColor: KvColor.key,
      strokeWidth: 2,
      child: scroll,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pinned headers, and the measurement that makes their extents facts.
// ─────────────────────────────────────────────────────────────────────────────

/// Pins a subtree while the ledger scrolls beneath it.
///
/// It paints the ground itself, so rows passing underneath never show through —
/// a transparent pinned header is how a sticky plate ends up with text sliding
/// across it.
///
/// The child lays out under a **relaxed** height constraint so it reports its
/// natural size no matter what [extent] currently says; [onMeasured] carries
/// that number back and the delegate adopts it next frame. The seam is why the
/// extent can never be a stale claim (`L121`).
class _PinnedHeader extends SliverPersistentHeaderDelegate {
  const _PinnedHeader({
    required this.extent,
    required this.minimum,
    required this.onMeasured,
    required this.child,
  });

  /// The subtree's measured height — what the header takes when it can.
  final double extent;

  /// The most it may keep when the viewport cannot hold [extent]. Equal to
  /// [extent] for a header that can never outgrow the screen.
  final double minimum;

  final ValueChanged<double> onMeasured;
  final Widget child;

  @override
  double get minExtent => minimum;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    // **`ClipRect` is load-bearing, not tidiness.** The `OverflowBox` exists so
    // the child lays out at its natural height whatever the current extent
    // says — that is what makes the measurement possible — but an unclipped
    // overflow keeps PAINTING past the sliver's band, with no ground behind
    // it, straight over the ledger rows. Measured at 320x568 and 360x640 at
    // 1.3x: the trust line and the chain clock rendered as text on top of the
    // activity rows, and no widget test could see it because an `OverflowBox`
    // overflowing by design throws nothing (`ux-auditor`, this sitting — the
    // second BLOCK, and the first one my own comment had claimed was fine).
    //
    // Clipping costs the measurement nothing: layout is unaffected, only paint
    // is bounded.
    return ClipRect(
      child: Container(
        color: KvColor.abyss,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: 0,
          maxHeight: double.infinity,
          child: _MeasuredHeight(onMeasured: onMeasured, child: child),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_PinnedHeader old) =>
      old.extent != extent || old.minimum != minimum || old.child != child;
}

/// Reports its child's laid-out height, once per change.
///
/// A render object rather than a second invisible copy of the subtree: the
/// prototype measured a duplicate plate, which works but pays for a whole
/// extra widget tree — including a second animation controller — on the most
/// frequently rebuilt region of the app. This measures the real thing.
class _MeasuredHeight extends SingleChildRenderObjectWidget {
  const _MeasuredHeight({
    required this.onMeasured,
    required Widget super.child,
  });

  final ValueChanged<double> onMeasured;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredHeight(onMeasured);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasuredHeight box) =>
      box.onMeasured = onMeasured;
}

class _RenderMeasuredHeight extends RenderProxyBox {
  _RenderMeasuredHeight(this.onMeasured);

  ValueChanged<double> onMeasured;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (_reported == h) return;
    _reported = h;
    // Never during layout: the report drives a `setState`, and mutating the
    // tree mid-layout is illegal. It lands at the end of THIS frame, so the
    // corrected extent is in place for the next one.
    WidgetsBinding.instance.addPostFrameCallback((_) => onMeasured(h));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The rail — the app's two destinations, and nothing that competes with money.
// ─────────────────────────────────────────────────────────────────────────────

class _TopRail extends StatelessWidget {
  const _TopRail({required this.onMessages, required this.onSettings});

  final VoidCallback? onMessages;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      child: Row(
        children: [
          // The wordmark is the ONLY flex child, and that is the whole layout
          // decision — F5's lesson, pointed the other way.
          //
          // Flutter lays non-flex children out first with UNBOUNDED main-axis
          // constraints and hands the remainder to the flex ones. In the old
          // header the beacon pill sat after a `Spacer()`, took its intrinsic
          // width, and pushed the Settings gear past the Row's clip — at 320dp
          // from textScale 1.15, and at 360dp (the V60's bucket) at 1.30,
          // which is AOSP's stock maximum. The app's only door to biometric
          // enrolment, the lock-grace picker, address scanning and merge
          // became untappable.
          //
          // Here the doors are fixed 48dp targets that must never move, so the
          // WORDMARK is the thing given a bounded constraint and told to
          // yield. `Expanded` + a left `Align` reproduces a `Spacer`'s visual
          // result exactly when there is room, while making the brand — not a
          // custody control — the thing that gives way under a squeeze.
          //
          // Not `Flexible` beside a `Spacer()`: that is two flex children at
          // flex 1 each, so the wordmark would take half the free space and
          // ellipsize on a wide screen with room to spare — a new defect
          // wearing the fix's clothes.
          //
          // `inkNav` is the wordmark's own tone (§1.3). The literal string in
          // Inter stands until the brand identity lands (phase §3).
          const Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'KaspaVerse',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.1,
                  color: KvColor.inkNav,
                ),
              ),
            ),
          ),
          if (onMessages != null)
            _RailAction(
              mark: KvMark.chat,
              label: 'Messages',
              onTap: onMessages!,
            ),
          if (onMessages != null && onSettings != null)
            const SizedBox(width: KvSpace.touchGap),
          if (onSettings != null)
            _RailAction(
              mark: KvMark.settings,
              label: 'Settings',
              onTap: onSettings!,
            ),
        ],
      ),
    );
  }
}

/// A 24dp mark inside a 48dp target — the smaller visual is permitted only
/// because the code says so (BG-12), and the target never shrinks. The label
/// is what a screen reader reads; the glyph stays decorative (§1.2a).
class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.mark,
    required this.label,
    required this.onTap,
  });

  final KvMark mark;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KvRadius.control),
        child: SizedBox(
          width: KvSpace.touchTarget,
          height: KvSpace.touchTarget,
          child: Center(child: KvGlyphIcon(mark, tone: KvColor.inkNav)),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The plate — an earned container, and the only one on this screen.
// ─────────────────────────────────────────────────────────────────────────────

/// The balance, plated (D-191).
///
/// The export drew this in an instrument register — tracked mono caps, a
/// graduated datum, the unit engraved under a scale — and on glass it read as
/// **telemetry**: it made a number look measured rather than owned. It was
/// reversed. Sentence case, the unit beside the figure, and every statement
/// that vouches for the number sits inside the plate with it.
class _MoneyPlate extends StatelessWidget {
  const _MoneyPlate({
    required this.balance,
    required this.trust,
    required this.dimmed,
    required this.daa,
    required this.onNetwork,
    required this.onTailMeasured,
    required this.fiat,
    required this.now,
  });

  final ValueListenable<_BalanceView> balance;
  final ValueListenable<_TrustView> trust;
  final ValueListenable<bool> dimmed;
  final ValueListenable<BigInt?> daa;
  final VoidCallback? onNetwork;

  /// The fiat seam. Null ⇒ the restatement line does not render at all.
  final FiatScope? fiat;

  /// The screen's freshness clock (BG-8), forwarded to the restatement.
  final ValueListenable<DateTime> now;

  /// Reports the height of everything below the rule, so the pinned floor can
  /// be the measured remainder rather than a fraction.
  final ValueChanged<double> onTailMeasured;

  @override
  Widget build(BuildContext context) {
    return KvSurface(
      // Tight to the corners. The label row is 48dp because the chip's TARGET
      // is 48dp (BG-12 — the target never shrinks), so the plate's own top
      // padding is small and the target's transparent half supplies the
      // breathing room instead of stacking on top of it. That is most of what
      // made the plate read as a box rather than a container.
      padding: const EdgeInsets.fromLTRB(
        KvSpace.m,
        KvSpace.xs,
        KvSpace.m,
        KvSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // NOT "Total balance". The figure below is the MATURE balance,
              // and the qualifiers sit directly under it — so "total" would be
              // wrong by exactly the amount printed beneath it, and would
              // disagree with the send screen, which calls the identical value
              // "Available" (product-audit run 1, F9). One value, one name,
              // both surfaces.
              //
              // The label yields, never the chip: the chip is a control with
              // a 48dp target and a destination, and F5's lesson is that the
              // thing which gives way under a squeeze must never be the one
              // the user needs to press. At 320dp / 1.3x this label is what
              // runs out of room, so it wraps (BG-14: labels wrap or shrink)
              // and the plate's MEASURED extent absorbs the extra line.
              const Expanded(child: _SoftLabel('Available balance')),
              ValueListenableBuilder<bool>(
                valueListenable: dimmed,
                builder: (context, stale, _) =>
                    _NetworkChip(live: !stale, onTap: onNetwork),
              ),
            ],
          ),
          const SizedBox(height: KvSpace.xs),
          // **Above the rule: the money.** The figure, its fiat restatement,
          // and the amounts that qualify it. **Below: the instrument** — the
          // chain clock and the link's own sentence (founder, on glass).
          //
          // This moves the honesty line BELOW the rule, which reverses the
          // order the third `ux-auditor` pass required — there, the trust line
          // had to sit above the shed point so a squeeze took the decoration
          // first. It is only safe because the plate now sheds **solely under
          // pressure**: when the whole plate fits the cap, nothing is shed at
          // all. At the geometries where it does not fit, the honesty line is
          // again what goes, and that is a real cost, recorded rather than
          // discovered later (`2026-08-27_UI-UX_…TODO.md`, risk note on A3).
          ValueListenableBuilder<_BalanceView>(
            valueListenable: balance,
            builder: (context, b, _) => _Figure(view: b, fiat: fiat, now: now),
          ),
          _MeasuredHeight(
            onMeasured: onTailMeasured,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: KvSpace.sm),
                Container(height: 1, color: KvColor.plateDivider),
                const SizedBox(height: KvSpace.s),
                // The chain clock, where an instrument puts its reading: small,
                // mono, tabular, and never competing with the money above it.
                // Dimmed with the link (BG-8) — a frozen last-known score at
                // full brightness is the P0.3 scar.
                ValueListenableBuilder<bool>(
                  valueListenable: dimmed,
                  builder: (context, stale, _) => AnimatedOpacity(
                    opacity: stale ? KvFreshness.opacityStale : 1,
                    duration: KvMotion.instant,
                    curve: KvMotion.out,
                    child: ValueListenableBuilder<BigInt?>(
                      valueListenable: daa,
                      builder: (context, score, _) => Text(
                        'DAA ${formatScore(score)}',
                        style: const TextStyle(
                          fontFamily: KvFont.mono,
                          fontSize: 11,
                          height: 15 / 11,
                          color: KvColor.inkMetaLow,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder<_TrustView>(
                  valueListenable: trust,
                  builder: (context, t, _) {
                    final words = t.words;
                    if (words == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: KvSpace.s),
                      child: KvStatusChip(
                        // Amber for everything the user should weigh, green
                        // for a swap running behind a link that still works —
                        // decided in `_computeTrust`, beside the sentences.
                        tone: t.tone,
                        // One lamp; the sentences queue under it, most
                        // consequential first.
                        words: words,
                        maxLines: null,
                        // 15% smaller than the meter's own scale: below the
                        // rule it is a reading, not the screen's subject.
                        trailing: KvCadence(running: t.running, scale: 0.85),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The number, its fiat restatement, and the two lines that qualify it.
class _Figure extends StatelessWidget {
  const _Figure({required this.view, required this.fiat, required this.now});

  final _BalanceView view;

  /// The fiat seam, forwarded from the screen. Null ⇒ no line (a build or a
  /// test with no rate wired).
  final FiatScope? fiat;

  /// The screen's 1 s freshness clock, forwarded so the restatement's age can
  /// advance without a new quote.
  final ValueListenable<DateTime> now;

  /// One step down from §2's `balanceHero` 46, because the unit now sits
  /// **beside** the figure instead of being engraved under it and the line has
  /// to hold both (D-191). Passed as [KvAmount.size] — the ramp is the rule
  /// and this is the composition asking for an exception, out loud.
  static const double heroSize = 42;

  @override
  Widget build(BuildContext context) {
    final pending = view.pending;
    final outgoing = view.outgoing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KvAmount(view.mature, size: heroSize, stale: view.stale),
        // The fiat restatement sits with the figure it restates, above the
        // rule (founder, on glass) — it is the same number in another unit,
        // not an instrument reading. It restates `mature`, the same BigInt
        // the hero above renders, so the two cannot drift.
        Padding(
          padding: const EdgeInsets.only(top: KvSpace.xs),
          child: _FiatLine(fiat: fiat, sompi: view.mature, now: now),
        ),
        if (pending != null && pending > BigInt.zero) ...[
          const SizedBox(height: KvSpace.s),
          // Money ARRIVING that the hero does not yet contain: at the pin
          // `pending` is a set disjoint from `mature`. Green and signed `+`,
          // which is what BG-7 reserves green for.
          _Qualifier(
            amount: pending,
            direction: KvMoneyDirection.incoming,
            words: 'pending',
            stale: view.stale,
          ),
        ],
        // Money we have spent that the network has not handed back yet. It
        // matters most at exactly the moment it is easiest to miss: a wallet
        // that just spent everything reads `0.00000000 KAS`, and without this
        // line that zero is indistinguishable from an empty wallet (F4/F20,
        // product-audit run 3).
        //
        // **It carries NO sign, and that is the whole design.** It looks like
        // the pending line and it is NOT its mirror — the two have opposite
        // arithmetic under identical grammar, which is exactly the trap
        // (consensus-auditor, V5). At the pin the hero figure is already NET
        // of the send: `mature = (mature_utxos + consumed).saturating_sub(fees
        // + payment)` (`wallet/core/src/utxo/context.rs:506-547 @ cfafeb4`).
        // So `+ N pending` is money the hero does not yet contain, and this
        // value is money the hero has already lost. A `−` here would invite a
        // second subtraction: a partial send of 30 from 100 would read
        // `70.00 KAS` over `− 30.00000000`, and 70 − 30 is wrong.
        //
        // The sign would also be a lie outright on `SignableKind::
        // SelfSendFrame` — the KaChat message path — where `payment_value()`
        // is `Some`, so the frame's own amount lands in
        // `outgoing_without_batch_tx` and is rendered here while travelling
        // straight back to this wallet.
        //
        // So it is a memo, not a term in a sum: the amount and what it is
        // doing. The prototype drew it signed and red; the prototype was
        // rendering a fabricated number and had never carried this argument.
        //
        // **Two bounds, verified at the pin rather than assumed.** The memo
        // excludes FEES by construction — `Balance.outgoing` is
        // `outgoing_without_batch_tx`, the payment alone, while the hero is
        // net of payment *and* fee. And it goes silent on a SWEEP:
        // `discharges_outgoing()` (`rust/chain/src/send.rs:1668`) drops the
        // pin's outgoing record immediately after submit for a ReceiverPays
        // drain, so a swept wallet reads `0.00000000 KAS` with no memo — the
        // very state this line was written to prevent. The ledger row beneath
        // is what carries it there. Gating the memo on an unaccepted outgoing
        // row instead of on `Balance.outgoing` is the real fix and belongs
        // with Send (UX-4); recorded rather than half-built
        // (`consensus-auditor`, this sitting).
        if (outgoing != null && outgoing > BigInt.zero) ...[
          const SizedBox(height: KvSpace.s),
          _Qualifier(
            amount: outgoing,
            direction: KvMoneyDirection.internal,
            words: 'in flight',
            stale: view.stale,
          ),
        ],
      ],
    );
  }
}

/// An amount that qualifies the hero, with the word that says what it is
/// doing. Merged for a screen reader: unmerged, two bare KAS amounts are
/// announced back to back and the qualifier arrives only on the next swipe.
class _Qualifier extends StatelessWidget {
  const _Qualifier({
    required this.amount,
    required this.direction,
    required this.words,
    required this.stale,
  });

  final BigInt amount;
  final KvMoneyDirection direction;
  final String words;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Row(
        children: [
          Flexible(
            child: KvAmount(
              amount,
              role: KvAmountRole.row,
              direction: direction,
              stale: stale,
              showUnit: true,
            ),
          ),
          const SizedBox(width: KvSpace.s),
          Text(
            words,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 12,
              height: 16 / 12,
              fontWeight: FontWeight.w500,
              color: KvColor.inkMeta,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the balance is worth, in fiat — the app's one unverifiable claim.
///
/// D-191 permits it from a named, replaceable, disable-able source, and D-192
/// then narrowed the disclosure twice: the figure is subordinate and
/// `≈`-prefixed, its **source is disclosed where the source is chosen** (the
/// node surface), its **age appears only when age matters** (D-189), and it
/// reaches no signing surface. UX-3 built the source control, which is what
/// let this stop rendering an honest placeholder and start rendering an honest
/// number.
///
/// **Three states, and the third is the point.** A price: `≈ $12.34`. No
/// usable price: `≈ —`, which is what BG-5 says an unknown renders as — never
/// a stale figure at full confidence and never a fabricated one. Switched
/// off: **nothing at all**, because a user who turned fiat off did not ask for
/// a row explaining that they turned fiat off.
class _FiatLine extends StatelessWidget {
  const _FiatLine({required this.fiat, required this.sompi, required this.now});

  /// Null ⇒ the rate seam is not wired at all (a widget test, a build without
  /// it): the line renders nothing, exactly as if the user had switched it off.
  final FiatScope? fiat;

  /// What to restate — the hero's own number, so the two can never disagree.
  /// Null is the hero's `—`, and it restates as `≈ —` rather than as `$0.00`:
  /// an unknown balance has an unknown value, and a confident zero beside a
  /// dash is the kind of true-looking lie BG-8 exists to stop.
  final BigInt? sompi;

  /// **The screen's freshness clock, not a `clock()` call** (BG-8).
  ///
  /// The age below is the one branch that must appear WITHOUT a new value
  /// arriving — a vendor that goes down stops delivering quotes, which is
  /// exactly when the figure starts being able to mislead. Computed from a
  /// bare `clock()` it was unreachable in practice: the only thing that
  /// rebuilt this line was a fresh quote, and a fresh quote resets the age to
  /// zero. So a dead source rendered a confident `≈ \$36.79`, ageless, forever
  /// (`consensus-auditor`, this sitting — `L126` in its purest form: the
  /// degraded branch was tested by constructing it already-degraded, which
  /// proves the rendering and not the transition).
  final ValueListenable<DateTime> now;

  @override
  Widget build(BuildContext context) {
    final scope = fiat;
    if (scope == null) return const SizedBox.shrink();
    return ValueListenableBuilder<bool?>(
      valueListenable: scope.enabled,
      builder: (context, on, _) {
        // Off, or not yet known: both render nothing. A line that appears one
        // frame after launch is better than one that appears and then leaves.
        if (on != true) return const SizedBox.shrink();
        return ValueListenableBuilder<KvRateQuote?>(
          valueListenable: scope.quote,
          builder: (context, quote, _) => ValueListenableBuilder<DateTime>(
            valueListenable: now,
            builder: (context, at, _) {
              final value = sompi == null ? null : quote?.usdFor(sompi!);
              final figure = value == null
                  ? '≈ —'
                  : '≈ \$${value.toStringAsFixed(2)}';
              // Silence is the healthy state (D-189/D-192): a fresh rate says
              // nothing about its age, and the age appears at the point where it
              // could start to mislead.
              final since = quote == null
                  ? null
                  : at.difference(quote.fetchedAt);
              final age = since == null
                  ? 'no rate yet'
                  : since >= RateService.staleAfter
                  ? '${formatAge(since)} old'
                  : null;
              return Semantics(
                label: value == null
                    ? 'Value in dollars: no exchange rate yet'
                    : 'Approximately ${value.toStringAsFixed(2)} US dollars',
                excludeSemantics: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      figure,
                      style: const TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 13,
                        height: 18 / 13,
                        // Subordinate by scale AND tone (BG-5): KAS is the unit
                        // of account and this sits beside it, never instead.
                        color: KvColor.inkMeta,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (age != null) ...[
                      const SizedBox(width: KvSpace.s),
                      Flexible(
                        child: Text(
                          age,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 11,
                            height: 15 / 11,
                            color: KvColor.inkMetaLow,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Sentence case, Inter, no tracking — a label a person reads, not one an
/// instrument wears.
class _SoftLabel extends StatelessWidget {
  const _SoftLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 13,
      height: 18 / 13,
      color: KvColor.inkDim,
    ),
  );
}

/// The plate's own control, the money screen's door to the node surface, and
/// **the screen's standing link indicator**.
///
/// **The lamp came back on a founder call, 2026-08-27, and it needs its history
/// stated or the next auditor removes it again.** It was deleted earlier in
/// this same sitting because BG-7, as narrowed at **D-200**, took link health
/// away from `ok` green — green is money arriving, things confirmed, and a
/// control the user switched on, and a link changes without the user. That
/// reading is what made a green lamp here forbidden and an amber one redundant
/// with the trust line.
///
/// The founder's call, made on glass, is that a wallet's connection is exactly
/// the thing a user should be able to read at a glance without parsing a
/// sentence, and that the pulse is what makes it legible. **It is a scope
/// decision, and scope is his** — but it amends BG-7, so it is ledgered rather
/// than absorbed. The P0.3 scar the original lamp caused is guarded a
/// different way now: this lamp and the trust line are computed from the SAME
/// `_LinkView`, so they cannot disagree, and a test pins that.
class _NetworkChip extends StatelessWidget {
  const _NetworkChip({required this.live, required this.onTap});

  /// Drives the lamp. Never const — one sat green beside an amber "Link lost"
  /// on this very plate once.
  final bool live;

  /// Null ⇒ no node surface is wired, so this is a plain reading rather than a
  /// control. Never a dead button: BG-12 forbids a disabled control with no
  /// stated reason, and "the seam is absent" is not a reason a user can act on.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chip = KvSurface.control(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The pulse is the liveness tell; it stills when the link does, the
          // way every other breathing thing in this app does (BG-8).
          KvBreath(
            active: live,
            child: KvLamp(live ? KvLampTone.ok : KvLampTone.warn),
          ),
          const SizedBox(width: KvSpace.s),
          const Text(
            'Mainnet',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              fontWeight: FontWeight.w500,
              color: KvColor.inkDim,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: KvSpace.xs),
            const KvGlyphIcon(KvMark.chevron, size: 12, tone: KvColor.inkMeta),
          ],
        ],
      ),
    );
    if (onTap == null) {
      return Semantics(
        label: 'Mainnet',
        child: ExcludeSemantics(child: chip),
      );
    }
    return Semantics(
      button: true,
      label: 'Mainnet. Open network and node settings',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(KvRadius.control),
          // A 28dp visual inside a 48dp target. It sits beside a 42dp balance
          // and would compete with it at full height; a network chip is a way
          // OUT of this screen, not a thing on it. The smaller visual is
          // declared (BG-12) and the target never shrinks.
          child: SizedBox(
            height: KvSpace.touchTarget,
            child: Center(child: chip),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The ledger — rows, not cards. Rhythm from spacing (BG-1).
// ─────────────────────────────────────────────────────────────────────────────

/// Pins under the plate: scrolling a ledger should never leave you unsure
/// which ledger you are in (D-189).
class _SectionRule extends StatelessWidget {
  const _SectionRule(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.gutter,
        0,
        KvSpace.gutter,
        KvSpace.s,
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 15,
          height: 20 / 15,
          fontWeight: FontWeight.w600,
          color: KvColor.ink,
        ),
      ),
    );
  }
}

/// How many rows the feed can hold — the Rust-side bound, mirrored.
///
/// **Source of truth is `ACTIVITY_CAP` in `rust/chain/src/wallet_sync.rs`**; the
/// list crosses the bridge already truncated, so the glass cannot derive the
/// number and has to carry it. `test/activity_cap_test.dart` reads that Rust
/// constant and fails if the two ever drift — the mirror is pinned, not trusted.
const int kActivityFeedCap = 100;

/// The activity list, or the one empty state (live, never a forever-skeleton).
class _Feed extends StatelessWidget {
  const _Feed({
    required this.records,
    required this.now,
    this.virtualDaaScore,
    this.stale = false,
  });

  final List<ActivityRecord> records;
  final DateTime now;

  /// BG-8: a stale link must not stream a frozen counter at full presence —
  /// counters fall back to their static words until the link is live again
  /// (ux-audit counter finding 1; the P0.3 scar class).
  final bool stale;

  /// Live DAA — the streaming counter for both directions is a DAA-distance:
  /// a deposit counts from its inclusion DAA (`blockDaaScore`), a send from its
  /// DAG-acceptance DAA (`acceptedDaaScore`). Both node-read and cosmetic (the
  /// number dies with wallet-core's own maturity truth; finding 18 replaced the
  /// send's laggy 1 Hz tracker-depth poll with this synchronous path so it
  /// streams as fluidly as a deposit).
  final BigInt? virtualDaaScore;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return const SliverToBoxAdapter(
        child: KvEmptyState(
          mark: KvMark.diamond,
          // Shipped copy, verbatim (D-196): the redesign is a change of form,
          // not of voice.
          truth: 'No recent activity',
          nudge: 'Payments you send and receive appear here.',
        ),
      );
    }
    // The list arrives already truncated by Rust, so "full" is the only signal
    // the glass gets that anything was cut (F29).
    final atCap = records.length >= kActivityFeedCap;
    return SliverList.builder(
      // +1 for the bound's own caption when the feed is full (F29).
      itemCount: records.length + (atCap ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == records.length) {
          // Only a user the bound actually binds ever reads this. Quiet tier:
          // it states the bound, it does not offer to lift it. Paging is a
          // deliberate non-feature (D-175).
          return const Padding(
            padding: EdgeInsets.fromLTRB(
              KvSpace.gutter,
              KvSpace.sm,
              KvSpace.gutter,
              0,
            ),
            child: Text(
              'Showing the $kActivityFeedCap most recent.',
              textAlign: TextAlign.center,
              // `inkMetaLow`, the smallest tone that still carries
              // information: this is the app's only disclosure that the
              // user's history has been cut, and `etch` is decoration only.
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 11,
                height: 15 / 11,
                color: KvColor.inkMetaLow,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A hairline between two facts is what turns a list into a ledger
            // you read down rather than a block you scan (D-189).
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: KvSpace.gutter),
                child: SizedBox(
                  height: 1,
                  child: ColoredBox(color: KvColor.rowDivider),
                ),
              ),
            _ActivityRow(
              // Txid-keyed so a row keeps its chip's transition state across
              // reconciles (the list is rebuilt on every snapshot).
              key: ValueKey(records[i].txid),
              record: records[i],
              now: now,
              stale: stale,
              confirmations: _confirmations(records[i]),
            ),
          ],
        );
      },
    );
  }

  /// The chip's streaming counter for one row — a DAA-distance depth, node-read
  /// and cosmetic (it dies with wallet-core's own maturity truth; the depth
  /// gate quiets it once deep). `null` ⇒ static label. A stale link never
  /// counts (a frozen last-known DAA must not read live — BG-8).
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
    // A send counts from its DAG-ACCEPTANCE score; a receive from its own
    // inclusion score. Widened at the founder's call so EVERY row has a depth,
    // not only the ones that were still counting — the burial mark needs the
    // number on both sides of 100 and 1,000 to say which side it is on.
    final anchor = record.direction == ActivityDirection.outgoing
        ? record.acceptedDaaScore
        : record.blockDaaScore;
    if (anchor == null || daa < anchor) return null;
    return (daa - anchor).toInt();
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    super.key,
    required this.record,
    required this.now,
    required this.stale,
    this.confirmations,
  });

  final ActivityRecord record;
  final DateTime now;
  final bool stale;
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
    // Direction rides FOUR ways at once — word, sign, colour and weight — so
    // the row survives greyscale, colour-blindness and a screen reader (BG-7).
    // `KvAmount` carries the last three; the title carries the word.
    final (
      KvMark mark,
      KvMoneyDirection direction,
      String title,
    ) = switch (record.direction) {
      ActivityDirection.incoming => (
        KvMark.arrowIn,
        KvMoneyDirection.incoming,
        record.isCoinbase ? 'Mined' : 'Received',
      ),
      ActivityDirection.outgoing => (
        KvMark.arrowOut,
        KvMoneyDirection.outgoing,
        'Sent',
      ),
      ActivityDirection.change => (
        KvMark.selfSend,
        KvMoneyDirection.internal,
        'Consolidated',
      ),
    };
    final tone = switch (direction) {
      KvMoneyDirection.incoming => KvColor.ok,
      KvMoneyDirection.outgoing => KvColor.risk,
      KvMoneyDirection.internal => KvColor.inkDim,
    };
    final chip = _chipState();
    final time = record.unixtimeMsec;

    return Opacity(
      opacity: stale ? KvFreshness.opacityStale : 1,
      // No card and no tinted icon plate: the ledger reads by spacing, and a
      // container that exists because content needed somewhere to sit is the
      // admission BG-1 forbids.
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: KvSpace.gutter,
          vertical: KvSpace.m,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: KvGlyphIcon(mark, tone: tone),
            ),
            const SizedBox(width: KvSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 15,
                      height: 20 / 15,
                      fontWeight: FontWeight.w500,
                      color: KvColor.ink,
                    ),
                  ),
                  const SizedBox(height: KvSpace.xs),
                  // A `Wrap`, not a `Row`: at 320dp / 1.3x the lifecycle label
                  // and the age together need more than this text column has,
                  // and the honest answer is a second line rather than a
                  // clipped one. On every geometry with room they sit side by
                  // side, so nothing is spent on the common case.
                  Wrap(
                    spacing: KvSpace.s,
                    runSpacing: KvSpace.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // The lifecycle chip is NOT a second rendering of
                      // `KvStatusChip`: it carries a breathing dot, a staged
                      // transition and a streaming depth counter, and its
                      // quiet `Pending` tier has no lamp tone at all — BG-7
                      // gives lamps three hues and none of them is neutral.
                      // The two answer different questions.
                      KvBurialMark(
                        state: chip,
                        confirmations: confirmations,
                        maturity: record.maturity,
                      ),
                      if (time != null)
                        Text(
                          _relativeAge(now, time),
                          maxLines: 1,
                          // A timestamp is tabular (§2), so a ticking age does
                          // not jiggle the row.
                          style: const TextStyle(
                            fontFamily: KvFont.mono,
                            fontSize: 11,
                            height: 15 / 11,
                            color: KvColor.inkMetaLow,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: KvSpace.sm),
            // **Hard against the row's end.** `Flexible` alone let the amount
            // hug the START of its share of the free space, so a short figure
            // floated ~33dp clear of the gutter while the divider above it ran
            // the full width — the ledger's right edge read ragged (founder, on
            // glass). `Expanded` + a right `Align` gives it the whole column
            // and puts the figure at the end of it, while `KvAmount`'s own
            // `FittedBox` still scales down rather than clipping (BG-5).
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: KvAmount(
                  record.valueSompi,
                  role: KvAmountRole.row,
                  direction: direction,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "2 m ago" / "just now" — floors, never overstates (BG-8).
  static String _relativeAge(DateTime now, BigInt unixtimeMsec) {
    final at = DateTime.fromMillisecondsSinceEpoch(unixtimeMsec.toInt());
    final age = now.difference(at);
    if (age.inSeconds < 5) return 'just now';
    return '${formatAge(age)} ago';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The thumb arc — Send and Receive, and nothing else (§5).
// ─────────────────────────────────────────────────────────────────────────────

/// On a wallet with nothing to send the light flips to Receive, because the
/// brightest thing on screen should always be the most sensible next act.
///
/// **Only a PROVEN zero flips it.** An unknown balance is not an empty one, and
/// telling a user with a dark link that they have nothing to send is a claim we
/// cannot make (BG-5/BG-8).
class _ThumbActions extends StatelessWidget {
  const _ThumbActions({
    required this.balance,
    required this.onSend,
    required this.onReceive,
  });

  final ValueListenable<_BalanceView> balance;
  final VoidCallback? onSend;
  final VoidCallback? onReceive;

  @override
  Widget build(BuildContext context) {
    if (onSend == null && onReceive == null) return const SizedBox.shrink();
    return Entrance(
      index: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.sm,
          KvSpace.gutter,
          KvSpace.m,
        ),
        child: ValueListenableBuilder<_BalanceView>(
          valueListenable: balance,
          builder: (context, b, _) {
            final mature = b.mature;
            // **Only a PROVEN zero flips it**, and proven means more than
            // non-null. `discoveryIncomplete` says the balance was computed
            // over a window that may be SHORT, and `utxoIndexMissing` says the
            // node cannot see this wallet's coins at all — a zero under either
            // is exactly the confidently-wrong number those flags exist to
            // mark. Without these terms the plate said "this may not be your
            // whole balance" and "Nothing to send yet" in the same frame, and
            // closed the money door on a wallet that may hold funds
            // (`consensus-auditor`, this sitting).
            final nothingToSend =
                mature != null &&
                mature == BigInt.zero &&
                !b.utxoIndexMissing &&
                !b.discoveryIncomplete;
            return Row(
              children: [
                if (onReceive != null)
                  Expanded(
                    child: KvAction(
                      label: 'Receive',
                      primary: nothingToSend,
                      onTap: onReceive!,
                    ),
                  ),
                if (onReceive != null && onSend != null)
                  const SizedBox(width: KvSpace.sm),
                if (onSend != null)
                  Expanded(
                    child: KvAction(
                      label: 'Send',
                      primary: !nothingToSend,
                      // BG-12: a disabled control always says why, in words.
                      disabledReason: nothingToSend
                          ? 'Nothing to send yet'
                          : null,
                      onTap: onSend!,
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
