import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/widgets/kv_loader.dart';
import 'package:kaspaverse/src/ui/widgets/status_beacon.dart';

/// C7 (D-091 ruling 1) — the honest link states, ON GLASS.
///
/// [evaluateBeacon]'s truth table is unit-tested in `status_beacon_test.dart`;
/// this file proves the three states are actually *distinguishable to a user*
/// and that a Reconnect tap is acknowledged in the frame after the tap.
void main() {
  Widget host({
    required ValueListenable<bool> connected,
    required ValueListenable<DateTime?> lastUpdate,
    required DateTime Function() clock,
    ValueListenable<bool>? searching,
    ValueListenable<bool>? osOffline,
    ValueListenable<DateTime?>? disconnectedAt,
    ValueListenable<bool>? reconnecting,
    Future<void> Function()? onReconnect,
  }) => MaterialApp(
    theme: kvDarkTheme(),
    home: HomeScreen(
      chain: ChainScope(
        connected: connected,
        endpoint: ValueNotifier<String?>('wss://nora.kaspa.stream/borsh'),
        virtualDaaScore: ValueNotifier<BigInt?>(BigInt.from(499524873)),
        error: ValueNotifier<String?>(null),
        lastUpdate: lastUpdate,
        searching: searching,
        osOffline: osOffline,
        disconnectedAt: disconnectedAt,
        reconnecting: reconnecting,
        onReconnect: onReconnect,
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

  group('StatusBeacon — three distinguishable truths (C7)', () {
    Future<void> pumpBeacon(WidgetTester tester, BeaconState state) =>
        tester.pumpWidget(
          MaterialApp(
            theme: kvDarkTheme(),
            home: Scaffold(
              body: StatusBeacon(state: state, error: null, age: null),
            ),
          ),
        );

    testWidgets('each state wears its own words', (tester) async {
      await pumpBeacon(tester, BeaconState.offline);
      expect(find.text('phone offline'), findsOneWidget);

      await pumpBeacon(tester, BeaconState.connecting);
      expect(find.text('finding a node…'), findsOneWidget);

      await pumpBeacon(tester, BeaconState.connected);
      expect(find.text('Mainnet'), findsOneWidget);

      // No two states share a label — colour is never the only signal (§11),
      // and here the words alone carry the whole truth.
      await pumpBeacon(tester, BeaconState.offline);
      expect(find.text('finding a node…'), findsNothing);
      expect(find.text('Mainnet'), findsNothing);
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

      expect(find.text('finding a node…'), findsOneWidget);
      expect(find.text('as of 20 s ago'), findsNothing);
      expect(find.textContaining('as of'), findsNothing);

      await tester.pumpWidget(const SizedBox()); // cancel the 1 s ticker
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

      expect(find.text('phone offline'), findsOneWidget);
      expect(find.text('finding a node…'), findsNothing);

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
      expect(find.text('Mainnet'), findsOneWidget);

      // The socket blips: dropped, and the race is already hunting.
      connected.value = false;
      searching.value = true;
      disconnectedAt.value = now;
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1)); // the freshness ticker
      expect(
        find.text('Mainnet'),
        findsOneWidget,
        reason: 'sub-2 s churn is noise, not information (item 16)',
      );

      // It stays down: honesty takes over once the hold expires.
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('finding a node…'), findsOneWidget);
      expect(find.text('Mainnet'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the network sheet acknowledges the tap (C7, ≤200 ms bar)', () {
    // Roomy surface, deliberately: widget tests render in a fallback font
    // whose glyphs are square em-boxes, so every label measures far wider
    // than on a device. Real phone geometry is proven on the device, not
    // here; this window just keeps the sheet's button inside the hit-test
    // area so the ACK — the thing under test — is what gets measured.
    void roomySurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(2000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    // Never pumpAndSettle in this group: the freshness ticker and KvBreath are
    // deliberately never-ending, so "settled" never arrives. Two pumps — the
    // first starts the route's ticker (elapsed 0), the second carries it past
    // the 250 ms entrance.
    Future<void> openSheet(WidgetTester tester, String beaconLabel) async {
      // The beacon is the only way in — the power-user detail lives behind it
      // (§12). No new entry point was added for C7 (INV-12).
      await tester.tap(find.text(beaconLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Network'), findsOneWidget);
    }

    testWidgets('one frame after the tap the sheet is visibly busy', (
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

      await openSheet(tester, 'Mainnet');
      expect(find.text('Reconnect'), findsOneWidget);
      expect(
        find.text('waiting for first block…'),
        findsOneWidget,
        reason: 'link up, no status yet — the honest pre-first-block line',
      );

      await tester.tap(find.text('Reconnect'));
      await tester.pump(); // exactly ONE frame after the tap
      expect(
        find.text('Searching…'),
        findsOneWidget,
        reason: 'the tap is acknowledged in the next frame, backend or not',
      );
      expect(find.byType(KvLoader), findsWidgets);

      tapped.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('mid-hunt the button reads busy AND stays kickable', (
      tester,
    ) async {
      // The R1 sheet drove the busy label off `reconnecting` alone, which
      // clears the instant the race is spawned — so a real 14–28 s hunt
      // rendered a button reading "Reconnect", idle-looking, for its whole
      // duration. The busy state must last as long as the search does; the
      // button must nonetheless stay tappable, because a tap mid-hunt IS
      // C4's kick.
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

      await openSheet(tester, 'finding a node…');
      expect(
        find.text('finding a node…'),
        findsWidgets,
        reason: 'the sheet must not disagree with the chip',
      );
      expect(
        find.text('Searching…'),
        findsOneWidget,
        reason: 'the hunt owns the busy label, not the millisecond dispatch',
      );
      expect(find.text('Reconnect'), findsNothing);
      // The link is down, so the scan line may not claim liveness — its own
      // 2 s poll would otherwise contradict the Status row beside it.
      expect(find.text('not scanning — no link'), findsOneWidget);
      expect(find.text('live — scanning every block'), findsNothing);

      await tester.tap(find.text('Searching…'));
      await tester.pump();
      expect(
        kicks,
        1,
        reason: 'a busy-looking button that cannot be tapped deletes C4',
      );

      await tester.pumpWidget(const SizedBox());
    });
  });
}
