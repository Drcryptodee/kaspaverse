import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/dag.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/services/chain_service.dart';

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
    statusValue = const DagStatusDto(connected: true, lastBlockAgeSecs: null);
    ChainService.statusFn = () async => statusValue;
    ChainService.reconnectFn = () async => reconnectCalls++;
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
      statusValue = DagStatusDto(
        connected: true,
        lastBlockAgeSecs: BigInt.from(30),
      );
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
      statusValue = DagStatusDto(
        connected: true,
        lastBlockAgeSecs: BigInt.from(1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(reconnectCalls, 0);
    });

    test('the watchdog stays quiet while backgrounded', () async {
      final service = ChainService.instance..start();
      // Stalled, but we're backgrounded — the grace-drop owns the socket.
      statusValue = DagStatusDto(
        connected: true,
        lastBlockAgeSecs: BigInt.from(30),
      );
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
  });
}
