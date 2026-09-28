import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/rate_service.dart' show KvRateQuote;
import '../error_text.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_live_dot.dart';
import '../widgets/kv_cadence.dart';
import '../theme/kv_window.dart';
import '../widgets/kv_fact_line.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_latency.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_sheet.dart';
import '../widgets/kv_two_pane.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_status_chip.dart';
import '../widgets/kv_streaming_count.dart';
import '../widgets/kv_surface.dart';
import '../widgets/status_beacon.dart' show formatAge;
import '../widgets/kv_toggle.dart';

/// `T5`'s pill and field height — the `Test` pill and the `host:port` field
/// both measure 44 dp on the render.
/// **The compact density** (D-278, founder on glass 2026-09-05: *"make
/// everything on that network screen 10% smaller … all of it"*). The pill and
/// the field take 40 where the render measured 44; the pill keeps a 52 dp
/// TARGET around it, because BG-12 does not scale with a density.
const double _pillHeight = 40;

/// **The host and port, as `T5` prints them** (`node.kaspa.org:1…`), not
/// the whole URL. The scheme is a fact the Transport row states one card up
/// (`TLS`, or not), and a resolver URL carries a path the row has no use
/// for — printed whole, `wss://isla.kaspa.red` broke after its scheme at the
/// reference width (seen in the frame). The full URL still stands where it
/// is an identifier a user compares: the *You pinned* reading and the field.
String _hostOf(String endpoint) {
  final uri = Uri.tryParse(endpoint);
  if (uri == null || uri.host.isEmpty) return endpoint;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// Everything [NodeScreen] needs, as listenables and callbacks — the same
/// service-singleton → `ValueNotifier` shape the rest of `lib/src/ui` consumes,
/// so the screen is testable without a native library and there is exactly one
/// writer (`ChainService`) behind every value on it.
class NodeScope {
  const NodeScope({
    required this.connected,
    required this.activeEndpoint,
    required this.virtualDaaScore,
    required this.pinnedNode,
    required this.pinDropped,
    required this.setPinnedNode,
    required this.lastUpdate,
    this.searching,
    this.osOffline,
    this.reconnecting,
    this.onReconnect,
    this.refreshConfig,
    this.tickPulse,
    this.paceAverage,
    this.probeLink,
    this.testNode,
  });

  final ValueListenable<bool> connected;

  /// The endpoint the socket is bound to right now, or null while dark. This
  /// is deliberately **not** the same value as [pinnedNode]: showing what the
  /// user chose beside what the link actually did is how they verify the pin
  /// rather than take our word for it (`NodeConfigDto`).
  final ValueListenable<String?> activeEndpoint;

  final ValueListenable<BigInt?> virtualDaaScore;

  /// The pinned node, or null for public discovery (the default).
  final ValueListenable<String?> pinnedNode;

  /// A stored pin was refused when the wallet loaded it.
  final ValueListenable<bool> pinDropped;

  /// Pin the wallet to one node, or clear the pin with null (D-187).
  ///
  /// **Rust validates, persists and re-links.** Dart never parses a URL and
  /// never decides what a pin means — a second, weaker guard on this side is
  /// precisely the thing INV-9's reasoning forbids. This throws, and the throw
  /// is the message the user must see.
  final Future<void> Function(String? url) setPinnedNode;

  final ValueListenable<bool>? searching;
  final ValueListenable<bool>? osOffline;
  final ValueListenable<bool>? reconnecting;

  /// When the last fresh snapshot landed. BG-8 requires a dimmed reading to
  /// carry a **visible age**: `ChainService` deliberately keeps the last-known
  /// DAA when a dropped link emits nulls, which is only honest if the screen
  /// says the number is old.
  ///
  /// **Required, deliberately.** It was optional for one revision and the sole
  /// production factory took the option, so every disconnect would have
  /// captioned a ninety-second-old score `never updated` — an assertion worse
  /// than the dimming it was meant to explain, and one no widget test could
  /// see because the fixtures all pass it. Required makes the omission a
  /// compile error instead of a caption.
  final ValueListenable<DateTime?> lastUpdate;

  /// The user's own "try now" — since P0b (D-213) a bounded find-then-swap
  /// hunt behind the live bind rather than the drop-then-hunt it was named
  /// for; [_Reconnect] carries which of the three things a tap actually does.
  ///
  /// **It lands here because the money screen's only node door is this
  /// screen.** UX-2 replaced the home beacon with the plate's network chip,
  /// which opens this surface, and UX-3 then collapsed the network sheet into
  /// it — so this is now the single site. Leaving it only on the sheet would
  /// have put the escape hatch three taps from the screen where a dead link is
  /// actually noticed. The watchdog reconnects on its own either way —
  /// this is agency, not the only path.
  final Future<void> Function()? onReconnect;

  /// Re-read the node choice from Rust so the surface can open cold and paint
  /// the truth rather than the last thing the app happened to see.
  final Future<void> Function()? refreshConfig;

  /// **The link's pulse**, polled while this screen is open: seconds since
  /// the last DAA tick (`null` before the first), and the node's virtual DAA
  /// score at that moment — the freshest fold, read before the bridge's 250 ms
  /// coalescer — which the screen differences against its own clock to print
  /// the chain's pace as `BPS` (D-338).
  ///
  /// **The score, not the tick count** (D-338): the pinned node emits one
  /// `VirtualDaaScoreChanged` per virtual resolve and folds whatever blocks
  /// arrived into it, so the tick count read a busy node as a slower chain
  /// (6 where the chain ran at 10). The score climbs by one per block the
  /// virtual merges inside the DAA window — `daa_score = sp_daa_score +
  /// mergeset_size − |mergeset_non_daa|`, the mergeset counting the selected
  /// parent (`consensus/src/processes/difficulty.rs:27-29`,
  /// `model/stores/ghostdag.rs:111` @ `01b532e`, verified at LINK-UX1, INV-9)
  /// — so its climb IS the chain's pace, `BlockrateParams::new::<10>()` on
  /// mainnet. The tick count stays in the logs, where it diagnoses a lagging
  /// node.
  ///
  /// It was `blockAgeSecs` until LINK-Q1 moved the heartbeat off full blocks
  /// (D-334). **Carried across from `NetworkSheet` when UX-3 collapsed the
  /// two surfaces** — dropping it would have made the sovereign path the
  /// poorer one (D-207 clause c).
  final Future<({int? ageSecs, int? score})> Function()? tickPulse;

  /// **The chain's average pace over up to the last hour**, and the span it
  /// covers (D-342) — `ChainService.paceLog`, kept from the score the app
  /// already receives. Null ⇒ not yet two minutes of it (or the seam is not
  /// wired), and the `BPS` row's right side reads `—` (BG-5).
  final ({double bps, Duration span})? Function()? paceAverage;

  /// **One honest round trip, the node's own word on its sync, and — when
  /// asked — its peer count**, polled while this screen is open (`T5`'s
  /// connection card).
  ///
  /// Three outcomes (D-333): an answer (`latencyMs`), a round trip that
  /// outlasted the probe's own adaptive deadline (`timedOutMs` — "at least
  /// this", a slow live link, never drawn as no link), or neither — a refused
  /// probe, which the screen counts toward its dwell before going dark.
  ///
  /// A pull rather than a stream, and on the screen's own cadence, for the
  /// same reason [tickPulse] is: it costs a real round trip, and the money
  /// screen's link tick must not start paying for a card it never draws. The
  /// caller says whether it wants the peer count this time — that number
  /// changes over minutes where a latency changes over seconds, so it is asked
  /// for one tick in [NodeScreen.peersEvery].
  ///
  /// Null ⇒ the seam is not wired, and the card renders the readings as absent
  /// rather than as zeros (BG-8). A widget test gets exactly that.
  final Future<({int? latencyMs, int? timedOutMs, int? peers, bool? synced})>
  Function({required bool peers})?
  probeLink;

  /// **`T5`'s `Test`** — dial a node the user typed, on an ephemeral client,
  /// and say what it is before anything is pinned. Rust runs the connect
  /// race's own probe and **throws the refusal** the user must read: wrong
  /// network, not synced, no UTXO index, a newer RPC major, or unreachable.
  /// A node that passes is not bound by passing; `Use this node` is still the
  /// commit.
  ///
  /// Null ⇒ the seam is not wired and the pill is absent rather than dead
  /// (BG-12).
  final Future<({int latencyMs, String serverVersion, BigInt daa})> Function(
    String url,
  )?
  testNode;
}

/// Where a transaction or an address opens when a link leads out of the
/// wallet — **a template, never a vendor list** (D-207, amending D-192's
/// closed two-vendor choice: a list only we can edit is not a sovereignty
/// decision either).
class ExplorerScope {
  const ExplorerScope({required this.read, required this.write});

  /// `(txTemplate, addressTemplate, defaults)`. The defaults are one-tap
  /// starting points, not the only options.
  final Future<ExplorerChoice> Function() read;

  /// Persist both templates. **Rust validates** — Dart builds and parses no
  /// URL — so this throws with the refusal the user must read.
  final Future<void> Function(String txTemplate, String addressTemplate) write;
}

/// The explorer choice as the surface needs it.
@immutable
class ExplorerChoice {
  const ExplorerChoice({
    required this.txTemplate,
    required this.addressTemplate,
    required this.defaults,
  });

  final String txTemplate;
  final String addressTemplate;
  final List<ExplorerOption> defaults;
}

/// One shipped explorer, offered and replaceable.
@immutable
class ExplorerOption {
  const ExplorerOption({
    required this.name,
    required this.txTemplate,
    required this.addressTemplate,
  });

  final String name;
  final String txTemplate;
  final String addressTemplate;
}

/// The fiat rate — the one claim in this app consensus cannot re-verify, and
/// therefore the one with a switch on it (INV-8's carve-out, D-191).
class RateScope {
  const RateScope({
    required this.enabled,
    required this.endpoint,
    required this.defaultEndpoint,
    required this.quote,
    required this.error,
    required this.setConfig,
    required this.load,
  });

  /// `null` until the stored posture has been read.
  final ValueListenable<bool?> enabled;
  final ValueListenable<String> endpoint;
  final ValueListenable<String> defaultEndpoint;

  /// The live price, or null — which is what `—` means on the money plate.
  final ValueListenable<KvRateQuote?> quote;

  /// Why the last fetch produced nothing. Shown here, where the source is
  /// chosen, and never on the money plate (D-193).
  final ValueListenable<String?> error;

  /// Throws the bridge's refusal — an endpoint is validated in Rust.
  final Future<void> Function({required bool enabled, required String endpoint})
  setConfig;

  /// Re-read the stored posture so this surface opens cold on the truth.
  final Future<void> Function() load;
}

/// **Node & connection** — the INV-8 escape hatch, made reachable.
///
/// The sovereign-node line (D-187) shipped the Rust validation, the bridge and
/// the service seam gate-green with no way for a user to get to any of it. This
/// is that way. A sovereignty statement wearing a diagnostic's precision: who
/// serves you, how freshly, and the standing offer to serve yourself.
class NodeScreen extends StatefulWidget {
  const NodeScreen({
    super.key,
    required this.scope,
    this.explorer,
    this.rate,
    this.clock = DateTime.now,
  });

  final NodeScope scope;

  /// The explorer choice. Absent ⇒ the section does not render, rather than
  /// rendering dead: a control wired to nothing is a drawing of a feature
  /// wearing a real screen (D-206).
  final ExplorerScope? explorer;

  /// The fiat rate's source. Absent ⇒ the section does not render.
  final RateScope? rate;

  /// Injectable so a test can render a fixed age rather than race the wall
  /// clock — the same seam `HomeScreen` takes.
  final DateTime Function() clock;

  /// **The poll's cadence: twice a second** (D-332 — it was the retired
  /// sheet's 2 s). A number can only be as live as its measurement, so the
  /// latency's liveliness comes from measuring more, never from animating a
  /// stale value; the figure is the median of the last three answers, a 1.5 s
  /// window. Still gated to the screen being open and in the foreground.
  /// The probe is one small round trip on the bound socket — H1's cleared
  /// suspect (D-331) — and the pulse pull takes no I/O at all.
  static const Duration pollEvery = KvLatencyReading.cadence;

  /// How many polls apart the peer count is asked for: every ten seconds,
  /// as before the faster cadence — a node's peers change over minutes.
  static const int peersEvery = 20;

  /// Forget the latency reading carried between openings — for tests, which
  /// must not leak one test's reading into the next one's first frame.
  @visibleForTesting
  static void forgetLatency() => _latencyMemory = null;

  /// Carry a reading into the next opening, as a previous visit would have —
  /// for the preview catalogue's frame of that face (L205).
  @visibleForTesting
  static void carryLatency({
    required KvLatencyReading reading,
    required DateTime at,
    required String endpoint,
  }) => _latencyMemory = (reading: reading, at: at, endpoint: endpoint);

  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

/// **The last latency reading, held past the screen's life** (D-333's
/// stale-while-revalidate). A user who opens the Network screen sees the
/// link's last known distance at once, dimmed with its age, and watches it
/// count to the first fresh answer — not a dash for as long as a first probe
/// takes on a slow link. Keyed to the endpoint it was measured on: another
/// node's distance is no reading of this one. Process memory only — nothing
/// is persisted, and the value is a public round-trip time (INV-3).
({KvLatencyReading reading, DateTime at, String endpoint})? _latencyMemory;

class _NodeScreenState extends State<NodeScreen> {
  final TextEditingController _url = TextEditingController();

  /// **The two explainers' open state** — the founder's circled-i beside a
  /// section's caps label (2026-09-05): tapping it eases the section's
  /// explainer in beneath its card and pushes what follows down; tapping again,
  /// leaving the screen, or a route arriving over it closes it.
  final ValueNotifier<bool> _nodeInfo = ValueNotifier(false);
  final ValueNotifier<bool> _sourcesInfo = ValueNotifier(false);

  /// **The reading's own explainer** (LINK-UX1): what *node reply* and *path*
  /// are, what their gap means, what the bars read — behind the circled-i on
  /// the connection card's caption, eased in beneath the card (BG-34).
  final ValueNotifier<bool> _replyInfo = ValueNotifier(false);

  /// What the last attempt to pin or unpin said, in plain English. Null while
  /// nothing has gone wrong.
  String? _problem;
  bool _busy = false;

  /// The stored explorer choice, once read — the SOURCES row prints its host
  /// and the sheet opens on it. Null until the first read lands.
  final ValueNotifier<ExplorerChoice?> _explorerChoice = ValueNotifier(null);

  /// The user has asked for a pinned node, whether or not one is live yet.
  bool _wantPin = false;

  /// What the field was seeded with. While the text still equals this, the
  /// user has not typed and a fresher pin from Rust may replace it; the moment
  /// they have, their draft wins.
  String _seeded = '';

  /// **The screen's live readings, each its own notifier**, so the rows that
  /// render them are the only things that rebuild when they land. The first
  /// cut delivered every probe result through a whole-screen `setState` —
  /// **205 elements every two seconds, four `TextField`s among them**,
  /// measured with `debugOnRebuildDirtyWidget` (UX-R3, second beat).
  ///
  /// The link's pulse: whether a poll has ever landed — "0 s since the last
  /// tick" and "we have never been told" are different sentences (the retired
  /// sheet's own `_haveStatus` distinction) — the tick age, and the chain's
  /// pace in blocks a second once two polls have landed (D-338).
  final ValueNotifier<({bool have, int? secs, double? bps})> _scan =
      ValueNotifier((have: false, secs: null, bps: null));

  /// The chain's pace, from the node's DAA score and this screen's clock.
  final KvBlockRate _rate = KvBlockRate();

  /// The chain's average pace, read from [NodeScope.paceAverage] each poll.
  final ValueNotifier<({double bps, Duration span})?> _average = ValueNotifier(
    null,
  );

  /// `T5`'s latency — smoothed and tiered by [KvLatencyReading] — the node's
  /// own word on whether it is synced, and its peer count. Each is *no
  /// reading* until a probe actually answers: never a zero, and never a number
  /// beside a dead socket (BG-8).
  final ValueNotifier<KvLatencyReading> _latency = ValueNotifier(
    const KvLatencyReading.none(),
  );
  final ValueNotifier<bool?> _synced = ValueNotifier(null);
  final ValueNotifier<int?> _peers = ValueNotifier(null);

  /// When the reading on the seat was taken, while it is the one carried over
  /// from before this screen opened (stale-while-revalidate, D-333); null once
  /// a fresh probe has answered. The seat dims and says this age until then.
  final ValueNotifier<DateTime?> _latencyTakenAt = ValueNotifier(null);

  /// Refused probes in a row. Only these count toward going dark — a timeout
  /// is a reading ("at least"), and one miss never blanks a live link (D-333).
  int _refusals = 0;

  /// **The dwell ran out** (three refusals): the seat reads `—`, not
  /// *measuring…* — the link is up, and the node will not answer.
  final ValueNotifier<bool> _dark = ValueNotifier(false);

  /// When the probe now in flight was sent, on [NodeScreen.clock] — the live
  /// count's origin (LINK-UX1: `> 1.8 s` counts up while the probe is out,
  /// because the elapsed time is itself a measurement). Null with none out.
  final ValueNotifier<DateTime?> _probeOutSince = ValueNotifier(null);

  /// **Three refused probes in a row before the seat goes dark** (D-333) — at
  /// two probes a second, a second and a half of a link that will not answer
  /// at all. A socket that actually drops clears the seat at once, as before.
  static const int refusalsBeforeDark = 3;

  /// **The last `Test`, as one value**: in flight, what answered, or why it
  /// was refused. Its own notifier, so a result lands on the field's own
  /// section and nowhere else.
  final ValueNotifier<({bool busy, _NodeAnswer? answer, String? problem})>
  _test = ValueNotifier((busy: false, answer: null, problem: null));

  /// The clock the ages on this screen are read against, bumped on every poll
  /// tick — so a dimmed reading's *as of N s ago* keeps counting while the
  /// link is down and nothing else on the screen is changing.
  late final ValueNotifier<DateTime> _now = ValueNotifier(widget.clock());

  /// **Polling runs only while the screen can be seen.** The first cut's
  /// `Timer.periodic` kept two real RPC calls going every two seconds with the
  /// app in the background and with another route covering this one — the
  /// node surface is a diagnostic a user opens for a minute, not a service.
  /// Two gates, both the framework's own: the app's lifecycle
  /// ([AppLifecycleListener]) and the route's visibility — the `Navigator`'s
  /// overlay disables [TickerMode] for every route under an opaque one, and
  /// that notifier is exactly *"can this subtree be seen"*.
  Timer? _poll;
  int _ticks = 0;
  bool _foreground = true;
  ValueListenable<TickerModeData>? _visible;
  late final AppLifecycleListener _lifecycle;

  /// **One probe in flight at a time** (`consensus-auditor`, UX-R3).
  ///
  /// Without it a stalled node would stack probes, and two overlapping ones
  /// could land out of order — an older slow reading overwriting a newer fast
  /// one through last-writer-wins, which is exactly the confidently-wrong-
  /// number the probe exists to prevent (BG-8). Rust carries the socket's own
  /// adaptive deadline (1–5 s, D-333), so a slow answer occupies poll ticks
  /// instead of stacking calls.
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _seeded = widget.scope.pinnedNode.value ?? '';
    _url.text = _seeded;
    _wantPin = widget.scope.pinnedNode.value != null;
    // **Stale-while-revalidate** (D-333): the last reading measured on THIS
    // endpoint shows at once, dimmed with its age, until the first fresh
    // answer lands and the figure counts to it.
    final carried = _latencyMemory;
    if (carried != null &&
        widget.scope.connected.value &&
        carried.endpoint == widget.scope.activeEndpoint.value) {
      _latency.value = carried.reading;
      _latencyTakenAt.value = carried.at;
    }
    widget.scope.connected.addListener(_onLink);
    _endpoint = widget.scope.activeEndpoint.value;
    widget.scope.activeEndpoint.addListener(_onEndpoint);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _loadExplorer();
    _loadRate();
    // Open cold and paint the truth (BG-8): the notifiers may be carrying
    // whatever the last poll saw, and a node surface that shows a stale pin is
    // the one lie this whole feature exists to prevent.
    widget.scope.refreshConfig?.call().then((_) {
      if (!mounted) return;
      final live = widget.scope.pinnedNode.value;
      // Only while the field is untouched. Adopting on `isEmpty` alone left a
      // stale pin standing in the box beside the fresh one in the reading —
      // with Apply lit, offering to re-pin the address that had just changed.
      if (_url.text == _seeded && (live ?? '') != _seeded) {
        setState(() {
          _seeded = live ?? '';
          _url.text = _seeded;
          _wantPin = live != null;
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.getValuesNotifier(context);
    if (!identical(visible, _visible)) {
      _visible?.removeListener(_gate);
      _visible = visible..addListener(_gate);
      _gate();
    }
  }

  @override
  void dispose() {
    widget.scope.connected.removeListener(_onLink);
    widget.scope.activeEndpoint.removeListener(_onEndpoint);
    _lifecycle.dispose();
    _visible?.removeListener(_gate);
    _poll?.cancel();
    _latencyTakenAt.dispose();
    _scan.dispose();
    _average.dispose();
    _test.dispose();
    _explorerChoice.dispose();
    _nodeInfo.dispose();
    _sourcesInfo.dispose();
    _replyInfo.dispose();
    _dark.dispose();
    _probeOutSince.dispose();
    _latency.dispose();
    _synced.dispose();
    _peers.dispose();
    _now.dispose();
    _url.dispose();
    super.dispose();
  }

  /// **A socket that drops takes its readings with it** — the dwell's first
  /// clause (D-333), and the house rule behind the old wipe: no confident
  /// number beside a dead socket (BG-8). A reading measured on the socket that
  /// died says nothing about the next one, so the window starts empty there.
  ///
  /// **Every reading of the node, not only its distance** (`ux-auditor`): the
  /// peer count and the node's word on its sync belong to the node that gave
  /// them. Kept across a drop, the old node's `14` stood beside the next node
  /// for up to ten seconds, and — since a timeout no longer clears the sync
  /// word — its `syncing` could stand there as long as the new node's probes
  /// timed out. A silence swap lands on a different node by design.
  void _onLink() {
    if (widget.scope.connected.value) return;
    _forgetNode();
  }

  /// **A different node is a different set of readings** — the same clear,
  /// for the swap the drop does not show: the bridge coalesces its stream,
  /// so a fast cut-over can arrive as one connected snapshot naming a new
  /// endpoint, and the window would carry the last node's samples into the
  /// memory kept under the new one.
  void _onEndpoint() {
    final endpoint = widget.scope.activeEndpoint.value;
    if (endpoint == _endpoint) return;
    final had = _endpoint != null;
    _endpoint = endpoint;
    if (had) _forgetNode();
  }

  /// The endpoint the readings on this screen were measured on.
  String? _endpoint;

  /// Bumped every time the node's readings are forgotten. A probe in flight
  /// across a forget belongs to the node that was forgotten, and is dropped
  /// when it lands — by construction, not by the bridge coalescer's timing
  /// happening to deliver the endpoint change first (`ux-auditor` N1).
  int _nodeEpoch = 0;

  /// The next probe asks for the peers, so an empty count is filled at the
  /// next answer rather than dashed for up to ten seconds (`ux-auditor` N2):
  /// owed from the start (a first probe that times out carries none), after
  /// a forget, and after the dwell goes dark (N8). Spent only by an answer.
  bool _peersDue = true;

  void _forgetNode() {
    _nodeEpoch++;
    _peersDue = true;
    _latency.value = const KvLatencyReading.none();
    _latencyTakenAt.value = null;
    _synced.value = null;
    _peers.value = null;
    _refusals = 0;
    _dark.value = false;
    _probeOutSince.value = null;
    // **Another node's score is another count** (D-338): nodes differ by a
    // few blocks at any moment, so a rate across a swap would print the
    // difference as a burst the chain never had.
    _rate.reset();
  }

  void _onLifecycle(AppLifecycleState state) {
    // `inactive` is a system dialog over a visible screen; the readings are
    // still being looked at. `hidden`, `paused` and `detached` are not.
    final foreground = switch (state) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      _ => false,
    };
    if (foreground == _foreground) return;
    _foreground = foreground;
    _gate();
  }

  void _gate() {
    if (_foreground && (_visible?.value.enabled ?? true)) {
      _start();
    } else {
      _stop();
      _closeExplainers();
    }
  }

  /// An explainer closes when the screen is left, covered, or opens a sheet
  /// of its own (founder, 2026-09-05) — a sheet's route is translucent, so the
  /// ticker gate alone would never see it.
  void _closeExplainers() {
    _nodeInfo.value = false;
    _sourcesInfo.value = false;
    _replyInfo.value = false;
  }

  /// Absent seams ⇒ no poll and no line, never a fabricated reading. A start
  /// ticks at once — a returning user is looking at the glass NOW — and the
  /// first tick asks for everything, peers included.
  void _start() {
    if (_poll != null) return;
    if (widget.scope.tickPulse == null && widget.scope.probeLink == null) {
      return;
    }
    // A rate across a stretch the screen was not watching would average the
    // pause in: every start begins the beat afresh.
    _rate.reset();
    _tick(first: true);
    _poll = Timer.periodic(NodeScreen.pollEvery, (_) => _tick());
  }

  void _stop() {
    _poll?.cancel();
    _poll = null;
  }

  void _tick({bool first = false}) {
    _ticks++;
    _now.value = widget.clock();
    unawaited(_refreshPulse());
    unawaited(
      _refreshProbe(
        peers: first || _peersDue || _ticks % NodeScreen.peersEvery == 0,
      ),
    );
  }

  /// **The link probe, on the screen's own cadence** — three outcomes, and
  /// only one of them can darken the seat (D-333).
  ///
  /// * **An answer** is a sample.
  /// * **A timeout** is a sample too — a *lower bound*: the round trip took at
  ///   least the socket's own adaptive deadline. The seat shows `> N s` on one
  ///   bar. The old seat blanked here, and on the founder's Starlink hop a
  ///   slow, live link blinked dark and relit five times while he wrote one
  ///   message.
  /// * **A refusal** (no socket, an error, a thrown seam) is not a sample.
  ///   Three in a row and the seat goes dark; fewer, and the reading stands.
  ///
  /// A socket that actually drops still clears everything at once ([_onLink])
  /// — the P0.3 scar's rule is untouched: never a confident number beside a
  /// dead socket. What changed is that a slow round trip on a LIVE socket is
  /// no longer mistaken for one.
  Future<void> _refreshProbe({required bool peers}) async {
    final probe = widget.scope.probeLink;
    if (probe == null || _probing) return;
    _probing = true;
    final epoch = _nodeEpoch;
    _probeOutSince.value = widget.clock();
    try {
      // ONE epoch check for the answer and the refusal alike: a probe that
      // crossed a forget belongs to the node that was forgotten, whichever
      // way it ends (`ux-auditor` N1, and N6 — two checks left the refusal's
      // untested).
      ({int? latencyMs, int? timedOutMs, int? peers, bool? synced})? reading;
      try {
        reading = await probe(peers: peers);
      } catch (_) {
        reading = null;
      }
      if (!mounted || epoch != _nodeEpoch) return;
      if (reading == null) {
        _refused();
        return;
      }
      final sample = switch ((reading.latencyMs, reading.timedOutMs)) {
        (final int ms, _) => KvLatencySample.answered(ms),
        (null, final int deadline) => KvLatencySample.atLeast(deadline),
        (null, null) => null,
      };
      if (sample == null) {
        _refused();
      } else {
        _fresh(sample);
        // Only an answer says anything about the node's sync; a timeout is
        // silence on that question, so the last word stands.
        if (reading.latencyMs != null) _synced.value = reading.synced;
      }
      // Not asked for this tick ⇒ the last answer stands; asked and absent ⇒
      // the dash. The seam's `null` means both, and only this side knows which.
      // **Only an answered probe speaks for the peers** (`ux-auditor`, L144's
      // whole class): a timed-out or refused one carries none, and one miss
      // must not blank a count for the ten seconds to the next ask — the
      // dwell, not a single miss, is what goes dark ([_refused]).
      if (peers && reading.latencyMs != null) {
        _peers.value = reading.peers;
        _peersDue = false;
      }
    } finally {
      _probing = false;
      if (mounted) _probeOutSince.value = null;
    }
  }

  /// A fresh outcome: into the window, the carried reading is retired, and
  /// the memory the next opening shows first is updated.
  ///
  /// **The carried reading is where the count starts, never a sample**
  /// (`ux-auditor`): offered into the carried window, a first fresh 300 ms
  /// answer beside a remembered `[40, 42, 45]` took the median to 45 and lifted
  /// the dim, so an old figure stood at full brightness as fresh — and a first
  /// probe that timed out left it standing until the next deadline. The window
  /// starts empty at the first fresh outcome ([KvLatencyReading.resumed]); the
  /// figure still glides from the carried number, because that is the number
  /// on the glass, and the carried minute stays drawn in the history, where
  /// time places it honestly.
  void _fresh(KvLatencySample sample) {
    _refusals = 0;
    _dark.value = false;
    final base = _latencyTakenAt.value == null
        ? _latency.value
        : _latency.value.resumed();
    _latency.value = base.offer(sample, at: widget.clock());
    _latencyTakenAt.value = null;
    final endpoint = widget.scope.activeEndpoint.value;
    if (endpoint != null) {
      _latencyMemory = (
        reading: _latency.value,
        at: widget.clock(),
        endpoint: endpoint,
      );
    }
  }

  /// A refused probe: counted, and only the third in a row goes dark.
  void _refused() {
    _refusals++;
    if (_refusals < refusalsBeforeDark) return;
    _dark.value = true;
    _latency.value = const KvLatencyReading.none();
    _latencyTakenAt.value = null;
    _synced.value = null;
    _peers.value = null;
    _peersDue = true;
  }

  Future<void> _refreshPulse() async {
    final read = widget.scope.tickPulse;
    if (read == null) return;
    try {
      final pulse = await read();
      if (!mounted) return;
      final score = pulse.score;
      final bps = score == null ? null : _rate.offer(widget.clock(), score);
      _scan.value = (have: true, secs: pulse.ageSecs, bps: bps);
      _average.value = widget.scope.paceAverage?.call();
    } catch (_) {
      // A failed pull leaves the last-known pulse standing; never crash the
      // screen a user opened to diagnose a link.
    }
  }

  /// **Test the typed node** — see [NodeScope.testNode]. The answer is one
  /// sentence a user can act on: how fast it answered, that it is synced and
  /// indexed (the probe refuses a node that is not), what it runs, and where
  /// its chain is. A refusal is Rust's own reason, in amber.
  Future<void> _runTest() async {
    final test = widget.scope.testNode;
    if (test == null || _test.value.busy) return;
    final typed = _url.text.trim();
    // Nothing typed: nothing to dial. The reason is already on the glass, in
    // words, under `Use this node` — a second copy of it here would be the
    // same sentence twice on one surface (BG-19).
    if (typed.isEmpty) return;
    _test.value = (busy: true, answer: null, problem: null);
    try {
      final answer = await test(typed);
      if (!mounted) return;
      _test.value = (
        busy: false,
        answer: (
          latencyMs: answer.latencyMs,
          version: answer.serverVersion,
          daa: answer.daa,
        ),
        problem: null,
      );
    } catch (e) {
      if (!mounted) return;
      _test.value = (busy: false, answer: null, problem: displayError(e));
    }
  }

  /// Errors from the seam are **not** all the same failure, and telling the
  /// user the wrong one is worse than saying nothing.
  ///
  /// `dagSetNodeConfig` persists and applies a validated URL *before* the first
  /// dial, so a throw means either *rejected at validation* (nothing changed)
  /// or *accepted, and the first dial failed* (the pin is live and its retry
  /// loop is running). The service refreshes the config on both arms, so after
  /// the throw the notifier itself distinguishes them — which is why this reads
  /// [NodeScope.pinnedNode] rather than guessing from the message.
  Future<void> _apply(String? url) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.scope.setPinnedNode(url);
      if (!mounted) return;
      setState(() => _problem = null);
    } catch (e) {
      if (!mounted) return;
      final live = widget.scope.pinnedNode.value;
      setState(() {
        // Three beats, every time: what happened → what it means for your
        // funds → what to do (BG-11).
        if (url == null) {
          // Clearing has the same two outcomes as pinning, for the same
          // reason: `save` writes the cleared config BEFORE the monitor is
          // reached, so a throw can arrive with the pin already gone. Resolve
          // it the same way — by reading what is live, never by trusting
          // which call threw.
          _url.text = live ?? '';
          _problem = live == null
              ? 'The pin is cleared, but the wallet has not moved off that '
                    'node yet. Your money is safe — nothing was sent. It '
                    'changes over on the next reconnect: $e'
              : 'The pin could not be cleared, so you are still on the node '
                    'below. Your money is safe — nothing was sent. Try '
                    'again: $e';
        } else if (live == url) {
          // The seam persists and applies a validated URL BEFORE its first
          // dial, so this branch means the pin is LIVE and its retry loop is
          // running. Saying "not accepted" here would be the opposite of true.
          _problem =
              'Pinned, but the wallet has not reached it yet. Your money is '
              'safe — nothing was sent. It keeps trying: $e';
        } else {
          _problem = 'That node was not accepted, so nothing changed. $e';
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// How old the last snapshot is, in the shipped `formatAge` wording. Falls
  /// back to naming the absence rather than inventing a duration.
  String _ageLabel() {
    final last = widget.scope.lastUpdate.value;
    if (last == null) return 'never updated';
    return 'as of ${formatAge(_now.value.difference(last))} ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              // **`Network`** (`T5`) — the drawer's own word for this
              // destination, and the one the founder reads on the row that
              // opens it. `Node & connection` named two things where the
              // screen is one place (BG-21).
              title: 'Network',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              // **BG-33's enforceable half for a one-column screen** (`KvColumn`):
              // `min(available, 560)` with the class's own gutter. Without it a
              // 1180 dp window drew one 1,148 dp column of settings rows — the
              // *wider column* BG-33 forbids, rather than columns with jobs.
              // The gutter comes from the window class, so `compact` keeps
              // D-261's 16 and the wider classes take 32 · 40 · 48.
              child: KvColumn(
                gutter: false,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    KvWindow.of(context).gutter,
                    KvSpace.xs,
                    KvWindow.of(context).gutter,
                    // **20, not 24.** The own-node card's bare toggle gained a
                    // row's vertical air (his glass finding, 2026-09-06: a
                    // card's top sat too close to its text), which cost this
                    // screen 16 dp and left the one-view guard 2 dp short.
                    // Spent on the list's own bottom edge — structure first,
                    // and the cheapest 4 dp on the screen (playbook §19.4).
                    KvSpace.s20,
                  ),
                  children: [
                    // **`T5`, in the render's order and at the render's
                    // density** (founder on glass, 2026-09-05): the connection
                    // card, the node row, the own-node card with its field,
                    // then SOURCES as one card of two rows that open sheets.
                    // **Compact** (founder on glass, 2026-09-05, twice): the
                    // whole screen sits in one view on the reference phone —
                    // every section break is the header row's own air, and
                    // nothing else is added between the cards.
                    _connectionPlate(),
                    // **What the reading means, behind its own mark**
                    // (LINK-UX1, BG-34): explanation only — the figure, the
                    // path and the bars are all on the card itself.
                    // **Concise, natural, exact** (the founder on glass,
                    // 2026-09-28: the first cut was "too long"): one fact a
                    // sentence, the numbers mono (§7.1), every claim the
                    // instrument makes and nothing it does not.
                    _Explainer(
                      open: _replyInfo,
                      figures: true,
                      text:
                          'Node reply is how long this node takes to answer, '
                          'smoothed. Path, its best answer in the last 10 s, '
                          'is mostly distance. The gap between '
                          'them is queueing. Bars grade the last 10 s. The '
                          'chart shows the last minute. In it, red marks a '
                          'wait with no answer.',
                    ),
                    // **`NODE`, with its circled-i** (founder on glass,
                    // 2026-09-05): the caps label sits at the card's upper
                    // left like `MY OWN NODE`, and the explainer — what a node
                    // can see and cannot forge (BG-17), and who chose it
                    // (D-207) — eases in beneath the card on a tap.
                    KvSectionHeader('Node', info: _nodeInfo),
                    _servingPlate(),
                    _Explainer(
                      open: _nodeInfo,
                      text:
                          'A node hands you blocks and takes your signed '
                          'transactions. It can go quiet or fall behind, and it '
                          'sees the addresses you ask about — it cannot forge a '
                          'balance, change an amount, or spend anything. Public '
                          'nodes are found for you by the public node directory; '
                          'pin your own and nothing else is used.',
                    ),
                    const KvSectionHeader('My own node'),
                    _picker(),
                    ..._sources(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// **`T5`'s node row** — the render's one row, rebuilt as drawn at the
  /// second beat: a tone disc, *Connected to* over the endpoint, and the
  /// `Switch node` pill at the row's right. The first cut stacked five things
  /// here (disc, heading, a lamp chip, two readings and a full-width glow
  /// pill); the render is the founder's approved picture and it is one row.
  ///
  /// **The words stay.** D-207 names the public node directory where it acts
  /// and D-187 makes a pinned node's silence as nameable as a dropped pin;
  /// both sentences are here, one line under the row in `inkMeta`, rather
  /// than in a lamp chip of their own — the disc already carries the tone, so
  /// the chip's lamp was the same fact a second time.
  Widget _servingPlate() {
    final s = widget.scope;
    return AnimatedBuilder(
      // **Not the DAA.** The first cut merged `virtualDaaScore` into this
      // plate's listenable and never rendered it — every score tick rebuilt a
      // cadence, a chip and a glow pill for nothing (measured: 84 elements per
      // tick on this screen, most of them here).
      animation: Listenable.merge([
        s.connected,
        s.activeEndpoint,
        s.pinnedNode,
        s.pinDropped,
        if (s.searching != null) s.searching!,
        if (s.osOffline != null) s.osOffline!,
        if (s.reconnecting != null) s.reconnecting!,
        _synced,
        _scan,
      ]),
      builder: (context, _) {
        final connected = s.connected.value;
        final offline = s.osOffline?.value ?? false;
        final hunting =
            (s.searching?.value ?? false) || (s.reconnecting?.value ?? false);
        final endpoint = s.activeEndpoint.value;
        final pinned = s.pinnedNode.value;
        final synced = _synced.value;

        // Hunting outranks connected, and the order is the point: the socket
        // can be alive in the snapshot while a race bounces it underneath
        // (`ChainService._linkTick`). Reading `connected` first would print
        // "Connected" beside a disc that is visibly searching — the words and
        // the cadence disagreeing about one link, which is the exact split C7
        // forbids and the P0.3 scar cost.
        //
        // Connected AND hunting is no longer that contradiction, though: since
        // P0b it is the swap hunt, where the link genuinely IS working while a
        // bounded errand looks for a different node behind it. Rendering that
        // as *Looking for a node…* would understate a wallet that can spend
        // right now — so it gets its own arm, ABOVE the dark-hunt one, and
        // says both halves of the truth.
        //
        // **A node that says it is not synced is a warning on a live link.**
        // The connect race checks `is_synced` once at candidacy; the probe asks
        // again every couple of seconds, and a bind that fell behind serves a
        // balance and a depth that lag the network (BG-8 — the reading is
        // stale even though the socket is live).
        final (KvLampTone tone, String title, String sentence) = switch (true) {
          _ when offline => (
            KvLampTone.warn,
            'Your phone has no network',
            'Nothing can be reached until it is back.',
          ),
          _ when connected && hunting => (
            KvLampTone.ok,
            'Connected to',
            'Looking for a different node behind this one. It keeps working '
                'until another answers.',
          ),
          _ when hunting => (
            KvLampTone.warn,
            'Looking for a node…',
            pinned == null
                ? 'Asking the public node directory.'
                : 'Dialling the node you pinned.',
          ),
          _ when connected && synced == false => (
            KvLampTone.warn,
            'Connected to',
            'This node says it is still syncing, so your balance and depths '
                'can lag the network.',
          ),
          // **The directory is named where it acts** (D-207 census; founder
          // call 2026-08-27). "A public community node" said which KIND of
          // node was answering and left out who chose it — and the PNN
          // resolver walk was the census's first unnamed row. A user cannot
          // consent to a discovery service they have never been told exists.
          _ when connected => (
            KvLampTone.ok,
            'Connected to',
            pinned == null
                ? 'A public community node, found for you by the public node '
                      'directory.'
                : 'The node you pinned. Redial drops the link you have and '
                      'dials it again.',
          ),
          // D-187: a pinned node's silence is a different sentence from a
          // hunt's, and only one of them tells the user what to do.
          _ => (
            KvLampTone.warn,
            'No node is answering yet',
            pinned == null
                ? 'The wallet keeps asking the public node directory.'
                : 'The node you pinned is not answering, and by your '
                      'instruction nothing else will be tried.',
          ),
        };
        // **One control, four states, and the label says what the tap does**
        // (D-213). Hunting: "Searching…", not "Reconnecting…" — the hunt is
        // just as often the FIRST connection of a session. Connected and
        // unpinned: the engine holds the live link while it looks
        // (find-then-swap), so the tap switches to a different node and the
        // render's own two words say exactly that. Connected and pinned:
        // there IS no different node to find, so a tap can only redial, and
        // that one drops the link first — the sentence above says so. Dark:
        // "Reconnect", unchanged.
        final label = switch (true) {
          _ when hunting => 'Searching…',
          _ when connected && pinned != null => 'Redial',
          _ when connected => 'Switch node',
          _ => 'Reconnect',
        };
        final tap = s.onReconnect;

        final scaler = MediaQuery.textScalerOf(context);
        // **The sentence is drawn only where there is news** — a hunt, a dark
        // or offline link, a node that says it is syncing, or a pin (whose
        // redial has a cost the user must be told, D-213). Healthy and
        // unpinned, the card is `T5`'s one row and nothing under it; the
        // directory is named in the trust line below the card.
        final news =
            !connected ||
            hunting ||
            offline ||
            synced == false ||
            pinned != null;
        return KvRowContainer(
          divided: false,
          inset: const EdgeInsets.symmetric(
            horizontal: KvSpace.s18,
            vertical: KvSpace.sm,
          ),
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                // **Measured, then either the render's one row or two** — at
                // 320 dp and 1.3× the pill left the title 77 dp and the word
                // broke as `Conn / ect…` (found in the floor frame, second
                // beat). A title is chrome and never breaks: when the title
                // cannot stand beside the pill, the pill takes its own line
                // under the row, right-aligned.
                final pillNeeds = math.max(
                  KvSpace.touchTarget,
                  _width(label, _ChipPill.style(hunting), scaler) +
                      KvSpace.sm * 2,
                );
                final titleNeeds = _width(title, _NodeRow.titleStyle, scaler);
                final beside =
                    tap == null ||
                    constraints.maxWidth -
                            KvSpace.rowDisc -
                            KvSpace.sm -
                            KvSpace.s -
                            pillNeeds >=
                        titleNeeds;
                final pill = tap == null
                    ? null
                    : _ChipPill(
                        label: label,
                        dim: hunting,
                        onTap: () => unawaited(tap()),
                      );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _NodeRow(
                      tone: tone,
                      busy: hunting || (!connected && !offline),
                      title: title,
                      // **In full** — `wss://host:port`, wrapping to a second
                      // line rather than cut to a host (founder on glass,
                      // 2026-09-05: *"let the link be in full"*).
                      endpoint: endpoint,
                      trailing: beside ? pill : null,
                    ),
                    if (news) ...[
                      const SizedBox(height: KvSpace.s),
                      Text(
                        sentence,
                        style: const TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 11,
                          height: 15 / 11,
                          color: KvColor.inkMeta,
                        ),
                      ),
                    ],
                    if (!beside && pill != null) ...[
                      const SizedBox(height: KvSpace.s),
                      Align(
                        alignment: Alignment.centerRight,
                        child: UnconstrainedBox(child: pill),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }

  /// A text run's width under the window's scaler, for the two rows on this
  /// screen that must never break a word.
  static double _width(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// **`T5`'s connection card** — the measurement, then what the link is.
  ///
  /// The home's card (founder on glass, 2026-09-05): `plate`, radius 28, no
  /// border, the house 6 / 20 padding with a hairline between one reading and
  /// the next, and nothing under the last row.
  ///
  /// **The instrument is `T5`'s head, grown into two numbers and a minute of
  /// history at no height** (LINK-UX1 — the founder's ruling in the sitting,
  /// 2026-09-28, on the Recommended option: the screen fits his phone). The
  /// caps label over the figure names what the figure is — **`NODE REPLY`**,
  /// the render's `CONNECTION` renamed to the honest name of the number under
  /// it (D-337: never "ping", never "network") — and carries the reading's
  /// circled-i; **`PATH`** takes the seat on the right where the render drew
  /// its tier word (D-332 retired the word); the history runs between the
  /// figure and the staircase. Then `DAA`, and directly under it its own
  /// `BPS` row (D-338 addendum). The `BPS` row is the one line of height
  /// this sitting adds.
  ///
  /// Each region its own listener (the V4 seam law, `rebuild_scope_test`): a
  /// probe rebuilds the caption and the instrument; the chain clock hears the
  /// score and the link; the pace hears the pulse; the transport line hears
  /// the endpoint; the peers hear the probe.
  Widget _connectionPlate() {
    final s = widget.scope;
    // `T5`'s row labels are `inkMeta` (122,133,131), measured.
    Widget row(String label, String text, Widget value) => KvFactLine(
      label: label,
      dense: true,
      labelColor: KvColor.inkMeta,
      valueText: text,
      value: value,
    );
    return KvRowContainer(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: KvSpace.xs, bottom: KvSpace.xs),
          // **A latency reading belongs to a live socket, and only to one.**
          // A drop clears the seat ([_onLink]), and each gate here closes the
          // frame between the notifier and its listener.
          child: _ReplyHead(
            open: _replyInfo,
            // The seat on the right: the age of a reading carried over from
            // before the screen opened (D-333), or else the path. Eased on
            // the house curve when the first fresh answer replaces the one
            // with the other, in step with the seat's own un-dimming (BG-24).
            trailing: ListenableBuilder(
              listenable: Listenable.merge([
                _latency,
                _latencyTakenAt,
                s.connected,
                _now,
              ]),
              builder: (context, _) {
                final live = s.connected.value;
                final carried = live ? _latencyTakenAt.value : null;
                return AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : KvMotion.calm,
                  switchInCurve: KvMotion.curve,
                  switchOutCurve: KvMotion.curve,
                  child: carried != null
                      ? _CarriedAge(
                          key: const ValueKey('carried'),
                          since: carried,
                          now: _now,
                        )
                      : _PathReading(
                          key: const ValueKey('path'),
                          ms: live ? _printedPath(_latency.value) : null,
                        ),
                );
              },
            ),
            instrument: ListenableBuilder(
              listenable: Listenable.merge([
                _latency,
                _latencyTakenAt,
                s.connected,
                _dark,
                _probeOutSince,
                _now,
              ]),
              builder: (context, _) {
                final live = s.connected.value;
                final reading = live
                    ? _latency.value
                    : const KvLatencyReading.none();
                final carried = live && _latencyTakenAt.value != null;
                // *measuring…* only where a measurement is under way: a live
                // socket, a probe seam wired, nothing answered on this node
                // yet, and the dwell not run out (that face is `—`).
                final measuring =
                    live &&
                    s.probeLink != null &&
                    !_dark.value &&
                    !carried &&
                    reading.isEmpty;
                final out = live ? _probeOutSince.value : null;
                return KvLatency(
                  milliseconds: reading.milliseconds,
                  atLeast: reading.atLeast,
                  tier: reading.tier,
                  stale: carried,
                  measuring: measuring,
                  waitingSince: out,
                  clock: widget.clock,
                  path: live && !carried ? _printedPath(reading) : null,
                  history: KvLatencyHistory(
                    reading: reading,
                    now: _now.value,
                    waitingSince: out,
                  ),
                );
              },
            ),
          ),
        ),
        // BG-8, all three states. `ChainService` deliberately KEEPS the
        // last-known score when a dropped link emits nulls — which is only
        // honest if the screen dims it and says how old it is. **Streamed,
        // not stepped** (BG-18 / D-226). In a layer of its own: the count
        // paints every frame of a crossing. **`DAA` and nothing else on the
        // left** (the founder, D-338 addendum: *"DAA remains DAA since to the
        // right is actually the DAA reading"*) — the pace and every state it
        // used to carry moved to the `BPS` row under it.
        RepaintBoundary(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              s.connected,
              s.virtualDaaScore,
              s.lastUpdate,
              _now,
              _synced,
              _scan,
            ]),
            builder: (context, _) {
              final connected = s.connected.value;
              final syncing = connected && _synced.value == false;
              final age = _scan.value.secs;
              // The LAMP's line: live through a quiet spell of up to 15 s on
              // a bound socket (D-331(b)) — the same hold the money plate's
              // chip keeps, so the two surfaces never disagree about a link.
              final lampQuiet =
                  connected &&
                  _scan.value.have &&
                  age != null &&
                  age >= KvFreshness.liveHoldBound.inSeconds;
              return KvStreamingCount(
                value: s.virtualDaaScore.value,
                stalled: !connected,
                builder: (context, shown) => row(
                  'DAA',
                  // **The lamp and its gap are part of the value's width.**
                  // `KvFactLine` measures the STRING it is given, so a row
                  // whose value carries a mark has to say so or the row will
                  // decide it fits and then ellipsise a chain figure — which
                  // BG-5 forbids and the 320 dp / 1.3× frame caught the moment
                  // the compact density made the arithmetic marginal (D-278).
                  '${formatScore(shown)}      ',
                  _CardValue(
                    formatScore(shown),
                    lamp: !connected
                        ? null
                        : (syncing || lampQuiet)
                        ? KvLampTone.warn
                        : KvLampTone.ok,
                    stale: !connected,
                    age: connected ? null : _ageLabel(),
                  ),
                ),
              );
            },
          ),
        ),
        // **`BPS · 10` on the left, the average on the right** (the founder
        // on glass, 2026-09-28, D-342, reshaping the D-338 addendum's row: *"let
        // BPS read like this 'BPS · 10' on the left of it, then on the right
        // side, let it show an avg"*). The live pace — blocks a second from the
        // DAA score's climb over three seconds ([KvBlockRate]) — rides the
        // label as `DAA · 10 Hz` once did, its figure mono in a two-figure slot
        // (BG-30), and with it the states that stand in its seat: `syncing`,
        // `7 s since last block` past the data's stale line, bare `BPS` with no
        // socket. The right side is the chain's average pace over up to the
        // last hour ([NodeScope.paceAverage]): `12 mins avg: 10.0`, then
        // `1 hour avg: 10.0`; `—` until two minutes of it exist or with no
        // socket.
        ListenableBuilder(
          listenable: Listenable.merge([
            s.connected,
            _synced,
            _scan,
            _average,
            if (s.searching != null) s.searching!,
            if (s.reconnecting != null) s.reconnecting!,
            if (s.osOffline != null) s.osOffline!,
          ]),
          builder: (context, _) {
            final connected = s.connected.value;
            final syncing = connected && _synced.value == false;
            final scan = _scan.value;
            final age = scan.secs;
            // The DATA's stale line — the balance's clock, 5 s — decides when
            // the label trades the pace for the silence.
            final quiet =
                connected &&
                scan.have &&
                age != null &&
                age > KvFreshness.staleAfter.inSeconds;
            // A live pace is the strongest claim on this screen (C7): it is
            // withheld while the link is hunting or the phone is offline,
            // exactly as the retired scan line withheld *live*.
            final settledLink =
                connected &&
                !(s.searching?.value ?? false) &&
                !(s.reconnecting?.value ?? false) &&
                !(s.osOffline?.value ?? false);
            // A hunting link prints the age it has rather than the claim it
            // may not make.
            final aged = scan.have && age != null && (quiet || !settledLink);
            final rate = _rateFigure(scan.bps);
            // The label's second run, and how it is heard. **An age inside a
            // sentence is a word** (BG-30's age clause, D-261): Jakarta, as the
            // money plate's trust line sets it; only the pace is a figure.
            final (String? words, String? figure, String spoken) = !connected
                ? (null, null, 'Blocks per second')
                : syncing
                ? ('syncing', null, 'Blocks per second: the node is syncing')
                : aged
                ? (
                    '${formatAge(Duration(seconds: age))} since last block',
                    null,
                    'Blocks per second: '
                        '${formatAge(Duration(seconds: age))} since last block',
                  )
                : settledLink && rate != null
                ? (null, rate, _spokenRate(rate))
                : (null, null, 'Blocks per second');
            // **The average is the chain's pace, so it keeps the pace's
            // rules** (`ux-auditor`): nothing beside a dead link (BG-8), and
            // nothing while the node syncs — a syncing node's climb is its
            // catch-up speed, not the chain's.
            final average = connected && !syncing ? _average.value : null;
            final value = average == null
                ? '—'
                : '${_PaceAverage.window(average.span)} avg: '
                      '${average.bps.toStringAsFixed(1).padLeft(4)}';
            return KvFactLine(
              label: spoken,
              labelSpan: TextSpan(
                children: [
                  const TextSpan(text: 'BPS'),
                  // **The dot is JetBrains Mono's** (the founder on glass,
                  // 2026-09-28: *"i expect the dot to be well centered"*) —
                  // the Transport row's own separator. Measured off both
                  // faces' outlines at the label's 12 dp: Jakarta's `·` sits
                  // 1.3 dp under the capitals' centre and is 1 dp wide; the
                  // mono one sits within 0.4 dp and is 2 dp. The spaces stay
                  // Jakarta's, so the dot keeps the label's rhythm and not
                  // the mono cell's.
                  if (words != null || figure != null) ...const [
                    TextSpan(text: ' '),
                    TextSpan(text: '·', style: _labelDot),
                    TextSpan(text: ' '),
                  ],
                  if (words != null) TextSpan(text: words),
                  if (figure != null)
                    TextSpan(text: figure, style: _labelFigure),
                ],
              ),
              dense: true,
              labelColor: KvColor.inkMeta,
              valueText: value,
              value: _PaceAverage(average: average, text: value),
            );
          },
        ),
        // **Read off the live endpoint, never asserted.** Whether the
        // transport is encrypted is a property of the URL the socket
        // actually bound.
        ValueListenableBuilder<String?>(
          valueListenable: s.activeEndpoint,
          builder: (context, endpoint, _) => row(
            'Transport',
            _transportLine(endpoint),
            _CardValue(_transportLine(endpoint)),
          ),
        ),
        // **The NODE's peers, and the label says so** (BG-11): a light wallet
        // has exactly one peer — this node. `—` where the node declines.
        ListenableBuilder(
          listenable: Listenable.merge([_peers, s.connected]),
          builder: (context, _) {
            final line = _peersLine(s.connected.value, _peers.value);
            return row("Node's peers", line, _CardValue(line));
          },
        ),
      ],
    );
  }

  /// **The path this screen prints and speaks** — one helper for both, so
  /// the caption and the sentence a screen reader hears cannot disagree
  /// (floored to its step, never above the figure: [KvLatencyReading
  /// .printedPath]).
  int? _printedPath(KvLatencyReading reading) => KvLatencyReading.printedPath(
    reading.pathAt(_now.value),
    figure: reading.milliseconds,
    atLeast: reading.atLeast,
  );

  /// `wRPC · borsh` plus `TLS` only where the bound socket actually has it.
  static String _transportLine(String? endpoint) {
    const base = 'wRPC · borsh';
    if (endpoint == null) return base;
    return endpoint.startsWith('wss://') ? '$base · TLS' : base;
  }

  static String _peersLine(bool connected, int? n) {
    if (!connected || n == null) return '—';
    return '$n';
  }

  /// **`T5`'s own-node card**: the toggle row over its field and `Test`, in
  /// one card of the home's topography (founder on glass, 2026-09-05).
  ///
  /// **The switch governs the field** (his second finding, 2026-09-05; since
  /// D-342 by folding it): off, the card is the toggle row alone; on, the
  /// field eases in, takes a node, and `Test` can dial it. **The commit is a standard pill** — `KvAction
  /// .raised`, disabled with its reason until there is a change to commit,
  /// enabled when there is, pressed one step lighter — not an edge that lights
  /// (the pattern he asked to lose). The playbook allows no fourth kind of
  /// button, and this is the second kind.
  Widget _picker() {
    final s = widget.scope;
    return AnimatedBuilder(
      // The field is a `Listenable` too: a keystroke enables the commit
      // through this builder and nothing else on the screen.
      animation: Listenable.merge([s.pinnedNode, s.pinDropped, _url, _test]),
      builder: (context, _) {
        final pinned = s.pinnedNode.value;
        final dropped = s.pinDropped.value;
        // The switch reads as "I want my own node", which is true the moment
        // the user asks for it and stays true while a pin exists.
        final on = _wantPin || pinned != null;
        final typed = _url.text.trim();
        final changed = typed.isNotEmpty && typed != pinned;
        final canApply = on && !_busy && changed;
        final test = _test.value;
        final canTest = on && !_busy && !test.busy && typed.isNotEmpty;
        return KvRowContainer(
          divided: false,
          inset: const EdgeInsets.fromLTRB(
            KvSpace.s18,
            KvSpace.s14,
            KvSpace.s18,
            KvSpace.s14,
          ),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KvToggle(
                  bare: true,
                  on: on,
                  // `T5`'s own words: *Use my own node · Bypass public nodes
                  // entirely* — true of this build, where a pinned wallet
                  // never touches the resolver (D-187).
                  title: 'Use my own node',
                  sub: pinned != null
                      ? 'A pinned node never silently falls back to a public one.'
                      : 'Bypass public nodes entirely.',
                  disabledReason: 'Setting the node…',
                  // On opens the field; the pin happens when the user says
                  // which node. Off clears the pin at once — the safe
                  // direction needs no second step.
                  onChanged: _busy
                      ? null
                      : (next) {
                          if (next) {
                            setState(() => _wantPin = true);
                            return;
                          }
                          setState(() => _wantPin = false);
                          _url.clear();
                          if (pinned != null) _apply(null);
                        },
                ),
                // The startup refusal yields to a FRESHER answer (D-192 / BG-2).
                if (dropped && _problem == null) ...[
                  const SizedBox(height: KvSpace.sm),
                  const KvStatusChip(
                    tone: KvLampTone.warn,
                    plated: true,
                    maxLines: null,
                    words:
                        'The node you pinned was refused when the wallet started, '
                        'so you are back on public nodes. Your money is safe. '
                        'Switch on Use my own node to set it again.',
                  ),
                ],
                // **The field folds behind the switch** (the founder's ruling,
                // 2026-09-28, D-342 — reversing D-275 item 2's disabled field
                // under an off switch): off, the card is the toggle row alone;
                // on, the field, `Test` and the commit ease in beneath it. A
                // field that cannot be used is chrome the one-view screen could
                // not afford on his phone (360 × 769 dp at 0.9 text), and
                // switching it on is the deliberate act that asks for it. A
                // refused pin is no exception: its notice names that act
                // (`ux-auditor`: pointing at an empty, disabled field below
                // asked for something the user could not do).
                _Unfold(
                  open: on,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: KvSpace.sm),
                      // **`T5`: the field with `Test` beside it** — measured, both
                      // 44 dp tall with a 10 dp gap, the pill in `chip`.
                      Row(
                        children: [
                          Expanded(
                            child: _UrlField(
                              controller: _url,
                              enabled: on && !_busy,
                              // **The address shape** (founder on glass,
                              // 2026-09-05): a hint that says what to type teaches
                              // the form. `wss://`, the scheme a public node speaks —
                              // Rust takes either, and this is the one to encourage.
                              hint: 'wss://host:port',
                              onSubmitted: canApply
                                  ? () => _apply(typed)
                                  : null,
                            ),
                          ),
                          if (s.testNode != null) ...[
                            const SizedBox(width: KvSpace.s10),
                            _ChipPill(
                              label: test.busy ? 'Testing…' : 'Test',
                              dim: !canTest,
                              // Nothing to dial: no tap and no haptic.
                              onTap: canTest
                                  ? () => unawaited(_runTest())
                                  : null,
                            ),
                          ],
                        ],
                      ),
                      if (test.answer case final answer?) ...[
                        const SizedBox(height: KvSpace.s),
                        _TestAnswer(answer),
                      ],
                      if (test.problem case final problem?) ...[
                        const SizedBox(height: KvSpace.s),
                        _Fault(problem),
                      ],
                      // The commit: disabled with its reason until there is a
                      // change, enabled when there is (BG-12). **No `if (on)` of
                      // its own** — the fold already gates on the switch, and a
                      // second gate dropped the pill and its gap (~68 dp) in the
                      // first frame of every close (`ux-auditor`, BG-24).
                      const SizedBox(height: KvSpace.sm),
                      KvAction.raised(
                        label: 'Use this node',
                        onTap: () => _apply(typed),
                        disabledReason: _busy
                            ? 'Setting the node…'
                            : typed.isEmpty
                            ? 'Type the address of your node first.'
                            : !changed
                            ? 'This is already the node you pinned.'
                            : null,
                      ),
                    ],
                  ),
                ),
                if (_problem != null) ...[
                  const SizedBox(height: KvSpace.sm),
                  KvStatusChip(
                    tone: KvLampTone.warn,
                    plated: true,
                    maxLines: null,
                    words: _problem!,
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  /// **`SOURCES`** — `T5`'s one card of two rows, each opening its own sheet
  /// (founder on glass, 2026-09-05): the explorer, and the price source. A row
  /// names the seat, says what it is for, prints the host, and points on. The
  /// caps label carries the circled-i; the census sentence — what else this
  /// app can reach — eases in beneath the card (D-207 clause a).
  /// Absent seams ⇒ absent rows, never rows wired to nothing (D-206).
  List<Widget> _sources() {
    final explorer = widget.explorer;
    final rate = widget.rate;
    if (explorer == null && rate == null) return const [];
    return [
      KvSectionHeader('Sources', info: _sourcesInfo),
      // **The host and the chevron sit close to the card's edge** (founder
      // on glass, 2026-09-05): 12 on the right where the card's rule is 20.
      KvRowContainer(
        inset: const EdgeInsets.fromLTRB(
          KvSpace.s18,
          KvSpace.xs,
          KvSpace.sm,
          KvSpace.xs,
        ),
        children: [
          if (explorer != null)
            ValueListenableBuilder<ExplorerChoice?>(
              valueListenable: _explorerChoice,
              builder: (context, choice, _) => _SourceRow(
                title: 'Explorer',
                sub: 'Where "View on explorer" opens',
                value: choice == null ? '—' : _hostOf(choice.txTemplate),
                onTap: () => _openExplorer(choice),
              ),
            ),
          if (rate != null)
            ListenableBuilder(
              listenable: Listenable.merge([rate.enabled, rate.endpoint]),
              builder: (context, _) => _SourceRow(
                title: 'API source',
                // What it actually fetches — a price and nothing else (the
                // render's "token metadata" is not a thing this wallet asks
                // for, and a row must not claim an egress it does not make).
                sub: 'Prices',
                value: switch (rate.enabled.value) {
                  null => '—',
                  false => 'Off',
                  true => _hostOf(rate.endpoint.value),
                },
                onTap: _openRate,
              ),
            ),
        ],
      ),
      _Explainer(
        open: _sourcesInfo,
        text:
            'Nothing else reaches out. Your balance, your history and your '
            'sends go to a Kaspa node and nowhere else — the price source and '
            'the explorer above are the only other places this app can reach, '
            'and both are yours to change or switch off.',
      ),
    ];
  }

  void _openExplorer(ExplorerChoice? choice) {
    final scope = widget.explorer;
    if (scope == null || choice == null) return;
    _closeExplainers();
    Navigator.of(context).push(
      KvSheetRoute<void>(
        builder: (_) => _ExplorerSheet(
          scope: scope,
          current: choice,
          onSaved: _loadExplorer,
        ),
      ),
    );
  }

  void _openRate() {
    final scope = widget.rate;
    if (scope == null) return;
    _closeExplainers();
    Navigator.of(context).push(
      KvSheetRoute<void>(
        builder: (_) => _RateSheet(scope: scope, clock: widget.clock),
      ),
    );
  }

  Future<void> _loadExplorer() async {
    final scope = widget.explorer;
    if (scope == null) return;
    try {
      final choice = await scope.read();
      if (!mounted) return;
      _explorerChoice.value = choice;
    } catch (_) {
      // The row keeps the last choice it knew; the sheet reports a refusal
      // where the user can act on it.
    }
  }

  Future<void> _loadRate() async {
    final scope = widget.rate;
    if (scope == null) return;
    try {
      await scope.load();
    } catch (_) {
      // The notifiers keep whatever they last knew.
    }
  }
}

/// **A block that eases open AND shut beneath its trigger** — the own-node
/// card's field (D-342) and every explainer on this screen. Closed it takes
/// no room; it grows and fades in over `enter`, and on closing it keeps what
/// it held while it shrinks and fades out, then lets it go (BG-24 in both
/// directions — `ux-auditor`: an `AnimatedSize` around a swapped child grew
/// smoothly and vanished in one frame, the field, `Test` and the commit all
/// at once). The house curve both ways, flipped for closing so the motion
/// still only decelerates (BG-9). Under reduced motion it simply appears and
/// goes.
class _Unfold extends StatefulWidget {
  const _Unfold({required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<_Unfold> createState() => _UnfoldState();
}

class _UnfoldState extends State<_Unfold> with SingleTickerProviderStateMixin {
  late final AnimationController _run = AnimationController(
    vsync: this,
    duration: KvMotion.enter,
    value: widget.open ? 1 : 0,
  )..addStatusListener(_onStatus);

  late final Animation<double> _eased = CurvedAnimation(
    parent: _run,
    curve: KvMotion.curve,
    reverseCurve: KvMotion.curve.flipped,
  );

  /// Shut and done: the child leaves the tree (a folded field holds nothing).
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed) setState(() {});
  }

  @override
  void didUpdateWidget(_Unfold old) {
    super.didUpdateWidget(old);
    if (widget.open == old.open) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _run.value = widget.open ? 1 : 0;
      return;
    }
    widget.open ? _run.forward() : _run.reverse();
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _run.isDismissed) {
      return const SizedBox(width: double.infinity);
    }
    return SizeTransition(
      sizeFactor: _eased,
      axisAlignment: -1,
      child: FadeTransition(opacity: _eased, child: widget.child),
    );
  }
}

/// **An explainer that eases in beneath its card** (founder, 2026-09-05):
/// closed it takes no room; open it pushes what follows down over `enter`
/// and fades in, and closing runs the same way back ([_Unfold]) — motion that
/// accounts for where the text came from and where it went (BG-24).
class _Explainer extends StatelessWidget {
  const _Explainer({
    required this.open,
    required this.text,
    this.figures = false,
  });

  final ValueNotifier<bool> open;
  final String text;

  /// Its numerals are figures (see [_TrustLabel.figures]).
  final bool figures;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: open,
    builder: (context, on, _) => _Unfold(
      open: on,
      child: Padding(
        padding: const EdgeInsets.only(top: KvSpace.sm),
        child: _TrustLabel(text, figures: figures),
      ),
    ),
  );
}

/// **The playbook's ceremony truths card, holding choices** (§3.4, §8): a
/// `chip` inner card at radius 22 with hairlines between rows, and the one
/// current choice wearing `KvCheck` — a status is a check, never a tinted row
/// (§6). Sub-lines are `inkDim`, because `inkMeta` fails AA on `chip` (BG-14).
/// **The explorer sheet — a settings ceremony** (playbook §3.4 / §3.5: a
/// setting whose change has consequences opens a sheet, not an inline
/// control). The question in one line; the choices as truths in a chip card —
/// the shipped explorers, and **`Custom`**, which is what the two link inputs
/// were for and now reveals them; one primary act in the foot, disabled with
/// its reason until a choice differs; the disclosure as the one instruction
/// line. Rust validates every template; a refusal stays on the sheet where
/// it can be fixed (BG-11).
class _ExplorerSheet extends StatefulWidget {
  const _ExplorerSheet({
    required this.scope,
    required this.current,
    required this.onSaved,
  });

  final ExplorerScope scope;
  final ExplorerChoice current;
  final Future<void> Function() onSaved;

  @override
  State<_ExplorerSheet> createState() => _ExplorerSheetState();
}

class _ExplorerSheetState extends State<_ExplorerSheet> {
  /// The chosen preset's index, or -1 for `Custom`.
  late int _selected;
  late final TextEditingController _tx;
  late final TextEditingController _address;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    final c = widget.current;
    _selected = c.defaults.indexWhere(
      (d) =>
          d.txTemplate == c.txTemplate &&
          d.addressTemplate == c.addressTemplate,
    );
    _tx = TextEditingController(text: c.txTemplate)..addListener(_changed);
    _address = TextEditingController(text: c.addressTemplate)
      ..addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _tx.dispose();
    _address.dispose();
    super.dispose();
  }

  (String, String) get _templates => _selected >= 0
      ? (
          widget.current.defaults[_selected].txTemplate,
          widget.current.defaults[_selected].addressTemplate,
        )
      : (_tx.text.trim(), _address.text.trim());

  String? get _reason {
    if (_busy) return 'Saving…';
    final (tx, address) = _templates;
    if (tx.isEmpty || address.isEmpty) {
      return 'Both links need an address before they can be saved.';
    }
    if (tx == widget.current.txTemplate &&
        address == widget.current.addressTemplate) {
      return 'This is already your explorer.';
    }
    return null;
  }

  Future<void> _save() async {
    if (_busy) return;
    final (tx, address) = _templates;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.scope.write(tx, address);
      await widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _problem = displayError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final custom = _selected < 0;
    return KvSheet(
      title: 'Explorer',
      onCancel: () => Navigator.of(context).pop(),
      foot: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.m,
          KvSpace.sm,
          KvSpace.m,
          KvSpace.m,
        ),
        child: KvAction(
          label: 'Use this explorer',
          primary: true,
          onTap: _save,
          disabledReason: _reason,
        ),
      ),
      child: SingleChildScrollView(
        // `KvSheet` owns the gutter (D-284); this sheet had been at 16 while
        // its own title sat at 24.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Where "View on explorer" opens.',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 20,
                height: 26 / 20,
                fontWeight: FontWeight.w600,
                fontVariations: KvWeight.w600,
                color: KvColor.ink,
              ),
            ),
            const SizedBox(height: KvSpace.s),
            // **The disclosure, at the top and in one line** (D-277). The
            // founder struck the paragraph that stood over the act, twice —
            // but D-192/BG-17 is why it exists at all: a departure you cannot
            // name is not one you consented to, and `KvExplorerExit`'s compact
            // button rests its own case on this sheet naming it. So the fact
            // moved to where the choice is made and shrank to a sentence.
            const _TrustLabel(
              'An explorer gets the transaction id and your network address.',
            ),
            const SizedBox(height: KvSpace.m),
            KvChoiceCard(
              children: [
                for (var i = 0; i < widget.current.defaults.length; i++)
                  KvChoiceRow(
                    title: widget.current.defaults[i].name,
                    selected: _selected == i,
                    onTap: _busy ? null : () => setState(() => _selected = i),
                  ),
                KvChoiceRow(
                  title: 'Custom',
                  sub: 'Your own explorer links',
                  selected: custom,
                  onTap: _busy ? null : () => setState(() => _selected = -1),
                ),
              ],
            ),
            // The inputs `Custom` stands for, revealed only under it.
            AnimatedSize(
              duration: KvMotion.enter,
              curve: KvMotion.curve,
              alignment: Alignment.topCenter,
              child: custom
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: KvSpace.sm),
                        _UrlField(
                          controller: _tx,
                          enabled: !_busy,
                          hint: 'https://explorer.example/txs/{txid}',
                          label: 'Transaction link',
                          onSubmitted: _reason == null ? _save : null,
                        ),
                        const SizedBox(height: KvSpace.s),
                        _UrlField(
                          controller: _address,
                          enabled: !_busy,
                          hint: 'https://explorer.example/addresses/{address}',
                          label: 'Address link',
                          onSubmitted: _reason == null ? _save : null,
                        ),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
            if (_problem case final problem?) ...[
              const SizedBox(height: KvSpace.s),
              _Fault(problem),
            ],
            // No paragraph above the act (founder on glass, 2026-09-05:
            // *"there is no need for the text"*). What an explorer is handed
            // is said where the link is taken — `KvExplorerExit`'s own line.
            const SizedBox(height: KvSpace.s),
          ],
        ),
      ),
    );
  }
}

/// Which price source, or none.
enum _RateChoice { off, shipped, custom }

/// **The price-source sheet — the same ceremony** for the one claim consensus
/// cannot check (INV-8's carve-out, D-191): `Off`, the shipped source, or
/// **`Custom`** with its field; what the source last said, so the setting is
/// verifiable rather than declarative; one primary act; the disclosure.
class _RateSheet extends StatefulWidget {
  const _RateSheet({required this.scope, required this.clock});

  final RateScope scope;
  final DateTime Function() clock;

  @override
  State<_RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends State<_RateSheet> {
  _RateChoice? _choice;
  late final TextEditingController _endpoint;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _endpoint = TextEditingController(text: widget.scope.endpoint.value)
      ..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  /// What the wallet has right now, as a choice.
  _RateChoice? get _stored => switch (widget.scope.enabled.value) {
    null => null,
    false => _RateChoice.off,
    true =>
      widget.scope.endpoint.value == widget.scope.defaultEndpoint.value
          ? _RateChoice.shipped
          : _RateChoice.custom,
  };

  (bool, String) _commit(_RateChoice choice) => switch (choice) {
    _RateChoice.off => (false, widget.scope.endpoint.value),
    _RateChoice.shipped => (true, widget.scope.defaultEndpoint.value),
    _RateChoice.custom => (true, _endpoint.text.trim()),
  };

  String? _reason(_RateChoice choice) {
    if (_busy) return 'Saving…';
    final (enabled, endpoint) = _commit(choice);
    if (enabled && endpoint.isEmpty) {
      return 'Type the address of a price source first.';
    }
    if (enabled == widget.scope.enabled.value &&
        (!enabled || endpoint == widget.scope.endpoint.value)) {
      return 'This is already your price source.';
    }
    return null;
  }

  Future<void> _save(_RateChoice choice) async {
    if (_busy) return;
    final (enabled, endpoint) = _commit(choice);
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.scope.setConfig(enabled: enabled, endpoint: endpoint);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      // The refusal is the message: a source Rust would not store must not
      // leave the sheet looking as though it had been.
      if (mounted) setState(() => _problem = displayError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.scope;
    return AnimatedBuilder(
      animation: Listenable.merge([
        scope.enabled,
        scope.endpoint,
        scope.quote,
        scope.error,
      ]),
      builder: (context, _) {
        final stored = _stored;
        final choice = _choice ?? stored;
        return KvSheet(
          title: 'API source',
          onCancel: () => Navigator.of(context).pop(),
          foot: choice == null
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    KvSpace.m,
                    KvSpace.sm,
                    KvSpace.m,
                    KvSpace.m,
                  ),
                  child: KvAction(
                    label: 'Use this source',
                    primary: true,
                    onTap: () => _save(choice),
                    disabledReason: _reason(choice),
                  ),
                ),
          child: SingleChildScrollView(
            // `KvSheet` owns the gutter (D-284).
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Where the price under your balance comes from.',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 20,
                    height: 26 / 20,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.ink,
                  ),
                ),
                const SizedBox(height: KvSpace.s),
                // One line, at the top, never over the act (D-277) — and the
                // two facts a price owes: what the source learns, and that
                // nothing on chain can check what it says (BG-17).
                const _TrustLabel(
                  'The source learns that this wallet asked for a price and '
                  'the address it asked from; no node can check the figure.',
                ),
                const SizedBox(height: KvSpace.m),
                // Not yet read: say so, and offer no control (a switch drawn
                // over a posture nobody has read is a switch reporting a state
                // it does not know — `wallet-security-auditor`).
                if (choice == null)
                  const _TrustLabel('Reading your setting…')
                else ...[
                  KvChoiceCard(
                    children: [
                      KvChoiceRow(
                        title: 'Off',
                        sub:
                            'Your balance is shown in KAS only. Nothing is fetched.',
                        selected: choice == _RateChoice.off,
                        onTap: _busy
                            ? null
                            : () => setState(() => _choice = _RateChoice.off),
                      ),
                      KvChoiceRow(
                        title: _hostOf(scope.defaultEndpoint.value),
                        sub: 'The shipped price source',
                        selected: choice == _RateChoice.shipped,
                        onTap: _busy
                            ? null
                            : () =>
                                  setState(() => _choice = _RateChoice.shipped),
                      ),
                      KvChoiceRow(
                        title: 'Custom',
                        sub: 'Your own price source',
                        selected: choice == _RateChoice.custom,
                        onTap: _busy
                            ? null
                            : () =>
                                  setState(() => _choice = _RateChoice.custom),
                      ),
                    ],
                  ),
                  AnimatedSize(
                    duration: KvMotion.enter,
                    curve: KvMotion.curve,
                    alignment: Alignment.topCenter,
                    child: choice == _RateChoice.custom
                        ? Padding(
                            padding: const EdgeInsets.only(top: KvSpace.sm),
                            child: _UrlField(
                              controller: _endpoint,
                              enabled: !_busy,
                              hint: scope.defaultEndpoint.value,
                              label: 'Price source',
                              onSubmitted: _reason(choice) == null
                                  ? () => _save(choice)
                                  : null,
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  // What the source actually said, so the setting is
                  // verifiable rather than declarative; `—` when there is no
                  // usable price (BG-5).
                  if (stored != _RateChoice.off) ...[
                    const SizedBox(height: KvSpace.s),
                    _Reading(
                      label: 'Price, per KAS',
                      value: switch (scope.quote.value) {
                        null => '—',
                        final quote =>
                          '\$${trimTrailingZeros(quote.usdPerKas)}',
                      },
                    ),
                    if (scope.quote.value case final quote?)
                      _Reading(
                        label: 'As of',
                        numeric: false,
                        value:
                            '${formatAge(widget.clock().difference(quote.fetchedAt))} ago',
                      ),
                  ],
                  if (scope.error.value case final error?) ...[
                    const SizedBox(height: KvSpace.s),
                    _Fault(displayError(error)),
                  ],
                  if (_problem case final problem?) ...[
                    const SizedBox(height: KvSpace.s),
                    _Fault(problem),
                  ],
                ],
                // No paragraph above the act (D-277): the choices say what is
                // fetched and from where; `Off` says nothing is.
                const SizedBox(height: KvSpace.s),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// **One row of `SOURCES`** — the seat's name over what it is for, the host it
/// points at, and a chevron (`T5`, measured: title 16/600 `ink`, sub `inkMeta`,
/// the host in mono `inkDim`). A 52 dp target (BG-12).
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.title,
    required this.sub,
    required this.value,
    required this.onTap,
  });

  final String title;
  final String sub;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _row(constraints.maxWidth),
  );

  Widget _row(double width) => Semantics(
    button: true,
    label: '$title. $sub. $value',
    child: ExcludeSemantics(
      child: InkWell(
        onTap: onTap,
        highlightColor: KvColor.chip,
        splashFactory: NoSplash.splashFactory,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: KvSpace.s10),
            child: Row(
              children: [
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
                          fontWeight: FontWeight.w600,
                          fontVariations: KvWeight.w600,
                          color: KvColor.ink,
                        ),
                      ),
                      Text(
                        sub,
                        style: const TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 12,
                          height: 16 / 12,
                          color: KvColor.inkMeta,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: KvSpace.sm),
                // **Not a flex child** (founder on glass, 2026-09-05:
                // *"let `api.kaspa.org ›` be closer to the right edge too"*).
                // A `Flexible` here took an equal share of the free space with
                // the title's `Expanded`, so a short host left its slack at the
                // row's right edge and the two chevrons did not line up. Bound
                // it instead: the value takes what it needs up to half the row,
                // the title absorbs the rest, and the chevron is flush.
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width * 0.5),
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 12,
                      height: 16 / 12,
                      color: KvColor.inkDim,
                    ),
                  ),
                ),
                const SizedBox(width: KvSpace.xs),
                const KvGlyphIcon(
                  KvGlyph.chevron,
                  tone: KvColor.inkMeta,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// **The card's age line** — `inkMeta` at full strength, 4.75:1 on `plate`,
/// because body size never dims (BG-14 as narrowed by D-257). One style for
/// both seats that say how old a reading is.
const TextStyle _ageLine = TextStyle(
  fontFamily: KvFont.ui,
  fontSize: 12,
  height: 17 / 12,
  color: KvColor.inkMeta,
);

/// **The age of a latency reading carried over from before the screen opened**
/// (D-333) — the seat's one caption, where the tier word used to sit. BG-8's
/// "a dimmed reading carries a visible age", in the card's own age-line style
/// (`inkMeta` at full strength, 4.75:1 — body size never dims). It listens to
/// the poll's clock alone, so the age counts without rebuilding the seat.
class _CarriedAge extends StatelessWidget {
  const _CarriedAge({super.key, required this.since, required this.now});

  final DateTime since;
  final ValueListenable<DateTime> now;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DateTime>(
    valueListenable: now,
    builder: (context, at, _) {
      final age = at.difference(since);
      return Text(
        'as of ${formatAge(age.isNegative ? Duration.zero : age)} ago',
        // On the label's line, so in the label's line metrics
        // (`KvRuledLabel`, tight: 12 / 16): a taller caption lifted the
        // figure row a dp when it left (`ux-auditor`).
        style: _ageLine.copyWith(height: 16 / 12),
      );
    },
  );
}

/// **The pace's figure**: whole blocks a second in a two-figure slot — a
/// monospace space holds the tens place, so the figure does not step a
/// digit's width as mainnet at rest reads 9 and 10 by turns — and `< 1` when
/// the score DID climb but by fewer than one block a second on average: over
/// three seconds a single block rounds to 0, and `0` is the stall's face,
/// which a block is not (BG-20, `ux-auditor`). Null when there is no pace yet.
String? _rateFigure(double? bps) {
  if (bps == null) return null;
  final whole = bps.round();
  if (whole == 0 && bps > 0) return '< 1';
  return '$whole'.padLeft(2);
}

/// The pace as a screen reader hears it — words, never a glyph (`< 1`).
String _spokenRate(String figure) {
  final f = figure.trim();
  if (f == '< 1') return 'Fewer than one block per second';
  if (f == '1') return '1 block per second';
  return '$f blocks per second';
}

/// **The chain's pace** (D-338) — `BPS` `10`, blocks a second from the
/// node's virtual DAA score sampled on the screen's own clock. Pure, so the
/// arithmetic is provable without a socket.
///
/// The score is Rust's freshest fold (read before the bridge's 250 ms
/// coalescer), and it climbs by one per block the virtual merges inside the
/// DAA window (verified at the pin — [NodeScope.tickPulse]); the pace is its
/// climb over the most recent **three seconds** of samples, in whole blocks a
/// second. A stall shows as the pace falling toward 0 over those seconds; the
/// recovery as the backlog landing, a burst past 10, then the pace again.
/// Until LINK-UX1 this counted `VirtualDaaScoreChanged` ticks and read a busy
/// node as a slower chain; the score cannot, because it counts blocks.
///
/// **Three seconds, whole numbers** (the founder on glass, 2026-09-27: "too
/// busy"): on a weak link the updates arrive in bursts, and over one second
/// the figure leapt 6 → 12 → 19 twice a second while a tenths digit printed
/// noise (`ux-auditor`, the same finding from the other side). Three seconds
/// resolves a third of a block a second, so the whole number is the honest
/// precision. (For the screen's first three seconds the window is what has
/// been sampled — the first pace spans one poll, half a second.)
///
/// **Reset on a new node** ([_NodeScreenState._forgetNode]): another node's
/// score is another count, a few blocks apart at any moment.
class KvBlockRate {
  final List<(DateTime, int)> _samples = <(DateTime, int)>[];

  /// The span a pace is taken over, once the samples reach back that far.
  static const Duration window = Duration(seconds: 3);

  /// Forget every sample — a pace must never average across a stretch the
  /// screen was not watching, or across two nodes.
  void reset() => _samples.clear();

  /// The pace after a sample of the [score] taken [at], in blocks per second,
  /// or null until two samples exist.
  double? offer(DateTime at, int score) {
    if (_samples.isNotEmpty &&
        (score < _samples.last.$2 || !at.isAfter(_samples.last.$1))) {
      // A score that went backwards (a virtual reorg) or a clock that did not
      // advance is not a pace to measure — start again from here rather than
      // print nonsense.
      _samples.clear();
    }
    _samples.add((at, score));
    // Keep exactly one sample at or past the window's edge, and every newer
    // one: the span is then the most recent window (a little more on a late
    // poll), never the whole time the screen has been open.
    while (_samples.length > 2 &&
        !at.difference(_samples[1].$1).isNegative &&
        at.difference(_samples[1].$1) >= window) {
      _samples.removeAt(0);
    }
    if (_samples.length < 2) return null;
    final (from, fromScore) = _samples.first;
    final seconds = at.difference(from).inMicroseconds / 1e6;
    return (score - fromScore) / seconds;
  }
}

/// A figure inside a row's label — mono and tabular (BG-30), everything else
/// inherited from the label it sits in: `BPS · 10`'s pace (D-342).
const TextStyle _labelFigure = TextStyle(
  fontFamily: KvFont.mono,
  fontFeatures: [FontFeature.tabularFigures()],
);

/// The separator inside a row's label — `BPS · 10`'s dot, set in mono so it
/// sits on the capitals' centre (D-342, re-set on glass).
const TextStyle _labelDot = TextStyle(fontFamily: KvFont.mono);

/// **The `BPS` row's right side: the chain's average pace** (D-342) — a
/// caption, `37 mins avg:`, then the average as a figure (mono, tabular,
/// `ink`) hard right on the card's one edge, the two on one baseline; `—`
/// until two minutes of it exist. Heard as a sentence (§11).
///
/// **Re-set on glass the same day** (the founder: *"the way its written is not
/// appealing … just write it better and align it well"*). The first cut ran
/// the window, in `formatAge`'s words, straight into the figure at the
/// figure's own size — `37 m avg 10.0`, where `m avg` read as one word and
/// the span outweighed the number it qualifies. Now the caption is set as the
/// row's own label is (Jakarta 12/500, `inkMeta`), a step under the figure,
/// and the window is spelled for reading. The words are his, on the second
/// look: *"let the avg say `3 mins avg: 10.2` like that"* — so `mins` (one
/// minute never shows: the average waits for two), `1 hour` once the hour
/// exists, and the colon carries the separation, with `xs` of air after it
/// where a typed space would sit.
class _PaceAverage extends StatelessWidget {
  const _PaceAverage({required this.average, required this.text});

  final ({double bps, Duration span})? average;

  /// What the row measures (`37 mins avg: 10.0`, or `—`).
  final String text;

  /// The average's window as its caption reads it: `37 mins`, then `1 hour`.
  /// Figure and unit never part (§7.1).
  static String window(Duration span) {
    if (span >= const Duration(hours: 1)) return '1\u00A0hour';
    final minutes = span.inMinutes;
    return minutes == 1 ? '1\u00A0min' : '$minutes\u00A0mins';
  }

  /// The caption: the row label's own face, size and ink.
  static const TextStyle _caption = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 12,
    height: 17 / 12,
    fontWeight: FontWeight.w500,
    fontVariations: KvWeight.w500,
    color: KvColor.inkMeta,
  );

  static const TextStyle _figure = TextStyle(
    fontFamily: KvFont.mono,
    fontSize: _CardValue.figureSize,
    height: 18 / _CardValue.figureSize,
    color: KvColor.ink,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    final average = this.average;
    if (average == null) return _CardValue(text);
    // **A slot as wide as `10.0`** (BG-30's slot precedent, `ux-auditor`): an
    // hour of mainnet averages 10 ± 0.07 and crosses 9.95 often, and without
    // the slot every crossing would move the words beside it by a cell.
    final figure = average.bps.toStringAsFixed(1).padLeft(4);
    final over = average.span >= const Duration(hours: 1)
        ? 'the last hour'
        : 'the last ${average.span.inMinutes} minutes';
    return Semantics(
      label: 'Average over $over: ${figure.trim()} blocks per second',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('${window(average.span)} avg:', maxLines: 1, style: _caption),
          const SizedBox(width: KvSpace.xs),
          Text(figure, maxLines: 1, style: _figure),
        ],
      ),
    );
  }
}

/// **The path, in the seat on the caption's right** (LINK-UX1, D-337) — the
/// best answer in the last ten seconds, where `T5` drew its tier word. Caps
/// like the label it faces, the figure mono on the figure's display grid
/// ([KvLatencyReading.quantize]) so the two numbers read in the same steps,
/// `—` when nothing answered in the window (BG-5). Not heard from here: the
/// instrument speaks it with the figure, as one sentence.
///
/// **What it is, stated honestly** (LINK-Q2 measured it, D-340 item 5): the
/// best round trip to THIS node right now — not the phone's network. The
/// public nodes sit behind Cloudflare, whose edge is 35–47 ms away on the
/// founder's air; the rest of the floor is the edge-to-node leg, i.e. where
/// the node is hosted.
class _PathReading extends StatelessWidget {
  const _PathReading({super.key, required this.ms});

  final int? ms;

  @override
  Widget build(BuildContext context) {
    final ms = this.ms;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const KvRuledLabel('Path', tight: true),
          const SizedBox(width: KvSpace.s),
          // Already on its grid ([KvLatencyReading.printedPath]). **From a
          // second up it is printed in seconds**, floored to a tenth: `1480`
          // and its `ms` pushed the caption past the 320 dp / 1.3× floor and
          // onto a second line (`ux-auditor`, measured 252.3 against 248).
          Text(
            ms == null
                ? '—'
                : ms >= 1000
                ? KvLatency.seconds(ms)
                : '$ms',
            style: const TextStyle(
              fontFamily: KvFont.mono,
              fontSize: 13,
              height: 16 / 13,
              color: KvColor.ink,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (ms != null) ...[
            const SizedBox(width: KvSpace.xs),
            Text(
              ms >= 1000 ? 's' : 'ms',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 12,
                height: 16 / 12,
                color: KvColor.inkMeta,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// **The instrument's head: its caption over its reading, and the caption is
/// the reading's explainer** (LINK-UX1) — `NODE REPLY` with the circled-i,
/// the house's mark for "there is more to read about this" (D-275), and the
/// path or a carried reading's age in the seat on the right.
///
/// **A 52 dp target that adds no height** (BG-12). The caption line is 16 dp
/// and the screen has none to spare (the founder's one-view bar, D-278), so
/// the target is laid OVER the head rather than grown into it: the caption,
/// the gap under it and the top of the reading below — a figure and a chart
/// that take no touch of their own, so a thumb that lands on the number opens
/// what the number means. The press tints the caption line, one step lighter
/// (§9); the mark lights `primaryMuted` while its explainer is open, as the
/// section headers' marks do. A screen reader meets one button, *About node
/// reply*, toggled, and hears the reading as its own node.
class _ReplyHead extends StatefulWidget {
  const _ReplyHead({
    required this.open,
    required this.trailing,
    required this.instrument,
  });

  final ValueNotifier<bool> open;
  final Widget trailing;
  final Widget instrument;

  /// The caption's words — the figure's honest name (D-337).
  static const String label = 'Node reply';

  @override
  State<_ReplyHead> createState() => _ReplyHeadState();
}

class _ReplyHeadState extends State<_ReplyHead> {
  bool _down = false;

  void _toggle() => widget.open.value = !widget.open.value;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.open,
    builder: (context, open, _) => Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A `Wrap`, not a `Row` (L160): at 320 dp / 1.3× the path drops
            // to its own run rather than squeezing the caps label mid-word.
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: KvSpace.s,
              runSpacing: KvSpace.xs,
              children: [
                // The press tints the words and their mark, and nothing
                // else: the seat on the right sets `inkMeta` (the path's
                // unit, a carried age), which is 4.30:1 on `chip` — under AA
                // (BG-14, `ux-auditor`).
                CustomPaint(
                  painter: _PressTint(down: _down),
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const KvRuledLabel(_ReplyHead.label, tight: true),
                        const SizedBox(width: KvSpace.s),
                        KvInfoMark(open: open),
                      ],
                    ),
                  ),
                ),
                widget.trailing,
              ],
            ),
            const SizedBox(height: KvSpace.s),
            widget.instrument,
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: KvSpace.touchTarget,
          // **The control is the 52 dp overlay, and so is its semantics**
          // (`KvSectionHeader`'s shape, L143): a screen reader meets one
          // button, *About node reply*, toggled, whose rect is the target a
          // thumb gets — not the 16 dp caption line under it. **`GestureDetector`,
          // not `InkWell`** — the house rule (`KvRow`'s own note, D-277): this
          // language has no ripple.
          child: Semantics(
            container: true,
            button: true,
            toggled: open,
            label: KvSectionHeader.aboutLabel(_ReplyHead.label),
            onTap: _toggle,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTapDown: (_) => setState(() => _down = true),
              onTapCancel: () => setState(() => _down = false),
              onTapUp: (_) => setState(() => _down = false),
              onTap: _toggle,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The caption's pressed state — `chip` behind the words and their mark, the
/// pill's radius, reaching 12 dp past their ends and 6 dp above and below so
/// the words sit inside the tint rather than on its edge. Painted, not laid
/// out: the press must not move a pixel of the card.
class _PressTint extends CustomPainter {
  const _PressTint({required this.down});

  final bool down;

  @override
  void paint(Canvas canvas, Size size) {
    if (!down) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(
          -KvSpace.sm,
          -KvSpace.xs - 2,
          size.width + KvSpace.sm,
          size.height + KvSpace.xs + 2,
        ),
        const Radius.circular(KvRadius.control),
      ),
      Paint()..color = KvColor.chip,
    );
  }

  @override
  bool shouldRepaint(_PressTint old) => old.down != down;
}

/// A label and its reading. Mono and tabular on the value, because every value
/// on this screen is an identifier or a counter.
/// A value in the connection card's right column — `T5` puts every one of them
/// hard right, on the same edge, which is what makes three readings a table
/// rather than three sentences.
///
/// It is a `_CardValue` and not a bare [Text] for two reasons the render asks
/// for: the DAA row carries a live lamp beside its figure, and a dimmed reading
/// owes a visible age (BG-8). Both belong to the value, not to the row.
class _CardValue extends StatelessWidget {
  const _CardValue(this.text, {this.lamp, this.stale = false, this.age});

  /// The ramp this value is set at — named once, so the dim gate below and the
  /// style cannot drift (item 0 / L121).
  static const double figureSize = 13;

  final String text;

  /// `T5` draws a lamp beside the streaming DAA — sampled off the render, an
  /// `ok` disc inside its `okTint` ring, §4's `KvLamp` — the same fact the
  /// row's own label states in words, in a second channel (BG-7's
  /// redundancy). Null draws none.
  final KvLampTone? lamp;

  /// Dims to [KvFreshness.opacityStale] — dimmed cached truth beats a shimmer,
  /// and beats a confident number nobody can vouch for (BG-8).
  final bool stale;

  /// How old the reading is, in words. BG-8 requires this whenever [stale].
  final String? age;

  @override
  Widget build(BuildContext context) {
    assert(
      !stale || age != null,
      'A dimmed reading carries a visible age (BG-8) — dimming alone says '
      '"old" without saying how old, which is the half-truth the law names.',
    );
    // **A body-size reading does not dim** (BG-14 as narrowed by D-257).
    // `inkMeta` is 4.75:1 at full strength, so any multiply at all puts it under
    // the 4.5 body bar — 13 dp mono fell to **4.22** and the 12 dp age line to
    // **1.94**, destroying the very string BG-8 requires beside a dimmed
    // reading (`ux-auditor`, UX-R3). [KvFreshness.staleDimFloor] is WCAG's own
    // boundary between the body bar and the large-text bar, and `KvAmount`
    // already gates on it; this call site was ignoring both.
    //
    // Staleness is still carried, the ways BG-8 itself provides: the counter
    // **stops**, and the age is printed underneath.
    const dims = figureSize >= KvFreshness.staleDimFloor;
    return Opacity(
      opacity: stale && dims ? KvFreshness.opacityStale : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (lamp case final tone?) ...[
                // The plate's live dot, pinging while the chain is live
                // (BG-9). `const`, so a DAA tick re-running this row leaves
                // the dot and its ping untouched (`rebuild_scope_test`). The
                // mono digits' centre sits 0.2 dp from the line box's at
                // 13/18, so the row's own centring is already optical.
                tone == KvLampTone.ok
                    ? const KvLiveDot(live: true)
                    : const KvLiveDot(live: false),
                const SizedBox(width: KvSpace.s),
              ],
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: figureSize,
                    height: 18 / figureSize,
                    color: KvColor.ink,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          if (age != null) Text(age!, style: _ageLine),
        ],
      ),
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({
    required this.label,
    required this.value,
    this.numeric = true,
  });

  final String label;
  final String value;

  /// Is this reading a NUMBER or an identifier? Only those may not wrap
  /// (BG-14: *labels wrap or shrink, a number scales down and never
  /// truncates*), and everything else on this plate is a sentence.
  ///
  /// It exists because the collapse got it wrong: the scan line arrived from
  /// `NetworkSheet._DetailRow`, which set no `maxLines` and therefore wrapped,
  /// landed in a row that clips at one line, and read *"live — scanning every
  /// b"* at 320dp — with no ellipsis, and invisible to every test, because a
  /// clipped `Text` inside an `Expanded` raises no overflow (`ux-auditor`,
  /// measured: 27 characters at 0.60 em needs 210.6dp against 176dp).
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: KvSpace.xxl * 2,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 18 / 13,
                color: KvColor.inkMeta,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: numeric ? 1 : null,
              overflow: TextOverflow.clip,
              style: const TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 13,
                height: 18 / 13,
                color: KvColor.ink,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The node address, typed.
///
/// A bare [TextField] inside a control surface rather than an
/// [InputDecorator]: the decorator resolves `bodyLarge` and `labelStyle` from
/// the theme, which is a live divergence UX-6 owns — and a field this screen
/// can draw itself has no reason to wait for it. The **mono** face is right
/// here on its own merits: a node URL is an identifier to be compared
/// character by character, exactly like an address.
class _UrlField extends StatelessWidget {
  const _UrlField({
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
    // `T5` hints `host:port`; Rust refuses a URL without its scheme, and a hint
    // that would be refused is a trap — so the scheme is in the hint.
    this.hint = 'ws://host:port',
    this.label,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback? onSubmitted;

  /// The shape of the thing being asked for, shown in the empty field.
  final String hint;

  /// What this field is, when the section holds more than one of them. A
  /// screen with three URL boxes and no labels is a screen you have to guess
  /// at — and the guess costs the user their explorer link.
  final String? label;

  @override
  Widget build(BuildContext context) {
    // `T5`, measured: the field is a `chip` pill, 44 dp tall, with no edge —
    // the same surface as the `Test` pill beside it (founder on glass,
    // 2026-09-05: no borders).
    final field = KvSurface(
      tone: KvSurfaceTone.chip,
      radius: KvRadius.control,
      edge: Colors.transparent,
      height: _pillHeight,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
      child: TextField(
        controller: controller,
        enabled: enabled,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => onSubmitted?.call(),
        style: const TextStyle(
          fontFamily: KvFont.mono,
          fontSize: 13,
          height: 20 / 13,
          color: KvColor.ink,
        ),
        // **Every border named, and `filled: false`.** `border:
        // InputBorder.none` alone is not enough: `applyDefaults` merges
        // `filled`, `fillColor`, `enabledBorder` and `focusedBorder` from the
        // theme, and `InputDecorator` reaches for `enabledBorder` BEFORE it
        // ever consults `border` — so the field painted a `well` fill and a
        // 5dp-radius outline INSIDE its own pill, and a 1.5dp white rectangle
        // on focus (`ux-auditor`, this sitting). The surface around it is the
        // container; the field draws nothing.
        decoration: InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          hintText: hint,
          hintStyle: const TextStyle(
            fontFamily: KvFont.mono,
            fontSize: 13,
            height: 20 / 13,
            color: KvColor.inkMeta,
          ),
        ),
      ),
    );
    if (label == null) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label!,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 12,
            height: 17 / 12,
            color: KvColor.inkMeta,
          ),
        ),
        const SizedBox(height: KvSpace.xs),
        field,
      ],
    );
  }
}

/// What an endpoint can see, and what it can lie about — in plain words,
/// beside the row that points at it (BG-17; `ux-auditor` item 30).
///
/// **Not a disclosure string** the user is asked to accept: it is the sentence
/// that makes the switch beside it meaningful. A row naming only the class of
/// service ("an explorer", "a node") is what D-192 refused — *a departure you
/// cannot name is not one you consented to*.
class _TrustLabel extends StatelessWidget {
  const _TrustLabel(this.words, {this.figures = false});

  final String words;

  /// **Set its numerals in mono** (BG-30, §7.1: a number is checked, not
  /// read) — for an explanation that states thresholds, the reading's own
  /// (`60 ms`, `10 seconds`). Off by default: the trust lines' ages are words
  /// (BG-30's age clause), and a mono `7` inside *last update 7 s ago* would
  /// break the rule the other way.
  final bool figures;

  static const TextStyle _style = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 12,
    height: 17 / 12,
    // Information is colourless (BG-7), and 5.12:1 on the ground (`inkMeta`
    // on `abyss`, measured from the hexes — the 6.08 once written here was
    // never measured, `ux-auditor`) clears AA for a paragraph a user is
    // expected to actually read.
    color: KvColor.inkMeta,
  );

  @override
  Widget build(BuildContext context) {
    if (!figures) return Text(words, style: _style);
    return Text.rich(
      TextSpan(
        style: _style,
        children: [
          for (final run in RegExp(r'\d+|\D+').allMatches(words))
            TextSpan(
              text: run[0],
              style: run[0]!.contains(RegExp(r'\d'))
                  ? const TextStyle(
                      fontFamily: KvFont.mono,
                      fontFeatures: [FontFeature.tabularFigures()],
                    )
                  : null,
            ),
        ],
      ),
    );
  }
}

/// What a tested node answered — one sentence, its three figures in mono
/// (BG-30: a latency, a version and a score are figures, not speech).
typedef _NodeAnswer = ({int latencyMs, String version, BigInt daa});

class _TestAnswer extends StatelessWidget {
  const _TestAnswer(this.answer);

  final _NodeAnswer answer;

  @override
  Widget build(BuildContext context) {
    const words = TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 12,
      height: 17 / 12,
      color: KvColor.inkMeta,
    );
    const figure = TextStyle(
      fontFamily: KvFont.mono,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Text.rich(
      TextSpan(
        style: words,
        children: [
          const TextSpan(text: 'Answers in '),
          TextSpan(text: '${answer.latencyMs}', style: figure),
          const TextSpan(text: ' ms · synced and indexed · kaspad '),
          TextSpan(text: answer.version, style: figure),
          const TextSpan(text: ' · DAA '),
          TextSpan(text: formatScore(answer.daa), style: figure),
        ],
      ),
      // Node text is sanitized and capped in Rust; three lines is the most
      // an honest answer needs at the floor.
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A refusal, in the words the layer that refused used.
///
/// **Deliberately not a `KvStatusChip`.** Every chip carries a lamp, and BG-2
/// (as clarified at D-209) rations lamps to two per screen, never two saying
/// the same thing. This screen already spends both in its compound failure
/// state — the serving plate's status and the pin's refusal — so a lamped
/// chip on each of the two preference sections would have taken a bad moment
/// to four. Amber plus the words carries the meaning, which is all BG-7 asks:
/// every hue travels with words, and the words survive greyscale alone.
class _Fault extends StatelessWidget {
  const _Fault(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Text(
    words,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 12,
      height: 17 / 12,
      color: KvColor.warn,
    ),
  );
}

/// **`T5`'s node row**: the disc, *Connected to* over the host, and — when
/// the width allows it — the pill at the right. The serving plate measures
/// and decides; this only draws.
class _NodeRow extends StatelessWidget {
  const _NodeRow({
    required this.tone,
    required this.busy,
    required this.title,
    required this.endpoint,
    required this.trailing,
  });

  final KvLampTone tone;
  final bool busy;
  final String title;
  final String? endpoint;
  final Widget? trailing;

  static const TextStyle titleStyle = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 14,
    height: 20 / 15,
    fontWeight: FontWeight.w600,
    fontVariations: KvWeight.w600,
    color: KvColor.ink,
  );

  @override
  Widget build(BuildContext context) => Row(
    children: [
      // The disc is `network` — the drawer's own glyph for this destination,
      // so the row and the door that opens it wear one mark (BG-21/BG-25) —
      // in the link's own tone, which makes a dark link visible before a
      // word is read. While the link is being hunted the disc holds the
      // cadence instead: the app's one loading indicator, in the row's own
      // status seat (D-192 — motion means something is happening).
      _NodeDisc(tone: tone, busy: busy),
      const SizedBox(width: KvSpace.sm),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, softWrap: false, style: titleStyle),
            // **The endpoint is an identifier and never truncates** (BG-15's
            // reasoning, one layer over): whole, wrapping at its own `/`
            // (D-342). `T5` clips it with an ellipsis; the founder ruled the
            // whole address on glass.
            if (endpoint != null) _EndpointText(endpoint!),
          ],
        ),
      ),
      // Absent when the seam is not wired, rather than present and dead:
      // BG-12 forbids a disabled control with no stated reason, and "no
      // callback" is not a reason anyone can act on.
      if (trailing != null) ...[const SizedBox(width: KvSpace.s), trailing!],
    ],
  );
}

