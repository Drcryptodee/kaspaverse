import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/ui/send/confirm_send_flow.dart';
import 'package:kaspaverse/src/ui/send/confirm_send_sheet.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/widgets/amount_text.dart';

const _addr =
    'kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692';

/// The canonical signable summary (V5): ONE DTO for every send-like flow —
/// the kind is RUST's decode of the flow, never a caller bool, and payment
/// mode structurally carries no payload fields.
SignableSummaryDto _summary({
  int txCount = 1,
  SignableKind kind = SignableKind.payment,
  int? payloadLen,
  String? payloadKind,
}) => SignableSummaryDto(
  nonce: BigInt.one,
  kind: kind,
  destination: _addr,
  amountSompi: BigInt.from(1240000000), // 12.40000000 KAS
  feeSompi: BigInt.from(2036), // 0.00002036 KAS — exact, never "free"
  totalSompi: BigInt.from(1240002036),
  mass: BigInt.from(2036),
  txCount: txCount,
  utxoCount: 2,
  payloadLen: payloadLen,
  payloadKind: payloadKind,
  feeStrategy: FeeStrategyKind.senderPays,
  priorityFeeSompi: BigInt.zero,
);

SendOutcomeDto _ok() =>
    SendOutcomeDto(finalTxid: 'a' * 64, submitted: 1, total: 1, partial: false);

Widget _host(Widget child) => MaterialApp(theme: kvDarkTheme(), home: child);

