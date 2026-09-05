import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/rate_service.dart' show KvRateQuote;
import '../error_text.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_cadence.dart';
import '../widgets/kv_check.dart';
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
    this.blockAgeSecs,
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

  /// Seconds since the node last handed us a block, polled while this screen
  /// is open — the transport scan's own freshness.
  ///
  /// **Carried across from `NetworkSheet` when UX-3 collapsed the two
  /// surfaces**, and it is the one thing that sheet rendered and this screen
  /// did not. Dropping it would have made the sovereign path the poorer one
  /// (D-207 clause c): a user who came here to understand their link would
  /// have lost the most precise liveness signal the app has by the surface
  /// being merged rather than by anyone deciding to remove it.
  final Future<int?> Function()? blockAgeSecs;

  /// **One honest round trip, the node's own word on its sync, and — when
  /// asked — its peer count**, polled while this screen is open (`T5`'s
  /// connection card).
  ///
  /// A pull rather than a stream, and on the screen's own cadence, for the
  /// same reason [blockAgeSecs] is: it costs real RPC calls, and the money
  /// screen's link tick must not start paying for a card it never draws. The
  /// caller says whether it wants the peer count this time — that number
  /// changes over minutes where a latency changes over seconds, so it is asked
  /// for one tick in [_NodeScreenState.peersEvery].
  ///
  /// Null ⇒ the seam is not wired, and the card renders the readings as absent
  /// rather than as zeros (BG-8). A widget test gets exactly that.
  final Future<({int? latencyMs, int? peers, bool? synced})> Function({
    required bool peers,
  })?
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

  @override
  State<NodeScreen> createState() => _NodeScreenState();
}

class _NodeScreenState extends State<NodeScreen> {
  final TextEditingController _url = TextEditingController();

  /// **The two explainers' open state** — the founder's circled-i beside a
  /// section's caps label (2026-09-05): tapping it eases the section's
  /// explainer in beneath its card and pushes what follows down; tapping again,
  /// leaving the screen, or a route arriving over it closes it.
  final ValueNotifier<bool> _nodeInfo = ValueNotifier(false);
  final ValueNotifier<bool> _sourcesInfo = ValueNotifier(false);

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
  /// The scan's freshness carries whether a poll has ever landed, because
  /// "0 s since the last block" and "we have never been told" are different
  /// sentences (the retired sheet's own `_haveStatus` distinction).
  final ValueNotifier<({bool have, int? secs})> _scan = ValueNotifier((
    have: false,
    secs: null,
  ));

  /// `T5`'s latency — smoothed and tiered by [KvLatencyReading] — the node's
  /// own word on whether it is synced, and its peer count. Each is *no
  /// reading* until a probe actually answers: never a zero, and never the
  /// last good number still standing after the link died (BG-8).
  final ValueNotifier<KvLatencyReading> _latency = ValueNotifier(
    const KvLatencyReading.none(),
  );
  final ValueNotifier<bool?> _synced = ValueNotifier(null);
  final ValueNotifier<int?> _peers = ValueNotifier(null);

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

  /// The poll's cadence (the retired sheet's 2 s, unchanged), and how many
  /// ticks apart the peer count is asked for.
  static const Duration pollEvery = Duration(seconds: 2);
  static const int peersEvery = 5;