/// **The endpoint, whole, always** (the founder on glass, 2026-09-28, D-342:
/// *"i want 'Connected to' to always show full link of the wss thingy and no
/// compacting it with '…' in between anymore"*). It wraps at the URL's own
/// break points (after each `/`) under the title, beside the disc — the
/// resolver's endpoints carry a path (`wss://nina.kaspa.blue/kaspa/mainnet/
/// wrpc/borsh`), and folded to one line with a middle ellipsis the card read
/// as empty space around a fragment. It supersedes his 2026-09-05 ruling
/// (fold to one line, tap to open), and with it the fold's 52 dp target and
/// its width measurement: plain text takes no target and measures nothing.
///
/// 11 dp mono in `inkDim`, BG-14's floor, as before; an identifier never
/// truncates (BG-15's reasoning).
class _EndpointText extends StatelessWidget {
  const _EndpointText(this.endpoint);

  final String endpoint;

  static const TextStyle style = TextStyle(
    fontFamily: KvFont.mono,
    fontSize: 11,
    height: 16 / 11,
    color: KvColor.inkDim,
  );

  @override
  Widget build(BuildContext context) => Text(endpoint, style: style);
}

/// The node row's disc: `T5`'s 40 dp tint disc with the `network` glyph, in
/// the link's tone — and, while the link is being hunted, the cadence hill in
/// its place. One seat, two faces: a mark when there is a node, the app's one
/// loading indicator while there is not yet one (BG-20, D-192).
class _NodeDisc extends StatelessWidget {
  const _NodeDisc({required this.tone, required this.busy});

