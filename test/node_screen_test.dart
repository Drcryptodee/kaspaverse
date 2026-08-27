import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
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

  NodeScope get scope => NodeScope(
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
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _FakeSeam seam, {
  double width = 393,
  double textScale = 1,
  // A dark link is a link being hunted, so the cadence runs and "settled"
  // never arrives — which is the meter doing its job, not a test problem.
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: MaterialApp(
        theme: ThemeData(scaffoldBackgroundColor: KvColor.abyss),
        home: NodeScreen(
          scope: seam.scope,
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

void main() {
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
      expect(find.text('Answering — a public community node.'), findsOneWidget);

      seam.searching.value = true;
      await tester.pump();
      expect(_cadenceRunning(tester), isTrue);
      expect(find.text('Looking for a node…'), findsOneWidget);
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
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.text('Searching…'), findsNothing);

      await tester.tap(find.text('Reconnect'));
      await tester.pump();
      expect(seam.kicks, 1);
      // The busy state rides the HUNT, not the dispatch — and the label swap
      // IS the signal, because BG-2 will not pay for a second meter on a
      // screen whose serving plate already runs one.
      expect(find.text('Searching…'), findsOneWidget);
      expect(find.text('Reconnect'), findsNothing);
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
Widget _home({required NodeScope? node, required DateTime now}) => MaterialApp(
  theme: kvDarkTheme(),
  home: HomeScreen(
    chain: ChainScope(
      connected: ValueNotifier<bool>(true),
      virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(499524873)),
      error: ValueNotifier<String?>(null),
      lastUpdate: ValueNotifier<DateTime?>(now),
      node: node,
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