Widget _sheet(SignableSummaryDto summary, {String? title}) => _host(
  Scaffold(
    body: ConfirmSendSheet(
      summary: summary,
      commit: (_) async => _ok(),
      abandon: () async {},
      title: title,
    ),
  ),
);

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
      await tester.pumpWidget(_sheet(_summary()));

      // The CTA label carries the summary's amount (Rust's decode → the value
      // signed), not a form echo.
      expect(find.text('Hold to send 12.40000000 KAS'), findsOneWidget);
      // Amount + network fee + total each render through AmountText (the exact
      // fee, never "≈ free").
      expect(find.byType(AmountText), findsNWidgets(3));
      // Destination shown for review (chunked, prefix preserved).
      expect(find.textContaining('kaspa:'), findsOneWidget);
      // The payment default title — kind-derived, no caller string needed.
      expect(find.text('Confirm send'), findsOneWidget);
    });

    testWidgets('a chained send tells the user it is multiple transactions', (
      tester,
    ) async {
      await tester.pumpWidget(_sheet(_summary(txCount: 3)));
      expect(find.textContaining('3 transactions'), findsOneWidget);
    });

    testWidgets('self-send rendering derives from the Rust kind, never a '
        'caller bool', (tester) async {
      // V5: the mode rides the Rust-decoded DTO — there is no selfSend
      // parameter left for a caller to lie through.
      await tester.pumpWidget(
        _sheet(
          _summary(
            kind: SignableKind.selfSendFrame,
            payloadLen: 154,
            payloadKind: 'comm',
          ),
        ),
      );

      // Leads with the honest cost (the fee), never the returning value.
      expect(find.text('Costs you'), findsOneWidget);
      expect(find.text('Returns to you'), findsOneWidget);
      // The raw self "To" address is dropped (D-069).
      expect(find.textContaining('kaspa:'), findsNothing);
      // The returning value is never quoted as the thing being sent.
      expect(find.textContaining('Hold to send 12.40000000'), findsNothing);
      expect(find.text('Hold to send message'), findsOneWidget);
      // Kind-derived default title.
      expect(find.text('Confirm message'), findsOneWidget);
    });

    testWidgets('payment mode renders no payload fields', (tester) async {
      // The variant law: a payment summary structurally has no payload facts
      // (Rust sets them None) — nothing payload-ish may appear.
      await tester.pumpWidget(_sheet(_summary()));
      expect(find.textContaining('payload'), findsNothing);
      expect(find.textContaining('Carries'), findsNothing);
    });

    testWidgets('a bond confirm renders the payload facts from the DTO, not '
        'a caller string', (tester) async {
      await tester.pumpWidget(
        _sheet(
          _summary(
            kind: SignableKind.bond,
            payloadLen: 154,
            payloadKind: 'handshake',
          ),
        ),
      );
      // The payload line is the SHEET's rendering of the DTO's built-tx
      // decode — the caller no longer assembles it (B7: one source).
      expect(
        find.text(
          'Carries: handshake payload, 154 bytes '
          '(decoded from the built transaction).',
        ),
        findsOneWidget,
      );
      // A bond pays the counterparty: To shown, amount headline, Total row.
      expect(find.textContaining('kaspa:'), findsOneWidget);
      expect(find.text('Sending'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('Confirm contact request'), findsOneWidget);
    });

    testWidgets('a bond refund (accept) is not a self-send — D-069 preserved', (
      tester,
    ) async {
      await tester.pumpWidget(
        _sheet(
          _summary(
            kind: SignableKind.bondRefund,
            payloadLen: 154,
            payloadKind: 'handshake',
          ),
        ),
      );
      // D-069 keeps bonds as REAL value to the counterparty: never the
      // self-send rendering.
      expect(find.text('Costs you'), findsNothing);
      expect(find.text('Returns to you'), findsNothing);
      expect(find.text('Sending'), findsOneWidget);
      expect(find.textContaining('kaspa:'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('Confirm accept'), findsOneWidget);
      expect(find.text('Hold to send 12.40000000 KAS'), findsOneWidget);
    });

    testWidgets('a hypothetical P4 stake flow renders through the one sheet', (
      tester,
    ) async {
      // The V5 variant-coverage bar: P4's challenge/stake adds a PRODUCER,
      // never a sixth sheet. A stake is value at risk to a covenant + a game
      // frame — payment-like rendering with the payload facts, through the
      // same hold-to-sign ceremony.
      await tester.pumpWidget(
        _sheet(
          _summary(
            kind: SignableKind.stake,
            payloadLen: 96,
            payloadKind: 'comm',
          ),
          title: 'Confirm stake',
        ),
      );
      expect(find.text('Confirm stake'), findsOneWidget);
      expect(find.text('Sending'), findsOneWidget);
      expect(find.textContaining('kaspa:'), findsOneWidget);
      expect(
        find.text(
          'Carries: comm payload, 96 bytes '
          '(decoded from the built transaction).',
        ),
        findsOneWidget,
      );
      expect(find.text('Hold to send 12.40000000 KAS'), findsOneWidget);
    });

    testWidgets('a surface that unmounts mid-prepare abandons the stash', (
      tester,
    ) async {
      // The ceremony helper's custody hygiene: prepare stashed an unsigned
      // plan in Rust, but the surface died before the sheet could open —
      // nobody can ever commit it, so the helper releases it instead of
      // leaving a nonce-guarded orphan (V5 wallet-security note).
      final prepared = Completer<SignableSummaryDto>();
      var abandoned = 0;
      late BuildContext ctx;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final pending = runConfirmSend(
        ctx,
        prepare: () => prepared.future,
        commit: (_) async => _ok(),
        abandon: () async => abandoned++,
      );
      await tester.pumpWidget(const SizedBox()); // the surface unmounts
      prepared.complete(_summary());
      final outcome = await pending;
      expect(outcome, isNull);
      expect(abandoned, 1, reason: 'the orphaned stash is released');
    });

    test('the fee-strategy field rides the DTO (senderPays, 0)', () {
      // The reserved seam (V5): present on every summary, constant today —
      // the ★ Send-UX pass gives it real choices; nothing estimates here.
      final dto = _summary();
      expect(dto.feeStrategy, FeeStrategyKind.senderPays);
      expect(dto.priorityFeeSompi, BigInt.zero);
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