  final KvLampTone tone;

  /// Something is genuinely in flight — a hunt, or a dark link still trying.
  final bool busy;

  @override
  Widget build(BuildContext context) => Container(
    width: KvSpace.rowDisc,
    height: KvSpace.rowDisc,
    decoration: BoxDecoration(color: tone.ring, shape: BoxShape.circle),
    child: Center(
      child: busy
          ? KvCadence(running: true, tone: tone.color)
          : KvGlyphIcon(KvGlyph.network, tone: tone.color, size: 18),
    ),
  );
}

/// **`T5`'s compact chip pill** — `Switch node` at the node row's right and
/// `Test` beside the pin field, as the render draws both: a `chip`-filled pill
/// (26,33,32) about 44 dp tall with a 15/600 `ink` label and 12 dp of side
/// padding, measured. It sits in a 52 dp target (BG-12 permits the smaller
/// visual and requires the target) and presses to `chipPressed`, the raised
/// pill's own pressed tone. One class for both seats (item 33).
///
/// **Not a glow pill, and §4 is corrected rather than the picture.** §4's glow
/// pill row named *Switch node* as one of its seats; the render never drew it
/// that way — the transcription put it there. The glow pill keeps the hold and
/// the commit controls, which are the weighty actions it was specified for;
/// switching nodes behind a live link costs the user nothing (P0b), and the
/// render weighs it accordingly.
///
/// **Never disabled while hunting** — a tap mid-search IS C4's kick, and
/// greying the control out deletes that affordance exactly when the user most
/// wants it. Repeat taps are already harmless: `ChainService.reconnect()`
/// returns early while a dispatch is in flight. (This shipped correctly on the
/// network sheet, UX-2 dropped it when the action moved here, and it was found
/// on glass; the test that "proved" the swallow had codified the regression.)
/// The node screen's compact raised pill — `Search`, `Test`, and the `Use`
/// verb on a peer row.
///
/// **Not `KvAction.raised`, by ruling (UX-R8), after two deferrals.** It reads
/// as that part's compact register and is not one: `T5` measured it at 600
/// where `KvAction` sets its verb at 700, at 12 dp of side air where `KvAction`
/// takes 20 (`M2`), and its in-flight state — `Searching…` in `inkDim` on a
/// pill that stays filled and pressable — has no form in `KvAction`, whose
/// only dimmed state is the outlined *disabled* one. Folding it in either
/// re-tones a founder-signed screen in three measured ways or grows `KvAction`
/// a fourth form for one screen. It stays here, deliberately, and the register
/// (§27) carries the same sentence so the next sweep does not re-defer it.
class _ChipPill extends StatefulWidget {
  const _ChipPill({
    required this.label,
    required this.dim,
    required this.onTap,
  });

