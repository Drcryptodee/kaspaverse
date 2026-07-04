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
        blockDaaScore: BigInt.from(10),
        direction: ActivityDirection.incoming,
        isCoinbase: false,
        maturity: MaturityState.pending,
      ),
    ];
    await tester.pump();
    expect(find.textContaining('1,234.56789012 KAS'), findsOneWidget);
    expect(find.text('No recent activity'), findsNothing);
    expect(find.text('Pending'), findsOneWidget); // the activity row maturity

    // The link goes quiet: advance past the stale threshold. The beacon ages
    // (the balance dims — opacity is unit-tested in amount_text_test).
    now = now.add(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1)); // the 1 s ticker fires
    expect(find.text('as of 12 s ago'), findsOneWidget);
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
