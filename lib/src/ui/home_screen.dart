import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../rust/api/wallet.dart';
import 'widgets/kv_fiat.dart';
import 'format.dart';
import 'theme/kv_page_route.dart';
import 'theme/kv_window.dart';
import 'theme/tokens.dart';
import 'widgets/entrance.dart';
import 'widgets/kv_activity.dart';
import 'widgets/kv_amount.dart';
import 'widgets/kv_breath.dart';
import 'widgets/kv_burial_mark.dart';
import 'widgets/kv_derived.dart';
import 'widgets/kv_cadence.dart';
import 'widgets/kv_chrome.dart';
import 'widgets/kv_coming_soon.dart';
import 'widgets/kv_drawer.dart';
import 'widgets/kv_empty_state.dart';
import 'widgets/kv_glyph.dart';
import 'widgets/kv_money_plate.dart';
import 'widgets/kv_rows.dart';
import 'widgets/kv_status_chip.dart';
import 'widgets/kv_streaming_count.dart';
import 'widgets/kv_tabs.dart';
import 'widgets/kv_two_pane.dart';
import 'widgets/status_beacon.dart';

/// `FiatScope` moved to `widgets/kv_fiat.dart` when a second and third
/// surface began drawing a price (Send's amount, the signing sheet). Re-exported
/// so every shipped import path keeps working.
export 'widgets/kv_fiat.dart' show FiatScope, KvFiatLine;

