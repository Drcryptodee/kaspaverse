import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/dag.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/services/chain_service.dart';

/// The pull DTO, built by field so a new bit (C7 added two) never edits every
/// call site again.
DagStatusDto status({
  bool connected = true,
  int? blockAgeSecs,
  bool searching = false,
  bool osOffline = false,
}) => DagStatusDto(
  connected: connected,
  lastBlockAgeSecs: blockAgeSecs == null ? null : BigInt.from(blockAgeSecs),
  searching: searching,
  osOffline: osOffline,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<DagSnapshot> controller;
  late int pauseCalls;
  late int resumeCalls;
  late int reconnectCalls;
  late DagStatusDto statusValue;

  setUp(() async {
    controller = StreamController<DagSnapshot>();
    ChainService.streamFactory = () => controller.stream;
    pauseCalls = 0;
    resumeCalls = 0;
    reconnectCalls = 0;
    ChainService.pauseBridge = () async => pauseCalls++;
    ChainService.resumeBridge = () async => resumeCalls++;
    ChainService.graceDuration = const Duration(milliseconds: 20);
    // Watchdog: fast cadence + low stall threshold, healthy by default.
    statusValue = status();
    ChainService.statusFn = () async => statusValue;
    ChainService.reconnectFn = (stalled) async => reconnectCalls++;
    ChainService.watchdogPeriod = const Duration(milliseconds: 10);
    ChainService.watchdogStallSecs = 5;
    await ChainService.instance.reset();
  });

  tearDown(() async {
    await ChainService.instance.reset();
    await controller.close();
  });

  test('folded snapshots land in the notifiers', () async {
    final service = ChainService.instance..start();

    controller.add(
      DagSnapshot(
        connected: true,
        endpoint: 'wss://node.example/borsh',
        virtualDaaScore: BigInt.parse('18446744073709551615'), // u64::MAX
        sinkBlueScore: BigInt.from(456290012),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(service.connected.value, isTrue);
    expect(service.endpoint.value, 'wss://node.example/borsh');
    // Survives the > 2^53 range intact (L3).
    expect(service.virtualDaaScore.value, BigInt.parse('18446744073709551615'));
    expect(service.sinkBlueScore.value, BigInt.from(456290012));
    expect(service.error.value, isNull);
  });

  test('start is idempotent — one subscription total (L4)', () async {
    final service = ChainService.instance
      ..start()
      ..start();

    // A second listen on a non-broadcast stream would have thrown; pushing
    // an event proves the single subscription is the live one.
    controller.add(const DagSnapshot(connected: true));
    await Future<void>.delayed(Duration.zero);
    expect(service.connected.value, isTrue);
  });

  test('stream errors surface through the error notifier', () async {
    final service = ChainService.instance..start();

    controller.addError(const AppError(message: 'resolver unreachable'));
    await Future<void>.delayed(Duration.zero);
    expect(service.error.value, 'resolver unreachable');

    // A healthy snapshot clears the error.
    controller.add(const DagSnapshot(connected: true));
    await Future<void>.delayed(Duration.zero);
    expect(service.error.value, isNull);
  });

  group('OS network signal relay (C5/D-089)', () {
    // Drive the platform channel exactly as MainActivity's native
    // invokeMethod would; the relay must reach the bridge seam untouched —
    // Rust owns the semantics, Dart carries the bool.
    Future<void> nativeNetworkChanged(Object? payload) async {
      final messenger =
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
      await messenger.handlePlatformMessage(
        'org.kaspaverse.app/network',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('networkChanged', payload),
        ),
        (_) {},
      );
    }

    test('networkChanged reaches the bridge with the OS bool', () async {
      final forwarded = <bool>[];
      ChainService.networkChangedBridge = (available) async =>
          forwarded.add(available);
      ChainService.instance.start();

      await nativeNetworkChanged(true);
      await nativeNetworkChanged(false);
      expect(forwarded, [true, false]);
    });

    test('a non-bool payload and a bridge failure are swallowed', () async {
      var calls = 0;
      ChainService.networkChangedBridge = (available) async {
        calls++;
        throw const AppError(message: 'bridge down');
      };
      ChainService.instance.start();

      await nativeNetworkChanged('garbage'); // ignored: not a bool
      expect(calls, 0);
      await nativeNetworkChanged(true); // forwarded; failure swallowed
      expect(calls, 1);
    });
  });

  group('background grace-drop (PERFORMANCE_BUDGET battery posture)', () {
    test(
      'background past the grace drops the socket; resume reconnects',
      () async {
        final service = ChainService.instance..start();

        service.didChangeAppLifecycleState(AppLifecycleState.paused);
        expect(pauseCalls, 0, reason: 'inside the grace window — still up');
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(pauseCalls, 1, reason: 'grace elapsed — socket dropped');

        service.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);
        expect(resumeCalls, 1, reason: 'we dropped it — we reconnect');
      },
    );

    test(
      'resume inside the grace window cancels the drop — no bounce',
      () async {
        final service = ChainService.instance..start();

        service.didChangeAppLifecycleState(AppLifecycleState.paused);
        service.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          pauseCalls,
          0,
          reason: 'drop cancelled before the grace elapsed',
        );
        expect(
          resumeCalls,
          0,
          reason: 'nothing was dropped — nothing to resume',
        );
      },
    );

    test('repeated pause events arm one timer, not several', () async {
      final service = ChainService.instance..start();

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(pauseCalls, 1);
    });
  });

  group('foreground liveness watchdog (P3/D-068)', () {
    test('a stalled chain while foreground forces a reconnect', () async {
      ChainService.instance.start();
      // Block-age past the stall threshold: the socket went silently dead.
      statusValue = status(blockAgeSecs: 30);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        reconnectCalls,
        greaterThanOrEqualTo(1),
        reason: 'the watchdog recovered the dead socket',
      );
    });

    test('a live chain never triggers a reconnect', () async {
      ChainService.instance.start();
      // Fresh blocks arriving — nothing to recover.
      statusValue = status(blockAgeSecs: 1);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(reconnectCalls, 0);
    });

    test('the watchdog stays quiet while backgrounded', () async {
      final service = ChainService.instance..start();
      // Stalled, but we're backgrounded — the grace-drop owns the socket.
      statusValue = status(blockAgeSecs: 30);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        reconnectCalls,
        0,
        reason: 'no watchdog reconnects while the app is backgrounded',
      );
    });

    test(
      'the reconnecting indicator toggles around a manual reconnect',
      () async {
        final service = ChainService.instance..start();
        final seen = <bool>[];
        service.reconnecting.addListener(
          () => seen.add(service.reconnecting.value),
        );
        await service.reconnect();
        expect(reconnectCalls, 1);
        // It rose to true (honest indicator) and settled back to false.
        expect(seen, contains(true));
        expect(service.reconnecting.value, isFalse);
      },
    );

    // ── V3: the stall evidence bit (demotion's control-group input) ────────

    test(
      'a watchdog reconnect carries stalled=true; manual carries false',
      () async {
        final stalledSeen = <bool>[];
        ChainService.reconnectFn = (stalled) async => stalledSeen.add(stalled);
        final service = ChainService.instance..start();
        // Manual button first: bouncing a healthy node is never evidence.
        await service.reconnect();
        expect(stalledSeen, [false]);
        // Then a genuine stall: 30 s past threshold while foreground.
        statusValue = status(blockAgeSecs: 30);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(stalledSeen, contains(true));
      },
    );

    // ── V3: register item 10 — the freshness watchdog's local pull ─────────

    test('a connected-but-quiet wallet lane gets a local pull', () async {
      var pulls = 0;
      final service = ChainService.instance;
      service.walletLastApply = () =>
          DateTime.now().subtract(const Duration(seconds: 60));
      service.onWalletQuiet = () => pulls++;
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(pulls, greaterThan(0));
    });

    test('a fresh wallet lane is left alone', () async {
      var pulls = 0;
      final service = ChainService.instance;
      service.walletLastApply = () => DateTime.now();
      service.onWalletQuiet = () => pulls++;
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(pulls, 0);
    });

    test('a disconnected link never triggers the wallet pull', () async {
      var pulls = 0;
      statusValue = status(connected: false);
      final service = ChainService.instance;
      service.walletLastApply = () =>
          DateTime.now().subtract(const Duration(seconds: 60));
      service.onWalletQuiet = () => pulls++;
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(pulls, 0, reason: 'quiet-while-down is the LINK\'s problem');
    });
  });

  // ── C7 (D-091): the honest-states lane ───────────────────────────────────
  group('honest link states (C7)', () {
    setUp(() {
      ChainService.linkPollPeriod = const Duration(milliseconds: 10);
      // Park the watchdog so its own pulls can't be mistaken for the link
      // poll's in the call counts below.
      ChainService.watchdogPeriod = const Duration(seconds: 30);
    });

    test('while dark, the engine bits reach the notifiers', () async {
      statusValue = status(connected: false, searching: true);
      final service = ChainService.instance..start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.searching.value, isTrue);
      expect(service.osOffline.value, isFalse);

      statusValue = status(connected: false, searching: false, osOffline: true);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.osOffline.value, isTrue, reason: 'the OS said onLost');
      expect(service.searching.value, isFalse);
    });

    test('a connected link costs NO bridge call (battery posture)', () async {
      var pulls = 0;
      ChainService.statusFn = () async {
        pulls++;
        return statusValue;
      };
      final service = ChainService.instance..start();
      controller.add(const DagSnapshot(connected: true));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        pulls,
        0,
        reason: 'a live socket is neither hunting nor offline — nothing to ask',
      );
      expect(service.searching.value, isFalse);
      expect(service.osOffline.value, isFalse);
    });

    test('backgrounded, the poll stands down', () async {
      statusValue = status(connected: false, searching: true);
      var pulls = 0;
      ChainService.statusFn = () async {
        pulls++;
        return statusValue;
      };
      final service = ChainService.instance..start();
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(pulls, 0, reason: 'the grace-drop owns the socket while dark');
    });

    test('a connect clears the hunt bits and the drop clock', () async {
      statusValue = status(connected: false, searching: true, osOffline: true);
      final service = ChainService.instance..start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.searching.value, isTrue);
      expect(service.osOffline.value, isTrue);

      controller.add(const DagSnapshot(connected: true));
      await Future<void>.delayed(Duration.zero);
      expect(service.searching.value, isFalse);
      expect(service.osOffline.value, isFalse);
      expect(service.disconnectedAt.value, isNull);
    });

    test(
      'the drop clock starts when the link dies (churn hold input)',
      () async {
        final service = ChainService.instance..start();
        controller.add(const DagSnapshot(connected: true));
        await Future<void>.delayed(Duration.zero);
        expect(service.disconnectedAt.value, isNull);

        controller.add(const DagSnapshot(connected: false));
        await Future<void>.delayed(Duration.zero);
        expect(service.disconnectedAt.value, isNotNull);
      },
    );

    test(
      'the Reconnect ack is synchronous — no await before it shows',
      () async {
        final service = ChainService.instance..start();
        final inFlight = service.reconnect(); // deliberately not awaited yet
        expect(
          service.reconnecting.value,
          isTrue,
          reason:
              'the honest indicator must be set BEFORE the first await — '
              'that is what makes the tap ack a render, not a round-trip',
        );
        await inFlight;
        expect(service.reconnecting.value, isFalse);
      },
    );
  });
}
