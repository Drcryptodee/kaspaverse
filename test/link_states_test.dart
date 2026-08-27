import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/node/node_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/widgets/kv_cadence.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';

/// C7 (D-091 ruling 1) — the honest link states, ON GLASS.
///
/// [evaluateBeacon]'s truth table is unit-tested in `status_beacon_test.dart`;
/// this file proves the states are actually *distinguishable to a user* and
/// that a Reconnect tap is acknowledged in the frame after the tap.
///
/// **UX-2 moved the surfaces these assertions ride on, and nothing else.** The
/// home beacon is retired: its green-for-healthy was the call site BG-7 took
/// away (§9.3 register item 2). The link now speaks through the money plate's
/// **trust line** — which is silent when the link is live, because a standing
/// "fine" beside a permanently animating meter reports that nothing changed,
/// twice (D-192) — and through the **network chip's lamp**, which carries the
/// good news on its own. The Reconnect action moved with the chip's
/// destination, onto the node surface. The C7/C4 bars are unchanged; only
/// where you look for them is.
void main() {
  NodeScope nodeScope({
    required ValueListenable<bool> connected,
    required ValueListenable<DateTime?> lastUpdate,
    ValueListenable<bool>? searching,
    ValueListenable<bool>? osOffline,
    ValueListenable<bool>? reconnecting,
    Future<void> Function()? onReconnect,
    Future<int?> Function()? blockAgeSecs,
  }) => NodeScope(
    connected: connected,
    activeEndpoint: ValueNotifier<String?>('wss://nora.kaspa.stream/borsh'),
    virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(499524873)),
    pinnedNode: ValueNotifier<String?>(null),
    pinDropped: ValueNotifier<bool>(false),
    setPinnedNode: (_) async {},
    lastUpdate: lastUpdate,
    searching: searching,
    osOffline: osOffline,
    reconnecting: reconnecting,
    onReconnect: onReconnect,
    blockAgeSecs: blockAgeSecs,
  );

  Widget host({
    required ValueListenable<bool> connected,
    required ValueListenable<DateTime?> lastUpdate,
    required DateTime Function() clock,
    ValueListenable<bool>? searching,
    ValueListenable<bool>? osOffline,
    ValueListenable<DateTime?>? disconnectedAt,
    ValueListenable<bool>? reconnecting,
    Future<void> Function()? onReconnect,
    bool withNode = true,
  }) => MaterialApp(
    theme: kvDarkTheme(),
    home: HomeScreen(
      nodeRoute: withNode
          ? (_) => NodeScreen(
              scope: nodeScope(
                connected: connected,
                lastUpdate: lastUpdate,
                searching: searching,
                osOffline: osOffline,
                reconnecting: reconnecting,
                onReconnect: onReconnect,
              ),
            )
          : null,
      chain: ChainScope(
        connected: connected,
        virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(499524873)),
        error: ValueNotifier<String?>(null),
        lastUpdate: lastUpdate,
        searching: searching,
        osOffline: osOffline,
        disconnectedAt: disconnectedAt,
        reconnecting: reconnecting,
      ),
      wallet: WalletScope(
        mature: ValueNotifier<BigInt?>(BigInt.from(123456789012)),
        pending: ValueNotifier<BigInt?>(null),
        activity: ValueNotifier<List<ActivityRecord>>(const []),
        syncing: ValueNotifier<bool>(false),
        utxoIndexMissing: ValueNotifier<bool>(false),
      ),
      clock: clock,
    ),
  );

  /// **The chip's lamp is the standing link indicator** (founder call,
  /// 2026-08-27, amending BG-7's D-200 narrowing — see `_NetworkChip`'s doc).
  ///
  /// Read from the FIRST lamp on the screen, which is the chip's: it is
  /// rendered before the trust line's. Asserting the tone rather than a
  /// presence is what catches the P0.3 shape — a lamp that reads live beside
  /// words that say the link is gone.
  bool linkReadsLive(WidgetTester tester) =>
      tester.widgetList<KvLamp>(find.byType(KvLamp)).first.tone ==
      KvLampTone.ok;

  group('the money plate — distinguishable truths (C7)', () {
    testWidgets('each state wears its own words, and health is silent', (
      tester,
    ) async {
      final now = DateTime(2026, 7, 30, 0, 53);
      final connected = ValueNotifier<bool>(true);
      final searching = ValueNotifier<bool>(false);
      final osOffline = ValueNotifier<bool>(false);

      await tester.pumpWidget(
        host(
          connected: connected,
          lastUpdate: ValueNotifier<DateTime?>(now),
          searching: searching,
          osOffline: osOffline,
          clock: () => now,
        ),
      );

      // Live: the trust line says NOTHING. Silence is the healthy state
      // (D-192) — the chip's lamp is the whole report.
      expect(find.textContaining('finding a node…'), findsNothing);
      expect(find.textContaining('phone offline'), findsNothing);
      expect(linkReadsLive(tester), isTrue);
      expect(find.text('Mainnet'), findsOneWidget);

      connected.value = false;
      searching.value = true;
      await tester.pump();
      expect(find.textContaining('finding a node…'), findsOneWidget);
      expect(linkReadsLive(tester), isFalse);

      osOffline.value = true;
      await tester.pump();
      expect(find.textContaining('phone offline — no network'), findsOneWidget);
      // No two states share a label — colour is never the only signal, and
      // here the words alone carry the whole truth.
      expect(find.textContaining('finding a node…'), findsNothing);
      expect(linkReadsLive(tester), isFalse);

      // The network's NAME is not its health. The chip says Mainnet through
      // every one of these and reports none of them — it is a door, and the
      // trust line is the indicator.
      expect(find.text('Mainnet'), findsOneWidget);

      await tester.pumpWidget(const SizedBox()); // cancel the 1 s ticker
    });
  });

  group('the home glass during a hunt (the 2026-07-30 field case)', () {
    testWidgets('a warm-process hunt reads finding a node, not "as of N ago"', (
      tester,
    ) async {
      // Observation A's exact shape: the process is warm (a fresh snapshot
      // landed 20 s ago), the socket is gone, and a race is hunting. Before
      // C7 this glass said "as of 20 s ago" and the founder could not tell
      // whether the app was working.
      final now = DateTime(2026, 7, 30, 0, 53);
      final connected = ValueNotifier<bool>(false);
      final lastUpdate = ValueNotifier<DateTime?>(
        now.subtract(const Duration(seconds: 20)),
      );
      final searching = ValueNotifier<bool>(true);

      await tester.pumpWidget(
        host(
          connected: connected,
          lastUpdate: lastUpdate,
          searching: searching,
          clock: () => now,
        ),
      );

      // C7's ruling, kept exactly: the hunt is what the sentence SAYS, and the
      // age is a clause under it. A bare "as of 20 s ago" reads as *connected,
      // data slightly stale* — the opposite of the truth — and that is the
      // defect this test was written for. The age still has to be there, or a
      // balance dimmed to 45% has no age beside it at all (BG-8).
      final said = tester
          .widget<Text>(find.textContaining('finding a node…'))
          .data!;
      expect(said, startsWith('finding a node…'));
      expect(said, contains('last update 20 s ago'));
      // Motion means something is happening, and a hunt IS something
      // happening — the meter is the tell that separates searching from dead.
      expect(tester.widget<KvCadence>(find.byType(KvCadence)).running, isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the OS-offline truth names the phone', (tester) async {
      final now = DateTime(2026, 7, 30, 0, 53);
      final connected = ValueNotifier<bool>(false);

      await tester.pumpWidget(
        host(
          connected: connected,
          lastUpdate: ValueNotifier<DateTime?>(
            now.subtract(const Duration(seconds: 20)),
          ),
          searching: ValueNotifier<bool>(true),
          osOffline: ValueNotifier<bool>(true),
          clock: () => now,
        ),
      );

      expect(find.textContaining('phone offline — no network'), findsOneWidget);
      expect(find.textContaining('finding a node…'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a 2 s blip does not flip the glass; a real drop does', (
      tester,
    ) async {
      var now = DateTime(2026, 7, 30, 0, 53);
      final connected = ValueNotifier<bool>(true);
      final lastUpdate = ValueNotifier<DateTime?>(now);
      final searching = ValueNotifier<bool>(false);
      final disconnectedAt = ValueNotifier<DateTime?>(null);

      await tester.pumpWidget(
        host(
          connected: connected,
          lastUpdate: lastUpdate,
          searching: searching,
          disconnectedAt: disconnectedAt,
          clock: () => now,
        ),
      );
      expect(linkReadsLive(tester), isTrue);

      // The socket blips: dropped, and the race is already hunting.
      connected.value = false;
      searching.value = true;
      disconnectedAt.value = now;
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1)); // the freshness ticker
      expect(
        linkReadsLive(tester),
        isTrue,
        reason: 'sub-2 s churn is noise, not information (item 16)',
      );
      expect(find.textContaining('finding a node…'), findsNothing);

      // It stays down: honesty takes over once the hold expires.
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('finding a node…'), findsOneWidget);
      expect(linkReadsLive(tester), isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a stale link wears its age, and the meter freezes', (
      tester,
    ) async {
      // BG-8's whole demand in one frame: dimmed cached truth, a VISIBLE age,
      // and a meter that is not pretending to work. A frozen cadence beside a
      // dimmed number is what "the link died" looks like; a running one would
      // say a hunt is under way, which would be a lie here.
      var now = DateTime(2026, 7, 30, 0, 53);
      final connected = ValueNotifier<bool>(false);

      await tester.pumpWidget(
        host(
          connected: connected,
          lastUpdate: ValueNotifier<DateTime?>(
            now.subtract(const Duration(seconds: 20)),
          ),
          searching: ValueNotifier<bool>(false),
          disconnectedAt: ValueNotifier<DateTime?>(
            now.subtract(const Duration(seconds: 20)),
          ),
          clock: () => now,
        ),
      );
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('as of 21 s ago'), findsOneWidget);
      expect(
        tester.widget<KvCadence>(find.byType(KvCadence)).running,
        isFalse,
        reason: 'nothing is happening, so nothing may look like it is',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the node surface acknowledges the tap (C7, ≤200 ms bar)', () {
    // Roomy surface, deliberately: widget tests render in a fallback font
    // whose glyphs are square em-boxes, so every label measures far wider
    // than on a device. Real phone geometry is proven on the device, not
    // here; this window just keeps the button inside the hit-test area so the
    // ACK — the thing under test — is what gets measured.
    void roomySurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(2000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    // Never pumpAndSettle in this group: the freshness ticker and a hunting
    // cadence are deliberately never-ending, so "settled" never arrives.
    Future<void> openNode(WidgetTester tester) async {
      // One frame for the pinned plate to report its measured extent. Before
      // it does, the header is the 1dp bootstrap and the chip is not where a
      // finger would find it — invisible to a user behind the entrance fade,
      // but a tap dispatched inside that frame would miss.
      await tester.pump();
      // The network chip is the money screen's only door to the node surface
      // (D-191/D-206) — asserted end to end rather than assumed, because a
      // surface nobody can reach is the defect this whole line exists to fix.
      await tester.tap(find.text('Mainnet'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Node & connection'), findsOneWidget);
    }

    testWidgets('one frame after the tap the surface is visibly busy', (
      tester,
    ) async {
      roomySurface(tester);
      final now = DateTime(2026, 7, 30, 0, 53);
      final reconnecting = ValueNotifier<bool>(false);
      final tapped = Completer<void>();

      await tester.pumpWidget(
        host(
          connected: ValueNotifier<bool>(true),
          lastUpdate: ValueNotifier<DateTime?>(now),
          searching: ValueNotifier<bool>(false),
          reconnecting: reconnecting,
          // ChainService flips `reconnecting` synchronously before its first
          // await (proven in chain_service_test); the fake mirrors that
          // ordering so this test measures the RENDER, not the fake.
          onReconnect: () {
            reconnecting.value = true;
            return tapped.future;
          },
          clock: () => now,
        ),
      );

      await openNode(tester);
      expect(find.text('Reconnect'), findsOneWidget);

      await tester.tap(find.text('Reconnect'));
      await tester.pump(); // exactly ONE frame after the tap
      expect(
        find.text('Searching…'),
        findsOneWidget,
        reason: 'the tap is acknowledged in the next frame, backend or not',
      );

      tapped.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('mid-hunt the button reads busy, and the words agree', (
      tester,
    ) async {
      // The R1 sheet drove the busy label off `reconnecting` alone, which
      // clears the instant the race is spawned — so a real 14–28 s hunt
      // rendered a button reading "Reconnect", idle-looking, for its whole
      // duration. The busy state must last as long as the search does.
      roomySurface(tester);
      final now = DateTime(2026, 7, 30, 0, 53);
      var kicks = 0;

      await tester.pumpWidget(
        host(
          connected: ValueNotifier<bool>(false),
          lastUpdate: ValueNotifier<DateTime?>(
            now.subtract(const Duration(seconds: 20)),
          ),
          searching: ValueNotifier<bool>(true),
          // Never flips: the engine's own hunt, no tap involved. This is the
          // state the old label was blind to.
          reconnecting: ValueNotifier<bool>(false),
          onReconnect: () async => kicks++,
          clock: () => now,
        ),
      );

      expect(find.textContaining('finding a node…'), findsOneWidget);
      await openNode(tester);
      expect(
        find.text('Looking for a node…'),
        findsOneWidget,
        reason:
            'the node surface must not disagree with the plate it came from',
      );
      expect(
        find.text('Searching…'),
        findsOneWidget,
        reason: 'the hunt owns the busy label, not the millisecond dispatch',
      );
      expect(find.text('Reconnect'), findsNothing);
      expect(kicks, 0);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the scan line survives the collapse into the node surface', () {
    // The sheet is gone (UX-3) and `NodeScreen` renders its scan line now. The
    // coverage moves with the feature rather than dying with the surface:
    // **the sovereign path is never the degraded path** (D-207 clause c), and
    // a line that quietly stopped being rendered would be exactly that.
    Future<void> pumpNode(
      WidgetTester tester, {
      required bool connected,
      required bool searching,
      required DateTime now,
      required Duration since,
      required Future<int?> Function()? blockAge,
    }) async {
      tester.view.physicalSize = const Size(2000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: kvDarkTheme(),
          home: NodeScreen(
            clock: () => now,
            scope: nodeScope(
              connected: ValueNotifier<bool>(connected),
              lastUpdate: ValueNotifier<DateTime?>(now.subtract(since)),
              searching: ValueNotifier<bool>(searching),
              osOffline: ValueNotifier<bool>(false),
              reconnecting: ValueNotifier<bool>(false),
              onReconnect: () async {},
              blockAgeSecs: blockAge,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a live link with no block yet says so', (tester) async {
      final now = DateTime(2026, 7, 30, 0, 53);
      await pumpNode(
        tester,
        connected: true,
        searching: false,
        now: now,
        since: Duration.zero,
        blockAge: () async => null,
      );
      expect(
        find.text('waiting for first block…'),
        findsOneWidget,
        reason: 'link up, no block seen yet — the honest pre-first-block line',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a live link with a fresh block claims the scan', (
      tester,
    ) async {
      // **The no-trigger half** (`L126`): every assertion below used to drive
      // the degraded branch, and a line that only ever renders its fallback
      // passes a suite while being wrong on every screen.
      final now = DateTime(2026, 7, 30, 0, 53);
      await pumpNode(
        tester,
        connected: true,
        searching: false,
        now: now,
        since: Duration.zero,
        blockAge: () async => 1,
      );
      await tester.pump();
      expect(find.text('live — scanning every block'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a slow chain reports the gap rather than claiming life', (
      tester,
    ) async {
      final now = DateTime(2026, 7, 30, 0, 53);
      await pumpNode(
        tester,
        connected: true,
        searching: false,
        now: now,
        since: Duration.zero,
        blockAge: () async => 42,
      );
      await tester.pump();
      expect(find.text('42 s since last block'), findsOneWidget);
      expect(find.text('live — scanning every block'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a dark link may not claim the scan is live', (tester) async {
      final now = DateTime(2026, 7, 30, 0, 53);
      await pumpNode(
        tester,
        connected: false,
        searching: true,
        now: now,
        since: const Duration(seconds: 20),
        blockAge: () async => null,
      );
      // The link decides whether the scan may claim liveness; the age only
      // refines the claim. Otherwise a 2 s poll could read "live — scanning
      // every block" beside a status chip saying the opposite.
      expect(find.text('not scanning — no link'), findsOneWidget);
      expect(find.text('live — scanning every block'), findsNothing);
      expect(find.text('Searching…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a link that is up but hunting does not claim it either', (
      tester,
    ) async {
      // The nastiest of the four: `connected` is true in the snapshot while a
      // race bounces the socket underneath, and a scan line that read only
      // `connected` would print "live" beside a plate saying "Looking for a
      // node…" — the C7 split the serving plate's own ordering exists to stop.
      final now = DateTime(2026, 7, 30, 0, 53);
      await pumpNode(
        tester,
        connected: true,
        searching: true,
        now: now,
        since: Duration.zero,
        blockAge: () async => 1,
      );
      await tester.pump();
      expect(find.text('live — scanning every block'), findsNothing);
      expect(find.text('1 s since last block'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no seam, no line — never a fabricated age', (tester) async {
      final now = DateTime(2026, 7, 30, 0, 53);
      await pumpNode(
        tester,
        connected: true,
        searching: false,
        now: now,
        since: Duration.zero,
        blockAge: null,
      );
      await tester.pump();
      expect(find.text('Transport scan'), findsNothing);
      expect(find.textContaining('since last block'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