/// **Money** — the surface a user opens every day, and the first one wired to
/// real funds (design_system §5, D-191…D-194).
///
/// Rebuilt in **Deep V6** at UX-R1. The balance sits on a `plateHero` money
/// plate holding *only what is always true* — the label, the figure, its `≈`
/// restatement, the live dot and the raised Send / Receive pair (BG-28) —
/// and everything transient arrives in a strip beneath it. The plate is
/// **pinned** and the ledger scrolls under it in one row container headed by
/// Activity · Tokens tabs (§5): what you own is not something you should have
/// to scroll back up to see. **Pull-to-refresh is hosted by the whole scroll
/// view**, not by the list, so the gesture works from the balance too — which
/// is where a hand reaches for it first (D-194).
///
/// **The window class decides the arrangement, and nothing else does**
/// (BG-33): `compact` is one column with the drawer pushing; `medium` is one
/// centred column beside the rail; `expanded`+ is ledger left, transaction
/// right, with no push at all; and `short` collapses the plate to
/// `KvMoneyBar`. Every one of those readings comes from `KvWindow.of` — there
/// is no breakpoint anywhere in this file.
///
/// **The DAA readout sits under the balance** (A4, founder ruling D-256). It
/// came off at UX-R1 on a reading of BG-8 — *nothing animates on a settled
/// screen* — and went back on with the distinction that reading was missing:
/// **the counter's animation is not the point, the numbers are**, and a chain
/// counter that stops IS the stale signal rather than a decoration that
/// happens to move. BG-8 is amended to seat it, because BG-18 had always
/// licensed a streaming chain counter and the two laws met on this one object.
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
/// (derived, value-gated notifiers — see [KvDerived]). A balance tick never
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
    this.nodeRoute,
    this.detailRoute,
    this.fiat,
    this.clock = DateTime.now,
    this.floatingActionButton,
  });

  /// Node / link scope (ChainService): the network chip's lamp, the trust
  /// line, the ledger's depth counters and the node surface behind the chip. A
  /// grouping of the SAME injected listenables the V4 seam law protects — the
  /// scope object may be rebuilt per parent build; the notifiers inside must
  /// stay identical (asserted in [State.didUpdateWidget]).
  final ChainScope chain;

  /// Wallet scope (WalletService): balance + activity + the pull heal.
  final WalletScope wallet;

  /// Where a ledger row goes when it is tapped — the transaction detail, by
  /// txid rather than by a captured snapshot, because that screen stays live
  /// while the burial gauge climbs. Null leaves the rows unreachable and
  /// **untappable**: a row that swallowed a tap would teach distrust of every
  /// other control on the screen (BG-12).
  ///
  /// Like [sendRoute] it is handed **this screen's own `_dimmed` bit** rather
  /// than deriving one of its own. The detail plots a burial depth against the
  /// live DAA, so it owes BG-8's live/stale exactly as this screen does, and
  /// two independent foldings of the link state are how a screen and the screen
  /// behind it start disagreeing about whether the wallet is connected.
  final Widget Function(
    BuildContext context,
    String txid,
    ValueListenable<bool> stale,
  )?
  detailRoute;

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

  // **Messages and Settings are the drawer's, not this screen's** (§4). They
  // were `messagesRoute` / `settingsRoute` here while the top rail was the
  // only place a destination could live (D-190 withdrew the nav panel); Deep
  // V6 seats them in `KvDrawer`, and a screen that also offered them would be
  // two doors to one room.

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
/// The wallet-facing wiring [HomeScreen] consumes — same law as [ChainScope].
class WalletScope {
  const WalletScope({
    required this.mature,
    required this.pending,
    required this.activity,
    required this.syncing,
    required this.utxoIndexMissing,
    required this.maturity,
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

  /// **The pin's maturity thresholds** (D-249), read once at startup and
  /// carried rather than assumed. Every ledger row's rung is decided against
  /// these; there is deliberately no default, so a wallet that could not read
  /// them fails to build instead of quietly quoting last year's numbers.
  final KvMaturity maturity;

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
/// what lets [KvDerived] swallow the no-op ticks.
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

/// What the balance region renders. The ledger's depth counters are scoped
/// separately — a DAA tick must not rebuild the money number.
typedef _BalanceView = ({
  BigInt? mature,
  BigInt? pending,
  BigInt? outgoing,
  bool stale,
  bool utxoIndexMissing,
  bool discoveryIncomplete,
});

class _HomeScreenState extends State<HomeScreen> {
  Timer? _ticker;

  /// The freshness clock (BG-8) — ticked once per second. Regions that render
  /// time listen to THIS, so the tick never lands as a whole-screen setState.
  late final ValueNotifier<DateTime> _now;

  late final KvDerived<_LinkView> _link;
  late final KvDerived<bool> _dimmed;
  late final KvDerived<_TrustView> _trust;
  late final KvDerived<_BalanceView> _balance;

  /// Everything the activity feed reads. The feed rebuilds on activity
  /// snapshots, depth ticks, DAA ticks and the 1 s clock (its counters and
  /// relative ages are live by design) — but never on a balance change.
  late final Listenable _feedInputs;

  /// **The ledger has the screen** (founder, on glass 2026-09-04, D-262).
  /// Closed, the card ends just above the Receive · Send bar with its own
  /// rounded foot and the rows sit still inside it. Open — `All`, or the
  /// first upward scroll on the rows — the card drops under the bar and the
  /// rows scroll beneath the fixed tabs. `Less` snaps it back. **The plate
  /// never moves and never minimises**: the founder ruled that out.
  bool _expanded = false;

  /// The rows' own scroll position, kept across the open/closed swap so the
  /// gesture that opened the card is the same gesture that keeps scrolling it.
  final ScrollController _ledgerScroll = ScrollController();

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
    _link = KvDerived([
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
    _dimmed = KvDerived([
      _link,
    ], () => _link.value.state != BeaconState.connected);
    _trust = KvDerived([
      _link,
      widget.wallet.syncing,
      widget.wallet.utxoIndexMissing,
      if (widget.wallet.discoveryIncomplete != null)
        widget.wallet.discoveryIncomplete!,
    ], _computeTrust);
    _balance = KvDerived(
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
    _ledgerScroll.dispose();
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

  /// The row the detail column is showing, in `expanded`+ (§3a.2). Null is
  /// the pane's one truth: *"Select a transaction."*
  ///
  /// It is a **txid**, not a record, for the same reason [detailRoute] takes
  /// one: the detail stays live while the burial gauge climbs, and a captured
  /// snapshot would freeze on the frame it was tapped.
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final metrics = KvWindow.of(context);
    return Scaffold(
      backgroundColor: KvColor.abyss,
      floatingActionButton: widget.floatingActionButton,
      body: SafeArea(
        // The real status bar inset and nothing more (founder, on glass
        // 2026-09-04, D-262): the 52 dp reserve left a band of ground above
        // the title on the V60, and the title now sits close under the bar.
        top: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // **The title sits over its own column, not over the window.**
            // Left at the page edge it started 28 dp inboard of the plate in
            // `expanded` and 40 dp of it in `medium` — a heading that does not
            // line up with the thing it names, visible on the first contact
            // sheet.
            _columnAligned(
              metrics,
              _Header(
                title: 'Wallet',
                scope: 'Main',
                // `_columnAligned` has already applied the outer gutter in a
                // two-pane window, so the header must not apply it twice.
                inset: metrics.isTwoPane ? 0 : null,
                // §3a.2: the avatar opens the drawer in `compact` and does
                // nothing in the classes where navigation is already
                // standing, **so the header drops it** rather than keeping a
                // control that is live in one window and inert in another.
                onOpenDrawer: KvNavScope.maybeOf(context)?.openDrawer,
              ),
            ),
            Expanded(
              child: metrics.isTwoPane
                  ? KvTwoPane(
                      list: _moneyColumn(metrics),
                      detail: _detailPane(),
                    )
                  : Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        // A content column never exceeds 560, in any class
                        // (BG-33) — a wider window gains columns, never a
                        // wider column.
                        constraints: const BoxConstraints(
                          maxWidth: KvLayout.columnMax,
                        ),
                        child: _moneyColumn(metrics),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Puts [child] on the same horizontal grid the content column stands on:
  /// the outer gutter in a two-pane window, the centred 560 column otherwise.
  Widget _columnAligned(KvWindowMetrics metrics, Widget child) {
    if (metrics.isTwoPane) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: KvLayout.pageMax),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: metrics.gutter),
            child: child,
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: KvLayout.columnMax),
        child: child,
      ),
    );
  }

  /// The money column: **the plate fixed, the strip under it, the ledger card
  /// filling the rest, and the Receive · Send bar over the card's foot**
  /// (founder, on glass 2026-09-04, D-262). Nothing above the card scrolls.
  Widget _moneyColumn(KvWindowMetrics metrics) {
    // **`short` is the only collapse there is** (BG-33). A phone on its side
    // has 412 dp of height and the ledger is what it was turned for, so the
    // plate becomes a 56 dp bar carrying the two verbs (R5) and there is no
    // foot bar.
    final short = metrics.collapseMoneyPlate;
    final Widget plate = short
        ? ValueListenableBuilder<_BalanceView>(
            valueListenable: _balance,
            builder: (context, b, _) => KvMoneyBar(
              sompi: b.mature,
              stale: b.stale,
              // **A live dot, not the whole chip** (§3a.1: "integer figure +
              // live dot + Send · Receive as 44 pills"). The `Mainnet` chip
              // is ~110 dp wide; in a 340 dp list pane it took the room the
              // figure needed and the balance was fitted down to nothing —
              // BG-5's one prohibition, found by looking at the 915x412 frame.
              // The node surface stays one door away, through Settings.
              indicator: _liveDot(),
              onSend: _sendTap(),
              onReceive: _receiveTap(),
              sendDisabledReason: _sendBlocked(b),
            ),
          )
        : ValueListenableBuilder<_BalanceView>(
            valueListenable: _balance,
            builder: (context, b, _) => KvMoneyPlate(
              label: 'Available balance',
              figure: KvAmount(b.mature, stale: b.stale),
              fiat: KvFiatLine(fiat: widget.fiat, sompi: b.mature, now: _now),
              chainClock: _ChainClock(
                daa: widget.chain.virtualDaaScore,
                dimmed: _dimmed,
              ),
              indicator: _indicator(),
            ),
          );
    final gutter = metrics.isTwoPane ? 0.0 : KvSpace.gutter;
    // The foot bar's whole footprint — its pills, the 12 above and the 16
    // below — which is what the closed card stops short of and what the open
    // card's last row scrolls clear of. The bar's height is constant: a
    // blocked Send says why INSIDE its pill (`KvAction.inlineReason`), so the
    // footprint never grows under the card.
    final foot = short ? 0.0 : _ActionBar.footprint;
    final expanded = short || _expanded;
    final band = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, KvSpace.xs, gutter, KvSpace.m),
          child: Entrance(child: plate),
        ),
        _StatusStrip(balance: _balance, trust: _trust, gutter: gutter),
      ],
    );
    final refresh = widget.wallet.onRefreshActivity;
    final column = LayoutBuilder(
      // Measures the height it was given; chooses nothing from a width
      // (BG-33).
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // **The band above the card is capped, and scrolls inside its cap.**
          // The plate and the strip do not scroll on a phone — they fit. At
          // the floor (320 × 568 / 1.3×, or the 2.0× accessibility scale)
          // they do not, and the card keeps at least [_Ledger.minHeight]
          // while the band clips: the trust *sentence* is what a squeeze
          // takes, as it was under the pinned band (A3), never the balance
          // and never the ledger. **Pull-to-refresh lives here too** (D-194:
          // it works FROM the balance), as well as on the rows.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(
                0.0,
                box.maxHeight - _Ledger.minHeight - foot,
              ),
            ),
            child: _refreshable(
              refresh,
              SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                child: band,
              ),
            ),
          ),
          // The feed's counters and relative ages are live by design, so it
          // listens to the clock and the chain — but a balance tick never
          // lands here (and the feed never rebuilds the plate).
          Expanded(
            child: ListenableBuilder(
              listenable: _feedInputs,
              builder: (context, _) => _Ledger(
                records: widget.wallet.activity.value,
                maturity: widget.wallet.maturity,
                now: _now.value,
                virtualDaaScore: widget.chain.virtualDaaScore.value,
                stale: _dimmed.value,
                gutter: gutter,
                selected: metrics.isTwoPane ? _selected : null,
                expanded: expanded,
                foot: foot,
                controller: _ledgerScroll,
                onRefresh: refresh,
                // `All` has nothing to do on a window that is already short —
                // the card is already open — so the action is absent there
                // rather than inert (§8).
                onExpand: short ? null : _toggleLedger,
                onOpen: widget.detailRoute == null
                    ? null
                    : (txid) => _open(txid, metrics),
              ),
            ),
          ),
        ],
      ),
    );
    if (short) return column;
    return Stack(
      children: [
        Positioned.fill(child: column),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ValueListenableBuilder<_BalanceView>(
            valueListenable: _balance,
            builder: (context, b, _) => _ActionBar(
              gutter: gutter,
              onSend: _sendTap(),
              onReceive: _receiveTap(),
              sendDisabledReason: _sendBlocked(b),
            ),
          ),
        ),
      ],
    );
  }

  /// The live indicator, and the money screen's door to the node surface.
  ///
  /// **The pulsing dot is back** (A6, founder ask). It was removed at UX-2
  /// because D-200's narrowing took link health away from `ok`; BG-7 as
  /// amended in Deep V6 v4.2 lists *"link healthy"* among `ok`'s meanings
  /// outright, so the ask is law-compliant as written and needed no
  /// amendment. Live is the **live dot** — `primary`, pulsing, one of BG-2's
  /// three permitted emissions — and a dark link is a static amber lamp.
  ///
  /// The lamp and the trust line are computed from the SAME `_LinkView`, so
  /// they cannot disagree; that is what guards the P0.3 scar now.
  Widget _indicator() => ValueListenableBuilder<bool>(
    valueListenable: _dimmed,
    builder: (context, stale, _) => _NetworkChip(
      live: !stale,
      onTap: widget.nodeRoute == null ? null : _openNode,
    ),
  );

  /// The bare live dot the `short` bar carries. Same widget, same law, same
  /// `_dimmed` reading as the chip's — so the two can never disagree about a
  /// link the way P0.3's did.
  Widget _liveDot() => ValueListenableBuilder<bool>(
    valueListenable: _dimmed,
    builder: (context, stale, _) => KvBreath(
      active: !stale,
      child: KvLamp(stale ? KvLampTone.warn : KvLampTone.ok),
    ),
  );

  VoidCallback? _sendTap() => widget.sendRoute == null
      ? null
      : () => Navigator.of(context).push(
          KvPageRoute<void>(builder: (c) => widget.sendRoute!(c, _dimmed)),
        );

  VoidCallback? _receiveTap() =>
      widget.receiveRoute == null ? null : () => _push(widget.receiveRoute);

  /// **Only a PROVEN zero closes the money door**, and proven means more than
  /// non-null. `discoveryIncomplete` says the balance was computed over a
  /// window that may be SHORT, and `utxoIndexMissing` says the node cannot see
  /// this wallet's coins at all — a zero under either is exactly the
  /// confidently-wrong number those flags exist to mark. Without these terms
  /// the plate said "this may not be your whole balance" and "Nothing to send
  /// yet" in the same frame (`consensus-auditor`, UX-2).
  String? _sendBlocked(_BalanceView b) {
    final mature = b.mature;
    final nothing =
        mature != null &&
        mature == BigInt.zero &&
        !b.utxoIndexMissing &&
        !b.discoveryIncomplete;
    return nothing ? 'Nothing to send yet' : null;
  }

  /// The detail column in `expanded`+ (§3a.2): the transaction, or the one
  /// truth that says why it is empty.
  Widget _detailPane() {
    final txid = _selected;
    final route = widget.detailRoute;
    if (txid == null || route == null) {
      return const Center(
        child: KvEmptyState(
          mark: KvGlyph.history,
          truth: 'Select a transaction.',
          nudge: 'Its detail opens here, beside the ledger.',
        ),
      );
    }
    return route(context, txid, _dimmed);
  }

  /// Opens one row: **the detail column in `expanded`+, a pushed route below
  /// it.** One decision, taken from the window class rather than from two
  /// call sites (BG-33).
  void _open(String txid, KvWindowMetrics metrics) {
    if (metrics.isTwoPane) {
      setState(() => _selected = txid);
      return;
    }
    final route = widget.detailRoute;
    if (route == null) return;
    Navigator.of(
      context,
    ).push(KvPageRoute<void>(builder: (c) => route(c, txid, _dimmed)));
  }

  /// The plate is pinned INSIDE the scroll view rather than sitting above it,
  /// and that is what makes D-194 true: a drag that starts on the balance is a
  /// drag on the scrollable, so the refresh gesture is reachable from the one
  /// place a hand goes first. A plate outside the viewport would emit no
  /// scroll notification and the gesture would die on it.
  /// The pull gesture over a scrollable, or the scrollable alone when there
  /// is nothing to pull for.
  static Widget _refreshable(Future<void> Function()? refresh, Widget child) {
    if (refresh == null) return child;
    return RefreshIndicator(
      onRefresh: refresh,
      // Not teal: a refresh is a mechanism, not the one primary action (BG-2).
      // RefreshIndicator resolves colorScheme.primary by default and no
      // component theme covers it.
      color: KvColor.ink,
      backgroundColor: KvColor.plate,
      strokeWidth: 2,
      child: child,
    );
  }

  /// `All` opens the card; `Less` snaps it back and returns the rows to the
  /// top, so the closed card always shows the newest rows.
  void _toggleLedger() {
    setState(() => _expanded = !_expanded);
    if (!_expanded && _ledgerScroll.hasClients) {
      _ledgerScroll.animateTo(
        0,
        duration: KvMotion.calm,
        curve: KvMotion.curve,
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The header.
// ─────────────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.scope,
    required this.onOpenDrawer,
    this.inset,
  });

  /// "Wallet" — `pageTitle`, 22 / 700 in `ink` (render `S1`, measured: the
  /// title takes the wordmark's size, not §2's 20).
  final String title;

  /// "Main" — which wallet, 16 / 500 in `inkMeta`, one word-space after the
  /// title with **no separator** (render `S1`, D-261; the first build set
  /// `Wallet · Main` at one weight from §2's transcription).
  final String scope;

  /// The horizontal inset. Null takes the class's own gutter; a pane that has
  /// already been inset passes 0.
  final double? inset;

  /// Null ⇒ navigation is already standing (rail or drawer), so the avatar is
  /// dropped rather than shown inert (§3a.2).
  final VoidCallback? onOpenDrawer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // The avatar's own 52 dp target overhangs the gutter by 4 dp on each
      // side, so the glyph inside it lands on the gutter rather than beside
      // it — the same trick the plate's label row uses.
      // 4 above, not 8: the title sits close under the status bar (D-262).
      padding: EdgeInsets.fromLTRB(
        inset ?? (onOpenDrawer == null ? KvSpace.gutter : KvSpace.s20),
        KvSpace.xs,
        inset ?? KvSpace.gutter,
        KvSpace.s,
      ),
      child: Row(
        children: [
          if (onOpenDrawer != null) ...[
            _Avatar(onTap: onOpenDrawer!),
            const SizedBox(width: KvSpace.sm),
          ],
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: title),
                  TextSpan(
                    text: ' $scope',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      fontVariations: KvWeight.w500,
                      letterSpacing: 0,
                      color: KvColor.inkMeta,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              semanticsLabel: '$title, $scope',
              // §2 `pageTitle` as amended (D-261): a drawer-header screen.
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 22,
                height: 26 / 22,
                fontWeight: FontWeight.w700,
                fontVariations: KvWeight.w700,
                letterSpacing: -0.2,
                color: KvColor.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// *Ours* — [KvColor.tealTint] with a [KvColor.primaryMuted] initial at 700
/// (§4). **Never `primary`**: an avatar that emits is BG-2's most common
/// finding, and `primaryMuted` is uncounted (§1.5).
class _Avatar extends StatelessWidget {
  const _Avatar({required this.onTap});

  final VoidCallback onTap;

  /// §4: 44 in a row, and the header is a row.
  static const double size = 44;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open navigation',
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: KvSpace.touchTarget,
            child: Center(
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: KvColor.tealTint,
                  shape: BoxShape.circle,
                ),
                child: const Text(
                  'K',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 17,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    fontVariations: KvWeight.w700,
                    color: KvColor.primaryMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The plate's own control — the network chip, and the live dot (A6).
// ─────────────────────────────────────────────────────────────────────────────

/// The money screen's standing link indicator, and its door to the node
/// surface.
///
/// **The lamp came back on a founder call, 2026-08-27, and A6 is now
/// law-compliant on its own terms.** It was deleted at UX-2 because BG-7, as
/// narrowed at D-200, took link health away from `ok`; Deep V6's BG-7 lists
/// *"link healthy"* among `ok`'s meanings outright, so no amendment was
/// needed to build it — only the new law.
///
/// **Live is `ok` GREEN, pulsing — not teal** (founder correction 2026-09-04,
/// D-259, from the intake render `S1 · Home`). UX-R1 built it as the `primary`
/// live dot on §4's *"`caps` label + live dot"*; the render the design came
/// from shows a green dot, and A6 said `ok` from the start — *"BG-7 now reads
/// `ok` = arriving, accepted, switched on, **link healthy**"*. The teal
/// reading was the transcription, not the design.
///
/// It also gives an emission back: teal is now spent on the ledger's active
/// tab underline alone, which is the ration BG-2 was asking for.
///
/// A dark link is a static amber lamp — motion means something is happening,
/// and nothing is.
class _NetworkChip extends StatelessWidget {
  const _NetworkChip({required this.live, required this.onTap});

  /// Drives the lamp. Never const — one sat green beside an amber "Link lost"
  /// on this very plate once.
  final bool live;

  /// Null ⇒ no node surface is wired, so this is a plain reading rather than a
  /// control. Never a dead button (BG-12).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // `S1` measures 34 tall with a 14 dp word; the founder asked for a little
    // less on glass (D-262): 30 tall, the word at 13 / 500 in `ink`.
    final chip = Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
      decoration: BoxDecoration(
        color: KvColor.chip,
        borderRadius: BorderRadius.circular(KvRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The pulse is the liveness tell; it stills when the link does, the
          // way every other breathing thing in this app does (BG-8/BG-9).
          KvBreath(
            active: live,
            child: KvLamp(live ? KvLampTone.ok : KvLampTone.warn),
          ),
          const SizedBox(width: KvSpace.s),
          const Text(
            'Mainnet',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 18 / 13,
              fontWeight: FontWeight.w500,
              fontVariations: KvWeight.w500,
              color: KvColor.ink,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: KvSpace.s),
            const KvGlyphIcon(KvGlyph.chevron, size: 14, tone: KvColor.inkMeta),
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
          // A 32dp visual inside a 52dp target. It sits beside a 48dp balance
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

/// **The chain clock, under the balance** (A4, founder ruling D-256).
///
/// It came off this screen at UX-R1 on a reading of BG-8 — *nothing animates on
/// a settled screen* — and the founder put it back with the distinction the law
/// was missing: **the counter's animation is not the point, the numbers are.**
/// BG-8 is amended rather than worked around, because BG-18 had always
/// licensed a streaming chain counter and the two laws met on exactly this
/// object.
///
/// **Streamed, not stepped** (D-226). The score is READ on the 1 Hz ticker, so
/// a plain render repaints once a second and jumps about ten at a time.
/// `KvStreamingCount` replays the interval between the last two readings at the
/// panel's refresh rate — every frame is a score the chain actually had, and it
/// never runs past the newest reading. **It stops when the link does**, which
/// is why `stale` is passed in: a clock still ticking on a dead link is a
/// prediction, and the dimming above already says the reading is old.
///
/// `DAA` is a word and takes Jakarta; the score is a figure and takes mono
/// (BG-30). One line, two faces, which is the law rather than a flourish.
class _ChainClock extends StatelessWidget {
  const _ChainClock({required this.daa, required this.dimmed});

  final ValueListenable<BigInt?> daa;
  final ValueListenable<bool> dimmed;

  @override
  Widget build(BuildContext context) {
    // **It stops; it does not dim** (BG-8 as amended, D-257). At 11 dp the 45%
    // multiply takes `inkMeta` to **1.93:1** against BG-14's 4.5 — and no
    // opacity rescues it, because the tone is 4.75 at full strength. The
    // stopping IS the stale signal, which is the clause this same amendment
    // seated; the age and the amber lamp carry the rest.
    return ValueListenableBuilder<bool>(
      valueListenable: dimmed,
      builder: (context, stale, _) => RepaintBoundary(
        child: ValueListenableBuilder<BigInt?>(
          valueListenable: daa,
          builder: (context, score, _) => KvStreamingCount(
            value: score,
            stalled: stale,
            // Render `S1`, measured: `DAA` as a `caps` label in `inkMeta`,
            // a 12 dp gap, the figure in `fact`-weight mono at 16 in
            // `inkDim` — a reading, one step under the balance, not a
            // footnote at 11.
            builder: (context, shown) => Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                const Text(
                  'DAA',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 11,
                    height: 16 / 11,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    letterSpacing: 1.1,
                    color: KvColor.inkMeta,
                  ),
                ),
                const SizedBox(width: KvSpace.sm),
                Text(
                  formatScore(shown),
                  // 14, one down from `S1`'s 16 (founder, on glass, D-262).
                  style: const TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 14,
                    height: 20 / 14,
                    fontWeight: FontWeight.w500,
                    fontVariations: KvWeight.w500,
                    color: KvColor.inkDim,
                    fontFeatures: [FontFeature.tabularFigures()],
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

// ─────────────────────────────────────────────────────────────────────────────
// The ledger — one row container, headed by tabs (§4, §5).
// ─────────────────────────────────────────────────────────────────────────────

/// How many rows the feed can hold — the Rust-side bound, mirrored.
///
/// **Source of truth is `ACTIVITY_CAP` in `rust/chain/src/wallet_sync.rs`**; the
/// list crosses the bridge already truncated, so the glass cannot derive the
/// number and has to carry it. `test/activity_cap_test.dart` reads that Rust
/// constant and fails if the two ever drift — the mirror is pinned, not trusted.
const int kActivityFeedCap = 100;

/// The ledger, in **one row container** (§4, BG-1 as amended: a container that
/// groups rows is now the default and a bare list on the ground is the
/// finding), headed by the Activity · Tokens tabs.
///
/// **The Tokens tab ships as a seat, not a feature.** §5 specifies the whole
/// composition — KAS first, a `KvCheck` on the selected row, selection
/// re-scoping the plate, the ledger, Send and Receive, the title becoming
/// "Wallet · NACHO" — and **no token layer exists in Rust, the bridge or the
/// DTOs** (B1). So the tab renders a `KvComingSoon` in the seat the feature
/// will occupy, which is the founder's own acceptance condition: the shape of
/// what is missing is visible rather than tracked.
///
/// **The ledger card** (render `S1`; founder, on glass 2026-09-04, D-262).
///
/// One plate with the Activity · Tokens tabs **fixed at its head** and the
/// rows scrolling beneath them. Two states, one gesture apart:
///
///  * **closed** — the card ends just above the Receive · Send bar with its
///    own rounded foot; the rows fill it and stop.
///  * **open** — `All`, or the first upward scroll on the rows: the card drops
///    under the bar (the last row scrolls clear of it) and the rows scroll.
///    `Less` snaps it back and returns the rows to the top.
///
/// The same `ListView` serves both — the scroll that opens the card is the
/// scroll that keeps going — so nothing jumps and nothing is rebuilt. The
/// swap animates the card's foot on `calm` (BG-24). The plate above never
/// moves.
class _Ledger extends StatefulWidget {
  const _Ledger({
    required this.records,
    required this.now,
    required this.gutter,
    required this.foot,
    required this.controller,
    required this.maturity,
    this.virtualDaaScore,
    this.stale = false,
    this.selected,
    this.onOpen,
    this.onRefresh,
    this.expanded = false,
    this.onExpand,
  });

  final List<ActivityRecord> records;
  final DateTime now;

  /// The pin's maturity thresholds, forwarded to every row's mark (D-249).
  final KvMaturity maturity;

  /// The screen gutter, or 0 in a pane that is already inset.
  final double gutter;

  /// The foot bar's footprint: the closed card stops that far above the
  /// column's end, and the open card's rows scroll that far clear of it.
  final double foot;

  final ScrollController controller;

  /// BG-8: a stale link must not stream a frozen counter at full presence —
  /// counters fall back to their static words until the link is live again.
  final bool stale;

  /// Live DAA — the streaming counter for both directions is a DAA-distance.
  final BigInt? virtualDaaScore;

  /// The row the detail column is showing, in `expanded`+.
  final String? selected;

  /// Opens one row. Null ⇒ the rows are not controls at all.
  final void Function(String txid)? onOpen;

  /// Pull-to-refresh on the rows. Null ⇒ no pull.
  final Future<void> Function()? onRefresh;

  /// The card is open: it runs under the foot bar and the rows scroll.
  final bool expanded;

  /// Null ⇒ the action is absent (a `short` window is already open).
  final VoidCallback? onExpand;

  /// The least the card is ever given: its head, one row and its 6 dp foot.
  /// Below this the band above yields instead (see `_moneyColumn`).
  static const double minHeight = 62 + KvSpace.row + 6;

  @override
  State<_Ledger> createState() => _LedgerState();
}

class _LedgerState extends State<_Ledger> {
  int _tab = 0;

  /// The two views side by side, so a sideways swipe on the card moves
  /// between Activity and Tokens and the underline follows (founder, on
  /// glass 2026-09-04, D-263). The card's own horizontal drag wins the arena
  /// over the page's drawer swipe — innermost first — so the drawer is
  /// summoned from the plate, the header or the bar, never from the rows.
  late final PageController _pages = PageController();

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _select(int i) {
    setState(() => _tab = i);
    if (_pages.hasClients) {
      _pages.animateToPage(i, duration: KvMotion.calm, curve: KvMotion.curve);
    }
  }

  /// The first upward scroll opens the card (D-262): a user reaching for
  /// more rows gets them, without finding `All` first. Only ever from
  /// closed to open — the way back is `Less`, so a scroll can never snap the
  /// card shut under a thumb.
  bool _onScroll(ScrollNotification n) {
    if (widget.expanded || widget.onExpand == null) return false;
    // The page swipe is a scroll too, and sideways; only the rows' own
    // vertical motion opens the card.
    if (n.metrics.axis != Axis.vertical) return false;
    final dragging = switch (n) {
      ScrollUpdateNotification(:final dragDetails, :final scrollDelta) =>
        dragDetails != null && (scrollDelta ?? 0) > 0,
      OverscrollNotification(:final dragDetails, :final overscroll) =>
        dragDetails != null && overscroll > 0,
      _ => false,
    };
    if (dragging) widget.onExpand!();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        KvRowContainer.padding.left,
        6,
        KvRowContainer.padding.right,
        KvSpace.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: KvTabs(
              tabs: const [KvTab('Activity'), KvTab('Tokens')],
              index: _tab,
              onSelect: _select,
            ),
          ),
          if (widget.onExpand != null)
            _QuietAction(
              label: widget.expanded ? 'Less' : 'All',
              onTap: widget.onExpand!,
            ),
        ],
      ),
    );
    // Page 1 — the tokens seat (§5's composition is a B1 carry; the seat
    // shows the shape of what is missing).
    final Widget tokens = SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KvRowContainer.padding.left,
          0,
          KvRowContainer.padding.right,
          KvSpace.sm,
        ),
        child: const KvComingSoon(
          mark: KvGlyph.assets,
          name: 'Assets',
          sentence: 'Not built yet. Your tokens will live here.',
        ),
      ),
    );
    // Page 0 — the rows, or the one empty state.
    final Widget activity = widget.records.isEmpty
        // A plate that does not fit the card's floor height scrolls inside
        // it rather than overflowing — measured at 320 × 568 / 1.3× the
        // empty state was 26 dp over the room the card had left.
        ? SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                KvRowContainer.padding.left,
                0,
                KvRowContainer.padding.right,
                KvSpace.sm,
              ),
              child: const KvEmptyState(
                mark: KvGlyph.diamond,
                // Shipped copy, verbatim (D-196): the redesign is a change of
                // form, not of voice.
                truth: 'No recent activity',
                nudge: 'Payments you send and receive appear here.',
              ),
            ),
          )
        : NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: _HomeScreenState._refreshable(widget.onRefresh, _rows()),
          );
    final body = PageView(
      controller: _pages,
      physics: const ClampingScrollPhysics(),
      onPageChanged: (i) {
        if (i != _tab) setState(() => _tab = i);
      },
      children: [activity, tokens],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.gutter, 0, widget.gutter, 0),
      // The foot moves on `calm`: closed, a 12 dp gap above the bar and a
      // rounded foot; open, none and none — the card runs under the bar.
      child: AnimatedContainer(
        duration: KvMotion.calm,
        curve: KvMotion.curve,
        margin: EdgeInsets.only(bottom: widget.expanded ? 0 : widget.foot),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: KvColor.plate,
          borderRadius: widget.expanded
              ? const BorderRadius.vertical(
                  top: Radius.circular(KvRadius.plate),
                )
              : BorderRadius.circular(KvRadius.plate),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            // **The ledger dims as a region while the link is not live**
            // (D-276, founder on glass 2026-09-05: the activity did not say
            // *not connected* while the balance above it did). 0.55, not the
            // balance's 0.45 — the opacity at which the rows' small text
            // still clears BG-14 (`KvFreshness.opacityStaleRegion`); the
            // rows raise their quiet tones to `inkDim` under it. Eased, so a
            // link that flaps does not blink the list (BG-24).
            Expanded(
              child: AnimatedOpacity(
                opacity: widget.stale ? KvFreshness.opacityStaleRegion : 1,
                duration: KvMotion.normal,
                curve: KvMotion.out,
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rows() {
    // The list arrives already truncated by Rust, so "full" is the only signal
    // the glass gets that anything was cut (F29).
    final atCap = widget.records.length >= kActivityFeedCap;
    return ListView.builder(
      controller: widget.controller,
      // Always scrollable, so the pull gesture exists even when the rows are
      // few — and so the first upward drag is a notification the card can
      // open on.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        KvRowContainer.padding.left,
        0,
        KvRowContainer.padding.right,
        6 + (widget.expanded ? widget.foot : 0),
      ),
      // +1 for the bound's own caption when the feed is full (F29).
      itemCount: widget.records.length + (atCap ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == widget.records.length) {
          // Only a user the bound actually binds ever reads this. Quiet tier:
          // it states the bound, it does not offer to lift it. Paging is a
          // deliberate non-feature (D-175).
          // **The count is mono, the sentence is not** (BG-30). Two faces,
          // one line, because the reader should know before reading whether a
          // run is to be read or checked.
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: KvSpace.sm),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'Showing the '),
                  TextSpan(
                    text: '$kActivityFeedCap',
                    style: TextStyle(
                      fontFamily: KvFont.mono,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  TextSpan(text: ' most recent.'),
                ],
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 11,
                height: 16 / 11,
                color: KvColor.inkMeta,
              ),
            ),
          );
        }
        final record = widget.records[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The one line inside a container (§1.2) — never above the first.
            if (i > 0)
              const SizedBox(
                height: 1,
                child: ColoredBox(color: KvColor.hairline),
              ),
            _LedgerRow(
              // Txid-keyed so a row keeps its mark's transition state across
              // reconciles (the list is rebuilt on every snapshot).
              key: ValueKey(record.txid),
              record: record,
              now: widget.now,
              stale: widget.stale,
              selected: record.txid == widget.selected,
              maturity: widget.maturity,
              confirmations: KvBurial.depthOf(
                record,
                widget.virtualDaaScore,
                stale: widget.stale,
              ),
              onOpen: widget.onOpen,
            ),
          ],
        );
      },
    );
  }
}

