import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/ui/send/confirm_send_sheet.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/widgets/amount_text.dart';

const _addr =
    'kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692';

SendSummaryDto _summary({int txCount = 1}) => SendSummaryDto(
  nonce: BigInt.one,
  destination: _addr,
  amountSompi: BigInt.from(1240000000), // 12.40000000 KAS
  feeSompi: BigInt.from(2036), // 0.00002036 KAS — exact, never "free"
  totalSompi: BigInt.from(1240002036),
  mass: BigInt.from(2036),
  txCount: txCount,
  utxoCount: 2,
);

SendOutcomeDto _ok() =>
    SendOutcomeDto(finalTxid: 'a' * 64, submitted: 1, total: 1, partial: false);

Widget _host(Widget child) => MaterialApp(theme: kvDarkTheme(), home: child);

void main() {
  group('SendScreen', () {
    testWidgets('Review is disabled until a valid amount and address', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SendScreen(
            mature: ValueNotifier<BigInt?>(BigInt.from(100000000000)),
            prepare: (_, _) async => _summary(),
            commit: (_) async => _ok(),
            abandon: () async {},
          ),
        ),
      );

      FilledButton review() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review'),
      );
      expect(review().onPressed, isNull, reason: 'disabled with empty fields');

      await tester.enterText(find.byType(TextField).first, '12.4');
      await tester.enterText(find.byType(TextField).at(1), _addr);
      await tester.pump();
      expect(review().onPressed, isNotNull, reason: 'enabled once valid');
    });

    testWidgets('a malformed amount keeps Review disabled', (tester) async {
      await tester.pumpWidget(
        _host(
          SendScreen(
            mature: ValueNotifier<BigInt?>(BigInt.from(100000000000)),
            prepare: (_, _) async => _summary(),
            commit: (_) async => _ok(),
            abandon: () async {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).first, '1.2.3');
      await tester.enterText(find.byType(TextField).at(1), _addr);
      await tester.pump();
      final review = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review'),
      );
      expect(review.onPressed, isNull);
    });

    testWidgets('an honest prepare error (not-yet-spendable) is surfaced', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SendScreen(
            mature: ValueNotifier<BigInt?>(BigInt.from(100000000000)),
            prepare: (_, _) async => throw const AppError(
              message: 'not yet spendable — still confirming',
            ),
            commit: (_) async => _ok(),
            abandon: () async {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).first, '12.4');
      await tester.enterText(find.byType(TextField).at(1), _addr);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Review'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('not yet spendable'), findsOneWidget);
    });

    testWidgets('the probed KIP-9 floor renders as an advisory line (D-054)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SendScreen(
            mature: ValueNotifier<BigInt?>(BigInt.from(100000000000)),
            prepare: (_, _) async => _summary(),
            commit: (_) async => _ok(),
            abandon: () async {},
            minimumSendable: () async => BigInt.from(23000000), // 0.23 KAS
          ),
        ),
      );
      await tester.pump(); // resolve the probe future
      expect(find.textContaining('Minimum right now'), findsOneWidget);
      expect(find.textContaining('0.23000000 KAS'), findsOneWidget);
      // Advisory only: Review enablement is unchanged by the hint.
      await tester.enterText(find.byType(TextField).first, '0.01');
      await tester.enterText(find.byType(TextField).at(1), _addr);
      await tester.pump();
      final review = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review'),
      );
      expect(
        review.onPressed,
        isNotNull,
        reason: 'the Generator on prepare stays the single authority',
      );
    });

    testWidgets('no minimum provider ⇒ no hint line', (tester) async {
      await tester.pumpWidget(
        _host(
          SendScreen(
            mature: ValueNotifier<BigInt?>(BigInt.from(100000000000)),
            prepare: (_, _) async => _summary(),
            commit: (_) async => _ok(),
            abandon: () async {},
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Minimum right now'), findsNothing);
    });
  });

  group('ConfirmSendSheet (anti-blind-signing, B7)', () {
    testWidgets('renders Rust-decoded amount/fee/destination, not the form', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: ConfirmSendSheet(
              summary: _summary(),
              commit: (_) async => _ok(),
              abandon: () async {},
            ),
          ),
        ),
      );

      // The CTA label carries the summary's amount (Rust's decode → the value
      // signed), not a form echo.
      expect(find.text('Hold to send 12.40000000 KAS'), findsOneWidget);
      // Amount + network fee + total each render through AmountText (the exact
      // fee, never "≈ free").
      expect(find.byType(AmountText), findsNWidgets(3));
      // Destination shown for review (chunked, prefix preserved).
      expect(find.textContaining('kaspa:'), findsOneWidget);
    });

    testWidgets('a chained send tells the user it is multiple transactions', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: ConfirmSendSheet(
              summary: _summary(txCount: 3),
              commit: (_) async => _ok(),
              abandon: () async {},
            ),
          ),
        ),
      );
      expect(find.textContaining('3 transactions'), findsOneWidget);
    });

    Widget holdHost(void Function() onCommit) => _host(
      Scaffold(
        body: ConfirmSendSheet(
          summary: _summary(),
          commit: (_) async {
            onCommit();
            return _ok();
          },
          abandon: () async {},
        ),
      ),
    );

    const label = 'Hold to send 12.40000000 KAS';

    testWidgets('a quick tap does NOT sign (no double-tap path)', (
      tester,
    ) async {
      var commits = 0;
      await tester.pumpWidget(holdHost(() => commits++));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(commits, 0, reason: 'a tap is not a hold');
    });

    testWidgets('a full hold past the deliberate duration signs once', (
      tester,
    ) async {
      var commits = 0;
      await tester.pumpWidget(holdHost(() => commits++));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(label)),
      );
      await tester.pump(); // dispatch pointer-down → onTapDown → forward()
      await tester.pump(const Duration(milliseconds: 850)); // complete the hold
      expect(commits, 1, reason: 'a completed hold signs, once');
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}
