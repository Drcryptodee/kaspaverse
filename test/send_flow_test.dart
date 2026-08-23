import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/ui/send/confirm_send_flow.dart';
import 'package:kaspaverse/src/ui/send/confirm_send_sheet.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
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
  int utxoCount = 2,
  BigInt? typicalNowFeeSompi,
  BigInt? typicalAfterFeeSompi,
}) => SignableSummaryDto(
  nonce: BigInt.one,
  kind: kind,
  destination: _addr,
  amountSompi: BigInt.from(1240000000), // 12.40000000 KAS
  feeSompi: BigInt.from(2036), // 0.00002036 KAS — exact, never "free"
  totalSompi: BigInt.from(1240002036),
  mass: BigInt.from(2036),
  txCount: txCount,
  utxoCount: utxoCount,
  payloadLen: payloadLen,
  payloadKind: payloadKind,
  feeStrategy: FeeStrategyKind.senderPays,
  priorityFeeSompi: BigInt.zero,
  typicalAmountSompi: typicalNowFeeSompi == null
      ? null
      : BigInt.from(500000000),
  typicalNowUtxos: typicalNowFeeSompi == null ? null : 3,
  typicalNowFeeSompi: typicalNowFeeSompi,
  typicalAfterFeeSompi: typicalAfterFeeSompi,
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

    testWidgets('Send everything needs only an address and prepares the '
        'SWEEP, not a payment', (tester) async {
      var paymentPrepares = 0;
      var sweepPrepares = 0;
      String? sweptTo;
      await tester.pumpWidget(
        _host(
          SendScreen(
            mature: ValueNotifier<BigInt?>(BigInt.from(48152400)),
            prepare: (_, _) async {
              paymentPrepares++;
              return _summary();
            },
            commit: (_) async => _ok(),
            abandon: () async {},
            prepareSweep: (destination) async {
              sweepPrepares++;
              sweptTo = destination;
              return _summary(kind: SignableKind.sweep, utxoCount: 1);
            },
          ),
        ),
      );

      // The exit is on screen and TAPPABLE even while both fields are empty
      // — a wallet the anti-dust floor has trapped types no amount at all,
      // and a control that greys out silently would not say what it needs.
      await tester.tap(find.text('Send everything'));
      await tester.pump();
      expect(sweepPrepares, 0, reason: 'no address yet — nothing prepared');
      expect(
        find.textContaining('Enter the destination address first'),
        findsOneWidget,
        reason: 'the button answers with words, never a silent grey',
      );

      await tester.enterText(find.byType(TextField).at(1), _addr);
      await tester.pump();
      await tester.tap(find.text('Send everything'));
      // Bounded pumps: the sheet's ambient glow animates continuously, so
      // pumpAndSettle would never settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sweepPrepares, 1);
      expect(paymentPrepares, 0, reason: 'the sweep never rides prepare()');
      expect(sweptTo, _addr);
      // The one signing surface opened over the sweep summary.
      expect(find.text('Confirm send all'), findsOneWidget);
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

    testWidgets('a sweep confirms the whole-wallet exit in the DTO\'s own '
        'numbers', (tester) async {
      // The swept amount IS the built final tx's single output (fee already
      // deducted by the Generator) — the sheet renders it as what the
      // destination receives, plus the empties-wallet sentence with the
      // absorbed coin count.
      await tester.pumpWidget(
        _sheet(_summary(kind: SignableKind.sweep, utxoCount: 7)),
      );
      expect(find.text('Confirm send all'), findsOneWidget);
      expect(find.text('Sending'), findsOneWidget);
      // DS-8: the destination is reviewed in full form.
      expect(find.textContaining('kaspa:'), findsOneWidget);
      expect(find.textContaining('all 7 spendable coins move'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('Hold to send 12.40000000 KAS'), findsOneWidget);
    });

    testWidgets('a merge renders as returning value with the savings pair '
        'from the DTO', (tester) async {
      await tester.pumpWidget(
        _sheet(
          _summary(
            kind: SignableKind.consolidate,
            utxoCount: 22,
            typicalNowFeeSompi: BigInt.from(427200),
            typicalAfterFeeSompi: BigInt.from(203600),
          ),
        ),
      );
      expect(find.text('Confirm merge'), findsOneWidget);
      // The honest headline is the fee; the value returns to us.
      expect(find.text('Costs you'), findsOneWidget);
      expect(find.text('Returns to you'), findsOneWidget);
      // Our own address is not rendered as a destination (D-069's rule).
      expect(find.textContaining('kaspa:'), findsNothing);
      expect(find.textContaining('Merges 22 coins into one'), findsOneWidget);
      // The savings sentence quotes the Generator's own probed fees, exact.
      expect(
        find.text(
          'A typical send today costs 0.00427200 KAS in fees — after this, '
          '0.00203600 KAS.',
        ),
        findsOneWidget,
      );
      expect(find.text('Hold to merge 22 coins'), findsOneWidget);
    });

    testWidgets('a merge whose savings could not be priced omits the line — '
        'never invents one', (tester) async {
      await tester.pumpWidget(
        _sheet(_summary(kind: SignableKind.consolidate, utxoCount: 5)),
      );
      expect(find.text('Confirm merge'), findsOneWidget);
      expect(find.textContaining('A typical send today'), findsNothing);
      expect(find.textContaining('Merges 5 coins into one'), findsOneWidget);
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
        preparingObject: 'message',
      );
      await tester.pumpWidget(const SizedBox()); // the surface unmounts
      prepared.complete(_summary());
      final outcome = await pending;
      expect(outcome, isNull);
      expect(abandoned, 1, reason: 'the orphaned stash is released');
    });

    testWidgets('a slow prepare says so instead of freezing', (tester) async {
      // A prepare in the messages lane can BLOCK for twenty-odd seconds
      // waiting for the previous send's change to mature — that wait replaced
      // an outright refusal, and an unresponsive screen would be a worse bug
      // than the one it fixed. The card is held back a moment first, because
      // one that flashes and vanishes on a fast prepare reads as a glitch.
      final semantics = tester.ensureSemantics();
      final prepared = Completer<SignableSummaryDto>();
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
        abandon: () async {},
        preparingObject: 'message',
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('Preparing your message'),
        findsNothing,
        reason: 'no flash',
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Preparing your message'), findsOneWidget);
      // The reason is named only once the wait is long enough to need one.
      expect(find.textContaining('still'), findsNothing);

      // A HEALTHY maturity wait must not reach the reason beat. Measured on
      // the device 2026-08-15: `transport-send: waited 1203 ms`, whole prepare
      // ~1500 ms. The old threshold fired at 1450 ms of prepare, so the line
      // flashed for a few dozen milliseconds and then the sheet replaced it —
      // the same flash-and-vanish the card's own delay exists to prevent, and
      // on glass it read as a bare spinner every time. This is the assertion
      // that pins the beat to something a real prepare can be measured
      // against; the timer firing at all was never the thing in doubt.
      await tester.pump(const Duration(milliseconds: 1200)); // 1600ms total
      expect(
        find.text('This can take a few seconds.'),
        findsNothing,
        reason: 'a normal-length wait finishes without ever explaining itself',
      );

      // BOTH edges pinned, deliberately. The card is built by the t=400 pump,
      // so the beat fires at `400 + _explainAfter`: the t=2350 negative puts
      // the floor at 1951 and the t=2400 positive puts the ceiling at 2000, so
      // the constant is bracketed to [1951, 2000] and cannot drift either way.
      //
      // A single low guard would only have ruled out the exact old number: a
      // re-tune to 1300 fires the reason at ~1550 ms of prepare — dead on the
      // measured normal, the defect fully reproduced — and a one-sided test
      // would have stayed green through it.
      await tester.pump(const Duration(milliseconds: 750)); // 2350ms total
      expect(
        find.text('This can take a few seconds.'),
        findsNothing,
        reason: 'still silent just below the beat — pins the LOW edge',
      );

      await tester.pump(const Duration(milliseconds: 50)); // 2400ms total
      expect(find.text('This can take a few seconds.'), findsOneWidget);

      // The announcement is a beat too, and the only one a refactor could
      // silently drop — moving the `Semantics` above the `AnimatedOpacity`
      // would keep every timing assertion above green while a screen-reader
      // user behind a no-exit barrier hears nothing (§11).
      //
      // Asserted only AFTER the fade completes, and that is a fact about the
      // surface, not a test convenience: `AnimatedOpacity` excludes its
      // subtree from the semantics tree while opacity is 0, so the region does
      // not exist to announce until the fade lands. Asserting on the frame the
      // timer fires reads the ancestor node and fails.
      await tester.pump(KvMotion.fast);
      expect(
        tester
            .getSemantics(find.text('This can take a few seconds.'))
            .flagsCollection
            .isLiveRegion,
        isTrue,
        reason: 'the reason announces itself when it finally arrives',
      );

      // Past the point where "a few seconds" has become false, the card says
      // the one thing a barrier with no exit cannot let the user infer: that it
      // ends by itself. It still never names the cause — this surface does not
      // know which branch Rust took (L92).
      await tester.pump(const Duration(seconds: 7));
      expect(
        find.text(
          "Still working. This hasn't been sent yet, and the wait ends on its "
          'own either way.',
        ),
        findsOneWidget,
      );
      expect(find.text('This can take a few seconds.'), findsNothing);
      expect(find.textContaining('settling'), findsNothing);

      prepared.complete(_summary());
      await tester.pumpAndSettle();
      expect(
        find.text('Preparing your message'),
        findsNothing,
        reason: 'the card is gone',
      );
      expect(find.byType(ConfirmSendSheet), findsOneWidget);

      // Close the sheet so the ceremony's own future resolves.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await pending;
      semantics.dispose();
    });

    testWidgets('a prepare landing before the card builds still dismisses it', (
      tester,
    ) async {
      // THE ORPHANED BARRIER. `showDialog`'s builder does not run until the
      // next frame, while `await pending` resumes on a microtask — so a prepare
      // finishing inside that gap dismissed against a context the builder had
      // not yet set, did nothing, and left a barrier with no dismiss, no back
      // (`PopScope(canPop: false)`) and no cancel sitting over the whole app.
      // Here the timer fires at 250 ms and the prepare lands at 270 ms, both
      // inside ONE time advance, so the card is pushed and resolved before any
      // frame builds it.
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
        prepare: () =>
            Future.delayed(const Duration(milliseconds: 270), _summary),
        commit: (_) async => _ok(),
        abandon: () async {},
        preparingObject: 'message',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(
        find.text('Preparing your message'),
        findsNothing,
        reason: 'no orphaned card',
      );
      expect(find.byType(ConfirmSendSheet), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await pending;
    });

    testWidgets('the card sits under a Material, not the error fallback', (
      tester,
    ) async {
      // Without one, `DialogRoute` inherits MaterialApp's `_errorTextStyle` and
      // the card renders monospace, weight 900, under a yellow double underline
      // — the "you forgot a Material" fallback, on the money path.
      final prepared = Completer<SignableSummaryDto>();
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
        abandon: () async {},
        preparingObject: 'message',
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Preparing your message'), findsOneWidget);

      final style = tester
          .widget<RichText>(
            find.descendant(
              of: find.text('Preparing your message'),
              matching: find.byType(RichText),
            ),
          )
          .text
          .style;
      expect(style?.fontFamily, isNot('monospace'));
      expect(style?.decoration, anyOf(isNull, TextDecoration.none));

      prepared.complete(_summary());
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await pending;
    });

    testWidgets('a fast prepare never shows the card at all', (tester) async {
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
        prepare: () async => _summary(),
        commit: (_) async => _ok(),
        abandon: () async {},
        preparingObject: 'message',
      );
      await tester.pumpAndSettle();
      expect(find.text('Preparing your message'), findsNothing);
      expect(find.byType(ConfirmSendSheet), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await pending;
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