/// One ledger row: direction disc · `rowTitle` · the lifecycle mark ·
/// `amountRow` **in the direction's hue** · `metaMono` time (§4, BG-7).
///
/// **64 dp in every window class** (BG-33, A9) — a tablet shows more rows,
/// never smaller ones. It is a *minimum* rather than a clamp, because BG-14
/// requires the row to survive the user's 1.3× font setting and a clamped row
/// would clip instead of growing.
///
/// The lifecycle mark speaks D-248's ratified vocabulary — `Pending · Accepted
/// · Settled` — against thresholds read from the pin rather than typed
/// anywhere, which is what UX-R3 carried across the FFI (D-249). The row hands
/// the mark its own `direction` and `isCoinbase` because one `MaturityState`
/// means different things on a spend and on a receive, and a mined output
/// matures at a different depth.
class _LedgerRow extends StatelessWidget {
  const _LedgerRow({
    super.key,
    required this.record,
    required this.now,
    required this.stale,
    required this.selected,
    required this.maturity,
    this.confirmations,
    this.onOpen,
  });

  /// The pin's maturity thresholds, which decide this row's rung (D-249).
  final KvMaturity maturity;

  final ActivityRecord record;
  final DateTime now;
  final bool stale;

  /// This row is the one the detail column is showing (`expanded`+).
  final bool selected;

