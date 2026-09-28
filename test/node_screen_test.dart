import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/services/rate_service.dart' show KvRateQuote;
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/node/node_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_cadence.dart';
import 'package:kaspaverse/src/ui/widgets/kv_check.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/widgets/kv_fact_line.dart';
import 'package:kaspaverse/src/ui/widgets/kv_latency.dart';
import 'package:kaspaverse/src/ui/widgets/kv_rows.dart';
import 'package:kaspaverse/src/ui/widgets/kv_live_dot.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';
import 'support/maturity.dart';
import 'package:kaspaverse/src/ui/widgets/kv_sheet.dart';

/// A stand-in for `ChainService`'s node seam. Nothing here talks to Rust; the
/// screen's whole contract is these notifiers and this one call.
class _FakeSeam {
  _FakeSeam({String? pinned, bool connected = true, this.throws})
    : pinnedNode = ValueNotifier<String?>(pinned),
      connected = ValueNotifier<bool>(connected);

  final ValueNotifier<String?> pinnedNode;
  final ValueNotifier<bool> connected;
  final ValueNotifier<String?> activeEndpoint = ValueNotifier<String?>(
    'ws://public-1.kaspa.example:17110',
  );
  final ValueNotifier<BigInt?> daa = ValueNotifier<BigInt?>(
    BigInt.from(523216421),
  );
  final ValueNotifier<bool> pinDropped = ValueNotifier<bool>(false);
  final ValueNotifier<bool> searching = ValueNotifier<bool>(false);
  final ValueNotifier<bool> osOffline = ValueNotifier<bool>(false);
  final ValueNotifier<bool> reconnecting = ValueNotifier<bool>(false);
  final ValueNotifier<DateTime?> lastUpdate = ValueNotifier<DateTime?>(
    DateTime(2026, 8, 27, 11, 57),
  );

  final List<String?> calls = <String?>[];
  int refreshes = 0;
  int kicks = 0;

  /// Mirrors `ChainService.reconnect`, which flips `reconnecting`
  /// synchronously before its first await (proven in `chain_service_test`) —
  /// so a test that watches the label measures the RENDER, not the fake.
  Future<void> reconnect() async {
    kicks++;
    reconnecting.value = true;
  }

  /// Holds `setPinnedNode` open, so a test can measure the BUSY frame rather
  /// than the settled one after it.
  Completer<void>? hold;

  /// When set, `setPinnedNode` throws it. [pinsAnyway] models the seam's real
  /// behaviour: a validated URL is persisted and applied BEFORE the first dial,
  /// so a throw can mean "the pin is live and the dial failed".
  final Object? throws;
  bool pinsAnyway = false;

  Future<void> setPinnedNode(String? url) async {
    calls.add(url);
    if (hold != null) await hold!.future;
    if (throws != null) {
      if (pinsAnyway) pinnedNode.value = url;
      throw throws!;
    }
    pinnedNode.value = url;
  }

  /// Runs inside `refreshConfig`, so a test can model Rust returning a
  /// different pin from the one the notifier was carrying.
  void Function()? onRefresh;

  Future<void> refresh() async {
    refreshes++;
    onRefresh?.call();
  }

  NodeScope get scope => scopeWith();

  /// The same scope, optionally carrying the block-age poll the collapse
  /// brought over from the retired sheet.
  /// `T5`'s probe, faked. `null` on either field is BG-8's absent reading;
  /// [probeThrows] models a node that stopped answering mid-poll.
  int? latencyMs;
  int? peers;
  bool probeThrows = false;
  int probes = 0;

  /// A round trip that outlasted the socket's deadline (D-333): the probe
  /// answers "at least this", not nothing.
  int? timedOutMs;

  /// The node's own word on its sync, as the probe reports it.
  bool? synced = true;

  /// Which ticks asked for the peer count, in order.
  final List<bool> peerAsks = <bool>[];

  /// Holds each probe in flight until completed — for a probe that is still
  /// out when the node it asked is forgotten.
  Completer<void>? gate;

  Future<({int? latencyMs, int? timedOutMs, int? peers, bool? synced})> probe({
    required bool peers,
  }) async {
    probes++;
    peerAsks.add(peers);
    if (gate case final held?) await held.future;
    if (probeThrows) throw StateError('the node went away');
    // **Rust refuses a probe with no socket** — `DagMonitor::probe_link`
    // (`dag_monitor.rs`) answers the typed no-socket error at once, both
    // fields empty, which the screen counts as a refusal — so the fake does
    // too: a fake that answered while dark let a poll during a drop's fade
    // land a reading on the node the drop had just forgotten, a failure the
    // real seam cannot produce.
    if (!connected.value) throw StateError('no socket');
    return (
      latencyMs: latencyMs,
      timedOutMs: timedOutMs,
      peers: peers ? this.peers : null,
      synced: synced,
    );
  }

  /// `T5`'s `Test`, faked: what a passing node answers, or the refusal Rust
  /// would throw. The URLs tested land in [tests].
  ({int latencyMs, String serverVersion, BigInt daa})? testAnswer;
  Object? testRefuse;
  final List<String> tests = <String>[];

  Future<({int latencyMs, String serverVersion, BigInt daa})> testNode(
    String url,
  ) async {
    tests.add(url);
    if (testRefuse != null) throw testRefuse!;
    return testAnswer ??
        (latencyMs: 84, serverVersion: '1.0.1', daa: BigInt.from(528980542));
  }

  NodeScope scopeWith({
    Future<({int? ageSecs, int? score})> Function()? tickPulse,
    ({double bps, Duration span})? Function()? paceAverage,
    bool withProbe = false,
    bool withTest = false,
  }) => NodeScope(
    connected: connected,
    activeEndpoint: activeEndpoint,
    virtualDaaScore: daa,
    pinnedNode: pinnedNode,
    pinDropped: pinDropped,
    setPinnedNode: setPinnedNode,
    searching: searching,
    osOffline: osOffline,
    reconnecting: reconnecting,
    onReconnect: reconnect,
    lastUpdate: lastUpdate,
    refreshConfig: refresh,
    tickPulse: tickPulse,
    paceAverage: paceAverage,
    probeLink: withProbe ? probe : null,
    testNode: withTest ? testNode : null,
  );
}

/// The explorer choice, faked. Rust validates and persists in the real thing;
/// here the write either records or refuses, which is the only shape the
/// screen has to be right about.
class _FakeExplorer {
  _FakeExplorer({this.refuse});

  static const kaspaOrg = ExplorerOption(
    name: 'explorer.kaspa.org',
    txTemplate: 'https://explorer.kaspa.org/txs/{txid}',
    addressTemplate: 'https://explorer.kaspa.org/addresses/{address}',
  );
  static const kaspaStream = ExplorerOption(
    name: 'kaspa.stream',
    txTemplate: 'https://kaspa.stream/transactions/{txid}',
    addressTemplate: 'https://kaspa.stream/addresses/{address}',
  );

  /// The refusal Rust would raise, or null to accept.
  final Object? refuse;

  String tx = kaspaOrg.txTemplate;
  String address = kaspaOrg.addressTemplate;
  final List<(String, String)> writes = <(String, String)>[];
  int reads = 0;

  ExplorerScope get scope => ExplorerScope(
    read: () async {
      reads++;
      return ExplorerChoice(
        txTemplate: tx,
        addressTemplate: address,
        defaults: const [kaspaOrg, kaspaStream],
      );
    },
    write: (t, a) async {
      writes.add((t, a));
      if (refuse != null) throw refuse!;
      tx = t;
      address = a;
    },
  );
}

/// The price source, faked at the same seam `RateService` presents.
class _FakeRate {
  _FakeRate({bool on = true, KvRateQuote? quote, this.refuse})
    : enabled = ValueNotifier<bool?>(on),
      quote = ValueNotifier<KvRateQuote?>(quote);

  final ValueNotifier<bool?> enabled;
  final ValueNotifier<KvRateQuote?> quote;
  final ValueNotifier<String> endpoint = ValueNotifier<String>(
    'https://api.kaspa.org/info/price',
  );
  final ValueNotifier<String> fallback = ValueNotifier<String>(
    'https://api.kaspa.org/info/price',
  );
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);
  final Object? refuse;

  final List<(bool, String)> writes = <(bool, String)>[];
  int loads = 0;

  RateScope get scope => RateScope(
    enabled: enabled,
    endpoint: endpoint,
    defaultEndpoint: fallback,
    quote: quote,
    error: error,
    load: () async => loads++,
    setConfig: ({required bool enabled, required String endpoint}) async {
      writes.add((enabled, endpoint));
      if (refuse != null) throw refuse!;
      this.enabled.value = enabled;
      this.endpoint.value = endpoint;
      if (!enabled) quote.value = null;
    },
  );
}