  final String label;

  /// The label steps down while the pill's action is already in flight —
  /// `Searching…`, `Testing…` — or has nothing to act on, without the control
  /// going dead. **`inkDim`, not `inkMeta`**: on `chip` the quieter tone is
  /// 4.30 and under the 4.5 body bar, and the in-flight word is information
  /// (`ux-auditor` BLOCK, item 20; `inkDim` on `chip` is 7.36).
  final bool dim;

  /// Null ⇒ nothing to do on a tap, and no haptic either: the phone must not
  /// confirm a state change that did not happen (§6, item 23). The reason is
  /// already on the page, in words, where the control that owns it sits.
  final VoidCallback? onTap;

  /// `T5`, measured: the `Test` pill runs 552.0 → 596.0 dp — **44 dp** —
  /// and the row's own pill reads the same height at the row's centre.
  static const double height = _pillHeight;

  /// The label's style, named once so the plate can measure the pill it is
  /// about to seat (item 0 / L121).
  static TextStyle style(bool dim) => TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 15,
    height: 20 / 15,
    fontWeight: FontWeight.w600,
    fontVariations: KvWeight.w600,
    color: dim ? KvColor.inkDim : KvColor.ink,
  );

  @override
  State<_ChipPill> createState() => _ChipPillState();
}