  final int? confirmations;

  /// Null ⇒ this row is a record, not a control.
  final void Function(String txid)? onOpen;

  @override
  Widget build(BuildContext context) {
    // Direction rides FOUR ways at once — word, sign, colour and weight — so
    // the row survives greyscale, colour-blindness and a screen reader (BG-7).
    // `KvAmount` carries the last three; the title carries the word. The
    // switch itself is `kvActivityFace`, shared with the transaction detail
    // that renders the same transaction at full size (BG-21).
    final (:mark, :direction, :title) = kvActivityFace(record);
    final (tint, tone) = switch (direction) {
      KvMoneyDirection.incoming => (KvColor.okTint, KvColor.ok),
      KvMoneyDirection.outgoing => (KvColor.riskTint, KvColor.risk),
      // A self-send is not a value event: neither tint carries it, so it takes
      // the neutral socket (§4).
      KvMoneyDirection.internal => (KvColor.chip, KvColor.inkDim),
    };
    final time = record.unixtimeMsec;
    final open = onOpen;
    // **The row dims with its region, and keeps BG-14 doing it** (D-276,
    // amending D-257). D-257 kept rows bright because a 16 dp hued amount
    // under 0.45 measured 3.03:1 and an `inkMeta` time 1.93; the founder
    // asked for the *not live* effect on the ledger (on glass, 2026-09-05),
    // so the region dims to 0.55 and the row raises what would fall under
    // the floor: the figure to `inkDim` with its sign kept (`muted`), the
    // time to `inkDim`. The record is still the record; the fog says the
    // link, not the past, is uncertain — and the balance's age above it
    // says how long (BG-8).
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          // The selected row in a two-pane window lifts one step, which is the
          // whole of what "selected" needs to be (§1.1) — no tint, no edge.
          color: selected ? KvColor.chip : Colors.transparent,
          borderRadius: BorderRadius.circular(KvRadius.row),
        ),
        child: KvRow(
          leading: KvRowDisc(
            mark: mark,
            tint: tint,
            tone: tone,
            // BG-25: a direction arrow inside a value disc is 2.75 on the
            // 24 dp grid, not the 2.5 every other mark takes.
            stroke: direction == KvMoneyDirection.internal
                ? null
                : KvGlyphSpec.strokeArrow,
          ),
          title: title,
          // **One sub-line: the lifecycle word, a middle dot, the time**
          // (render `S1`: `Final · 2 h ago`, D-261). The time used to sit in
          // `metaMono` under the amount; the render puts it beside the word,
          // which frees the trailing column for the figure alone.
          //
          // **`inkDim` on a selected row.** §1.4's one standing obligation:
          // `inkMeta` is 4.30 on `chip` and may not carry information there.
          // A selection is persistent, not a press, so the row cannot borrow
          // a pressed state's licence.
          //
          // **A `Wrap`, not a `Row`** — the parent `KvBurialMark` was written
          // against (its own comment says so), and L160's scar: in a bare
          // `Row` the mark's self-bound left with the flex parent and the
          // sub-line overflowed by 77 dp at 320 dp / 1.3×; as two `Flexible`s
          // both halves ellipsized (`Seen… · just …`) at the same frame. A
          // `Wrap` lets the time drop to a second line at the floor instead —
          // the row is a minimum, not a clamp (BG-14) — and nothing is cut.
          subWidget: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KvBurialMark(
                stalled: record.stalled,
                confirmations: confirmations,
                maturity: record.maturity,
                direction: record.direction,
                isCoinbase: record.isCoinbase,
                thresholds: maturity,
                fontSize: 13,
              ),
              if (time != null)
                Text.rich(
                  // **Digits in mono, words in Jakarta** (BG-30, and `S1`
                  // sets `Yesterday, 09:14` exactly so) — a ticking age must
                  // not jiggle, and a face is not something a seat change
                  // gets to drop (`ux-auditor`, UX-R1B).
                  _ageSpans(' · ${_relativeAge(now, time)}'),
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 13,
                    height: 18 / 13,
                    color: selected || stale ? KvColor.inkDim : KvColor.inkMeta,
                  ),
                ),
            ],
          ),
          trailing: KvAmount(
            record.valueSompi,
            role: KvAmountRole.row,
            direction: direction,
            muted: stale,
          ),
          semanticLabel: '$title, details',
          onTap: open == null ? null : () => open(record.txid),
        ),
      ),
    );
  }

  /// Every run of digits in [text] set in tabular mono, the rest inherited
  /// (BG-30: speak and count in different faces).
  static TextSpan _ageSpans(String text) {
    final spans = <TextSpan>[];
    for (final m in RegExp(r'\d+|\D+').allMatches(text)) {
      final run = m.group(0)!;
      spans.add(
        RegExp(r'^\d').hasMatch(run)
            ? TextSpan(
                text: run,
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  fontWeight: FontWeight.w500,
                  fontVariations: KvWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              )
            : TextSpan(text: run),
      );
    }
    return TextSpan(children: spans);
  }

  /// "2 m ago" / "just now" — floors, never overstates (BG-8).
  static String _relativeAge(DateTime now, BigInt unixtimeMsec) {
    final at = DateTime.fromMillisecondsSinceEpoch(unixtimeMsec.toInt());
    final age = now.difference(at);
    if (age.inSeconds < 5) return 'just now';
    return '${formatAge(age)} ago';
  }
}

