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
    // V3 seams: deterministic no-ops unless a test overrides them.
    WalletService.resyncFn = () async => false;
    WalletService.snapshotNowFn = () async => null;
    WalletService.reattachDelay = const Duration(milliseconds: 10);
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
    discoveryIncomplete: false,
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

  // ── V3: register item 10 heal — onDone re-attach ─────────────────────────

  test('a mid-session stream end re-attaches after the backoff', () async {
    var attaches = 0;
    final second = StreamController<WalletSnapshot>();
    WalletService.streamFactory = () {
      attaches++;
      return attaches == 1 ? controller.stream : second.stream;
    };
    wallet.start();
    // The engine proves live (the re-attach guard's precondition).
    controller.add(snap(mature: BigInt.one));
    await Future<void>.delayed(Duration.zero);
    expect(attaches, 1);

    // Mid-session death (the V2-sitting freeze family): the lane ends.
    await controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(attaches, 2, reason: 're-attach is the service\'s own kick');

    // The healed lane delivers again.
    second.add(snap(mature: BigInt.two));
    await Future<void>.delayed(Duration.zero);
    expect(wallet.mature.value, BigInt.two);

    // Stop the loop before closing the second stream (test hygiene).
    await wallet.reset();
    await second.close();
  });

  test('a stream that ends before the engine proved live stays down', () async {
    var attaches = 0;
    WalletService.streamFactory = () {
      attaches++;
      return controller.stream;
    };
    wallet.start();
    // Done with zero applies (e.g. a locked-vault subscribe): no re-attach —
    // the unlock flow owns the retry, not a blind 1 s loop.
    await controller.close();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(attaches, 1);
  });

  test('repeated stream deaths back off exponentially', () async {
    final marks = <String>[];
    WalletService.uiMarkFn = (m) async => marks.add(m);
    final extra = <StreamController<WalletSnapshot>>[];
    var calls = 0;
    WalletService.streamFactory = () {
      calls++;
      if (calls == 1) return controller.stream;
      final c = StreamController<WalletSnapshot>();
      extra.add(c);
      return c.stream;
    };
    wallet.start();
    controller.add(snap(mature: BigInt.one));
    await Future<void>.delayed(Duration.zero);
    await controller.close(); // death 1 → base delay
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await extra[0].close(); // death 2, no live apply between → doubled
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(marks.where((m) => m.startsWith('stream done')).toList(), [
      'stream done — re-attach in 10ms',
      'stream done — re-attach in 20ms',
    ]);
    await wallet.reset();
    for (final c in extra) {
      if (!c.isClosed) await c.close();
    }
  });

  test('reset cancels a pending re-attach', () async {
    var attaches = 0;
    WalletService.streamFactory = () {
      attaches++;
      return controller.stream;
    };
    wallet.start();
    controller.add(snap(mature: BigInt.one));
    await Future<void>.delayed(Duration.zero);
    await controller.close();
    // The backoff is armed; reset must disarm it (test teardown safety).
    await wallet.reset();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(attaches, 1);
  });

  // ── V3: register item 12 — the pull heal's two halves ────────────────────

  test('swipe refresh re-serves the fold AND asks the node', () async {
    var resyncs = 0;
    WalletService.resyncFn = () async {
      resyncs++;
      return true;
    };
    WalletService.snapshotNowFn = () async => snap(mature: BigInt.from(7));
    wallet.start(); // listen, so the suite's tearDown close() completes
    await wallet.refreshNow();
    // Delivery half: the fold's latest painted.
    expect(wallet.mature.value, BigInt.from(7));
    // Detection half: the node was asked (rate limiting lives in Rust).
    expect(resyncs, 1);
  });

  test('the freshness pull is local only — no node traffic', () async {
    var resyncs = 0;
    WalletService.resyncFn = () async {
      resyncs++;
      return true;
    };
    WalletService.snapshotNowFn = () async => snap(mature: BigInt.one);
    wallet.start(); // listen, so the suite's tearDown close() completes
    await wallet.refreshLocal();
    expect(wallet.mature.value, BigInt.one);
    expect(resyncs, 0, reason: 'the watchdog tick must never bounce sockets');
  });

  test('every apply stamps the freshness clock', () async {
    expect(wallet.lastApply, isNull);
    wallet.start();
    controller.add(snap(mature: BigInt.one));
    await Future<void>.delayed(Duration.zero);
    expect(wallet.lastApply, isNotNull);
  });
}
