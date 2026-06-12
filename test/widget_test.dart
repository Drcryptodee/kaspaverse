import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/hello_dag_screen.dart';

void main() {
  testWidgets('hello-DAG screen renders live score updates', (tester) async {
    final connected = ValueNotifier<bool>(false);
    final endpoint = ValueNotifier<String?>(null);
    final daa = ValueNotifier<BigInt?>(null);
    final blue = ValueNotifier<BigInt?>(null);
    final error = ValueNotifier<String?>(null);

    await tester.pumpWidget(
      MaterialApp(
        home: HelloDagScreen(
          connected: connected,
          endpoint: endpoint,
          virtualDaaScore: daa,
          sinkBlueScore: blue,
          error: error,
        ),
      ),
    );

    expect(find.text('KaspaVerse'), findsOneWidget);
    expect(find.text('connecting to mainnet…'), findsOneWidget);
    expect(find.text('—'), findsNWidgets(2));

    // Live update: notifier change repaints without a new pumpWidget.
    connected.value = true;
    endpoint.value = 'wss://node.example/borsh';
    daa.value = BigInt.parse('458174109');
    blue.value = BigInt.parse('18446744073709551615'); // u64::MAX (L3)
    await tester.pump();

    expect(find.text('wss://node.example/borsh'), findsOneWidget);
    expect(find.text('458,174,109'), findsOneWidget);
    expect(find.text('18,446,744,073,709,551,615'), findsOneWidget);
    expect(find.text('—'), findsNothing);

    error.value = 'bridge unavailable';
    await tester.pump();
    expect(find.text('bridge unavailable'), findsOneWidget);
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