/// **Receive · Send, pinned at the foot** (render `S1`, D-261).
///
/// Two 60 dp pills across the gutter with a 10 dp gap, **Send lit** — the
/// screen's one primary, and it is the money door (BG-2). Each wears its
/// arrow: `↙ Receive`, `↗ Send` — the same two marks the ledger's discs use,
/// beside their words (§2a rule 1 as amended). Receive is raised. A blocked
/// Send says why beneath itself (BG-12, `KvAction`).
///
/// Absent in `short`, where the collapsed bar carries the same two verbs
/// (`R5`) and 60 dp of a 412 dp window is the ledger's.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.gutter,
    required this.onSend,
    required this.onReceive,
    required this.sendDisabledReason,
  });

  final double gutter;
  final VoidCallback? onSend;
  final VoidCallback? onReceive;
  final String? sendDisabledReason;

  /// The render's foot pills: 60, not `control`'s 56 (S1, measured).
  static const double height = 60;

  /// The bar's whole footprint, and it is **constant**: the pills, 12 above,
  /// 16 below. A blocked Send says why inside its pill rather than beneath
  /// it, so the ledger card can stop exactly this far short of the column's
  /// end and never be overrun (D-262).
  static const double footprint = height + KvSpace.sm + KvSpace.m;

  @override
  Widget build(BuildContext context) {
    if (onSend == null && onReceive == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, KvSpace.sm, gutter, KvSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onReceive != null)
            Expanded(
              child: KvAction.raised(
                label: 'Receive',
                mark: KvGlyph.arrowIn,
                height: height,
                onTap: onReceive!,
              ),
            ),
          if (onReceive != null && onSend != null)
            const SizedBox(width: KvSpace.s10),
          if (onSend != null)
            Expanded(
              child: KvAction(
                label: 'Send',
                primary: true,
                mark: KvGlyph.arrowOut,
                height: height,
                disabledReason: sendDisabledReason,
                inlineReason: true,
                onTap: onSend!,
              ),
            ),
        ],
      ),
    );
  }
}

