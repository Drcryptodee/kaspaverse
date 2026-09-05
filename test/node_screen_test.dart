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
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';
import 'support/maturity.dart';
import 'package:kaspaverse/src/ui/widgets/kv_latency.dart';
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

  /// The node's own word on its sync, as the probe reports it.
  bool? synced = true;

  /// Which ticks asked for the peer count, in order.
  final List<bool> peerAsks = <bool>[];

  Future<({int? latencyMs, int? peers, bool? synced})> probe({
    required bool peers,
  }) async {
    probes++;
    peerAsks.add(peers);
    if (probeThrows) throw StateError('the node went away');
    return (
      latencyMs: latencyMs,
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
    Future<int?> Function()? blockAgeSecs,
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
    blockAgeSecs: blockAgeSecs,
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
      await tester.pump(const Duration(seconds: 2));
      expect(seam.probes, 2);

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
      // Pumped by hand: the latency dot breathes for as long as there is a
      // reading, so a settle would wait on an animation whose whole point is
      // not to stop. The route's own transition is well inside 400 ms.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(seconds: 6));
      expect(
        seam.probes,
        1,
        reason: 'a covered screen asks the node for nothing',
      );

      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(seam.probes, 2, reason: 'and asks the moment it is back');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'the peer count is asked for on the first tick and every fifth',
      (tester) async {
        final seam = _FakeSeam()
          ..latencyMs = 80
          ..peers = 9;
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        for (var i = 0; i < 9; i++) {
          await tester.pump(const Duration(seconds: 2));
        }
        expect(seam.peerAsks, [
          true,
          false,
          false,
          false,
          true,
          false,
          false,
          false,
          false,
          true,
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
        // The visual: `T5`'s `chip`-filled pill, measured at ~44 dp.
        final visual = find
            .ancestor(of: pill, matching: find.byType(AnimatedContainer))
            .first;
        expect(tester.getSize(visual).height, closeTo(44, 1));
        final box = tester.widget<AnimatedContainer>(visual);
        expect((box.decoration! as BoxDecoration).color, KvColor.chip);
        // And the endpoint still stands beside it, whole (BG-15's reasoning).
        expect(find.text('public-1.kaspa.example:17110'), findsOneWidget);
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
  Future<int?> Function()? blockAge,
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
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: Size(width, height),
        textScaler: TextScaler.linear(textScale),
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
            blockAgeSecs: blockAge,
            withProbe: withProbe,
            withTest: withTest,
          ),
          explorer: explorer?.scope,
          rate: rate?.scope,
          clock: () => DateTime(2026, 8, 27, 12),
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
      expect(find.text('public-1.kaspa.example:17110'), findsOneWidget);
      expect(find.text('523,216,421'), findsOneWidget);
    });

    group('`T5` — the connection card reads a measurement', () {
      testWidgets('the latency, its tier and its bars come from the probe', (
        tester,
      ) async {
        final seam = _FakeSeam()
          ..latencyMs = 151
          ..peers = 14;
        // `settle: false`: a live latency reading breathes its dot, so the
        // card never settles — the same reason the harness already documents
        // for a dark link. Two pumps let the async probe's microtask land.
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        await tester.pump();

        // The render's own reading: 151 ms, three amber bars, `Slow` — the
        // `< 300` band exactly (§4, checked against `T5` rather than assumed).
        expect(find.text('Slow'), findsOneWidget);
        expect(find.text('ms'), findsOneWidget);
        expect(
          KvLatency.tierFor(151).bars,
          3,
          reason: 'the tier the card is drawing',
        );
        expect(find.text('14'), findsOneWidget, reason: "the node's peers");
        expect(seam.probes, greaterThan(0));
      });

      testWidgets('a failed probe CLEARS the reading rather than holding it', (
        tester,
      ) async {
        // The opposite of what the block-age poll does with its last value, and
        // deliberately so: a block age that stops advancing is itself the
        // signal and the line says how old it is, but a latency measures *this*
        // round trip — so a stale 42 ms beside a dead socket would be a
        // confident wrong number rather than an old true one (BG-8).
        final seam = _FakeSeam()
          ..latencyMs = 42
          ..peers = 9;
        // `settle: false`: a live latency reading breathes its dot, so the
        // card never settles — the same reason the harness already documents
        // for a dark link. Two pumps let the async probe's microtask land.
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        await tester.pump();
        expect(find.text('Fast'), findsOneWidget);

        seam.probeThrows = true;
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(find.text('Fast'), findsNothing);
        expect(find.text('No reading'), findsOneWidget);
        expect(find.text('9'), findsNothing, reason: 'the peer count went too');
      });

      testWidgets('a dropped link cannot leave a latency standing', (
        tester,
      ) async {
        // The probe clears itself on a failure, but the poll runs at 2 s while
        // the notifiers are pushed — so a socket that dropped a moment ago
        // could hold the last good number for one tick. The card gates on
        // `connected` to close that window without waiting for the probe.
        final seam = _FakeSeam()..latencyMs = 42;
        // `settle: false`: a live latency reading breathes its dot, so the
        // card never settles — the same reason the harness already documents
        // for a dark link. Two pumps let the async probe's microtask land.
        await _pumpScreen(tester, seam, withProbe: true, settle: false);
        await tester.pump();
        await tester.pump();
        expect(find.text('Fast'), findsOneWidget);

        seam.connected.value = false;
        await tester.pump();
        expect(find.text('Fast'), findsNothing);
        expect(find.text('No reading'), findsOneWidget);
      });

      testWidgets('with no probe seam the card is dashed, never zeroed', (
        tester,
      ) async {
        await _pumpScreen(tester, _FakeSeam(), settle: false);
        await tester.pump();
        expect(find.text('No reading'), findsOneWidget);
        expect(find.text('0'), findsNothing);
        expect(
          find.text('—'),
          findsNWidgets(2),
          reason: 'the latency figure and the peer count, both absent',
        );
      });

      testWidgets('the transport line is READ off the bound socket', (
        tester,
      ) async {
        // `wRPC` and `borsh` are what this client is built as; whether the
        // transport is encrypted is a property of the URL the socket actually
        // bound. A `ws://` node must not be reported as TLS.
        final seam = _FakeSeam();
        // `settle: false`: a live latency reading breathes its dot, so the
        // card never settles — the same reason the harness already documents
        // for a dark link. Two pumps let the async probe's microtask land.
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
      expect(find.text('as of 3 m ago'), findsOneWidget);
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
      // **Three readings, three dashes, and that is the point.** `T5`'s
      // connection card carries the DAA, the latency and the peer count, and a
      // fixture with no probe seam has none of them — every one renders BG-8's
      // dash rather than a fabricated zero. The count is asserted so a future
      // reading that quietly defaults to `0` shows up here.
      expect(find.text('—'), findsNWidgets(3));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('asking for a pin is not pinning — the toggle is not dead', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      // `T5`'s own-node card always holds its field, and the switch governs
      // it (2026-09-05): off, the field is disabled and says why; on, it takes
      // a node and the commit appears, disabled until there is one.
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.text('Turn on to set a node'), findsOneWidget);
      expect(find.text('Use this node'), findsNothing);

      await tester.tap(find.text('Use my own node'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(find.text('Use this node'), findsOneWidget);
      expect(find.text('Type the address of your node first.'), findsOneWidget);
      // Asking with nothing typed pins nothing: no call reached Rust.
      expect(seam.calls, isEmpty);
      await tester.enterText(find.byType(TextField), 'ws://mine.local:17110');
      await tester.pumpAndSettle();
      expect(find.text('Type the address of your node first.'), findsNothing);
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
      // The field stays (it is the card's, 2026-09-05), cleared and disabled.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '');
      expect(field.enabled, isFalse);
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
          find.byType(KvLamp).evaluate().length;

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
          find.byType(KvLamp).evaluate().length;

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

    testWidgets('back goes back', (tester) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      expect(find.bySemanticsLabel('Back'), findsOneWidget);
    });
  });

  group('the block age rides the DAA row (2026-09-05)', () {
    testWidgets('blocks landing reads streaming; a quiet node says how long', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam, blockAge: () async => 1, settle: false);
      await tester.pump();
      await tester.pump();
      expect(find.text('DAA · streaming'), findsOneWidget);
      // A fresh mount: pumping a second seam into the same tree reuses the
      // state, whose poll would only read the new age on its next tick.
      await tester.pumpWidget(const SizedBox());

      final quiet = _FakeSeam();
      await _pumpScreen(tester, quiet, blockAge: () async => 12, settle: false);
      await tester.pump();
      await tester.pump();
      expect(find.text('DAA · 12 s since last block'), findsOneWidget);
      expect(find.text('DAA · streaming'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the DAA reading still refuses to wrap at 320dp', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam, width: 320, blockAge: () async => 1);
      final figure = tester.widget<Text>(find.text('523,216,421'));
      expect(figure.maxLines, 1);
      expect(tester.takeException(), isNull);
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
      // wears the check and only it.
      expect(_inSheet(find.text('explorer.kaspa.org')), findsOneWidget);
      expect(_inSheet(find.text('kaspa.stream')), findsOneWidget);
      expect(_inSheet(find.text('Custom')), findsOneWidget);
      expect(_inSheet(find.byType(KvCheck)), findsOneWidget);
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
      expect(_inSheet(find.byType(KvCheck)), findsOneWidget);
      // Every significant digit, no trailing zeros (D-210).
      expect(find.text('\$0.0712'), findsOneWidget);
      expect(find.text('Price, per KAS'), findsOneWidget);
      expect(find.textContaining('30 s ago'), findsOneWidget);
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
      expect(find.text('This is already your price source.'), findsOneWidget);
      await tester.tap(find.text('Use this source'));
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
      await tester.pump(KvMotion.slow);
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
      await tester.pump(KvMotion.slow);
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
