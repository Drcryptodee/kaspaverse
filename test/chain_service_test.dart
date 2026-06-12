import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/dag.dart';
import 'package:kaspaverse/src/services/chain_service.dart';

void main() {
  late StreamController<DagSnapshot> controller;

  setUp(() async {
    controller = StreamController<DagSnapshot>();
    ChainService.streamFactory = () => controller.stream;
    await ChainService.instance.reset();
  });

  tearDown(() async {
    await ChainService.instance.reset();
    await controller.close();
  });

  test('folded snapshots land in the notifiers', () async {
    final service = ChainService.instance..start();

    controller.add(DagSnapshot(
      connected: true,
      endpoint: 'wss://node.example/borsh',
      virtualDaaScore: BigInt.parse('18446744073709551615'), // u64::MAX
      sinkBlueScore: BigInt.from(456290012),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(service.connected.value, isTrue);
    expect(service.endpoint.value, 'wss://node.example/borsh');
    // Survives the > 2^53 range intact (L3).
    expect(
      service.virtualDaaScore.value,
      BigInt.parse('18446744073709551615'),
    );
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
}