/// A quiet text action with a chevron — `All ›` beside the tabs (render `S1`:
/// 14 / 600 in **`inkDim`**, not the `primary` ghost §4 gave it; the render
/// spends no teal on it, D-261).
class _QuietAction extends StatelessWidget {
  const _QuietAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          // A 52 dp target both ways (BG-12): the word and its chevron are
          // ~44 wide, so the box is held open to the target and the ink sits
          // at its right edge, flush with the rows' figures.
          child: Container(
            height: KvSpace.touchTarget,
            constraints: const BoxConstraints(minWidth: KvSpace.touchTarget),
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 14,
                    height: 20 / 14,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.inkDim,
                  ),
                ),
                const SizedBox(width: 2),
                const KvGlyphIcon(
                  KvGlyph.chevron,
                  size: 16,
                  tone: KvColor.inkDim,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The strip — transient news, beneath the plate (BG-28).
// ─────────────────────────────────────────────────────────────────────────────

/// **Transient status, in a container of its own beneath the plate** (BG-28,
/// founder device sitting 2026-08-31).
///
/// The money plate used to hold these lines, so it grew one the moment a
/// deposit started arriving, lost it again when the money matured, and lost
/// another when `syncing…` cleared a second after every cold open — the
/// balance moved three times for events the user did not cause. **The plate
/// now holds only what is always true**, and everything transient arrives
/// here, easing the ledger down and back.
///
/// Every row reads the way a ledger row reads: a lamp, a label in `caps`, and
/// the value hard right, on one [KvColor.plate] container with the hairline
/// between rows. The lamp carries the hue (§1.6: the dot is coloured, the
/// words are not), so a status panel and a money row use one vocabulary.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.balance,
    required this.trust,
    required this.gutter,
  });

  final ValueListenable<_BalanceView> balance;
  final ValueListenable<_TrustView> trust;
  final double gutter;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_BalanceView>(
      valueListenable: balance,
      builder: (context, b, _) => ValueListenableBuilder<_TrustView>(
        valueListenable: trust,
        builder: (context, t, _) {
          final pending = b.pending;
          final outgoing = b.outgoing;
          final rows = <Widget>[
            // Money ARRIVING that the hero does not yet contain: at the pin
            // `pending` is a set disjoint from `mature`.
            if (pending != null && pending > BigInt.zero)
              _StatusRow(
                tone: KvLampTone.warn,
                label: 'pending',
                trailing: KvAmount(
                  pending,
                  role: KvAmountRole.row,
                  direction: KvMoneyDirection.incoming,
                  // **BG-23.** A qualifier is the likeliest sub-1 amount on the
                  // screen — dust deposits land here — and `row`'s default
                  // emphasis puts the one bright run on `+0`, lighting a
                  // leading zero (the identical defect as [[L147]]).
                  emphasis: KvAmountEmphasis.significant,
                  stale: b.stale,
                  showUnit: true,
                ),
              ),
            // **The in-flight memo carries NO sign, and that is the design.**
            // At the pin the hero is already NET of the send (`mature =
            // (mature_utxos + consumed).saturating_sub(fees + payment)`,
            // `wallet/core/src/utxo/context.rs:506-547 @ cfafeb4`), so a `−`
            // would invite a second subtraction — a partial send of 30 from
            // 100 would read `70.00 KAS` over `− 30.00000000`. It would also
            // be a lie outright on `SignableKind::SelfSendFrame`. So it is a
            // memo, not a term in a sum.
            if (outgoing != null && outgoing > BigInt.zero)
              _StatusRow(
                tone: KvLampTone.warn,
                label: 'in flight',
                trailing: KvAmount(
                  outgoing,
                  role: KvAmountRole.row,
                  direction: KvMoneyDirection.internal,
                  emphasis: KvAmountEmphasis.significant,
                  stale: b.stale,
                  showUnit: true,
                ),
              ),
            // What is wrong with the NUMBER or with the LINK, most
            // consequential first. It is a sentence rather than a label/value
            // pair, so it spans the row and keeps the meter on the right.
            if (t.words case final words?)
              _StatusRow(
                tone: t.tone,
                sentence: words,
                // The meter shares the lamp's hue (§4): one indicator, one
                // colour, and no teal object on this screen that BG-2's list
                // does not name.
                trailing: KvCadence(
                  running: t.running,
                  scale: 0.85,
                  tone: t.tone.color,
                ),
              ),
          ];
          return AnimatedSize(
            duration: KvMotion.fast,
            curve: KvMotion.curve,
            alignment: Alignment.topCenter,
            child: rows.isEmpty
                // Not `shrink()`: a zero-WIDTH child would make the panel
                // animate its width as well as its height on the first row.
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: EdgeInsets.fromLTRB(gutter, 0, gutter, KvSpace.sm),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: KvColor.plate,
                        borderRadius: BorderRadius.circular(KvRadius.plate),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: KvSpace.s20,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < rows.length; i++) ...[
                              if (i > 0)
                                const SizedBox(
                                  height: 1,
                                  child: ColoredBox(color: KvColor.hairline),
                                ),
                              rows[i],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

/// One line of the status panel: lamp, then either a label or a sentence, then
/// the value hard right.
///
/// Merged for a screen reader — unmerged, a bare KAS amount is announced
/// without the word that says what it is doing, and the qualifier arrives only
/// on the next swipe.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.tone,
    this.label,
    this.sentence,
    required this.trailing,
  }) : assert(
         (label == null) != (sentence == null),
         'a row is a labelled value or a sentence, never both',
       );

  final KvLampTone tone;

  /// A short noun set in `caps` (§2).
  final String? label;

  /// A full sentence, which takes the width instead of a caps label.
  final String? sentence;

  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final words = label;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: KvSpace.sm),
        child: Row(
          children: [
            KvLamp(tone),
            const SizedBox(width: KvSpace.s),
            // **The label yields; the figure never does.** A `Spacer` beside
            // an intrinsically-sized caps label overflowed this row by 43 dp
            // at 320 dp / 1.3×, and the thing that would have been cut is an
            // amount — which BG-5 forbids outright. `Expanded` gives the
            // label the remainder and lets it ellipsize instead.
            if (words != null)
              Expanded(
                child: Text(
                  words.toUpperCase(),
                  // Two lines before it gives up: at 320 dp / 1.3x a one-line
                  // cap turned `PENDING` into `PEN…` beside a figure it was
                  // supposed to name. A label wraps (BG-14); the row's own
                  // height is measured, so growing costs nothing.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 11,
                    height: 16 / 11,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    letterSpacing: 1.1,
                    color: KvColor.inkMeta,
                  ),
                ),
              )
            else
              Expanded(
                child: Text(
                  sentence!,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 13,
                    height: 18 / 13,
                    color: KvColor.inkDim,
                  ),
                ),
              ),
            const SizedBox(width: KvSpace.s),
            trailing,
          ],
        ),
      ),
    );
  }
}
