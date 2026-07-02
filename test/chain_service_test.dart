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

  setUp(() async {
    controller = StreamController<DagSnapshot>();
    ChainService.streamFactory = () => controller.stream;
    pauseCalls = 0;
    resumeCalls = 0;
    ChainService.pauseBridge = () async => pauseCalls++;
    ChainService.resumeBridge = () async => resumeCalls++;
    ChainService.graceDuration = const Duration(milliseconds: 20);
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
}