/// **The poll runs only while the screen can be seen** (UX-R3, second beat).
/// The first cut's `Timer.periodic` kept two real RPC calls going every two
/// seconds with the app in the background and with another route covering
/// this one.
void pollLifecycleTests() {
  group('the poll runs only while the screen can be seen', () {
    testWidgets('backgrounded it stops asking; resumed it asks at once', (
      tester,
    ) async {
      final seam = _FakeSeam()
        ..latencyMs = 80
        ..peers = 9;
      await _pumpScreen(tester, seam, withProbe: true, settle: false);
      await tester.pump();
      expect(seam.probes, 1, reason: 'the open ticks at once');
      await tester.pump(NodeScreen.pollEvery);
      expect(seam.probes, 2, reason: 'and again one period later (D-332)');

      // The binding only accepts the transitions the OS makes: resumed →
      // inactive → hidden → paused, and back the same way.
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(
        seam.probes,
        2,
        reason: 'nothing while the app is in the background',
      );

      for (final state in const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(
        seam.probes,
        3,
        reason: 'a returning user is looking at the glass NOW',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('covered by another route it stops; uncovered it resumes', (
      tester,
    ) async {
      final seam = _FakeSeam()..latencyMs = 80;
      await _pumpScreen(tester, seam, withProbe: true, settle: false);
      await tester.pump();
      expect(seam.probes, 1);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox()),
        ),
      );
      // Pumped by hand. The route's own transition is well inside 400 ms —
      // and at two polls a second (D-332) one may land while the new route is
      // still sliding over a screen that is still visible, which is the gate
      // doing its job. Count from the moment the route has covered it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final covered = seam.probes;
      await tester.pump(const Duration(seconds: 6));
      expect(
        seam.probes,
        covered,
        reason: 'a covered screen asks the node for nothing',
      );

      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        seam.probes,
        greaterThan(covered),
        reason: 'and asks the moment it is back',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'the peer count is asked for on the first tick and every ten seconds',
      (tester) async {
        final seam = _FakeSeam()
          ..latencyMs = 80
          ..peers = 9;
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        for (var i = 0; i < 2 * NodeScreen.peersEvery - 1; i++) {
          await tester.pump(NodeScreen.pollEvery);
        }
        // Twice a second for the latency (D-332), still every ten seconds for
        // a number that changes over minutes.
        expect(
          NodeScreen.pollEvery * NodeScreen.peersEvery,
          const Duration(seconds: 10),
        );
        expect(seam.peerAsks, [
          for (var tick = 1; tick <= 2 * NodeScreen.peersEvery; tick++)
            tick == 1 || tick % NodeScreen.peersEvery == 0,
        ]);
        // Between asks the last answer stands — a number that was not asked
        // for is not a number that went missing.
        expect(find.text('9'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('`T5` — `Test`, the render\'s own affordance', () {
    testWidgets('it dials the typed node and says what answered', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam, withTest: true);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ws://mine.local:17110');
      await tester.pumpAndSettle();
      expect(find.text('Test'), findsOneWidget);
      await tester.tap(find.text('Test'));
      await tester.pumpAndSettle();
      // The URL reaches the seam verbatim; Rust validates it, never Dart.
      expect(seam.tests, ['ws://mine.local:17110']);
      // A rich run — the three figures in mono (BG-30) — so it is read back
      // as plain text.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              (w.textSpan?.toPlainText() ?? '') ==
                  'Answers in 84 ms · synced and indexed · kaspad 1.0.1 · '
                      'DAA 528,980,542',
        ),
        findsOneWidget,
      );
      // A test is not a pin: nothing was committed.
      expect(seam.calls, isEmpty);
    });

    testWidgets('a node the probe refuses says why, in amber', (tester) async {
      final seam = _FakeSeam()
        ..testRefuse = StateError('probe ws://mine.local:17110: not synced');
      await _pumpScreen(tester, seam, withTest: true);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ws://mine.local:17110');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not synced'), findsOneWidget);
      expect(find.textContaining('Answers in'), findsNothing);
    });

    testWidgets('with nothing typed it dials nothing — the reason is already '
        'on the glass, once', (tester) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam, withTest: true);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test'));
      await tester.pumpAndSettle();
      expect(seam.tests, isEmpty);
      // The commit is on the page, disabled, saying why — once (BG-12/BG-19).
      expect(find.text('Type the address of your node first.'), findsOneWidget);
    });

    testWidgets('without the seam there is no pill', (tester) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      expect(find.text('Test'), findsNothing);
    });
  });

  group('`T5` — the node row, second beat', () {
    testWidgets(
      'a node that says it is not synced is a warning on a live link',
      (tester) async {
        final seam = _FakeSeam()
          ..latencyMs = 80
          ..synced = false;
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        await tester.pump();
        expect(find.text('Connected to'), findsOneWidget);
        expect(find.textContaining('still syncing'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '`Switch node` is the render\'s compact pill in a 52 dp target',
      (tester) async {
        final seam = _FakeSeam();
        await _pumpScreen(tester, seam);
        final pill = find.text('Switch node');
        expect(pill, findsOneWidget);
        // BG-12: the target, whatever the visual measures.
        final target = find
            .ancestor(of: pill, matching: find.byType(GestureDetector))
            .first;
        expect(
          tester.getSize(target).height,
          greaterThanOrEqualTo(KvSpace.touchTarget),
        );
        expect(
          tester.getSize(target).width,
          greaterThanOrEqualTo(KvSpace.touchTarget),
        );
        // The visual: `T5`'s `chip`-filled pill, measured at 44 and drawn at
        // **40** since the compact density (D-278) — the target above stays
        // 52, because BG-12 does not scale with a density.
        final visual = find
            .ancestor(of: pill, matching: find.byType(AnimatedContainer))
            .first;
        expect(tester.getSize(visual).height, closeTo(_pillHeight, 1));
        final box = tester.widget<AnimatedContainer>(visual);
        expect((box.decoration! as BoxDecoration).color, KvColor.chip);
        // And the endpoint stands beside it with its scheme and its port
        // (D-277: 11 dp, the middle folded away where the seat is narrow —
        // never the tail, which is what tells two nodes apart).
        expect(_endpointRun(tester), startsWith('ws://'));
        expect(_endpointRun(tester), endsWith(':17110'));
      },
    );

    testWidgets(
      'while hunting, the disc holds the cadence and the pill says so',
      (tester) async {
        final seam = _FakeSeam(connected: false);
        seam.searching.value = true;
        await _pumpScreen(tester, seam, settle: false);
        expect(find.text('Searching…'), findsOneWidget);
        expect(_cadenceRunning(tester), isTrue);
        expect(
          find.byType(KvCadence).evaluate().length,
          1,
          reason: 'one loading indicator, in the row\'s own status seat',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _FakeSeam seam, {
  _FakeExplorer? explorer,
  _FakeRate? rate,
  Future<({int? ageSecs, int? score})> Function()? pulse,
  ({double bps, Duration span})? Function()? paceAverage,
  bool withProbe = false,
  bool withTest = false,
  // `T5`'s SOURCES rows open their controls in a sheet; a test about one
  // names it and the harness opens it.
  String? source,
  double width = 393,
  // The screen grew two preference sections at UX-3, and a `ListView` only
  // builds what a viewport can reach. A test about the explorer needs the
  // explorer laid out; a test about the plate keeps the phone's own height.
  double height = 800,
  double textScale = 1,
  // A dark link is a link being hunted, so the cadence runs and "settled"
  // never arrives — which is the meter doing its job, not a test problem.
  bool settle = true,
  // The screen's clock. Fixed by default so an age reads the same on every
  // run; a test about a RATE passes the fake-async clock, which advances.
  DateTime Function()? clock,
}) async {
  // No reading may leak from one test's screen into the next one's first frame.
  NodeScreen.forgetLatency();
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: Size(width, height),
        textScaler: TextScaler.linear(textScale),
        // **The DAA figure's live dot pings forever** (BG-9), so a settled
        // screen never quiesces. Reduced motion stills it, which is the
        // ping's own gate; its motion is proven in `kv_primitives_test`.
        disableAnimations: settle,
      ),
      child: MaterialApp(
        // **The app's own theme and the app's own fonts.** This harness used
        // to pump a bare `ThemeData`, which is how a field inheriting the
        // theme's input decoration and a scan line clipping at 320dp both
        // passed a green suite (`ux-auditor`, this sitting). A test that
        // measures a layout under the fallback font is measuring Ahem.
        theme: kvDarkTheme(),
        // The screen clamps its column with `KvColumn` since UX-R3, and
        // `KvWindow.of` asserts rather than falling back — so the window is
        // mounted here exactly as the app mounts it at its root (UX-R1's law).
        builder: (context, page) => KvWindow(child: page!),
        home: NodeScreen(
          scope: seam.scopeWith(
            tickPulse: pulse,
            paceAverage: paceAverage,
            withProbe: withProbe,
            withTest: withTest,
          ),
          explorer: explorer?.scope,
          rate: rate?.scope,
          clock: clock ?? () => DateTime(2026, 8, 27, 12),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(KvMotion.enter);
  }
  if (source != null) {
    await tester.ensureVisible(find.text(source));
    await tester.pumpAndSettle();
    await tester.tap(find.text(source));
    await tester.pumpAndSettle();
  }
}

/// The compact density's pill and field height (D-278), restated here so
/// the guard moves with the screen rather than pinning a number twice.
const double _pillHeight = 40;

/// What the node row actually prints for the endpoint — folded or whole.
/// The run is the only 11 dp mono text on the screen (D-277).
String _endpointRun(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .firstWhere(
      (t) =>
          t.style?.fontFamily == KvFont.mono &&
          t.style?.fontSize == 11 &&
          (t.data ?? '').contains('://'),
    )
    .data!;

/// A finder scoped to the open sheet — `SOURCES` prints a host on its row too,
/// and the sheet's route is not opaque, so the row is still in the tree.
Finder _inSheet(Finder f) =>
    find.descendant(of: find.byType(KvSheet), matching: f);

bool _cadenceRunning(WidgetTester tester) =>
    tester.widgetList<KvCadence>(find.byType(KvCadence)).any((c) => c.running);

Future<void> loadBundledFonts() async {
  for (final font in const {
    'PlusJakartaSans': 'assets/fonts/PlusJakartaSans-Variable.ttf',
    'JetBrainsMono': 'assets/fonts/JetBrainsMono-Variable.ttf',
  }.entries) {
    final bytes = await File(font.value).readAsBytes();
    await (FontLoader(
      font.key,
    )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  }
}

void main() {
  pollLifecycleTests();
  setUpAll(loadBundledFonts);

  group('NodeScreen — the INV-8 escape hatch, made reachable (D-187)', () {
    testWidgets('it opens cold and re-reads the truth from Rust', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      expect(seam.refreshes, 1);
      expect(_endpointRun(tester), startsWith('ws://'));
      expect(_endpointRun(tester), endsWith(':17110'));
      expect(find.text('523,216,421'), findsOneWidget);
    });

    group('`T5` — the connection card reads a measurement', () {
      testWidgets('the latency and its bars come from the probe — no word', (
        tester,
      ) async {
        final seam = _FakeSeam()
          ..latencyMs = 151
          ..peers = 14;
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        await tester.pump();

        // The render's own reading: 151 ms, three amber bars — the `< 300`
        // band exactly — printed on the display grid (10 ms steps above 100,
        // LINK-UX1: a single millisecond there is precision the probe does
        // not have). **No `Slow`** since D-332: the bars and their colour
        // carry the tier; the word is spoken, not drawn.
        expect(_seat('150'), findsOneWidget);
        expect(find.text('ms'), findsWidgets);
        expect(find.text('Slow'), findsNothing);
        // **Two numbers** (D-337): the caption names the figure for what it
        // is, and the path sits in the seat on its right.
        expect(find.text('NODE REPLY'), findsOneWidget);
        expect(find.text('CONNECTION'), findsNothing);
        expect(find.text('PATH'), findsOneWidget);
        expect(find.byType(KvLatencyHistory), findsOneWidget);
        final handle = tester.ensureSemantics();
        await tester.pump();
        // One sentence for the instrument: the reading, its word and the path.
        expect(
          find.bySemanticsLabel(
            RegExp(
              r'Node reply 150 milliseconds\. Slow\. Path 150 milliseconds\.',
            ),
          ),
          findsOneWidget,
        );
        handle.dispose();
        expect(find.text('14'), findsOneWidget, reason: "the node's peers");
        expect(seam.probes, greaterThan(0));
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets(
        'a timeout reads "at least", never "nothing" — the seat stays lit '
        '(D-333)',
        (tester) async {
          // Peers answered on the first tick, so the only dash that could
          // appear below is the latency's own.
          final seam = _FakeSeam()
            ..latencyMs = 120
            ..peers = 7;
          await _pumpScreen(tester, seam, withProbe: true, settle: false);
          await tester.pump();
          await tester.pump();
          expect(_seat('120'), findsOneWidget);

          // Two probes outlast the socket's deadline: a slow, live link.
          seam
            ..latencyMs = null
            ..timedOutMs = 1800;
          for (var i = 0; i < 2; i++) {
            await tester.pump(NodeScreen.pollEvery);
            await tester.pump();
          }
          expect(find.text('> 1.8'), findsOneWidget);
          expect(find.text('s'), findsOneWidget);
          expect(_seat('—'), findsNothing, reason: 'never drawn dark');
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'one refused probe never blanks the seat; three in a row do (D-333)',
        (tester) async {
          final seam = _FakeSeam()
            ..latencyMs = 42
            ..peers = 9;
          await _pumpScreen(tester, seam, withProbe: true, settle: false);
          await tester.pump();
          await tester.pump();
          expect(_seat('42'), findsOneWidget);

          seam.probeThrows = true;
          for (var refused = 1; refused < 3; refused++) {
            await tester.pump(NodeScreen.pollEvery);
            await tester.pump();
            expect(
              _seat('42'),
              findsOneWidget,
              reason: 'refusal $refused of 3: the reading stands',
            );
          }
          await tester.pump(NodeScreen.pollEvery);
          await tester.pump();
          // The figure leaves over the house's fade (BG-24) — it is going,
          // not standing beside the dark; the spoken label changes at once.
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(KvMotion.calm);
          expect(_seat('42'), findsNothing, reason: 'the third goes dark');
          expect(
            find.text('—'),
            findsNWidgets(4),
            reason:
                'the figure, the path, the pace (no pulse wired here) and '
                'the peers — and the figure is the dash, not *measuring…*',
          );
          expect(find.text('measuring…'), findsNothing);
          expect(find.text('9'), findsNothing, reason: 'the peer count too');

          // The link answers again: the count dashed by the dwell is owed, so
          // the first answer brings it back (`ux-auditor` N8).
          seam.probeThrows = false;
          final asked = seam.peerAsks.length;
          await tester.pump(NodeScreen.pollEvery);
          await tester.pump();
          expect(seam.peerAsks[asked], isTrue, reason: 'peers owed after dark');
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('9'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets('a dropped link cannot leave a latency standing', (
        tester,
      ) async {
        // The house rule behind the old wipe stands (BG-8): no number beside
        // a dead socket. A drop clears the seat at once, dwell or no dwell.
        final seam = _FakeSeam()..latencyMs = 42;
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        await tester.pump();
        expect(_seat('42'), findsOneWidget);

        seam.connected.value = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(KvMotion.calm);
        expect(_seat('42'), findsNothing, reason: 'faded out with the socket');
        expect(find.text('—'), findsWidgets);

        // …and the reading does not come back with the next socket: it
        // belonged to the one that died.
        seam
          ..latencyMs = null
          ..probeThrows = true;
        seam.connected.value = true;
        await tester.pump();
        expect(_seat('42'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      });

      testWidgets(
        'the last reading shows at once on open, dimmed with its age, then '
        'counts to the first fresh answer (D-333)',
        (tester) async {
          final seam = _FakeSeam()..latencyMs = 90;
          await _pumpScreen(tester, seam, withProbe: true, settle: false);
          await tester.pump();
          await tester.pump();
          expect(_seat('90'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());

          // Reopen without the memory wipe the harness does: the probe will
          // not answer before the first frame is looked at.
          final again = _FakeSeam()..probeThrows = true;
          tester.view.physicalSize = const Size(393, 800);
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            MediaQuery(
              data: const MediaQueryData(size: Size(393, 800)),
              child: MaterialApp(
                theme: kvDarkTheme(),
                builder: (context, page) => KvWindow(child: page!),
                home: NodeScreen(
                  scope: again.scopeWith(withProbe: true),
                  clock: () => DateTime(2026, 8, 27, 12, 0, 20),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(
            _seat('90'),
            findsOneWidget,
            reason: 'shown at once, not a dash',
          );
          expect(find.text('as of 20\u00A0s ago'), findsOneWidget);
          expect(_seatDim(tester, _seat('90')), KvFreshness.opacityStaleRegion);

          // The first fresh answer: it counts, and the age and the dim leave
          // together over the house's calm step — eased, never cut (BG-24).
          again
            ..probeThrows = false
            ..latencyMs = 130;
          await tester.pump(NodeScreen.pollEvery);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 40));
          final shown = tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => int.tryParse(t.data ?? ''))
              .whereType<int>()
              .where((n) => n > 90 && n < 130);
          expect(shown, isNotEmpty, reason: 'it counts from 90 toward 130');
          expect(
            find.text('as of 20\u00A0s ago'),
            findsOneWidget,
            reason: 'the age eases out with the dim; it is not cut',
          );
          await tester.pump(const Duration(seconds: 1));
          expect(_seat('130'), findsOneWidget);
          expect(find.text('as of 20\u00A0s ago'), findsNothing);
          expect(_seatDim(tester, _seat('130')), 1.0);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'a carried reading is where the count starts, never a sample — the '
        'first fresh outcome stands alone, a timeout included (ux-auditor)',
        (tester) async {
          // A remembered reading of [40, 42, 45]. Merged with the first fresh
          // outcome, the window's median would be 45 either way — an old
          // figure at full brightness, as if fresh.
          final at = DateTime(2026, 8, 27, 12, 0, 20);
          final memory = const KvLatencyReading.none()
              .offer(
                const KvLatencySample.answered(40),
                at: at.subtract(const Duration(seconds: 21)),
              )
              .offer(
                const KvLatencySample.answered(42),
                at: at.subtract(const Duration(milliseconds: 20500)),
              )
              .offer(
                const KvLatencySample.answered(45),
                at: at.subtract(const Duration(seconds: 20)),
              );
          final carried = '${memory.milliseconds}';
          for (final (latencyMs, timedOutMs, shows) in const [
            (300, null, '300'),
            (null, 1800, '> 1.8'),
          ]) {
            final seam = _FakeSeam()..probeThrows = true;
            NodeScreen.carryLatency(
              reading: memory,
              at: at.subtract(const Duration(seconds: 20)),
              endpoint: seam.activeEndpoint.value!,
            );
            await _reopen(tester, seam, at: at);
            await tester.pump();
            expect(_seat(carried), findsOneWidget, reason: 'carried, at once');
            expect(find.text('as of 20\u00A0s ago'), findsOneWidget);

            seam
              ..probeThrows = false
              ..latencyMs = latencyMs
              ..timedOutMs = timedOutMs;
            await tester.pump(NodeScreen.pollEvery);
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            expect(_seat(shows), findsOneWidget);
            expect(find.text('45'), findsNothing);
            expect(find.text('as of 20\u00A0s ago'), findsNothing);
            expect(_seatDim(tester, _seat(shows)), 1.0);
            await tester.pumpWidget(const SizedBox());
          }
        },
      );

      testWidgets(
        'a missed peers poll keeps the last count — only the dwell goes dark',
        (tester) async {
          final seam = _FakeSeam()
            ..latencyMs = 42
            ..peers = 9;
          await _pumpScreen(tester, seam, withProbe: true, settle: false);
          await tester.pump();
          await tester.pump();
          expect(find.text('9'), findsOneWidget);

          // The link slows past its deadline; a timed-out probe carries no
          // peers, and the next ask for them lands inside the slow spell.
          seam
            ..latencyMs = null
            ..timedOutMs = 1800
            ..peers = null;
          final asked = seam.peerAsks.where((ask) => ask).length;
          for (var i = 0; i < NodeScreen.peersEvery; i++) {
            await tester.pump(NodeScreen.pollEvery);
            await tester.pump();
          }
          expect(
            seam.peerAsks.where((ask) => ask).length,
            greaterThan(asked),
            reason: 'a peers poll landed on a timed-out probe',
          );
          expect(
            find.text('9'),
            findsOneWidget,
            reason: 'one miss never blanks the count (L144: the whole class)',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        "a different node never inherits the last one's peers or sync word "
        '(ux-auditor)',
        (tester) async {
          final seam = _FakeSeam()
            ..latencyMs = 42
            ..peers = 9
            ..synced = false;
          await _pumpScreen(tester, seam, withProbe: true, settle: false);
          await tester.pump();
          await tester.pump();
          expect(find.text('9'), findsOneWidget);
          // The node's word on its sync lives in the `BPS` row's value since
          // the D-338 addendum; `DAA` stays `DAA`.
          expect(find.text('BPS · syncing'), findsOneWidget);
          expect(find.text('DAA'), findsOneWidget);

          // A drop, and the link comes back on the SAME endpoint — so only
          // the drop can clear what the socket that died measured. Its probes
          // all time out, so nothing it answers could overwrite the old words.
          seam
            ..latencyMs = null
            ..timedOutMs = 1800
            ..peers = null
            ..synced = true;
          seam.connected.value = false;
          await tester.pump();
          seam.connected.value = true;
          for (var i = 0; i < NodeScreen.peersEvery + 2; i++) {
            await tester.pump(NodeScreen.pollEvery);
            await tester.pump();
          }
          expect(
            find.text('9'),
            findsNothing,
            reason: 'measured on the socket that died',
          );
          expect(find.text('BPS · syncing'), findsNothing);
          await tester.pumpWidget(const SizedBox());

          // And a swap the stream coalesced into one snapshot — a new node
          // named with no drop between — clears the same readings.
          final swap = _FakeSeam()
            ..latencyMs = 42
            ..peers = 9;
          await _pumpScreen(tester, swap, withProbe: true, settle: false);
          await tester.pump();
          await tester.pump();
          expect(_seat('42'), findsOneWidget);
          swap
            ..latencyMs = null
            ..timedOutMs = 1800
            ..peers = null;
          swap.activeEndpoint.value = 'wss://next.kaspa.example:17110';
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          await tester.pump(KvMotion.calm);
          expect(_seat('42'), findsNothing, reason: "the old node's reading");
          expect(find.text('9'), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        "an answer still in flight when its node is forgotten is dropped, and "
        'the next probe asks for the peers (ux-auditor N1, N2)',
        (tester) async {
          final seam = _FakeSeam()
            ..latencyMs = 42
            ..peers = 9
            ..gate = Completer<void>();
          await _pumpScreen(tester, seam, withProbe: true, settle: false);
          await tester.pump();
          // The first probe is out. The node changes under it, and then it
          // lands — with the OLD node's answer.
          seam.activeEndpoint.value = 'wss://next.kaspa.example:17110';
          await tester.pump();
          seam.gate!.complete();
          await tester.pump();
          await tester.pump();
          expect(_seat('42'), findsNothing, reason: "the old node's answer");
          expect(find.text('9'), findsNothing);

          // The next probe asks for the peers at once — not ten seconds on.
          seam
            ..gate = null
            ..latencyMs = 55
            ..peers = 12;
          final asked = seam.peerAsks.length;
          await tester.pump(NodeScreen.pollEvery);
          await tester.pump();
          expect(seam.peerAsks.length, greaterThan(asked));
          expect(seam.peerAsks[asked], isTrue, reason: 'peers asked at once');
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('12'), findsOneWidget);
          // Answered, the ask is spent: back to every ten seconds, never every
          // probe (N6 — a debt left standing would ask twice a second).
          final after = seam.peerAsks.length;
          await tester.pump(NodeScreen.pollEvery);
          await tester.pump();
          expect(seam.peerAsks.length, greaterThan(after));
          expect(seam.peerAsks.skip(after), everyElement(isFalse));
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets(
        'a first probe that times out leaves the peers owed, not dashed for '
        'ten seconds (ux-auditor N8)',
        (tester) async {
          final seam = _FakeSeam()
            ..latencyMs = null
            ..timedOutMs = 1800
            ..peers = null;
          await _pumpScreen(tester, seam, withProbe: true, settle: false);
          await tester.pump();
          await tester.pump();
          seam
            ..latencyMs = 60
            ..timedOutMs = null
            ..peers = 7;
          final asked = seam.peerAsks.length;
          await tester.pump(NodeScreen.pollEvery);
          await tester.pump();
          expect(seam.peerAsks[asked], isTrue, reason: 'still owed');
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('7'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        },
      );

      testWidgets('with no probe seam the card is dashed, never zeroed', (
        tester,
      ) async {
        await _pumpScreen(tester, _FakeSeam(), settle: false);
        await tester.pump();
        expect(
          find.text('No reading'),
          findsNothing,
          reason: 'no word (D-332)',
        );
        expect(find.text('0'), findsNothing);
        expect(
          find.text('—'),
          findsNWidgets(4),
          reason:
              'the figure, the path, the pace and the peer count, all '
              'absent',
        );
        expect(
          find.text('measuring…'),
          findsNothing,
          reason: 'nothing is being measured with no probe wired',
        );
      });

      testWidgets('the transport line is READ off the bound socket', (
        tester,
      ) async {
        // `wRPC` and `borsh` are what this client is built as; whether the
        // transport is encrypted is a property of the URL the socket actually
        // bound. A `ws://` node must not be reported as TLS.
        final seam = _FakeSeam();
        // `settle: false` and two pumps, as in the latency tests: the pumps let
        // the async probe's microtask land.
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        await tester.pump();
        expect(find.text('wRPC · borsh'), findsOneWidget);
        expect(find.textContaining('TLS'), findsNothing);

        seam.activeEndpoint.value = 'wss://secure.kaspa.example:17110';
        await tester.pump();
        expect(find.text('wRPC · borsh · TLS'), findsOneWidget);
      });
    });

    testWidgets('a healthy link is a STILL screen (BG-8 as amended, D-192)', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      // Motion means something is happening. A meter breathing beside a node
      // that is answering reports that nothing changed, forever.
      expect(_cadenceRunning(tester), isFalse);
      // **The discovery service is named** (D-207 census). "A public community
      // node" said which KIND of node was answering and left out who chose it,
      // and the PNN resolver walk was the census's first unnamed row.
      // The directory is named where it acts (D-207) — in the explainer the
      // circled-i beside `NODE` eases in beneath the card (founder, 2026-09-05):
      // the healthy card itself is `T5`'s bare row.
      await tester.tap(find.bySemanticsLabel('About node'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('found for you by the public node directory'),
        findsOneWidget,
      );

      seam.searching.value = true;
      await tester.pump();
      expect(_cadenceRunning(tester), isTrue);
      // **P0b: connected AND searching is the swap hunt, not a dark wallet.**
      // Since find-then-swap the engine holds the live link for the whole
      // search, so the old *Looking for a node…* here would understate a
      // wallet that can spend right now — and understating the link is the
      // same C7 split as overstating it, pointed the other way.
      expect(
        find.text(
          'Looking for a different node behind this one. It keeps working '
          'until another answers.',
        ),
        findsOneWidget,
      );
      expect(find.text('Looking for a node…'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a DARK hunt still says it is looking for a node', (
      tester,
    ) async {
      // The control for the assertion above: with no link to preserve the
      // words are the pre-P0b ones, so that test is measuring the swap rather
      // than a copy change that swallowed the dark state too.
      final seam = _FakeSeam(connected: false);
      seam.searching.value = true;
      // `settle: false` — the cadence is meant to be running here, so
      // pumpAndSettle would wait on an animation whose whole point is not to
      // stop.
      await _pumpScreen(tester, seam, settle: false);
      expect(find.text('Looking for a node…'), findsOneWidget);
      expect(_cadenceRunning(tester), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the phone being offline is said in plain English', (
      tester,
    ) async {
      final seam = _FakeSeam(connected: false);
      seam.osOffline.value = true;
      seam.activeEndpoint.value = null;
      await _pumpScreen(tester, seam);
      // `T5`'s row states the link in its title seat: the phone, not a node.
      expect(find.text('Your phone has no network'), findsOneWidget);
      expect(
        find.text('Nothing can be reached until it is back.'),
        findsOneWidget,
      );
      // Not hunting: a cadence over a dead radio claims work nobody is doing.
      expect(_cadenceRunning(tester), isFalse);
    });

    testWidgets('a DISCONNECTED reading is dimmed and wears its age (BG-8)', (
      tester,
    ) async {
      // `ChainService` deliberately KEEPS the last-known score when a dropped
      // link emits nulls, so the screen inherits the obligation: a
      // disconnected number at full brightness is a lie the user cannot
      // detect — the P0.3 scar.
      //
      // **And it discharges that obligation without dimming, because at this
      // ramp dimming is forbidden** (BG-14 as narrowed by D-257). This test
      // asserted the opacity and therefore *pinned a violation*: `inkMeta` is
      // 4.75:1 at full strength, so the 45 % multiply put the 13 dp figure at
      // **4.22** and the 12 dp age line at **1.94**, destroying the very string
      // BG-8 requires beside a stale reading (`ux-auditor`, UX-R3).
      // [KvFreshness.staleDimFloor] is where the dim becomes legal, and this
      // reading is well under it.
      //
      // What BG-8 asks for is still all here, in the ways it names: the counter
      // has **stopped**, and the age is printed underneath.
      final seam = _FakeSeam(connected: false);
      seam.activeEndpoint.value = null;
      await _pumpScreen(tester, seam, settle: false);
      expect(find.text('523,216,421'), findsOneWidget);
      expect(find.text('as of 3\u00A0m ago'), findsOneWidget);
      for (final o in tester.widgetList<Opacity>(find.byType(Opacity))) {
        if (o.opacity >= 1) continue;
        for (final t in tester.widgetList<Text>(
          find.descendant(of: find.byWidget(o), matching: find.byType(Text)),
        )) {
          expect(
            t.style?.fontSize ?? 0,
            greaterThanOrEqualTo(KvFreshness.staleDimFloor),
            reason:
                '"${t.data}" is dimmed at ${t.style?.fontSize} dp — under '
                'D-257\'s floor no multiply is legal, because the tone is '
                'already at the body bar',
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a live reading says nothing about its age', (tester) async {
      // Silence is the healthy state (D-192): "fresh" is not news.
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      expect(find.textContaining('as of'), findsNothing);
    });

    testWidgets('an unknown DAA is `—`, never a fabricated zero (BG-8)', (
      tester,
    ) async {
      final seam = _FakeSeam();
      seam.daa.value = null;
      await _pumpScreen(tester, seam);
      // **Five readings, five dashes, and that is the point.** `T5`'s
      // connection card carries the DAA, the latency, the path, the pace and
      // the peer count (LINK-UX1 added the path and the pace), and a fixture
      // with no probe or pulse seam has none of them — every one renders
      // BG-8's dash rather than a fabricated zero. The count is asserted so a
      // future reading that quietly defaults to `0` shows up here.
      expect(find.text('—'), findsNWidgets(5));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('asking for a pin is not pinning — the toggle is not dead', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      // **The field folds behind the switch** (the founder, 2026-09-28,
      // D-342, reversing D-275 item 2): off, the card is the toggle row alone;
      // on, the field eases in, takes a node, and the commit appears, disabled
      // until there is one.
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Test'), findsNothing);
      expect(find.text('Use this node'), findsNothing);

      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      // The hint teaches the address shape (founder, 2026-09-05).
      expect(find.text('wss://host:port'), findsOneWidget);
      // **The pill is present and disabled, and its LABEL is the reason**
      // (D-284): the verb arrives with the ability to use it. The control was
      // never absent — `Use this node` returns the moment there is something
      // to commit, two lines down.
      expect(find.text('Type the address of your node first.'), findsOneWidget);
      expect(find.text('Use this node'), findsNothing);
      // Asking with nothing typed pins nothing: no call reached Rust.
      expect(seam.calls, isEmpty);
      await tester.enterText(find.byType(TextField), 'ws://mine.local:17110');
      await tester.pumpAndSettle();
      expect(find.text('Type the address of your node first.'), findsNothing);
      expect(find.text('Use this node'), findsOneWidget);
      expect(seam.calls, isEmpty, reason: 'typing is not committing');
    });

    testWidgets('a control that cannot fire says why, in words (BG-12)', (
      tester,
    ) async {
      // A standard pill: disabled with its reason on the page until there is
      // a change to commit (BG-12), enabled when there is.
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      expect(find.text('Type the address of your node first.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'ws://10.0.0.5:17110');
      await tester.pumpAndSettle();
      expect(find.text('Type the address of your node first.'), findsNothing);
      // And a write in flight says why the control cannot fire again.
      seam.hold = Completer<void>();
      await tester.tap(find.text('Use this node'));
      await tester.pump();
      expect(find.text('Setting the node…'), findsWidgets);
      seam.hold!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('typing a node and applying it reaches the seam verbatim', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  ws://10.0.0.5:17110 ');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this node'));
      await tester.pumpAndSettle();

      // Trimmed, and otherwise untouched: Rust validates, Dart never parses a
      // URL and never applies a second, weaker guard (INV-9's reasoning).
      expect(seam.calls, ['ws://10.0.0.5:17110']);
      expect(seam.pinnedNode.value, 'ws://10.0.0.5:17110');
      // Nothing left to commit: the pill is disabled and says so.
      expect(find.text('This is already the node you pinned.'), findsOneWidget);
    });

    testWidgets('a refused pin names the act that repairs it, and the field '
        'stays folded until that act (D-342)', (tester) async {
      final seam = _FakeSeam();
      seam.pinDropped.value = true;
      await _pumpScreen(tester, seam);
      expect(
        find.textContaining('Switch on Use my own node to set it again.'),
        findsOneWidget,
      );
      expect(
        find.byType(TextField),
        findsNothing,
        reason: 'never an empty, disabled field to "check"',
      );
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    });

    testWidgets('the field closes the way it opened — every frame of the '
        'close eases, none of it drops at once (BG-24)', (tester) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam, settle: false);
      double card() => tester.getSize(find.byType(KvRowContainer).at(2)).height;
      await tester.tap(find.text('Use my own node'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(KvMotion.enter);
      await tester.pump();
      final open = card();
      await tester.tap(find.text('Use my own node'));
      final heights = <double>[open];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        heights.add(card());
      }
      final shut = heights.last;
      expect(find.byType(TextField), findsNothing, reason: 'gone at the end');
      final travel = open - shut;
      expect(travel, greaterThan(40), reason: 'the field, Test and the commit');
      var biggest = 0.0;
      for (var i = 1; i < heights.length; i++) {
        expect(
          heights[i],
          lessThanOrEqualTo(heights[i - 1] + 0.01),
          reason: 'it only closes',
        );
        final step = heights[i - 1] - heights[i];
        if (step > biggest) biggest = step;
      }
      // The house curve, flipped, moves fastest first: about a fifth of the
      // travel in a 16 ms frame. A child that left the tree at the switch —
      // the commit behind a second `if (on)` did — drops half at once.
      expect(
        biggest / travel,
        lessThan(0.3),
        reason:
            'largest single-frame drop ${biggest.toStringAsFixed(1)} of '
            '${travel.toStringAsFixed(1)} dp',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('turning it off clears the pin at once', (tester) async {
      final seam = _FakeSeam(pinned: 'ws://10.0.0.5:17110');
      await _pumpScreen(tester, seam);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        find.text('A pinned node never silently falls back to a public one.'),
        findsOneWidget,
      );

      // `T5`'s connection card grew the screen, so the toggle can sit past an
      // 800 dp viewport. Scroll to it the way a thumb would rather than
      // widening the window — the tap must work on a real phone.
      await tester.ensureVisible(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      expect(seam.calls, [null]);
      expect(seam.pinnedNode.value, isNull);
      // The field folds away with the switch (D-342), cleared: switched on
      // again it opens empty, never on the pin just cleared.
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '');
      expect(field.enabled, isTrue);
    });

    testWidgets('a REJECTED node says nothing changed — because nothing did', (
      tester,
    ) async {
      final seam = _FakeSeam(
        throws: 'node url must start with ws:// or wss://',
      );
      await _pumpScreen(tester, seam);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'http://nope');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this node'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('was not accepted, so nothing changed'),
        findsOneWidget,
      );
      expect(seam.pinnedNode.value, isNull);
    });

    testWidgets('a node that was PINNED but did not answer says exactly that', (
      tester,
    ) async {
      // The seam persists and applies a validated URL BEFORE its first dial,
      // so this error means the pin is LIVE and its retry loop is running.
      // Telling the user "not accepted" here would be the opposite of true.
      final seam = _FakeSeam(throws: 'connection refused')..pinsAnyway = true;
      await _pumpScreen(tester, seam);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ws://10.0.0.9:17110');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this node'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Pinned, but the wallet has not reached it yet'),
        findsOneWidget,
      );
      // BG-11: what happened → what it means for your funds → what to do.
      // "Your funds are safe" appears only when provably true, and here it is.
      expect(find.textContaining('Your money is safe'), findsOneWidget);
      expect(find.textContaining('keeps trying'), findsOneWidget);
      expect(seam.pinnedNode.value, 'ws://10.0.0.9:17110');
    });

    testWidgets('a failed UNPIN says what actually happened', (tester) async {
      // Clearing a pin can fail too, and it is neither of the other two
      // stories: nothing was submitted anywhere, and the pin is still on.
      final seam = _FakeSeam(pinned: 'ws://10.0.0.5:17110', throws: 'busy');
      await _pumpScreen(tester, seam);
      await tester.ensureVisible(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be cleared'), findsOneWidget);
      expect(find.textContaining('was not accepted'), findsNothing);
      expect(find.textContaining('Your money is safe'), findsOneWidget);
      // The field is re-seeded from the pin that is still live, so the screen
      // does not show an empty box beside a node that is still in use.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'ws://10.0.0.5:17110',
      );
    });

    testWidgets('an unpin that threw AFTER clearing says the pin is gone', (
      tester,
    ) async {
      // `save` writes the cleared config before the monitor is reached, so a
      // throw can arrive with the pin already gone. Telling the user it could
      // not be cleared would then be a false statement about their sovereignty
      // setting — resolve on what is LIVE, never on which call threw.
      final seam = _FakeSeam(
        pinned: 'ws://10.0.0.5:17110',
        throws: 'no monitor',
      )..pinsAnyway = true;
      await _pumpScreen(tester, seam);
      await tester.ensureVisible(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();

      expect(seam.pinnedNode.value, isNull);
      expect(find.textContaining('The pin is cleared'), findsOneWidget);
      expect(find.textContaining('could not be cleared'), findsNothing);
      expect(find.textContaining('Your money is safe'), findsOneWidget);
    });

    testWidgets('a fresher pin from Rust replaces an untouched field', (
      tester,
    ) async {
      // Adopting on "the field is empty" alone left a stale pin standing in
      // the box beside the fresh one in the reading — with Apply lit, offering
      // to re-pin the address that had just changed underneath it.
      final seam = _FakeSeam(pinned: 'ws://stale.local:17110');
      seam.onRefresh = () => seam.pinnedNode.value = 'ws://fresh.local:17110';
      await _pumpScreen(tester, seam);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'ws://fresh.local:17110',
      );
      expect(find.text('This is already the node you pinned.'), findsOneWidget);
    });

    testWidgets('a screen reader can actually work the toggle (BG-14)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      // `excludeSemantics` drops the InkWell's own tap action, so the wrapper
      // has to declare one — otherwise the only control on the INV-8 escape
      // hatch announces as a switch that cannot be activated.
      expect(
        tester.getSemantics(find.bySemanticsLabel('Use my own node')),
        isSemantics(
          hasTapAction: true,
          hasToggledState: true,
          isToggled: false,
          isEnabled: true,
        ),
      );
      // And the declared action actually DOES something. `tester.semantics.tap`
      // goes through the semantics tree the way TalkBack does, not through the
      // pointer — which is the only way to catch a control that looks tappable
      // to a sighted user and is inert to everyone else.
      tester.semantics.tap(find.semantics.byLabel('Use my own node'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a pin refused at startup is reported, in amber', (
      tester,
    ) async {
      final seam = _FakeSeam();
      seam.pinDropped.value = true;
      await _pumpScreen(tester, seam);
      final notice = tester
          .widgetList<KvStatusChip>(find.byType(KvStatusChip))
          .firstWhere((c) => c.plated);
      // Amber, not red: the truth is incomplete, no money is at risk (BG-7).
      expect(notice.tone, KvLampTone.warn);
      expect(notice.words, contains('was refused when the wallet started'));
      expect(notice.words, contains('Your money is safe'));
    });

    testWidgets('no lamp on this screen is ever teal (BG-2)', (tester) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      for (final chip in tester.widgetList<KvStatusChip>(
        find.byType(KvStatusChip),
      )) {
        expect(chip.tone.color, isNot(KvColor.primary));
      }
    });

    testWidgets('it survives 1.3x text scale at 320dp, in every state', (
      tester,
    ) async {
      final seam = _FakeSeam(pinned: 'ws://a-rather-long-hostname.local:17110');
      seam.pinDropped.value = true;
      await _pumpScreen(tester, seam, width: 320, textScale: 1.3);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Reconnect is the user\'s own try-now, and it says so', (
      tester,
    ) async {
      // The control had NO test at all when it landed: `_FakeSeam.scope` never
      // wired `onReconnect`, so nothing in this file rendered it — on the
      // INV-8 escape-hatch surface, which is the one place a user goes when
      // the link is dead (`ux-auditor`, UX-2).
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      // **P0b: the label names what the tap DOES.** On a connected, unpinned
      // wallet it no longer reconnects this node — the engine holds the live
      // link and hunts for a different one behind it, so "Reconnect" was
      // naming an action the code had stopped taking.
      expect(find.text('Switch node'), findsOneWidget);
      expect(find.text('Searching…'), findsNothing);

      await tester.tap(find.text('Switch node'));
      await tester.pump();
      expect(seam.kicks, 1);
      // The busy state rides the HUNT, not the dispatch — and the label swap
      // IS the signal, because BG-2 will not pay for a second meter on a
      // screen whose serving plate already runs one.
      expect(find.text('Searching…'), findsOneWidget);
      expect(find.text('Switch node'), findsNothing);
      expect(
        tester.widgetList<KvCadence>(find.byType(KvCadence)).length,
        lessThanOrEqualTo(1),
        reason: 'the serving plate owns the only meter on this screen',
      );

      // **A tap mid-hunt still reaches the seam — that IS C4's kick.** The
      // first version of this test asserted the opposite and passed, because
      // the control had been given `onTap: hunting ? null : onTap` when the
      // action moved off the network sheet. The engine's own hunt keeps
      // `searching` true, so that made the button dead from the moment the
      // screen opened, and the test locked it in. Repeat taps are harmless:
      // `ChainService.reconnect()` returns early while a dispatch is in flight.
      await tester.tap(find.text('Searching…'), warnIfMissed: false);
      await tester.pump();
      expect(
        seam.kicks,
        2,
        reason: 'a busy-looking button that cannot be tapped deletes C4',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the tap states its cost only where a cost is still paid', (
      tester,
    ) async {
      // **P0b, the residual case.** Find-then-swap makes a tap free on a
      // connected, unpinned wallet — there is nothing to warn about, and a
      // warning there would be false. Pinned is the case the mechanism cannot
      // fix: there is no different node to find, so a tap can only redial the
      // user's own, and that still drops the link first. The founder found
      // this defect by paying that cost without being told; the copy is where
      // it gets told.
      final pinned = _FakeSeam(pinned: 'ws://mine.local:17110');
      await _pumpScreen(tester, pinned);
      expect(find.text('Redial'), findsOneWidget);
      // The cost is stated in the row's own sentence, under the endpoint.
      expect(
        find.textContaining('drops the link you have and dials it again'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());

      // Unpinned and connected: no warning, because nothing is dropped.
      final unpinned = _FakeSeam();
      await _pumpScreen(tester, unpinned);
      expect(find.text('Switch node'), findsOneWidget);
      expect(find.textContaining('drops the link'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      // Dark: the label is the pre-P0b one, because there is no link to keep
      // and "reconnect" is exactly what the tap does.
      final dark = _FakeSeam(connected: false);
      await _pumpScreen(tester, dark, settle: false);
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.textContaining('drops the link'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no state on this screen spends more than three emissions', (
      tester,
    ) async {
      // BG-2 counts emitting objects. Measured at UX-2: a hunting link with a
      // dropped pin and the field open ran to FOUR, and a failed apply to
      // five, because `_Reconnect` had grown a meter of its own beside the
      // serving plate's.
      int emissions(WidgetTester t) =>
          find.byType(KvCadence).evaluate().length +
          find.byType(KvLamp).evaluate().length +
          find.byType(KvLiveDot).evaluate().length;

      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      expect(emissions(tester), lessThanOrEqualTo(3), reason: 'settled');

      seam.connected.value = false;
      seam.searching.value = true;
      seam.pinDropped.value = true;
      await tester.pump();
      expect(emissions(tester), lessThanOrEqualTo(3), reason: 'hunting');
      await tester.pumpWidget(const SizedBox());

      // The compound failure — a pin refused at boot AND a failed apply,
      // while the link hunts. Measured at FIVE before this sitting: the
      // serving plate's meter and lamp, a meter on Apply, a meter on
      // Reconnect, and two amber notices saying the pin is not working.
      final failing = _FakeSeam(
        throws: 'node url must start with ws:// or wss://',
      );
      // A pin refused at boot: the wallet fell back to public nodes and says
      // so. The user then types a bad address and it is refused too.
      failing.pinDropped.value = true;
      await _pumpScreen(tester, failing);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'http://nope');
      await tester.pumpAndSettle();
      // The boot-refusal notice pushes the control down a `ListView`, and a
      // tap dispatched at an off-screen centre silently misses — which is how
      // the first draft of this test measured a state it never reached.
      await tester.ensureVisible(find.text('Use this node'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this node'));
      await tester.pumpAndSettle();
      expect(find.textContaining('was not accepted'), findsOneWidget);
      failing.connected.value = false;
      failing.searching.value = true;
      await tester.pump();
      expect(
        emissions(tester),
        lessThanOrEqualTo(3),
        reason: 'a pin refused at boot, a failed apply, and a live hunt',
      );
      await tester.pumpWidget(const SizedBox());

      // **The UX-3 sections, in their own failure states, on top of that.**
      // Two more refusals land on this screen now — a rejected explorer
      // template and a rejected price source — and the reason they are amber
      // WORDS rather than `KvStatusChip`s is exactly this budget: every chip
      // carries a lamp, and BG-2 as clarified at D-209 rations lamps to two
      // per screen, never two saying the same thing. Chips here would have
      // taken a bad moment to four.
      final worst = _FakeSeam(throws: 'node url must start with ws://');
      worst.pinDropped.value = true;
      await _pumpScreen(
        tester,
        worst,
        explorer: _FakeExplorer(refuse: StateError('explorer link refused')),
        rate: _FakeRate(refuse: StateError('rate source refused')),
        height: 2400,
      );
      await tester.pumpAndSettle();
      // Each source's controls live on its own sheet now (`T5`'s SOURCES,
      // 2026-09-05): open, refuse, read the refusal, close.
      for (final (source, control, refusal) in const [
        ('Explorer', 'Use this explorer', 'explorer link refused'),
        ('API source', 'Use this source', 'rate source refused'),
      ]) {
        await tester.ensureVisible(find.text(source));
        await tester.pumpAndSettle();
        await tester.tap(find.text(source));
        await tester.pumpAndSettle();
        await tester.tap(_inSheet(find.text('Custom')));
        await tester.pumpAndSettle();
        await tester.enterText(
          _inSheet(find.byType(TextField)).first,
          'http://nope.example/x',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(control));
        await tester.pumpAndSettle();
        expect(find.textContaining(refusal), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
      worst.connected.value = false;
      worst.searching.value = true;
      await tester.pump();
      expect(
        emissions(tester),
        lessThanOrEqualTo(3),
        reason: 'every refusal this screen can hold, at once',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nor does the frame while a pin is being written', (
      tester,
    ) async {
      // The settled measurement cannot see this one: `_busy` is false again by
      // the time `pumpAndSettle` returns, so a meter that only lives during
      // the write would slip straight past it. Held open deliberately.
      //
      // A FRESH mount, too — `_pumpScreen` over a live screen reuses the
      // element, so `initState` does not re-run and `_wantPin` carries over
      // from the case before it.
      int emissions(WidgetTester t) =>
          find.byType(KvCadence).evaluate().length +
          find.byType(KvLamp).evaluate().length +
          find.byType(KvLiveDot).evaluate().length;

      final busy = _FakeSeam();
      busy.hold = Completer<void>();
      // With a boot refusal already on the glass, so the frame under test is
      // the compound one. A busy apply on an otherwise clean screen sits at
      // three either way, and would have measured nothing.
      busy.pinDropped.value = true;
      await _pumpScreen(tester, busy);
      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'ws://mine.example:17110');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this node'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this node'));
      await tester.pump();
      // The control is disabled while the write is in flight and says why in
      // words — the shipped string, which is why no busy LABEL was invented to
      // replace the meter that went. Twice, because the toggle above it is
      // disabled by the same operation and BG-12 asks each control to state
      // its own reason.
      expect(find.text('Setting the node…'), findsWidgets);
      busy.connected.value = false;
      busy.searching.value = true;
      await tester.pump();
      expect(
        emissions(tester),
        lessThanOrEqualTo(3),
        reason: 'a pin being written while the link hunts',
      );
      // Never `pumpAndSettle` past here: the serving plate's cadence is
      // running by design, so "settled" never arrives.
      busy.hold!.complete();
      await tester.pump();
      await tester.pump(KvMotion.calm);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the endpoint is whole, always — it wraps at its own `/`, is '
        'never a control, and never clips (D-342)', (tester) async {
      // The founder on glass, 2026-09-28: *"i want 'Connected to' to always
      // show full link … and no compacting it with '...' in between anymore"*
      // — superseding his 2026-09-05 fold (D-277).
      const long = 'wss://sara.kaspa.stream/kaspa/mainnet/wrpc/borsh';
      for (final width in [320.0, 393.0]) {
        final seam = _FakeSeam();
        seam.activeEndpoint.value = long;
        await _pumpScreen(tester, seam, width: width, textScale: 1.3);
        expect(find.text(long), findsOneWidget, reason: 'whole at $width dp');
        expect(find.textContaining('…'), findsNothing, reason: 'no fold');
        expect(find.bySemanticsLabel('Show the whole address'), findsNothing);
        // L131: a clipped `Text` raises no overflow, so re-lay the line in
        // the width it was given and prove every character is drawn.
        final text = tester.widget<Text>(find.text(long));
        final box = tester.renderObject<RenderBox>(find.text(long));
        final painter = TextPainter(
          text: TextSpan(text: long, style: text.style),
          textDirection: TextDirection.ltr,
          textScaler: const TextScaler.linear(1.3),
        )..layout(maxWidth: box.size.width);
        expect(painter.didExceedMaxLines, isFalse);
        expect(
          painter.height,
          lessThanOrEqualTo(box.size.height + 0.5),
          reason: 'every line it needs is laid out at $width dp',
        );
        painter.dispose();
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('the whole screen fits the phone, with nothing to scroll', (
      tester,
    ) async {
      // **The founder's bar, twice on glass** (2026-09-05, D-278): *"the
      // network screen has everything in view and i dont have to scroll down
      // to tap on API source"*.
      //
      // **Cut from his phone, measured, not from the playbook** (LINK-UX1,
      // D-342). The V60 is 1080 × 2460 px, and on 2026-09-28 it ran a forced
      // density of 480 (the larger display size) with text at 0.9× — so the
      // app gets 360 dp across, and 2460 px less a 76 px status bar and a
      // 76 px gesture bar is **769.3 dp** down (`adb shell wm density`,
      // `settings get system font_scale`, the bars' window frames). The
      // playbook's 393 × 845 was a different setting of the same phone; this
      // guard modelled that for three weeks while the phone showed less.
      // The shipped screen measured 769.2 there — 0.1 dp to spare — and
      // LINK-UX1's `BPS` row would have taken it to 808.2; the own-node field
      // folds behind its switch (his ruling the same day) and the endpoint is
      // whole: 760.2. The guard stands at **765**, 4 dp under the phone, so it
      // reds before he would see a scroll. Every seam the screen can show is
      // pumped (§19.3), and the endpoint is the public resolver's longest
      // shape, the one his phone showed on four lines.
      //
      // **If the phone's display size or text size changes, re-measure and
      // re-cut** — the numbers above are the claim.
      final seam = _FakeSeam()
        ..latencyMs = 170
        ..peers = 14;
      seam.activeEndpoint.value =
          'wss://sara.kaspa.stream/kaspa/mainnet/wrpc/borsh';
      await _pumpScreen(
        tester,
        seam,
        explorer: _FakeExplorer(),
        rate: _FakeRate(),
        withProbe: true,
        pulse: () async => (ageSecs: 0, score: 100),
        paceAverage: () =>
            (bps: 10.02, span: const Duration(minutes: 37, seconds: 12)),
        width: 360,
        height: 765,
        textScale: 0.9,
        settle: false,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      expect(
        position.maxScrollExtent,
        0,
        reason:
            'the Network screen overflows the phone by '
            '${position.maxScrollExtent.toStringAsFixed(1)} dp — `API source` '
            'is below the fold, which is the finding this guards',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('back goes back', (tester) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      expect(find.bySemanticsLabel('Back'), findsOneWidget);
    });
  });

  group('`DAA`, and `BPS` on its own row under it (D-338 and its addendum)', () {
    testWidgets('a beating chain reads its pace; a quiet one says how long '
        'since its last block — and `DAA` stays `DAA` throughout', (
      tester,
    ) async {
      // Ten blocks a second: the score climbs five at every half-second poll.
      var score = 523216421;
      await _pumpScreen(
        tester,
        _FakeSeam(),
        pulse: () async {
          score += 5;
          return (ageSecs: 0, score: score);
        },
        settle: false,
        clock: () => tester.binding.clock.now(),
      );
      await tester.pump();
      await tester.pump(NodeScreen.pollEvery);
      await tester.pump();
      expect(_pace(tester), 'BPS · 10');
      expect(find.text('DAA'), findsOneWidget, reason: 'DAA remains DAA');
      expect(find.textContaining('Hz'), findsNothing, reason: 'D-338');
      await tester.pumpWidget(const SizedBox());

      await _pumpScreen(
        tester,
        _FakeSeam(),
        pulse: () async => (ageSecs: 12, score: 100),
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      expect(
        _pace(tester),
        'BPS · 12 s since last block',
        reason:
            "D-332's ruled words, now in the pace's own seat (the founder's "
            'approval of the Recommended detail, D-338 addendum)',
      );
      expect(find.text('DAA'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      // Past a minute the age rolls to minutes, as every age does
      // (`formatAge`, `ux-auditor` N3).
      await _pumpScreen(
        tester,
        _FakeSeam(),
        pulse: () async => (ageSecs: 125, score: 100),
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      expect(_pace(tester), 'BPS · 2 m since last block');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with no socket the pace is a dash', (tester) async {
      final seam = _FakeSeam(connected: false);
      var score = 100;
      await _pumpScreen(
        tester,
        seam,
        pulse: () async => (ageSecs: 0, score: score += 5),
        settle: false,
        clock: () => tester.binding.clock.now(),
      );
      await tester.pump();
      await tester.pump(NodeScreen.pollEvery);
      await tester.pump();
      expect(_pace(tester), 'BPS');
      expect(_paceAverage(tester), '—');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a stall is watched falling toward 0 and recovering', (
      tester,
    ) async {
      var score = 523216421;
      var beating = true;
      await _pumpScreen(
        tester,
        _FakeSeam(),
        pulse: () async {
          if (beating) score += 5;
          return (ageSecs: beating ? 0 : 1, score: score);
        },
        settle: false,
        clock: () => tester.binding.clock.now(),
      );
      await tester.pump();
      await tester.pump(NodeScreen.pollEvery);
      await tester.pump();
      expect(_pace(tester), 'BPS · 10');

      // Over the three-second window it falls, and only a whole window of
      // silence reads 0 (the founder on glass, 2026-09-27).
      beating = false;
      for (var i = 0; i < 4; i++) {
        await tester.pump(NodeScreen.pollEvery);
        await tester.pump();
      }
      expect(
        _pace(tester),
        isNot('BPS ·  0'),
        reason: 'two seconds of silence is not yet a window of it',
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(NodeScreen.pollEvery);
        await tester.pump();
      }
      // A one-digit pace sits in the two-figure slot — a monospace space
      // holds the tens place, so the figure does not step (`ux-auditor`).
      expect(_pace(tester), 'BPS ·  0');
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp(r'(^|\n)0 blocks per second(\n|$)')),
        findsOneWidget,
        reason: 'the slot is typography; the pace is heard as words',
      );
      handle.dispose();

      // The backlog lands at once, then the pace.
      beating = true;
      score += 40;
      await tester.pump(NodeScreen.pollEvery);
      await tester.pump();
      expect(
        double.parse(_pace(tester).substring('BPS · '.length)),
        greaterThan(10),
        reason: 'the recovery shows as the backlog arriving',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a block in the window is never read as a stall: fewer than '
        'one a second reads "< 1", and only a window of none reads 0', (
      tester,
    ) async {
      // One block lands at the second poll, then nothing: over the widening
      // window the pace falls through 2 and 1 to a third of a block a second,
      // which a whole number would round to the stall face 0 (BG-20).
      var polls = 0;
      await _pumpScreen(
        tester,
        _FakeSeam(),
        pulse: () async {
          polls++;
          return (ageSecs: 0, score: polls >= 2 ? 101 : 100);
        },
        settle: false,
        clock: () => tester.binding.clock.now(),
      );
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(NodeScreen.pollEvery);
        await tester.pump();
      }
      expect(_pace(tester), 'BPS · < 1');
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        find.bySemanticsLabel(
          RegExp(r'(^|\n)Fewer than one block per second(\n|$)'),
        ),
        findsOneWidget,
      );
      handle.dispose();
      for (var i = 0; i < 2; i++) {
        await tester.pump(NodeScreen.pollEvery);
        await tester.pump();
      }
      expect(
        _pace(tester),
        'BPS ·  0',
        reason: 'the block has left the window: now it is a stall',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a new node starts the pace again — its score is another '
        'count, and the difference is no burst', (tester) async {
      // Node B is thirty blocks ahead of node A at the moment of the swap.
      // Differenced across the swap, the pace would print ten blocks a
      // second plus thirty over the window — a burst the chain never had.
      var score = 1000;
      final seam = _FakeSeam();
      await _pumpScreen(
        tester,
        seam,
        pulse: () async => (ageSecs: 0, score: score += 5),
        settle: false,
        clock: () => tester.binding.clock.now(),
      );
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(NodeScreen.pollEvery);
        await tester.pump();
      }
      expect(_pace(tester), 'BPS · 10');
      score += 30;
      seam.activeEndpoint.value = 'wss://next.kaspa.example:17110';
      await tester.pump();
      for (var i = 0; i < 2; i++) {
        await tester.pump(NodeScreen.pollEvery);
        await tester.pump();
      }
      expect(
        _pace(tester),
        'BPS · 10',
        reason: 'measured on the new node alone, not across the swap',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("the pace's figure is mono and tabular; its states are words "
        '(BG-30)', (tester) async {
      var score = 100;
      await _pumpScreen(
        tester,
        _FakeSeam(),
        pulse: () async => (ageSecs: 0, score: score += 5),
        settle: false,
        clock: () => tester.binding.clock.now(),
      );
      await tester.pump();
      await tester.pump(NodeScreen.pollEvery);
      await tester.pump();
      List<(String, String?)> runs() {
        final out = <(String, String?)>[];
        tester.widget<KvFactLine>(_bpsRow()).labelSpan!.visitChildren((span) {
          if (span is TextSpan && span.text != null) {
            out.add((span.text!, span.style?.fontFamily));
          }
          return true;
        });
        return out;
      }

      expect(runs(), const [
        ('BPS', null),
        (' · ', null),
        ('10', KvFont.mono),
      ], reason: 'only the figure is mono; the rest inherits the label');
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        find.bySemanticsLabel(RegExp(r'(^|\n)10 blocks per second(\n|$)')),
        findsOneWidget,
      );
      handle.dispose();
      await tester.pumpWidget(const SizedBox());

      await _pumpScreen(
        tester,
        _FakeSeam(),
        pulse: () async => (ageSecs: 9, score: 100),
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      expect(
        runs(),
        const [('BPS', null), (' · 9 s since last block', null)],
        reason: 'an age inside a sentence is a word, as S1 sets it (D-261)',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the right side is the chain\'s average pace over the span it '
        'covers — a figure, its span in words, heard as a sentence (D-342)', (
      tester,
    ) async {
      ({double bps, Duration span})? average;
      final seam = _FakeSeam();
      await _pumpScreen(
        tester,
        seam,
        pulse: () async => (ageSecs: 0, score: 100),
        paceAverage: () => average,
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      expect(_paceAverage(tester), '—', reason: 'under two minutes: nothing');

      average = (bps: 10.04, span: const Duration(minutes: 12, seconds: 40));
      await tester.pump(NodeScreen.pollEvery);
      await tester.pump();
      expect(_paceAverage(tester), '12 m avg 10.0');
      final value = tester.widget<Text>(
        find.descendant(
          of: _bpsRow(),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Text && (w.textSpan?.toPlainText() ?? '').contains('avg'),
          ),
        ),
      );
      final runs = <(String, String?)>[];
      value.textSpan!.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          runs.add((span.text!, span.style?.fontFamily));
        }
        return true;
      });
      expect(runs, const [('12 m avg ', KvFont.ui), ('10.0', KvFont.mono)]);
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        find.bySemanticsLabel(
          RegExp(
            r'(^|\n)Average over the last 12 minutes: 10\.0 blocks per second',
          ),
        ),
        findsOneWidget,
      );
      handle.dispose();

      average = (bps: 9.98, span: const Duration(hours: 1));
      await tester.pump(NodeScreen.pollEvery);
      await tester.pump();
      expect(_paceAverage(tester), '1 h avg 10.0');

      // No socket: the average is history, and a number beside a dead link is
      // the one BG-8 forbids.
      seam.connected.value = false;
      await tester.pump();
      expect(_paceAverage(tester), '—');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no average while the node syncs — its climb is catch-up '
        'speed, not the chain\'s pace', (tester) async {
      final seam = _FakeSeam()
        ..latencyMs = 150
        ..synced = false;
      await _pumpScreen(
        tester,
        seam,
        withProbe: true,
        pulse: () async => (ageSecs: 0, score: 100),
        paceAverage: () => (bps: 31.7, span: const Duration(minutes: 9)),
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      expect(_pace(tester), 'BPS · syncing');
      expect(_paceAverage(tester), '—');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the average holds a slot as wide as `10.0`, and never clips '
        'at the 320 dp / 1.3x floor (BG-30, L131)', (tester) async {
      ({double bps, Duration span}) average = (
        bps: 10.0,
        span: const Duration(minutes: 37),
      );
      final seam = _FakeSeam();
      await _pumpScreen(
        tester,
        seam,
        width: 320,
        textScale: 1.3,
        pulse: () async => (ageSecs: 0, score: 100),
        paceAverage: () => average,
        settle: false,
      );
      await tester.pump();
      await tester.pump();
      Text value() => tester.widget<Text>(
        find.descendant(
          of: _bpsRow(),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Text && (w.textSpan?.toPlainText() ?? '').contains('avg'),
          ),
        ),
      );
      final wide = value().textSpan!.toPlainText();
      average = (bps: 9.94, span: const Duration(minutes: 37));
      await tester.pump(NodeScreen.pollEvery);
      await tester.pump();
      final narrow = value().textSpan!.toPlainText();
      expect(narrow.length, wide.length, reason: '"$narrow" against "$wide"');
      // L131: re-lay the value in the box it was given.
      final box = tester.renderObject<RenderBox>(find.byWidget(value()));
      final painter = TextPainter(
        text: value().textSpan,
        textDirection: TextDirection.ltr,
        textScaler: const TextScaler.linear(1.3),
        maxLines: 1,
      )..layout(maxWidth: box.size.width);
      expect(painter.didExceedMaxLines, isFalse);
      painter.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the DAA lamp holds live to the hold on a bound socket', (
      tester,
    ) async {
      // The same law as the money plate's chip (D-331(b)): a short stall is
      // not amber on either surface.
      for (final (age, live) in const [(7, true), (16, false)]) {
        await _pumpScreen(
          tester,
          _FakeSeam(),
          pulse: () async => (ageSecs: age, score: 1),
          settle: false,
        );
        await tester.pump();
        await tester.pump();
        // The plate's own live dot since D-335.
        final dots = tester.widgetList<KvLiveDot>(find.byType(KvLiveDot));
        expect(
          dots.map((d) => d.live),
          contains(live),
          reason: 'a $age s silence on a bound socket',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('the DAA reading still refuses to wrap at 320dp', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(
        tester,
        seam,
        width: 320,
        pulse: () async => (ageSecs: 1, score: 1),
      );
      final figure = tester.widget<Text>(find.text('523,216,421'));
      expect(figure.maxLines, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('KvBlockRate — the chain\'s pace, from a score and a clock', () {
    test('blocks over the most recent three seconds, never the whole '
        'session', () {
      final rate = KvBlockRate();
      final t0 = DateTime(2026, 9, 26, 12);
      expect(rate.offer(t0, 100), isNull, reason: 'one sample is no pace');
      expect(rate.offer(t0.add(const Duration(milliseconds: 500)), 105), 10.0);
      expect(rate.offer(t0.add(const Duration(seconds: 1)), 110), 10.0);
      // A long quiet then a burst: the span is the last window, so the burst
      // reads as a burst rather than being averaged into the whole session.
      for (var i = 3; i <= 10; i++) {
        rate.offer(t0.add(Duration(milliseconds: 500 * i)), 110);
      }
      expect(rate.offer(t0.add(const Duration(milliseconds: 5500)), 110), 0.0);
      expect(
        rate.offer(t0.add(const Duration(seconds: 6)), 170),
        20.0,
        reason: 'sixty blocks over the last three seconds',
      );
    });

    test('a score that goes backwards or a clock that stands still starts '
        'over, rather than printing nonsense', () {
      final rate = KvBlockRate();
      final t0 = DateTime(2026, 9, 26, 12);
      rate.offer(t0, 100);
      expect(rate.offer(t0, 105), isNull);
      expect(rate.offer(t0.add(const Duration(seconds: 1)), 50), isNull);
      rate.reset();
      expect(rate.offer(t0.add(const Duration(seconds: 2)), 60), isNull);
    });
  });

  group('the instrument — node reply, path, the minute (LINK-UX1, D-337)', () {
    testWidgets('*measuring…* before the first answer, not a dash', (
      tester,
    ) async {
      final seam = _FakeSeam()
        ..latencyMs = 150
        ..gate = Completer<void>();
      await _pumpScreen(tester, seam, withProbe: true, settle: false);
      await tester.pump();
      expect(find.text('measuring…'), findsOneWidget);
      expect(find.text('—'), findsWidgets, reason: 'the path has no answer');
      seam.gate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(KvMotion.calm);
      expect(find.text('measuring…'), findsNothing, reason: 'faded out');
      expect(_seat('150'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a probe still out past the bound counts up on the figure — '
        'the screen hands its own clock and the probe\'s start to the seat', (
      tester,
    ) async {
      final seam = _FakeSeam()
        ..latencyMs = null
        ..timedOutMs = 1800;
      await _pumpScreen(
        tester,
        seam,
        withProbe: true,
        settle: false,
        clock: () => tester.binding.clock.now(),
      );
      await tester.pump();
      for (var i = 0; i < 2; i++) {
        await tester.pump(NodeScreen.pollEvery);
        await tester.pump();
      }
      expect(find.text('> 1.8'), findsOneWidget);
      // The next probe does not come back.
      seam.gate = Completer<void>();
      await tester.pump(NodeScreen.pollEvery);
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final shown = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .firstWhere((d) => d.startsWith('> '));
      expect(
        double.parse(shown.substring(2)),
        greaterThan(1.8),
        reason: 'the elapsed wait is a measurement, and it is growing',
      );
      seam.gate!.complete();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the reading explains itself: its mark, and a 52 dp target '
        'laid over the head that adds no height (BG-12, BG-34)', (
      tester,
    ) async {
      final seam = _FakeSeam()..latencyMs = 150;
      await _pumpScreen(tester, seam, withProbe: true, settle: false);
      await tester.pump();
      await tester.pump();
      const explained = 'The gap between them is queueing';
      expect(find.textContaining(explained), findsNothing);
      final handle = tester.ensureSemantics();
      await tester.tap(find.bySemanticsLabel('About node reply'));
      await tester.pump();
      await tester.pump(KvMotion.enter);
      expect(find.textContaining(explained), findsOneWidget);
      handle.dispose();
      // A thumb that lands on the number opens and closes what it means —
      // closing is eased too, so its end is the frame after `enter`.
      await tester.tap(_seat('150'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(KvMotion.enter);
      await tester.pump();
      expect(find.textContaining(explained), findsNothing);
      // **The control a screen reader meets is the 52 dp target**, not the
      // 16 dp caption line under it (`ux-auditor`: the first cut put the
      // button on the caption, and this test only measured the overlay's
      // own declared height — it could not have failed).
      final a11y = tester.ensureSemantics();
      await tester.pump();
      final node = tester.getSemantics(
        find.bySemanticsLabel('About node reply'),
      );
      expect(node.rect.height, greaterThanOrEqualTo(KvSpace.touchTarget));
      a11y.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('both explainer controls speak and toggle by one rule — the '
        'section header\'s and the card\'s (BG-21, L143)', (tester) async {
      await _pumpScreen(tester, _FakeSeam());
      final handle = tester.ensureSemantics();
      for (final label in ['Node', 'Node reply']) {
        final about = find.bySemanticsLabel(KvSectionHeader.aboutLabel(label));
        expect(about, findsOneWidget, reason: label);
        expect(
          tester.getSemantics(about),
          isSemantics(isButton: true, hasToggledState: true, isToggled: false),
          reason: label,
        );
        await tester.tap(about);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(about),
          isSemantics(hasToggledState: true, isToggled: true),
          reason: '$label opens',
        );
        expect(
          tester
              .widgetList<KvInfoMark>(find.byType(KvInfoMark))
              .where((m) => m.open),
          hasLength(1),
          reason: 'one mark lit, the open one',
        );
        await tester.tap(about);
        await tester.pumpAndSettle();
      }
      handle.dispose();
    });

    testWidgets('the explainer says what the numbers are — and never calls '
        'the round trip "ping" or "network" (D-337)', (tester) async {
      await _pumpScreen(tester, _FakeSeam());
      await tester.tap(find.bySemanticsLabel('About node reply'));
      await tester.pumpAndSettle();
      final said = tester
          .widgetList<Text>(find.byType(Text))
          .firstWhere(
            (t) => (t.data ?? t.textSpan?.toPlainText() ?? '').startsWith(
              'Node reply is',
            ),
          );
      final text = said.textSpan!.toPlainText();
      for (final claim in [
        'Path, its best answer in the last 10 s',
        'mostly distance',
        'queueing',
        'Bars grade the last 10 s',
        'The chart shows the last minute',
        'In it, red marks a wait with no answer',
      ]) {
        expect(text, contains(claim));
      }
      expect(text.toLowerCase(), isNot(contains('ping')));
      expect(text.toLowerCase(), isNot(contains('network')));
      // Its numbers are figures, its words are words (BG-30, §7.1).
      final runs = <(String, String?)>[];
      said.textSpan!.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          runs.add((span.text!, span.style?.fontFamily));
        }
        return true;
      });
      expect(
        runs.where((r) => r.$1.contains(RegExp(r'\d'))),
        everyElement(predicate<(String, String?)>((r) => r.$2 == KvFont.mono)),
      );
      expect(
        runs.where((r) => !r.$1.contains(RegExp(r'\d'))),
        everyElement(predicate<(String, String?)>((r) => r.$2 == null)),
      );
      // Short sentences (§7.1: 8–14 words).
      for (final sentence in text.split(RegExp(r'(?<=\.) '))) {
        expect(
          sentence.split(' ').length,
          lessThanOrEqualTo(14),
          reason: '"$sentence"',
        );
      }
    });
  });

  group('the explorer sheet — a settings ceremony from the playbook', () {
    _FakeSeam seamFor() => _FakeSeam();

    testWidgets('the choices are rows in a chip card with ONE check', (
      tester,
    ) async {
      final explorer = _FakeExplorer();
      await _pumpScreen(
        tester,
        seamFor(),
        explorer: explorer,
        source: 'Explorer',
        height: 2400,
      );
      // The two audited defaults and `Custom`, as rows; the current one
      // wears the check and only it — and **the others now carry a ring**
      // rather than a blank, which is what the promoted `KvChoiceRow`
      // brought (D-284). A shared part changing underneath is expected.
      expect(_inSheet(find.text('explorer.kaspa.org')), findsOneWidget);
      expect(_inSheet(find.text('kaspa.stream')), findsOneWidget);
      expect(_inSheet(find.text('Custom')), findsOneWidget);
      expect(_inSheet(find.byType(KvCheck)), findsOneWidget);
      // **Two: the two unchosen options.** The disabled act used to carry a
      // third ring in miniature — *nothing new has been picked* — and the
      // founder ruled that mark off every disabled pill at the UX-R6 glass
      // beat. Its label ("This is already your explorer.", asserted below)
      // was always the thing that said why.
      expect(_inSheet(find.byType(KvRadio)), findsNWidgets(2));
      // The inputs `Custom` stands for are not drawn until it is chosen.
      expect(_inSheet(find.byType(TextField)), findsNothing);
      // Nothing changed: the act is disabled and says why (BG-12).
      expect(find.text('This is already your explorer.'), findsOneWidget);
      expect(explorer.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('one tap takes both templates, and the act commits them', (
      tester,
    ) async {
      final explorer = _FakeExplorer();
      await _pumpScreen(
        tester,
        seamFor(),
        explorer: explorer,
        source: 'Explorer',
        height: 2400,
      );
      await tester.tap(_inSheet(find.text('kaspa.stream')));
      await tester.pumpAndSettle();
      expect(find.text('This is already your explorer.'), findsNothing);
      await tester.tap(find.text('Use this explorer'));
      await tester.pumpAndSettle();
      expect(explorer.writes, [
        (
          _FakeExplorer.kaspaStream.txTemplate,
          _FakeExplorer.kaspaStream.addressTemplate,
        ),
      ]);
      // The sheet closed on the commit, and the row prints the new host.
      expect(find.byType(KvSheet), findsNothing);
      expect(find.text('kaspa.stream'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      '`Custom` reveals the two link inputs and saves them verbatim',
      (tester) async {
        final explorer = _FakeExplorer();
        await _pumpScreen(
          tester,
          seamFor(),
          explorer: explorer,
          source: 'Explorer',
          height: 2400,
        );
        await tester.tap(_inSheet(find.text('Custom')));
        await tester.pumpAndSettle();
        expect(_inSheet(find.byType(TextField)), findsNWidgets(2));
        expect(find.text('Transaction link'), findsOneWidget);
        expect(find.text('Address link'), findsOneWidget);
        await tester.enterText(
          _inSheet(find.byType(TextField)).first,
          '  https://mine.example/t/{txid} ',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use this explorer'));
        await tester.pumpAndSettle();
        // Trimmed and otherwise untouched: Rust validates, Dart never parses a
        // URL and never applies a second, weaker guard (INV-9's reasoning).
        expect(explorer.writes, [
          (
            'https://mine.example/t/{txid}',
            'https://explorer.kaspa.org/addresses/{address}',
          ),
        ]);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets("a refusal stays on the sheet, and does not touch the link's "
        'message', (tester) async {
      final explorer = _FakeExplorer(
        refuse: StateError('the explorer link must start with https://'),
      );
      await _pumpScreen(
        tester,
        seamFor(),
        explorer: explorer,
        source: 'Explorer',
        height: 2400,
      );
      await tester.tap(_inSheet(find.text('Custom')));
      await tester.pumpAndSettle();
      await tester.enterText(
        _inSheet(find.byType(TextField)).first,
        'http://nope.example/{txid}',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this explorer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('must start with https://'), findsOneWidget);
      expect(find.byType(KvSheet), findsOneWidget, reason: 'fix it here');
      // The link's own state is a different fact and keeps its own line.
      expect(find.text('Connected to'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Cancel is red, and a tap on the ground cancels too', (
      tester,
    ) async {
      // D-277, on every sheet: the way out wears `risk`, and the scrim is
      // the same way out.
      await _pumpScreen(
        tester,
        seamFor(),
        explorer: _FakeExplorer(),
        source: 'Explorer',
        height: 2400,
      );
      final cancel = tester.widget<Text>(_inSheet(find.text('Cancel')));
      expect(cancel.style!.color, KvColor.risk);
      expect(find.textContaining('outbound link'), findsNothing);
      await tester.tapAt(const Offset(12, 12));
      await tester.pumpAndSettle();
      expect(find.byType(KvSheet), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no seam, no row — never a control wired to nothing', (
      tester,
    ) async {
      await _pumpScreen(tester, seamFor(), height: 2400);
      expect(find.text('Explorer'), findsNothing);
      expect(find.text('SOURCES'), findsNothing);
    });
  });

  group('the price-source sheet — the one claim consensus cannot check', () {
    _FakeSeam seamFor() => _FakeSeam();

    testWidgets('what the source actually said is on the sheet', (
      tester,
    ) async {
      final rate = _FakeRate();
      rate.quote.value = KvRateQuote(
        usdPerKas: 0.07120000,
        fetchedAt: DateTime(2026, 8, 27, 11, 59, 30),
        source: 'https://api.kaspa.org/info/price',
      );
      await _pumpScreen(
        tester,
        seamFor(),
        rate: rate,
        source: 'API source',
        height: 2400,
      );
      // The shipped source is the current choice, checked once.
      expect(_inSheet(find.text('api.kaspa.org')), findsOneWidget);
      // The price-source sheet is the same promoted part: the check marks
      // the choice, a ring marks every other option (D-284).
      expect(_inSheet(find.byType(KvCheck)), findsOneWidget);
      // Every significant digit, no trailing zeros (D-210).
      expect(find.text('\$0.0712'), findsOneWidget);
      expect(find.text('Price, per KAS'), findsOneWidget);
      expect(find.textContaining('30\u00A0s ago'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with no usable price the reading is an em dash', (
      tester,
    ) async {
      final rate = _FakeRate();
      await _pumpScreen(
        tester,
        seamFor(),
        rate: rate,
        source: 'API source',
        height: 2400,
      );
      expect(find.text('Price, per KAS'), findsOneWidget);
      expect(_inSheet(find.text('—')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('`Off` reaches the seam, and the row says Off', (tester) async {
      final rate = _FakeRate();
      await _pumpScreen(
        tester,
        seamFor(),
        rate: rate,
        source: 'API source',
        height: 2400,
      );
      await tester.tap(_inSheet(find.text('Off')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this source'));
      await tester.pumpAndSettle();
      expect(rate.writes.length, 1);
      expect(rate.writes.single.$1, isFalse);
      expect(find.byType(KvSheet), findsNothing);
      expect(find.text('Off'), findsOneWidget, reason: 'the row prints it');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the act is disabled with its reason until a choice differs', (
      tester,
    ) async {
      final rate = _FakeRate();
      await _pumpScreen(
        tester,
        seamFor(),
        rate: rate,
        source: 'API source',
        height: 2400,
      );
      // **Disabled, the pill's label IS the reason** (D-284) — so the verb
      // is not on the glass and the thing to tap is the reason itself.
      expect(find.text('This is already your price source.'), findsOneWidget);
      expect(find.text('Use this source'), findsNothing);
      await tester.tap(find.text('This is already your price source.'));
      await tester.pumpAndSettle();
      expect(rate.writes, isEmpty, reason: 'a disabled act does nothing');
      await tester.tap(_inSheet(find.text('Custom')));
      await tester.pumpAndSettle();
      // Custom with the shipped address typed is still no change.
      expect(find.text('This is already your price source.'), findsOneWidget);
      await tester.enterText(
        _inSheet(find.byType(TextField)),
        'https://prices.example/kas',
      );
      await tester.pumpAndSettle();
      expect(find.text('This is already your price source.'), findsNothing);
      await tester.tap(find.text('Use this source'));
      await tester.pumpAndSettle();
      expect(rate.writes, [(true, 'https://prices.example/kas')]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a rejected source is reported and not adopted', (
      tester,
    ) async {
      final rate = _FakeRate(refuse: StateError('rate source refused'));
      await _pumpScreen(
        tester,
        seamFor(),
        rate: rate,
        source: 'API source',
        height: 2400,
      );
      await tester.tap(_inSheet(find.text('Custom')));
      await tester.pumpAndSettle();
      await tester.enterText(
        _inSheet(find.byType(TextField)),
        'http://nope.example/x',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this source'));
      await tester.pumpAndSettle();
      expect(find.textContaining('rate source refused'), findsOneWidget);
      expect(find.byType(KvSheet), findsOneWidget);
      expect(rate.endpoint.value, isNot('http://nope.example/x'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refused stored source opens on Custom, ready to repair', (
      tester,
    ) async {
      // A stored endpoint Rust refuses loads as `enabled: false` with the
      // bad endpoint KEPT, so the sheet must show it where it can be fixed.
      final rate = _FakeRate();
      rate.enabled.value = false;
      rate.endpoint.value = 'http://bad.example/price';
      await _pumpScreen(
        tester,
        seamFor(),
        rate: rate,
        source: 'API source',
        height: 2400,
      );
      await tester.tap(_inSheet(find.text('Custom')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(_inSheet(find.byType(TextField)))
            .controller!
            .text,
        'http://bad.example/price',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no seam, no row', (tester) async {
      await _pumpScreen(tester, seamFor(), height: 2400);
      expect(find.text('API source'), findsNothing);
    });
  });

  group('the explainers — a circled-i beside the caps label', () {
    testWidgets('NODE eases its explainer in beneath the card, and out', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      expect(find.textContaining('found for you by the public'), findsNothing);
      await tester.tap(find.bySemanticsLabel('About node'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('found for you by the public'),
        findsOneWidget,
      );
      await tester.tap(find.bySemanticsLabel('About node'));
      await tester.pumpAndSettle();
      expect(find.textContaining('found for you by the public'), findsNothing);
    });

    testWidgets('SOURCES has its own, and a route arriving over it closes it', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam, explorer: _FakeExplorer(), height: 2400);
      await tester.ensureVisible(find.text('SOURCES'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('About sources'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing else reaches out'), findsOneWidget);
      // Opening a sheet over the screen closes it.
      await tester.tap(find.text('Explorer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing else reaches out'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('reachability — the whole point of this deliverable', () {
    // The sovereign-node line shipped the Rust, the bridge and the service
    // seam gate-green with **no way for a user to reach any of it**. A surface
    // that exists and cannot be opened is the same defect wearing a screen, so
    // the path is asserted end to end rather than assumed from the wiring.
    testWidgets('home network chip → node picker', (tester) async {
      // Roomy, for the same reason link_states_test is: the fallback test font
      // measures every label far wider than a device does.
      tester.view.physicalSize = const Size(2000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final seam = _FakeSeam();
      final now = DateTime(2026, 8, 27, 12);
      await tester.pumpWidget(_home(node: seam.scope, now: now));

      // Never pumpAndSettle here: the home screen's freshness ticker never
      // ends, so "settled" never arrives.
      //
      // UX-2 shortened this path by one surface. The chip on the money plate
      // IS the door (D-191); the network sheet keeps its own door from
      // Settings until UX-3 collapses the two.
      //
      // One frame first: the plate's pinned extent is MEASURED, so it is right
      // from the second frame and a tap inside the bootstrap frame would land
      // on a 1dp header.
      await tester.pump();
      await tester.tap(find.text('Mainnet'));
      await tester.pump();
      await tester.pump(KvMotion.enter);
      expect(find.byType(NodeScreen), findsOneWidget);
      expect(find.text('Network'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the seam the chip is a reading, not a dead control', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(2000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime(2026, 8, 27, 12);
      await tester.pumpWidget(_home(node: null, now: now));

      // BG-12 forbids a disabled control with no stated reason, and "the seam
      // is absent" is not a reason a user can act on. So the chip stops being
      // a control at all: a name and nothing else, no chevron, no route.
      await tester.pump();
      expect(find.text('Mainnet'), findsOneWidget);
      await tester.tap(find.text('Mainnet'));
      await tester.pump();
      await tester.pump(KvMotion.enter);
      expect(find.byType(NodeScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// The money screen, wired to nothing but the notifiers under test.
///
/// UX-3 turned the chip's destination into a **builder**: the node surface now
/// carries the explorer choice and the price source as well as the pin, and it
/// is built once in `main.dart` for both of its doors. The walk below still
/// proves the property that matters here — the chip opens the node surface, and
/// without a route it opens nothing.
Widget _home({required NodeScope? node, required DateTime now}) => MaterialApp(
  theme: kvDarkTheme(),
  // The window is derived once at the root and read from context (BG-33) —
  // the same mount point `main.dart` uses, so a test lays out the way the app
  // does rather than falling back to `compact`.
  builder: (context, page) => KvWindow(child: page!),
  home: HomeScreen(
    nodeRoute: node == null ? null : (_) => NodeScreen(scope: node),
    chain: ChainScope(
      connected: ValueNotifier<bool>(true),
      virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(499524873)),
      error: ValueNotifier<String?>(null),
      lastUpdate: ValueNotifier<DateTime?>(now),
    ),
    wallet: WalletScope(
      maturity: kTestMaturity,
      mature: ValueNotifier<BigInt?>(BigInt.from(123456789012)),
      pending: ValueNotifier<BigInt?>(null),
      activity: ValueNotifier<List<ActivityRecord>>(const []),
      syncing: ValueNotifier<bool>(false),
      utxoIndexMissing: ValueNotifier<bool>(false),
    ),
    clock: () => now,
  ),
);

/// The latency seat's dim over [figure]: the product of the eased opacities
/// above it — their targets, which an implicit animation's first frame is
/// already at, and which a finished one has reached.
double _seatDim(WidgetTester tester, Finder figure) => tester
    .widgetList<AnimatedOpacity>(
      find.ancestor(of: figure, matching: find.byType(AnimatedOpacity)),
    )
    .map((o) => o.opacity)
    .fold(1.0, (a, b) => a * b);

/// Open the screen over whatever latency memory is standing, as a user
/// reopening it would — [_pumpScreen] wipes that memory on purpose.
Future<void> _reopen(
  WidgetTester tester,
  _FakeSeam seam, {
  required DateTime at,
}) async {
  tester.view.physicalSize = const Size(393, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: Size(393, 800)),
      child: MaterialApp(
        theme: kvDarkTheme(),
        builder: (context, page) => KvWindow(child: page!),
        home: NodeScreen(
          scope: seam.scopeWith(withProbe: true),
          clock: () => at,
        ),
      ),
    ),
  );
}

/// The `BPS` row — found by its label, which since D-342 carries the live
/// pace (`BPS · 10`).
Finder _bpsRow() => find.byWidgetPredicate(
  (w) =>
      w is KvFactLine &&
      (w.labelSpan?.toPlainText() ?? w.label).startsWith('BPS'),
);

/// The `BPS` row's label, as printed: `BPS · 10`, `BPS · syncing`, `BPS`.
String _pace(WidgetTester tester) =>
    tester.widget<KvFactLine>(_bpsRow()).labelSpan!.toPlainText();

/// The `BPS` row's right side, as printed: `12 m avg 10.0`, or `—`.
String _paceAverage(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(
        find.descendant(of: _bpsRow(), matching: find.byType(Text)),
      )
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .where((d) => !d.startsWith('BPS'))
      .toList();
  expect(texts, hasLength(1));
  return texts.single;
}

/// A text on the latency seat itself — the path in the caption prints the
/// same figures, so a bare `find.text` would find both.
Finder _seat(String text) =>
    find.descendant(of: find.byType(KvLatency), matching: find.text(text));
