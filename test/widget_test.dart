import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';

void main() {
  testWidgets('wallet home: connecting → live empty zero → funds → stale', (
    tester,
  ) async {
    final connected = ValueNotifier<bool>(false);
    final endpoint = ValueNotifier<String?>(null);
    final daa = ValueNotifier<BigInt?>(null);
    final error = ValueNotifier<String?>(null);
    final lastUpdate = ValueNotifier<DateTime?>(null);
    final mature = ValueNotifier<BigInt?>(null);
    final pending = ValueNotifier<BigInt?>(null);
    final outgoing = ValueNotifier<BigInt?>(null);
    final activity = ValueNotifier<List<ActivityRecord>>(const []);
    final syncing = ValueNotifier<bool>(false);
    final utxoMissing = ValueNotifier<bool>(false);
    var now = DateTime(2026, 6, 14, 12);

    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: HomeScreen(
          connected: connected,
          endpoint: endpoint,
          virtualDaaScore: daa,
          error: error,
          lastUpdate: lastUpdate,
          mature: mature,
          pending: pending,
          outgoing: outgoing,
          activity: activity,
          syncing: syncing,
          utxoIndexMissing: utxoMissing,
          clock: () => now,
        ),
      ),
    );

    // Connecting: no data yet → balance unknown `—`, connecting beacon, empty
    // activity (never a forever-skeleton).
    expect(find.text('KaspaVerse'), findsOneWidget);
    expect(find.text('connecting to mainnet…'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('No recent activity'), findsOneWidget);

    // A live, EMPTY synced wallet: a real 0.00000000 KAS, never `—`/skeleton.
    connected.value = true;
    endpoint.value = 'wss://node.example/borsh';
    daa.value = BigInt.parse('458174109');
    mature.value = BigInt.zero;
    pending.value = BigInt.zero;
    lastUpdate.value = now;
    await tester.pump();
    expect(find.textContaining('0.00000000 KAS'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text('DAA 458,174,109'), findsOneWidget);

    // Funds arrive (matured + pending) with an incoming, still-pending row.
    mature.value = BigInt.parse('123456789012'); // 1,234.56789012 KAS
    pending.value = BigInt.from(50000000); // 0.5 KAS pending
    activity.value = [
      ActivityRecord(
        txid: 'a' * 64,
        valueSompi: BigInt.from(50000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 120000),
        blockDaaScore: BigInt.parse('458174059'), // 50 DAA below the live tip
        direction: ActivityDirection.incoming,
        isCoinbase: false,
        maturity: MaturityState.pending,
        stalled: false,
      ),
    ];
    await tester.pump();
    expect(find.textContaining('1,234.56789012 KAS'), findsOneWidget);
    expect(find.text('No recent activity'), findsNothing);
    // V2 counter (founder request): an immature deposit streams its DAA
    // distance instead of a static "Pending".
    expect(find.text('50 confirmations'), findsOneWidget);

    // V2 chip walk: acceptance lands (V1 overlay) → 'Accepted'; a settled
    // (confirmed) row goes quiet — no permanent label (founder-nodded).
    activity.value = [
      ActivityRecord(
        txid: 'b' * 64,
        valueSompi: BigInt.from(20000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 5000),
        blockDaaScore: BigInt.from(20),
        direction: ActivityDirection.outgoing,
        isCoinbase: false,
        maturity: MaturityState.accepted,
        stalled: false,
      ),
      ActivityRecord(
        txid: 'c' * 64,
        valueSompi: BigInt.from(30000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 90000),
        blockDaaScore: BigInt.from(5),
        direction: ActivityDirection.outgoing,
        isCoinbase: false,
        maturity: MaturityState.pending,
        stalled: true, // 60 s with no acceptance — the V1 stall signal
      ),
      ActivityRecord(
        txid: 'd' * 64,
        valueSompi: BigInt.from(10000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 900000),
        blockDaaScore: BigInt.from(1),
        direction: ActivityDirection.outgoing,
        isCoinbase: false,
        maturity: MaturityState.confirmed,
        stalled: false,
      ),
    ];
    await tester.pump(const Duration(milliseconds: 400)); // chip crossfade
    expect(find.text('Accepted'), findsOneWidget);
    expect(find.text('Not accepted yet'), findsOneWidget); // stalled, honest
    expect(find.text('Pending'), findsNothing);
    expect(find.text('Confirmed'), findsNothing); // terminal = quiet

    // Back to the pending-deposit shape for the staleness beat below.
    activity.value = [
      ActivityRecord(
        txid: 'a' * 64,
        valueSompi: BigInt.from(50000000),
        unixtimeMsec: BigInt.from(now.millisecondsSinceEpoch - 120000),
        blockDaaScore: BigInt.from(10),
        direction: ActivityDirection.incoming,
        isCoinbase: false,
        maturity: MaturityState.pending,
        stalled: false,
      ),
    ];
    await tester.pump(const Duration(milliseconds: 400));

    // The link goes quiet: advance past the stale threshold. The beacon ages
    // (the balance dims — opacity is unit-tested in amount_text_test).
    now = now.add(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1)); // the 1 s ticker fires
    expect(find.text('as of 12 s ago'), findsOneWidget);
    // DS-1: a stale link never streams a counter — the frozen last-known DAA
    // must not tick at full presence; the chip falls back to its static word.
    expect(find.textContaining('confirmations'), findsNothing);
    expect(find.text('Pending'), findsOneWidget);
    expect(
      find.textContaining('1,234.56789012 KAS'),
      findsOneWidget,
    ); // retained

    await tester.pumpWidget(const SizedBox()); // cancel the ticker
  });

  testWidgets('no UTXO index degrades honestly — never a silent zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: kvDarkTheme(),
        home: HomeScreen(
          connected: ValueNotifier(true),
          endpoint: ValueNotifier('wss://node.example/borsh'),
          virtualDaaScore: ValueNotifier(BigInt.from(1)),
          error: ValueNotifier(null),
          lastUpdate: ValueNotifier(DateTime(2026, 6, 14, 12)),
          mature: ValueNotifier(null), // no balance — but NOT a fake zero
          pending: ValueNotifier(null),
          outgoing: ValueNotifier(null),
          activity: ValueNotifier(const []),
          syncing: ValueNotifier(false),
          utxoIndexMissing: ValueNotifier(true),
          clock: () => DateTime(2026, 6, 14, 12),
        ),
      ),
    );

    expect(find.textContaining('no UTXO index'), findsOneWidget);
    expect(find.text('—'), findsOneWidget); // unknown, never a fabricated 0
    await tester.pumpWidget(const SizedBox());
  });

  test('formatScore groups digits and handles null', () {
    expect(formatScore(null), '—');
    expect(formatScore(BigInt.from(0)), '0');
    expect(formatScore(BigInt.from(1000)), '1,000');
    expect(formatScore(BigInt.parse('458174109')), '458,174,109');
  });
}
