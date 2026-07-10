import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/services/wallet_service.dart';

void main() {
  late StreamController<WalletSnapshot> controller;

  setUp(() async {
    controller = StreamController<WalletSnapshot>();
    WalletService.streamFactory = () => controller.stream;
    // No native lib in tests: the glass marker must resolve, not hang.
    WalletService.uiMarkFn = (_) async {};
    await WalletService.instance.reset();
  });

  tearDown(() async {
    await WalletService.instance.reset();
    await controller.close();
  });

  WalletSnapshot snap({
    bool connected = true,
    bool syncing = false,
    bool utxoIndexMissing = false,
    BigInt? mature,
    BigInt? pending,
    BigInt? outgoing,
    List<ActivityRecord> activity = const [],
    String? error,
  }) => WalletSnapshot(
    connected: connected,
    syncing: syncing,
    utxoIndexMissing: utxoIndexMissing,
    matureSompi: mature,
    pendingSompi: pending,
    outgoingSompi: outgoing,
    activity: activity,
    error: error,
  );

  final wallet = WalletService.instance;

  test('starts unknown — balance is null until the first sync (DS-1)', () {
    wallet.start();
    // Subscribed but no snapshot yet: the UI's initial state is unknown `—`,
    // never a fabricated 0.
    expect(wallet.mature.value, isNull);
    expect(wallet.lastUpdate.value, isNull);
  });

  test('an empty synced wallet is a live zero, not unknown', () async {
    wallet.start();
    controller.add(
      snap(mature: BigInt.zero, pending: BigInt.zero, outgoing: BigInt.zero),
    );
    await Future<void>.delayed(Duration.zero);

    // The critical bar: Some(0) (live zero), not null (unknown).
    expect(wallet.mature.value, BigInt.zero);
    expect(wallet.syncing.value, false);
    expect(wallet.lastUpdate.value, isNotNull);
  });

  test(
    'refreshNow pulls the latest snapshot past the stream (V2 heal)',
    () async {
      // Attach the stream listener so tearDown's controller.close() completes
      // (a single-subscription controller with no listener never closes).
      wallet.start();
      WalletService.snapshotNowFn = () async => snap(
        mature: BigInt.from(777),
        activity: [
          ActivityRecord(
            txid: 'e' * 64,
            valueSompi: BigInt.from(100000000),
            unixtimeMsec: BigInt.from(1),
            blockDaaScore: BigInt.from(10),
            direction: ActivityDirection.outgoing,
            isCoinbase: false,
            maturity: MaturityState.pending,
            stalled: false,
          ),
        ],
      );
      await wallet.refreshNow();
      expect(wallet.mature.value, BigInt.from(777));
      expect(wallet.activity.value, hasLength(1));
    },
  );

  test('balance + activity land in the notifiers (BigInt, L3)', () async {
    wallet.start();
    final record = ActivityRecord(
      txid: 'a' * 64,
      valueSompi: BigInt.from(50000000),
      unixtimeMsec: BigInt.from(1),
      blockDaaScore: BigInt.from(10),
      direction: ActivityDirection.incoming,
      isCoinbase: false,
      maturity: MaturityState.pending,
      stalled: false,
    );
    controller.add(
      snap(mature: BigInt.parse('12300000000'), activity: [record]),
    );
    await Future<void>.delayed(Duration.zero);

    expect(wallet.mature.value, BigInt.parse('12300000000'));
    expect(wallet.activity.value, hasLength(1));
    expect(wallet.activity.value.first.direction, ActivityDirection.incoming);
  });

  test('utxo-index-missing surfaces honestly (INV-8)', () async {
    wallet.start();
    controller.add(snap(utxoIndexMissing: true));
    await Future<void>.delayed(Duration.zero);
    expect(wallet.utxoIndexMissing.value, true);
  });

  test(
    'start is idempotent — a second call does not double-subscribe',
    () async {
      wallet.start();
      wallet.start();
      controller.add(snap(mature: BigInt.from(5)));
      await Future<void>.delayed(Duration.zero);
      expect(wallet.mature.value, BigInt.from(5));
    },
  );

  test('a stream error surfaces on the error notifier', () async {
    wallet.start();
    controller.addError(const AppError(message: 'wallet is locked'));
    await Future<void>.delayed(Duration.zero);
    expect(wallet.error.value, 'wallet is locked');
  });
}