  /// **One probe in flight at a time** (`consensus-auditor`, UX-R3).
  ///
  /// Without it a stalled node stacked a probe every 2 s, and two overlapping
  /// ones could land out of order — an older slow reading overwriting a newer
  /// fast one through last-writer-wins, which is exactly the
  /// confidently-wrong-number the probe exists to prevent (BG-8). Rust carries
  /// its own deadline under the cadence as well, so this is belt AND braces on
  /// a reading a user reads as *how far away is this node*.
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _seeded = widget.scope.pinnedNode.value ?? '';
    _url.text = _seeded;
    _wantPin = widget.scope.pinnedNode.value != null;
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
    _lifecycle.dispose();
    _visible?.removeListener(_gate);
    _poll?.cancel();
    _scan.dispose();
    _test.dispose();
    _explorerChoice.dispose();
    _nodeInfo.dispose();
    _sourcesInfo.dispose();
    _latency.dispose();
    _synced.dispose();
    _peers.dispose();
    _now.dispose();
    _url.dispose();
    super.dispose();
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
  }

  /// Absent seams ⇒ no poll and no line, never a fabricated reading. A start
  /// ticks at once — a returning user is looking at the glass NOW — and the
  /// first tick asks for everything, peers included.
  void _start() {
    if (_poll != null) return;
    if (widget.scope.blockAgeSecs == null && widget.scope.probeLink == null) {
      return;
    }
    _tick(first: true);
    _poll = Timer.periodic(pollEvery, (_) => _tick());
  }

  void _stop() {
    _poll?.cancel();
    _poll = null;
  }

  void _tick({bool first = false}) {
    _ticks++;
    _now.value = widget.clock();
    unawaited(_refreshScan());
    unawaited(_refreshProbe(peers: first || _ticks % peersEvery == 0));
  }

  /// **The link probe, on the screen's own cadence.**
  ///
  /// A failed probe **clears** the readings rather than leaving the last good
  /// set standing — the opposite of what [_refreshScan] does with the block
  /// age, and deliberately so. A block age that stops advancing is itself the
  /// signal, and the line says how old it is; a latency is a measurement of
  /// *this* round trip, so a stale 42 ms beside a dead socket would be a
  /// confident wrong number rather than an old true one (BG-8, and the P0.3
  /// scar in its original shape). The smoothing in [KvLatencyReading] never
  /// becomes holding for the same reason: a `null` empties its window.
  Future<void> _refreshProbe({required bool peers}) async {
    final probe = widget.scope.probeLink;
    if (probe == null || _probing) return;
    _probing = true;
    try {
      final reading = await probe(peers: peers);
      if (!mounted) return;
      _latency.value = _latency.value.offer(reading.latencyMs);
      _synced.value = reading.synced;
      // Not asked for this tick ⇒ the last answer stands; asked and absent ⇒
      // the dash. The seam's `null` means both, and only this side knows which.
      if (peers) _peers.value = reading.peers;
    } catch (_) {
      if (!mounted) return;
      _latency.value = const KvLatencyReading.none();
      _synced.value = null;
      _peers.value = null;
    } finally {
      _probing = false;
    }
  }

  Future<void> _refreshScan() async {
    final read = widget.scope.blockAgeSecs;
    if (read == null) return;
    try {
      final age = await read();
      if (!mounted) return;
      _scan.value = (have: true, secs: age);
    } catch (_) {
      // A failed pull leaves the last-known age standing; never crash the
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
                    KvSpace.l,
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
  /// the next, and nothing under the last row. Four regions, four listeners —
  /// the instrument hears the probe and the link; the chain clock hears the
  /// score, the link, the scan and the poll clock; the transport line hears
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
          child: ListenableBuilder(
            listenable: Listenable.merge([_latency, s.connected]),
            builder: (context, _) {
              // **A latency reading belongs to a live socket, and only to
              // one.** The probe clears itself on a failure, but the poll runs
              // at 2 s while the notifiers are pushed — so a socket that
              // dropped a moment ago could still be holding the last good
              // number for one tick. Gating on `connected` closes that window.
              final reading = s.connected.value
                  ? _latency.value
                  : const KvLatencyReading.none();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // A `Wrap`, not a `Row` (L160): at 320 dp / 1.3× the flex
                  // broke `CONNECTION` mid-word; the tier word drops to its
                  // own line instead.
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: KvSpace.s,
                    runSpacing: KvSpace.xs,
                    children: [
                      const KvRuledLabel(
                        'Connection',
                        tight: true,
                        rule: false,
                      ),
                      KvLatencyWord(
                        milliseconds: reading.milliseconds,
                        tier: reading.tier,
                      ),
                    ],
                  ),
                  const SizedBox(height: KvSpace.s),
                  KvLatency(
                    milliseconds: reading.milliseconds,
                    tier: reading.tier,
                  ),
                ],
              );
            },
          ),
        ),
        // BG-8, all three states. `ChainService` deliberately KEEPS the
        // last-known score when a dropped link emits nulls — which is only
        // honest if the screen dims it and says how old it is. **Streamed,
        // not stepped** (BG-18 / D-226). In a layer of its own: the count
        // paints every frame of a crossing. **The scan's freshness rides the
        // label** (founder on glass, 2026-09-05 — the separate *Transport
        // scan* line is gone): `streaming` while blocks are landing, the
        // block age when they are not, `syncing` when the node says so.
        RepaintBoundary(
          child: ListenableBuilder(
            listenable: Listenable.merge([
              s.connected,
              s.virtualDaaScore,
              s.lastUpdate,
              _now,
              _synced,
              _scan,
              if (s.searching != null) s.searching!,
              if (s.reconnecting != null) s.reconnecting!,
              if (s.osOffline != null) s.osOffline!,
            ]),
            builder: (context, _) {
              final connected = s.connected.value;
              final syncing = connected && _synced.value == false;
              final scan = _scan.value;
              final age = scan.secs;
              final quiet = connected && scan.have && age != null && age > 5;
              // *Streaming* is the strongest claim on this screen (C7): it is
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
              final label = !connected
                  ? 'DAA'
                  : syncing
                  ? 'DAA · syncing'
                  : aged
                  ? 'DAA · $age s since last block'
                  : settledLink
                  ? 'DAA · streaming'
                  : 'DAA';
              return KvStreamingCount(
                value: s.virtualDaaScore.value,
                stalled: !connected,
                builder: (context, shown) => row(
                  label,
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
                        : (syncing || quiet)
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
  /// **The switch governs the field** (his second finding): off, the field and
  /// `Test` are disabled and the field's hint says why; on, the field takes a
  /// node and `Test` can dial it. **The commit is a standard pill** — `KvAction
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
                        'Check the address below and set it again.',
                  ),
                ],
                const SizedBox(height: KvSpace.sm),
                // **`T5`: the field with `Test` beside it** — measured, both
                // 44 dp tall with a 10 dp gap, the pill in `chip`. Off, the
                // field's hint is the reason it is disabled (BG-12).
                Row(
                  children: [
                    Expanded(
                      child: _UrlField(
                        controller: _url,
                        enabled: on && !_busy,
                        // **The address shape, whether it is on or off**
                        // (founder on glass, 2026-09-05): a hint that says what
                        // to type teaches the form, where one saying the control
                        // is off repeats what the toggle beside it already
                        // shows. `wss://`, the scheme a public node speaks —
                        // Rust takes either, and this is the one to encourage.
                        hint: 'wss://host:port',
                        onSubmitted: canApply ? () => _apply(typed) : null,
                      ),
                    ),
                    if (s.testNode != null) ...[
                      const SizedBox(width: KvSpace.s10),
                      _ChipPill(
                        label: test.busy ? 'Testing…' : 'Test',
                        dim: !canTest,
                        // Nothing to dial: no tap and no haptic.
                        onTap: canTest ? () => unawaited(_runTest()) : null,
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
                // The commit, while the switch is on: disabled with its reason
                // until there is a change, enabled when there is (BG-12).
                if (on) ...[
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

/// **A caps label with the founder's circled-i** (2026-09-05). The mark is
/// `primaryMuted` while its explainer is open — *ours*, uncounted (playbook
/// §5) — and `inkMeta` at rest; the target is 44 dp (BG-12's icon button
/// target) around a 16 dp glyph.
/// **An explainer that eases in beneath its card** (founder, 2026-09-05):
/// closed it takes no room; open it pushes what follows down over `enter`
/// and fades in — motion that accounts for where the text came from (BG-24).
class _Explainer extends StatelessWidget {
  const _Explainer({required this.open, required this.text});

  final ValueNotifier<bool> open;
  final String text;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: open,
    builder: (context, on, _) => AnimatedSize(
      duration: KvMotion.enter,
      curve: KvMotion.curve,
      alignment: Alignment.topCenter,
      child: on
          ? Padding(
              padding: const EdgeInsets.only(top: KvSpace.sm),
              child: AnimatedOpacity(
                opacity: 1,
                duration: KvMotion.enter,
                curve: KvMotion.curve,
                child: _TrustLabel(text),
              ),
            )
          : const SizedBox(width: double.infinity),
    ),
  );
}

/// **The playbook's ceremony truths card, holding choices** (§3.4, §8): a
/// `chip` inner card at radius 22 with hairlines between rows, and the one
/// current choice wearing `KvCheck` — a status is a check, never a tinted row
/// (§6). Sub-lines are `inkDim`, because `inkMeta` fails AA on `chip` (BG-14).
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: KvColor.chip,
      borderRadius: BorderRadius.circular(KvRadius.bubble),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            const SizedBox(
              height: 1,
              child: ColoredBox(color: KvColor.hairline),
            ),
          children[i],
        ],
      ],
    ),
  );
}

/// One choice: a title, an optional line beneath, and the check when it is the
/// current one. A 56 dp row (BG-12).
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    this.sub,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String? sub;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: sub == null ? title : '$title. $sub',
    child: ExcludeSemantics(
      child: InkWell(
        onTap: onTap,
        highlightColor: KvColor.chipPressed,
        splashFactory: NoSplash.splashFactory,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: KvSpace.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: KvSpace.m,
              vertical: KvSpace.s10,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
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
                      if (sub case final sub?)
                        Text(
                          sub,
                          style: const TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 12,
                            height: 17 / 12,
                            color: KvColor.inkDim,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: KvSpace.sm),
                if (selected)
                  const KvCheck()
                else
                  const SizedBox(width: KvCheck.small, height: KvCheck.small),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

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
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
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
            _ChoiceCard(
              children: [
                for (var i = 0; i < widget.current.defaults.length; i++)
                  _ChoiceRow(
                    title: widget.current.defaults[i].name,
                    selected: _selected == i,
                    onTap: _busy ? null : () => setState(() => _selected = i),
                  ),
                _ChoiceRow(
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
            padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
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
                  _ChoiceCard(
                    children: [
                      _ChoiceRow(
                        title: 'Off',
                        sub:
                            'Your balance is shown in KAS only. Nothing is fetched.',
                        selected: choice == _RateChoice.off,
                        onTap: _busy
                            ? null
                            : () => setState(() => _choice = _RateChoice.off),
                      ),
                      _ChoiceRow(
                        title: _hostOf(scope.defaultEndpoint.value),
                        sub: 'The shipped price source',
                        selected: choice == _RateChoice.shipped,
                        onTap: _busy
                            ? null
                            : () =>
                                  setState(() => _choice = _RateChoice.shipped),
                      ),
                      _ChoiceRow(
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
        highlightColor: KvColor.keyPressed,
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
                KvLamp(tone),
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
          if (age != null)
            Text(
              age!,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 12,
                height: 17 / 12,
                color: KvColor.inkMeta,
              ),
            ),
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
  const _TrustLabel(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Text(
    words,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 12,
      height: 17 / 12,
      // Information is colourless (BG-7), and 6.08:1 on the ground clears AA
      // for a paragraph a user is expected to actually read.
      color: KvColor.inkMeta,
    ),
  );
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
            // **The host is an identifier and never truncates to nothing**
            // (BG-15's reasoning, one layer over): it wraps to a second line
            // rather than losing its tail. `T5` clips it with an ellipsis at
            // the reference width; two lines at the floor is the honest
            // version of the same picture.
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

/// **The endpoint on one line, and a tap opens it** (founder on glass,
/// 2026-09-05: *"20% smaller so the whole text can show in one line, but if
/// it breaks the link should be minimized with a '…' continuation that
/// maximizes if user taps"*). 11 dp mono — 20 % under the row's 13, landing
/// on BG-14's floor — so all but the longest addresses stand whole.
///
/// **Where it will not fit, the MIDDLE goes** (BG-15's reasoning, the same
/// one `KvAddress` follows): a tail ellipsis eats `:17110` and the
/// distinguishing subdomain, which is the half that tells two nodes apart.
/// The split is measured against the width actually given, never guessed.
///
/// **And only then is it a control** — a folded line is a 52 dp target
/// (BG-12; `KvExplorerExit`'s own 34 dp scar is why this is not left at the
/// line's 16), with its own semantics node; a line that fits is plain text
/// and takes no target at all, which is what keeps the card compact in the
/// ordinary case.
class _EndpointText extends StatefulWidget {
  const _EndpointText(this.endpoint);

  final String endpoint;

  static const TextStyle style = TextStyle(
    fontFamily: KvFont.mono,
    fontSize: 11,
    height: 16 / 11,
    color: KvColor.inkDim,
  );

  @override
  State<_EndpointText> createState() => _EndpointTextState();
}

class _EndpointTextState extends State<_EndpointText> {
  bool _open = false;

  /// The widest head…tail that fits [width], or null when the whole string
  /// does. Measured with the same painter that lays the line out.
  static String? _folded(String text, double width, TextScaler scaler) {
    double widthOf(String s) {
      final p = TextPainter(
        text: TextSpan(text: s, style: _EndpointText.style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    if (widthOf(text) <= width) return null;
    // Keep the tail — the port and the distinguishing label — and give the
    // head whatever is left. A binary search, so the measurement runs a
    // handful of times rather than once per character.
    var lo = 0;
    var hi = text.length;
    var best = '…${text.substring(text.length - 1)}';
    while (lo <= hi) {
      final keep = (lo + hi) ~/ 2;
      if (keep * 2 >= text.length) {
        hi = keep - 1;
        continue;
      }
      final candidate =
          '${text.substring(0, keep)}…${text.substring(text.length - keep)}';
      if (widthOf(candidate) <= width) {
        best = candidate;
        lo = keep + 1;
      } else {
        hi = keep - 1;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final folded = _folded(widget.endpoint, constraints.maxWidth, scaler);
        if (folded == null) {
          return Text(widget.endpoint, maxLines: 1, style: _EndpointText.style);
        }
        final text = Text(
          _open ? widget.endpoint : folded,
          maxLines: _open ? null : 1,
          style: _EndpointText.style,
        );
        return Semantics(
          container: true,
          button: true,
          expanded: _open,
          label: _open ? 'Fold the address' : 'Show the whole address',
          child: ExcludeSemantics(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _open = !_open),
              child: AnimatedSize(
                duration: KvMotion.fast,
                curve: KvMotion.out,
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: KvSpace.touchTarget,
                  ),
                  child: Align(alignment: Alignment.centerLeft, child: text),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
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
