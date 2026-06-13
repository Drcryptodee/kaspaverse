import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/hello_dag_screen.dart';

void main() {
  testWidgets('hello-DAG renders connecting → live → stale → error', (
    tester,
  ) async {
    final connected = ValueNotifier<bool>(false);
    final endpoint = ValueNotifier<String?>(null);
    final daa = ValueNotifier<BigInt?>(null);
    final blue = ValueNotifier<BigInt?>(null);
    final error = ValueNotifier<String?>(null);
    final lastUpdate = ValueNotifier<DateTime?>(null);
    var now = DateTime(2026, 6, 13, 12);

    await tester.pumpWidget(
      MaterialApp(
        home: HelloDagScreen(
          connected: connected,
          endpoint: endpoint,
          virtualDaaScore: daa,
          sinkBlueScore: blue,
          error: error,
          lastUpdate: lastUpdate,
          clock: () => now,
        ),
      ),
    );

    // Connecting: no fresh snapshot yet → "—" scores, connecting beacon.
    expect(find.text('KaspaVerse'), findsOneWidget);
    expect(find.text('connecting to mainnet…'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));

    // A live snapshot lands (and stamps the freshness clock, as ChainService
    // does). Beacon shows the node; scores format; BigInt range survives (L3).
    connected.value = true;
    endpoint.value = 'wss://node.example/borsh';
    daa.value = BigInt.parse('458174109');
    blue.value = BigInt.parse('18446744073709551615'); // u64::MAX
    lastUpdate.value = now;
    await tester.pump();

    expect(find.text('wss://node.example/borsh'), findsOneWidget);
    expect(find.text('458,174,109'), findsOneWidget);
    expect(find.text('18,446,744,073,709,551,615'), findsOneWidget);
    expect(find.text('—'), findsNothing);

    // The link goes quiet: advance the clock past the stale threshold. The
    // beacon ages and the scores stay (dimmed, not blanked — DS-1).
    now = now.add(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1)); // the 1 s ticker fires
    expect(find.text('as of 12 s ago'), findsOneWidget);
    expect(find.text('wss://node.example/borsh'), findsNothing);
    expect(find.text('458,174,109'), findsOneWidget); // retained, just dimmed

    // An error trumps everything.
    error.value = 'bridge unavailable';
    await tester.pump();
    expect(find.text('bridge unavailable'), findsOneWidget);

    // Dispose the screen so its periodic ticker is cancelled (no pending timer).
    await tester.pumpWidget(const SizedBox());
  });

  test('formatScore groups digits and handles null', () {
    expect(formatScore(null), '—');
    expect(formatScore(BigInt.from(0)), '0');
    expect(formatScore(BigInt.from(999)), '999');
    expect(formatScore(BigInt.from(1000)), '1,000');
    expect(formatScore(BigInt.parse('458174109')), '458,174,109');
    expect(
      formatScore(BigInt.parse('18446744073709551615')),
      '18,446,744,073,709,551,615',
    );
  });
}
