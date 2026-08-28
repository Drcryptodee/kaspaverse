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
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_cadence.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';

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
  NodeScope scopeWith({Future<int?> Function()? blockAgeSecs}) => NodeScope(
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

Future<void> _pumpScreen(
  WidgetTester tester,
  _FakeSeam seam, {
  _FakeExplorer? explorer,
  _FakeRate? rate,
  Future<int?> Function()? blockAge,
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
        home: NodeScreen(
          scope: seam.scopeWith(blockAgeSecs: blockAge),
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
}

bool _cadenceRunning(WidgetTester tester) =>
    tester.widgetList<KvCadence>(find.byType(KvCadence)).any((c) => c.running);

Future<void> loadBundledFonts() async {
  for (final font in const {
    'Inter': 'assets/fonts/Inter-Variable.ttf',
    'JetBrainsMono': 'assets/fonts/JetBrainsMono-Variable.ttf',
  }.entries) {
    final bytes = await File(font.value).readAsBytes();
    await (FontLoader(
      font.key,
    )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  }
}

void main() {
  setUpAll(loadBundledFonts);

  /// A healthy link, which is the background every new UX-3 section is judged
  /// against — the sections under test are not about the link.
  _FakeSeam seamFor() => _FakeSeam();

  group('NodeScreen — the INV-8 escape hatch, made reachable (D-187)', () {
    testWidgets('it opens cold and re-reads the truth from Rust', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      expect(seam.refreshes, 1);
      expect(find.text('ws://public-1.kaspa.example:17110'), findsOneWidget);
      expect(find.text('523,216,421'), findsOneWidget);
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
      expect(
        find.text(
          'Answering — a public community node, found for you by the public '
          'node directory.',
        ),
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
          'Answering — and looking for a different node. This one keeps '
          'working until another answers.',
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
      expect(find.text('Your phone has no network.'), findsOneWidget);
      expect(find.text('not connected'), findsOneWidget);
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
      final seam = _FakeSeam(connected: false);
      seam.activeEndpoint.value = null;
      await _pumpScreen(tester, seam, settle: false);
      expect(find.text('523,216,421'), findsOneWidget);
      expect(find.text('as of 3 m ago'), findsOneWidget);
      final dimmed = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .any((o) => o.opacity == KvFreshness.opacityStale);
      expect(dimmed, isTrue);
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
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('asking for a pin opens the field — the toggle is not dead', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.text('Pin a node I run'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      // Asking is not pinning: nothing has been sent to Rust yet.
      expect(seam.calls, isEmpty);
    });

    testWidgets('a control that cannot fire says why, in words (BG-12)', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      await tester.tap(find.text('Pin a node I run'));
      await tester.pumpAndSettle();
      expect(find.text('Type the address of your node first.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ws://10.0.0.5:17110');
      await tester.pumpAndSettle();
      expect(find.text('Type the address of your node first.'), findsNothing);
    });

    testWidgets('typing a node and applying it reaches the seam verbatim', (
      tester,
    ) async {
      final seam = _FakeSeam();
      await _pumpScreen(tester, seam);
      await tester.tap(find.text('Pin a node I run'));
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

      await tester.tap(find.text('Pin a node I run'));
      await tester.pumpAndSettle();
      expect(seam.calls, [null]);
      expect(seam.pinnedNode.value, isNull);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a REJECTED node says nothing changed — because nothing did', (
      tester,
    ) async {
      final seam = _FakeSeam(
        throws: 'node url must start with ws:// or wss://',
      );
      await _pumpScreen(tester, seam);
      await tester.tap(find.text('Pin a node I run'));
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
      await tester.tap(find.text('Pin a node I run'));
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
      await tester.tap(find.text('Pin a node I run'));
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
      await tester.tap(find.text('Pin a node I run'));
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
        tester.getSemantics(find.bySemanticsLabel('Pin a node I run')),
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
      tester.semantics.tap(find.semantics.byLabel('Pin a node I run'));
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
      expect(find.text('Find a different node'), findsOneWidget);
      expect(find.text('Searching…'), findsNothing);

      await tester.tap(find.text('Find a different node'));
      await tester.pump();
      expect(seam.kicks, 1);
      // The busy state rides the HUNT, not the dispatch — and the label swap
      // IS the signal, because BG-2 will not pay for a second meter on a
      // screen whose serving plate already runs one.
      expect(find.text('Searching…'), findsOneWidget);
      expect(find.text('Find a different node'), findsNothing);
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
      expect(find.text('Redial your node'), findsOneWidget);
      expect(
        find.text('Drops the link you have and dials your node again.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());

      // Unpinned and connected: no warning, because nothing is dropped.
      final unpinned = _FakeSeam();
      await _pumpScreen(tester, unpinned);
      expect(find.text('Find a different node'), findsOneWidget);
      expect(find.textContaining('Drops the link'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      // Dark: the label is the pre-P0b one, because there is no link to keep
      // and "reconnect" is exactly what the tap does.
      final dark = _FakeSeam(connected: false);
      await _pumpScreen(tester, dark, settle: false);
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.textContaining('Drops the link'), findsNothing);
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
      await tester.tap(find.text('Pin a node I run'));
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
      for (final control in const ['Use this explorer', 'Use this source']) {
        final field = control == 'Use this explorer'
            ? find.text('https://explorer.kaspa.org/txs/{txid}')
            : find.text('https://api.kaspa.org/info/price');
        await tester.enterText(field, 'http://nope.example/x');
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(control));
        await tester.pumpAndSettle();
        await tester.tap(find.text(control));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('explorer link refused'), findsOneWidget);
      expect(find.textContaining('rate source refused'), findsOneWidget);
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
      await tester.tap(find.text('Pin a node I run'));
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

  group('a sentence on the serving plate wraps — a number never does', () {
    testWidgets('the scan line renders whole at 320dp, not clipped', (
      tester,
    ) async {
      // **Measured, not asserted about the widget.** `find.text` matches the
      // string a `Text` was GIVEN, so it is blind to a clip — which is how
      // *"live — scanning every b"* reached the glass and passed the suite
      // (`ux-auditor`, this sitting). With the bundled font loaded, the line
      // is 27 characters at 0.60 em ≈ 210.6dp against the 176dp this row
      // leaves at 320dp, so a wrapping line MUST occupy more than one line
      // box and a clipping one occupies exactly one.
      final seam = seamFor();
      await _pumpScreen(tester, seam, width: 320, blockAge: () async => 1);
      await tester.pump();
      final line = find.text('live — scanning every block');
      expect(line, findsOneWidget);
      const lineHeight = 18.0; // 13dp at height 18/13, the plate's data style
      expect(
        tester.getSize(line).height,
        greaterThan(lineHeight * 1.5),
        reason: 'a label wraps (BG-14); only a number may not',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nothing on the serving plate is clipped at 320dp / 1.3x', (
      tester,
    ) async {
      // **The general guard, not another instance.** `find.text` matches the
      // string a `Text` was GIVEN and a clipped `Text` inside an `Expanded`
      // raises no overflow, so both of this sitting's clips were invisible to
      // a suite that was otherwise measuring the right screen. This lays the
      // plate out at the worst supported geometry and compares every reading
      // against what its own style actually needs.
      final rate = _FakeRate(
        quote: KvRateQuote(
          usdPerKas: 0.02864504,
          fetchedAt: DateTime(2026, 8, 27, 11, 58),
          source: 'https://api.kaspa.org/info/price',
        ),
      );
      await _pumpScreen(
        tester,
        seamFor(),
        rate: rate,
        blockAge: () async => 1,
        width: 320,
        height: 2400,
        textScale: 1.3,
      );
      await tester.pumpAndSettle();

      for (final finder in [
        find.text('live — scanning every block'),
        find.text('\$0.02864504'),
        find.text('2 m ago'),
        find.text('523,216,421'),
      ]) {
        expect(finder, findsOneWidget);
        final text = tester.widget<Text>(finder);
        final box = tester.getSize(finder);
        final painter = TextPainter(
          text: TextSpan(text: text.data, style: text.style),
          textDirection: TextDirection.ltr,
          maxLines: text.maxLines,
          textScaler: const TextScaler.linear(1.3),
        )..layout(maxWidth: box.width);
        expect(
          painter.didExceedMaxLines,
          isFalse,
          reason:
              '"${text.data}" needs more room than the ${box.width}dp it was '
              'given, and clips instead of wrapping or shrinking (BG-14)',
        );
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the DAA reading still refuses to wrap', (tester) async {
      // The other half: BG-14 lets a label wrap and forbids exactly this one
      // from doing it. A fix that made everything wrap would pass the test
      // above and break the law it was written for.
      final seam = seamFor();
      await _pumpScreen(tester, seam, width: 320);
      await tester.pump();
      final daa = find.text('523,216,421');
      expect(daa, findsOneWidget);
      expect(tester.widget<Text>(daa).maxLines, 1);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the explorer choice — a template, never a vendor list (D-207)', () {
    testWidgets('the audited defaults are offered, and one tap takes both', (
      tester,
    ) async {
      final explorer = _FakeExplorer();
      await _pumpScreen(tester, seamFor(), explorer: explorer, height: 2400);
      await tester.pumpAndSettle();

      // Two shipped starting points, named by host — "an explorer" cannot be
      // a sovereignty decision, so the row says which one.
      expect(find.text('explorer.kaspa.org'), findsOneWidget);
      expect(find.text('kaspa.stream'), findsOneWidget);
      // And the templates themselves are on the glass, editable — the field IS
      // the disclosure of where a link would go.
      expect(
        find.text('https://explorer.kaspa.org/txs/{txid}'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('kaspa.stream'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('kaspa.stream'));
      await tester.pumpAndSettle();
      // A transaction page and an address page are different paths, so a pick
      // must move BOTH — a half-applied default is a dead address link.
      expect(
        find.text('https://kaspa.stream/transactions/{txid}'),
        findsOneWidget,
      );
      expect(
        find.text('https://kaspa.stream/addresses/{address}'),
        findsOneWidget,
      );
      // Picking is not saving: nothing has been written yet.
      expect(explorer.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the two defaults are a CHIP ROW, not two stacked buttons', (
      tester,
    ) async {
      // Found on glass, not by the suite (2026-08-28 device pass): `_Pick` set
      // `alignment: Alignment.center` on its `Container`, which makes a
      // Container expand to its maximum constraint — so inside the `Wrap` each
      // pick took a whole line. Nothing overflowed, nothing threw, every
      // `find.text` passed, and the two-way choice read as two full-width
      // buttons down an already-long screen.
      //
      // The property is positional, so the assertion has to be: same row, and
      // neither one owning the width.
      final explorer = _FakeExplorer();
      await _pumpScreen(tester, seamFor(), explorer: explorer, height: 2400);
      await tester.pumpAndSettle();

      final org = tester.getRect(find.text('explorer.kaspa.org'));
      final stream = tester.getRect(find.text('kaspa.stream'));
      expect(
        org.center.dy,
        moreOrLessEquals(stream.center.dy, epsilon: 1),
        reason: 'both defaults sit on one line — it is a choice, not a stack',
      );
      // 393dp viewport minus the 24dp gutters; a pick that fills the row is the
      // defect, whatever it is aligned to.
      expect(
        org.width,
        lessThan(345 * 0.6),
        reason: 'a pick sizes to its label, never to the space available',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('saving reaches the seam verbatim', (tester) async {
      final explorer = _FakeExplorer();
      await _pumpScreen(tester, seamFor(), explorer: explorer, height: 2400);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Use this explorer'));
      await tester.pumpAndSettle();
      expect(
        find.text('These are already your explorer links.'),
        findsOneWidget,
        reason: 'BG-12: a disabled control always says why, in words',
      );

      await tester.enterText(
        find.text('https://explorer.kaspa.org/txs/{txid}'),
        '  https://mine.example/t/{txid} ',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this explorer'));
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
    });

    testWidgets("a refusal is shown, and does not touch the link's message", (
      tester,
    ) async {
      final explorer = _FakeExplorer(
        refuse: StateError('the explorer link must start with https://'),
      );
      final seam = seamFor();
      await _pumpScreen(tester, seam, explorer: explorer, height: 2400);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.text('https://explorer.kaspa.org/txs/{txid}'),
        'http://nope.example/{txid}',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this explorer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this explorer'));
      await tester.pumpAndSettle();

      expect(find.textContaining('must start with https://'), findsOneWidget);
      // The link's own state is a different fact and keeps its own line.
      expect(
        find.textContaining(
          'Answering — a public community node, found for you',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no seam, no section — never a control wired to nothing', (
      tester,
    ) async {
      await _pumpScreen(tester, seamFor(), height: 2400);
      await tester.pumpAndSettle();
      expect(find.text('Explorer'), findsNothing);
      expect(find.text('Use this explorer'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the fiat rate — the one claim consensus cannot check', () {
    testWidgets('what the source actually said is on the glass', (
      tester,
    ) async {
      final rate = _FakeRate(
        quote: KvRateQuote(
          usdPerKas: 0.02864504,
          fetchedAt: DateTime(2026, 8, 27, 11, 58),
          source: 'https://api.kaspa.org/info/price',
        ),
      );
      await _pumpScreen(tester, seamFor(), rate: rate, height: 2400);
      await tester.pumpAndSettle();

      // Verifiable rather than declarative: the setting shows the number it
      // produced and how old it is.
      expect(find.text('\$0.02864504'), findsOneWidget);
      expect(find.text('Price, per KAS'), findsOneWidget);
      expect(find.text('2 m ago'), findsOneWidget);
      // And the trust label names what the source can see and cannot do.
      expect(
        find.textContaining('no proof can check'),
        findsOneWidget,
        reason: 'BG-17 / ux-auditor 30: every endpoint row carries its label',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with no usable price the reading is an em dash', (
      tester,
    ) async {
      final rate = _FakeRate();
      await _pumpScreen(tester, seamFor(), rate: rate, height: 2400);
      await tester.pumpAndSettle();
      // BG-5's own rendering of an unknown. Never a stale figure at full
      // confidence, and never a fabricated one.
      expect(find.text('—'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('switching it off reaches the seam and hides the source', (
      tester,
    ) async {
      final rate = _FakeRate(
        quote: KvRateQuote(
          usdPerKas: 0.03,
          fetchedAt: DateTime(2026, 8, 27, 11, 58),
          source: 'https://api.kaspa.org/info/price',
        ),
      );
      await _pumpScreen(tester, seamFor(), rate: rate, height: 2400);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Show what your balance is worth'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show what your balance is worth'));
      await tester.pumpAndSettle();

      expect(rate.writes, [(false, 'https://api.kaspa.org/info/price')]);
      // Off means the endpoint field goes too: there is nothing to point at.
      expect(find.text('Price source'), findsNothing);
      expect(
        find.textContaining('Nothing is fetched'),
        findsOneWidget,
        reason: 'the off state says what it means, not just that it is off',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a rejected source is reported and not adopted', (
      tester,
    ) async {
      final rate = _FakeRate(
        refuse: StateError('the rate source must start with https://'),
      );
      await _pumpScreen(tester, seamFor(), rate: rate, height: 2400);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.text('https://api.kaspa.org/info/price'),
        'http://cleartext.example/price',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this source'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this source'));
      await tester.pumpAndSettle();

      expect(find.textContaining('must start with https://'), findsOneWidget);
      expect(
        rate.endpoint.value,
        'https://api.kaspa.org/info/price',
        reason: 'what the glass shows is what Rust stored',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a refused stored source can still be repaired', (
      tester,
    ) async {
      // `RateConfig::load` answers `enabled: false` while KEEPING an endpoint
      // it refuses — so the row can show what was refused. Gating the field on
      // the toggle hid the only control that could fix it: flipping the toggle
      // re-posts the same bad endpoint, is refused again, and there is no
      // field. A soft-lock (`consensus-auditor`, this sitting).
      final rate = _FakeRate(on: false);
      rate.endpoint.value = 'http://cleartext.example/price';
      rate.error.value = 'the rate source must start with https://';
      await _pumpScreen(tester, seamFor(), rate: rate, height: 2400);
      await tester.pumpAndSettle();

      expect(
        find.text('Price source'),
        findsOneWidget,
        reason: 'the field that repairs it must be reachable while it is off',
      );
      expect(find.textContaining('must start with https://'), findsOneWidget);
      // And the repair does not silently switch the rate back on.
      await tester.enterText(
        find.text('http://cleartext.example/price'),
        'https://mine.example/price',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use this source'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this source'));
      await tester.pumpAndSettle();
      expect(rate.writes, [(false, 'https://mine.example/price')]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with the shipped source and the rate off, no field', (
      tester,
    ) async {
      // The other proposition (`L126`): the field appears because there is
      // something to repair, not always. A user who simply turned fiat off
      // sees a switch and its explanation, and nothing else.
      final rate = _FakeRate(on: false);
      await _pumpScreen(tester, seamFor(), rate: rate, height: 2400);
      await tester.pumpAndSettle();
      expect(find.text('Price source'), findsNothing);
      expect(find.text('Use this source'), findsNothing);
      expect(find.text('Price'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no seam, no section', (tester) async {
      await _pumpScreen(tester, seamFor(), height: 2400);
      await tester.pumpAndSettle();
      expect(find.text('Fiat value'), findsNothing);
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
      expect(find.text('Node & connection'), findsOneWidget);
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
  home: HomeScreen(
    nodeRoute: node == null ? null : (_) => NodeScreen(scope: node),
    chain: ChainScope(
      connected: ValueNotifier<bool>(true),
      virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(499524873)),
      error: ValueNotifier<String?>(null),
      lastUpdate: ValueNotifier<DateTime?>(now),
    ),
    wallet: WalletScope(
      mature: ValueNotifier<BigInt?>(BigInt.from(123456789012)),
      pending: ValueNotifier<BigInt?>(null),
      activity: ValueNotifier<List<ActivityRecord>>(const []),
      syncing: ValueNotifier<bool>(false),
      utxoIndexMissing: ValueNotifier<bool>(false),
    ),
    clock: () => now,
  ),
);
