import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/transport.dart';
import 'package:kaspaverse/src/services/transport_service.dart';

TransportEventDto event(String? txid, {String kind = 'bcast'}) =>
    TransportEventDto(
      txid: txid,
      kind: kind,
      body: Uint8List.fromList('kv-dev:hi'.codeUnits),
      addresses: const ['kaspa:qzexample'],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StreamController<TransportEventDto> controller;

  setUp(() async {
    controller = StreamController<TransportEventDto>();
    TransportService.streamFactory = () => controller.stream;
    await TransportService.instance.reset();
  });

  tearDown(() async {
    await TransportService.instance.reset();
    await controller.close();
  });

  test('matches land newest-first', () async {
    final service = TransportService.instance..start();

    controller.add(event('aa'));
    controller.add(event('bb'));
    await Future<void>.delayed(Duration.zero);

    expect(service.events.value.map((e) => e.txid), ['bb', 'aa']);
  });

  test('start is idempotent — one subscription total (L4)', () async {
    final service = TransportService.instance
      ..start()
      ..start();

    controller.add(event('aa'));
    await Future<void>.delayed(Duration.zero);
    expect(service.events.value, hasLength(1));
  });

  test('a tx seen in two blocks shows once (DAG re-inclusion dedup)', () async {
    final service = TransportService.instance..start();

    controller.add(event('aa'));
    controller.add(event('aa'));
    // Id-less events can't dedup — they pass through (never dropped).
    controller.add(event(null));
    controller.add(event(null));
    await Future<void>.delayed(Duration.zero);

    expect(service.events.value, hasLength(3));
    expect(service.events.value.where((e) => e.txid == 'aa'), hasLength(1));
  });

  test('the live window is bounded', () async {
    final service = TransportService.instance..start();

    for (var i = 0; i < TransportService.maxEvents + 7; i++) {
      controller.add(event('tx$i'));
    }
    await Future<void>.delayed(Duration.zero);

    expect(service.events.value, hasLength(TransportService.maxEvents));
    // Newest survived the cap.
    expect(
      service.events.value.first.txid,
      'tx${TransportService.maxEvents + 6}',
    );
  });

  test('stream errors surface through the error notifier', () async {
    final service = TransportService.instance..start();

    controller.addError(const AppError(message: 'scan unavailable'));
    await Future<void>.delayed(Duration.zero);
    expect(service.error.value, 'scan unavailable');

    // A healthy match clears the error.
    controller.add(event('aa'));
    await Future<void>.delayed(Duration.zero);
    expect(service.error.value, isNull);
  });
}