class _ChipPillState extends State<_ChipPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tap = widget.onTap;
    return Semantics(
      button: true,
      enabled: tap != null,
      label: widget.label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: tap == null
              ? null
              : (_) => setState(() => _pressed = true),
          onTapCancel: tap == null
              ? null
              : () => setState(() => _pressed = false),
          onTapUp: tap == null ? null : (_) => setState(() => _pressed = false),
          onTap: tap == null
              ? null
              : () {
                  KvHaptic.selection();
                  tap();
                },
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: KvSpace.touchTarget,
              minWidth: KvSpace.touchTarget,
            ),
            child: Center(
              child: AnimatedContainer(
                duration: KvMotion.fast,
                curve: KvMotion.curve,
                constraints: const BoxConstraints(minHeight: _ChipPill.height),
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
                decoration: BoxDecoration(
                  color: _pressed ? KvColor.chipPressed : KvColor.chip,
                  borderRadius: BorderRadius.circular(KvRadius.control),
                ),
                child: Center(
                  // **No meter here.** The disc at the row's left already runs
                  // the cadence for this exact fact, and BG-2 counts emitting
                  // objects. The label swapping to `Searching…` is the signal,
                  // and it says more than a meter can.
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    softWrap: false,
                    style: _ChipPill.style(widget.dim),
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
