import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/transport.dart';
import 'package:kaspaverse/src/ui/send/confirm_send_flow.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/send/signing_ceremony.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_address.dart';
import 'package:kaspaverse/src/ui/widgets/kv_amount.dart';
import 'package:kaspaverse/src/ui/widgets/kv_check.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/widgets/kv_sheet.dart';
import 'package:kaspaverse/src/ui/widgets/kv_explorer_exit.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';

import 'support/preview_harness.dart';
import 'support/finders.dart';

const _addr =
    'kaspa:qrqrnyzdwh9ec2q05guzy3vv33f86nvdyw52qwlmk0mewzx3dgdss3pmcd692';

/// The canonical signable summary (V5): ONE DTO for every send-like flow —
/// the kind is RUST's decode of the flow, never a caller bool, and payment
/// mode structurally carries no payload fields.
SignableSummaryDto _summary({
  BigInt? amountSompi,
  int txCount = 1,
  int resultingCoins = 1,
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
  amountSompi: amountSompi ?? BigInt.from(1240000000), // 12.40000000 KAS
  feeSompi: BigInt.from(2036), // 0.00002036 KAS — exact, never "free"
  totalSompi: BigInt.from(1240002036),
  mass: BigInt.from(2036),
  txCount: txCount,
  utxoCount: utxoCount,
  resultingCoins: resultingCoins,
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

/// **`KvWindow` above the `Navigator`**, exactly as `main.dart` mounts it —
/// the ceremony arrives on a route now, and a sheet reads the window class to
/// decide whether it is full-width or floating (BG-33). A host without it is a
/// host that cannot build the surface under test.
Widget _host(Widget child) => MaterialApp(
  theme: kvDarkTheme(),
  builder: (context, page) => KvWindow(child: page!),
  home: child,
);

Widget _ceremony(SignableSummaryDto summary, {String? title}) => _host(
  SigningCeremony(
    summary: summary,
    commit: (_) async => _ok(),
    abandon: () async {},
    title: title,
  ),
);

/// Lay the test out at a real phone, not at the 800×600 desktop window the
/// harness defaults to. The design's reference geometry is 393dp; the floor it
/// must survive is 320dp at 1.3×, which the measurement group below sets
/// explicitly. A screen tested only at 800×600 is tested at a size nothing
/// ships.
void _phone(WidgetTester tester, {Size size = const Size(393, 851)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Press keys on the amount pad. Scoped to the pad so a digit that also
/// appears in the figure above it can never be the thing that got tapped, and
/// scrolled into view first so the assertion is about the grammar rather than
/// about the test viewport.
/// The screen's OWN list — the outer of the two scrollables inside it. The
/// address field lives in the list and brings a `Scrollable` of its own, so
/// "the scrollable" is ambiguous and `scrollUntilVisible`'s internal `.single`
/// throws on it.
ScrollableState _sendList(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(
        of: find.byKey(SendScreen.scrollTarget),
        matching: find.byType(Scrollable),
      )
      .first,
);

/// Press keys on the amount pad. Scoped to the pad so a digit that also
/// appears in the figure above it can never be the thing that got tapped.
Future<void> _type(WidgetTester tester, String keys) async {
  for (final k in keys.split('')) {
    final key = find.descendant(
      of: find.byType(KvKeypad),
      matching: find.text(k),
    );
    if (key.evaluate().isEmpty) {
      // Not built: the floor geometry puts the pad below the fold. Jump the
      // list directly rather than `scrollUntilVisible`, for the reason in
      // [_sendList].
      final position = _sendList(tester).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
    await tester.ensureVisible(key);
    await tester.pump();
    await tester.tap(key);
    await tester.pump();
  }
}

/// **Step 1, then step 2** (UX-R2). Put the destination in and walk through to
/// the amount, the way a user does. Leaving [advance] false stays on step 1 —
/// for the tests that are about what the address field itself says.
Future<void> _address(
  WidgetTester tester,
  String address, {
  bool advance = true,
}) async {
  // Step 2 → back to the destination, the way Edit does it. The step swap is
  // an `AnimatedSwitcher` on `enter`, so both steps are in the tree until it
  // finishes — the pump has to clear it before a finder means one step.
  if (find.text('Edit').evaluate().isNotEmpty) {
    await tester.tap(find.text('Edit'));
    await tester.pump();
    await tester.pump(KvMotion.enter);
    await tester.pump(KvMotion.enter);
  }
  if (find.byKey(SendScreen.addressTarget).evaluate().isEmpty) {
    // The floor geometry can leave the field above the fold.
    final position = _sendList(tester).position;
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
  }
  if (find.byKey(SendScreen.addressTarget).evaluate().isEmpty) {
    // The field RENDERS a valid address rather than editing it (`S6b`);
    // tapping it puts the caret back.
    await tester.tap(find.byType(KvAddress).first);
    await tester.pump();
    await tester.pump();
  }
  await tester.enterText(find.byKey(SendScreen.addressTarget), address);
  await tester.pump();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.pump(KvMotion.calm);
  if (!advance) return;
  final go = find.widgetWithText(KvAction, 'Continue to amount');
  if (go.evaluate().isEmpty) return;
  await tester.tap(go);
  await tester.pump();
  await tester.pump(KvMotion.enter);
  await tester.pump(KvMotion.enter);
}

/// The foot control of whichever step is on screen — one pill per step, and
/// the label carries the amount now, so the finder is by position rather than
/// by string.
KvAction _foot(WidgetTester tester) =>
    tester.widgetList<KvAction>(find.byType(KvAction)).last;

/// The reason a disabled foot control gives, or null when it is live.
String? _reviewReason(WidgetTester tester) => _foot(tester).disabledReason;

/// Sentinel, so a test can pass an explicit `null` balance and mean *unknown*
/// rather than *defaulted*.
const Object _unset = Object();

Widget _sendScreen({
  Object? mature = _unset,
  ValueListenable<bool>? balanceStale,
  Future<BigInt?> Function(String, BigInt)? feePreview,
  Future<SignableSummaryDto> Function(String, BigInt)? prepare,
  Future<SignableSummaryDto> Function(String)? prepareSweep,
  Future<BigInt?> Function()? minimumSendable,
  Future<SendOutcomeDto> Function(BigInt)? commit,
  Future<void> Function()? abandon,
}) => _host(
  SendScreen(
    mature: ValueNotifier<BigInt?>(
      identical(mature, _unset) ? BigInt.from(100000000000) : mature as BigInt?,
    ),
    balanceStale: balanceStale,
    feePreview: feePreview,
    prepare: prepare ?? (_, _) async => _summary(),
    commit: commit ?? (_) async => _ok(),
    abandon: abandon ?? () async {},
    prepareSweep:
        prepareSweep ??
        (_) async => _summary(kind: SignableKind.sweep, utxoCount: 1),
    minimumSendable: minimumSendable,
  ),
);

/// The send screen with an amount typed and a destination pasted — the only
/// state in which a fee exists, since `_probeFee` refuses without both.
Future<void> _pumpTypedSend(WidgetTester tester) async {
  tester.view.physicalSize = const Size(393, 851);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData'
        ? <String, dynamic>{'text': _addr}
        : null,
  );
  await tester.pumpWidget(
    _sendScreen(feePreview: (_, _) async => BigInt.from(315400)),
  );
  // The destination first: it is step 1, and the fee cannot be priced without
  // it either way.
  await tester.tap(
    find.byWidgetPredicate((w) => w is KvGlyphIcon && w.mark == KvGlyph.paste),
  );
  await tester.pump();
  await tester.tap(find.widgetWithText(KvAction, 'Continue to amount'));
  await tester.pump();
  await tester.pump(KvMotion.calm);
  await _type(tester, '12.4');
  await tester.pump(const Duration(milliseconds: 600));
}

/// The fee line as the user reads it, joined across its runs.
///
/// **Not `find.text('network fee 0.003154')`.** Since D-230 the figure renders
/// through `KvAmount`, so the leading zeros and the significant digits are
/// separate `Text`s and the label is a third — the string was never the law,
/// only how it happened to be drawn. Asserting the joined line survives the
/// face changing again (L143: a string comparison cannot testify about a
/// render, and its mirror — a string comparison breaks on a render that is
/// still correct).
String _feeLine(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find
            .ancestor(of: find.text('Network fee'), matching: find.byType(Row))
            .first,
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data ?? '')
    .join();

void main() {
  setUpAll(loadBundledFonts);

  group('SendScreen', () {
    testWidgets('the pad is the default, and tapping the figure hands over to '
        'the device keyboard', (tester) async {
      // **D-189 narrowed, not reversed** (founder, 2026-08-30). The on-screen
      // pad is still what a user meets, still the same primitive the
      // passphrase keyboard uses. What is new is that an amount may ALSO be
      // typed on the system keyboard — which costs nothing that mattered,
      // because the no-system-IME law is INV-3's and it protects SECRETS. An
      // amount is not one, and the passphrase surfaces have no such handover.
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      // The pad lives on step 2 (UX-R2), so the destination comes first.
      await _address(tester, _addr);
      expect(find.byType(KvKeypad), findsOneWidget);

      // The IME is driven through `viewInsets` rather than inferred from
      // focus: a widget test raises no real keyboard, and on the device the
      // two come apart (see the `follows the KEYBOARD` test below).
      await tester.tap(find.byKey(SendScreen.amountTarget));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.pump(KvMotion.calm);
      expect(
        find.byType(KvKeypad),
        findsNothing,
        reason: 'two keyboards at once is not a layout',
      );

      // Dismissing the keyboard brings the pad back.
      tester.view.viewInsets = FakeViewPadding.zero;
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pump(KvMotion.calm);
      expect(find.byType(KvKeypad), findsOneWidget);
    });

    testWidgets('the system keyboard obeys the SAME grammar as the pad', (
      tester,
    ) async {
      // One law, two doors: the formatter refuses at the field whatever
      // `amountKeyPress` refuses at the key, so a device keyboard cannot type
      // a second point, a ninth decimal, or a figure past the u64 ceiling.
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await _address(tester, _addr);
      final field = find.byKey(SendScreen.amountTarget);

      await tester.enterText(field, '1.2345678');
      await tester.pump();
      // NINE decimals. `1.23456789` is eight and perfectly legal — a fixture
      // that does not actually break the rule tests nothing (L126).
      await tester.enterText(field, '1.234567891');
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        '1.2345678',
        reason: 'a ninth decimal is refused at the field too',
      );

      await tester.enterText(field, '1.2.3');
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '1.2345678');
    });

    testWidgets('Review is disabled until a valid amount and address', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      // **One reason per step** (UX-R2): each step asks for one thing, so the
      // disabled control names that one thing instead of listing the form.
      expect(
        _reviewReason(tester),
        'Enter an address to continue',
        reason: 'BG-12: a disabled control always says why',
      );

      await _address(tester, _addr);
      expect(_reviewReason(tester), 'Enter an amount');

      await _type(tester, '12.4');
      expect(_reviewReason(tester), isNull, reason: 'live once valid');
      // BG-11: the control names the action AND its object, and the object is
      // the figure the user typed.
      expect(find.text('Review 12.4 KAS'), findsOneWidget);
    });

    testWidgets('the keypad refuses a ninth decimal rather than taking it and '
        'rejecting the amount later', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await _address(tester, _addr);
      await _type(tester, '1.123456789');
      expect(find.text('1.12345678'), findsOneWidget);
      expect(_reviewReason(tester), isNull);
    });

    testWidgets('Send max needs only an address and prepares the SWEEP, not '
        'a payment', (tester) async {
      _phone(tester);
      var paymentPrepares = 0;
      var sweepPrepares = 0;
      String? sweptTo;
      await tester.pumpWidget(
        _sendScreen(
          mature: BigInt.from(48152400),
          prepare: (_, _) async {
            paymentPrepares++;
            return _summary();
          },
          prepareSweep: (destination) async {
            sweepPrepares++;
            sweptTo = destination;
            return _summary(kind: SignableKind.sweep, utxoCount: 1);
          },
        ),
      );

      // **The chip is never greyed, and now it cannot be reached without an
      // address at all** — step 2 is only reachable through a destination that
      // parses, so D-190's *"a trapped user must never meet a control that
      // will not say what it needs"* is satisfied by construction rather than
      // by a sentence. The guard in `_reviewSweep` stands behind it.
      await _address(tester, _addr);
      expect(sweepPrepares, 0, reason: 'nothing prepared by arriving');
      await tester.tap(find.text('Max'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sweepPrepares, 1);
      expect(paymentPrepares, 0, reason: 'the sweep never rides prepare()');
      expect(sweptTo, _addr);
      // The one signing surface opened over the sweep summary.
      expect(find.text('Confirm send all'), findsOneWidget);
    });

    testWidgets('the share chips write a CANONICAL figure, at a balance big '
        'enough to be grouped', (tester) async {
      // **`kasParts().integer` is grouped for the eye and `sompiFromKas`
      // rejects a comma** (`consensus-auditor`, UX-R2). A grouped write put a
      // figure plainly on screen that parsed to null: Review greyed out beside
      // it, no fee was priced, and `_AmountGrammar` then refused every
      // keystroke *including deletion*, because the value being edited did not
      // parse either — a dead money-entry control on the spend path.
      //
      // It needs ≥ 1,000 KAS in the field to appear at all, which is why the
      // fixtures never saw it. This one holds 12,345 KAS, so 25 % is
      // `3,086.25` under the old write.
      _phone(tester);
      await tester.pumpWidget(_sendScreen(mature: BigInt.from(1234500000000)));
      await _address(tester, _addr);

      await tester.tap(find.text('25%'));
      await tester.pump();
      expect(find.text('3086.25'), findsOneWidget);
      expect(
        _reviewReason(tester),
        isNull,
        reason: 'a figure on screen that will not parse is a dead control',
      );

      await tester.tap(find.text('50%'));
      await tester.pump();
      expect(find.text('6172.50'), findsOneWidget);
      expect(_reviewReason(tester), isNull);
      // And the eye still reads it grouped where grouping belongs — on the
      // control that restates it, never in the field.
      expect(find.text('Review 6172.50 KAS'), findsOneWidget);
    });

    testWidgets('a stale balance is not typed into a spend', (tester) async {
      // `_amountBlock` yields when the reading is last-known — *a fabricated
      // certainty about someone's money* — and the Max chip annotates its
      // figure. A quarter of an unvouched figure, typed silently, is the same
      // claim (`consensus-auditor`, UX-R2).
      _phone(tester);
      final stale = ValueNotifier<bool>(true);
      addTearDown(stale.dispose);
      await tester.pumpWidget(
        _sendScreen(mature: BigInt.from(1234500000000), balanceStale: stale),
      );
      await _address(tester, _addr);
      await tester.tap(find.text('25%'));
      await tester.pump();
      expect(
        find.text('3086.25'),
        findsNothing,
        reason: 'the chips are inert while the balance cannot be vouched for',
      );
      // Max stays live: Rust solves the sweep, so no figure of ours is
      // asserted by tapping it.
      expect(find.textContaining('last known'), findsOneWidget);

      stale.value = false;
      await tester.pump();
      await tester.tap(find.text('25%'));
      await tester.pump();
      expect(find.text('3086.25'), findsOneWidget);
    });

    testWidgets('Send another clears the form rather than leaving it armed', (
      tester,
    ) async {
      // The one new commit-adjacent seam (`wallet-security-auditor`, UX-R2):
      // what stands between the user and a re-send-armed form after a send has
      // just gone out.
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await _address(tester, _addr);
      await _type(tester, '12.4');
      await tester.tap(find.textContaining('Review '));
      await tester.pump();
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.textContaining('Hold to send')),
      );
      await tester.pump();
      await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Sent'), findsOneWidget);

      await tester.tap(find.text('Send another'));
      await tester.pumpAndSettle();
      // Back on step 1, empty — not on step 2 holding the destination and the
      // amount of the send that just landed.
      expect(find.text('Send'), findsOneWidget);
      expect(_reviewReason(tester), 'Enter an address to continue');
      expect(find.textContaining('12.4'), findsNothing);
    });

    testWidgets('the live fee is the Generator\'s, debounced, and never a stale '
        'figure beside a changed amount', (tester) async {
      // The fee moves with the coin shape the amount selects, so it is probed
      // rather than computed — and the probe runs the SAME two-shape build and
      // shipping decision `prepare_send` runs, which is what lets the figure
      // carry no `≈`. What this pins is the Dart half: one probe per pause,
      // the newest answer wins, and nothing shown while it is unknown.
      _phone(tester);
      final asked = <BigInt>[];
      await tester.pumpWidget(
        _sendScreen(
          feePreview: (destination, amount) async {
            asked.add(amount);
            return BigInt.from(315400);
          },
        ),
      );
      await _address(tester, _addr);
      await _type(tester, '1');

      // Nothing yet: the probe is debounced, and an unknown fee shows nothing.
      expect(find.text('Network fee'), findsNothing);

      await tester.pump(const Duration(milliseconds: 300));
      expect(_feeLine(tester), 'Network fee0.003154KAS');

      // A further keystroke clears the figure IMMEDIATELY — a fee left
      // standing beside a changed amount is a lie for as long as it stands.
      await _type(tester, '2');
      expect(find.text('Network fee'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_feeLine(tester), 'Network fee0.003154KAS');

      // One probe per pause, not one per keystroke.
      expect(asked.length, 2);
      expect(asked.last, BigInt.from(1200000000));
    });

    testWidgets('a null fee renders nothing at all — never a guess', (
      tester,
    ) async {
      // `None` is a real answer: below the KIP-9 floor, more than the coins
      // cover, or a covenant-fenced draw. The screen says nothing rather than
      // showing a number nobody built.
      _phone(tester);
      await tester.pumpWidget(_sendScreen(feePreview: (_, _) async => null));
      await _address(tester, _addr);
      await _type(tester, '1');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Network fee'), findsNothing);
    });

    testWidgets('an honest prepare error (not-yet-spendable) is surfaced', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _sendScreen(
          prepare: (_, _) async =>
              throw const AppError(message: 'not yet spendable — confirming'),
        ),
      );
      await _address(tester, _addr);
      await _type(tester, '12.4');
      await tester.tap(find.textContaining('Review '));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('not yet spendable'), findsOneWidget);
    });

    testWidgets('below the probed KIP-9 floor: both exact figures in amber, '
        'and Review stays live (D-054)', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _sendScreen(
          minimumSendable: () async => BigInt.from(2036), // 0.00002036 KAS
        ),
      );
      await tester.pump(); // resolve the probe future
      await _address(tester, _addr);
      await _type(tester, '0.00000042');

      // The exact number, not "too small" — the floor AND the shortfall.
      expect(
        find.text(
          'The network will not relay less than 0.00002036 KAS. You are '
          '0.00001994 KAS short.',
        ),
        findsOneWidget,
      );
      // And it WARNS rather than blocking: the Generator on prepare stays the
      // single authority for what can be built, so a probe that went stale
      // high cannot take the send away from the user.
      expect(
        _reviewReason(tester),
        isNull,
        reason: 'the probed floor advises; Rust decides',
      );
    });

    testWidgets('the advisory floor cannot reach the destination\'s own '
        'ladder', (tester) async {
      // The floor WARNS and never blocks — but an advisory branch that
      // `return`s is an early exit for every blocking check after it, and the
      // one-screen form's version skipped all three address checks
      // (`consensus-auditor`). **The two steps now have two ladders**, so that
      // class of defect is structurally unreachable; this pins the structure
      // rather than the symptom.
      _phone(tester);
      await tester.pumpWidget(
        _sendScreen(minimumSendable: () async => BigInt.from(2036)),
      );
      await tester.pump();
      await _address(tester, _addr);
      await _type(tester, '0.00000042');
      expect(
        _reviewReason(tester),
        isNull,
        reason: 'the probed floor advises; Rust decides',
      );
      expect(find.textContaining('will not relay less than'), findsOneWidget);

      // Back to a destination that does not parse: its own ladder blocks, and
      // the amount step's advisory has no say in it.
      await _address(tester, 'kaspa:qpzt3vw8x2mne4ka0000', advance: false);
      expect(_reviewReason(tester), 'Check the destination address');
    });

    testWidgets('no minimum provider ⇒ no floor notice', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await tester.pump();
      await _address(tester, _addr);
      await _type(tester, '0.00000042');
      expect(find.textContaining('will not relay less than'), findsNothing);
      expect(_reviewReason(tester), isNull);
    });

    testWidgets('more than the spendable balance blocks, with the exact '
        'shortfall', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _sendScreen(mature: BigInt.from(1000000000)), // 10 KAS
      );
      await _address(tester, _addr);
      await _type(tester, '12.4');
      expect(
        find.text('You have 10.00 KAS spendable. You are 2.40 KAS short.'),
        findsOneWidget,
      );
      expect(_reviewReason(tester), 'More than you can spend');
    });

    testWidgets('an unknown balance never blocks and never fabricates a zero '
        '(BG-8)', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen(mature: null));
      await _address(tester, _addr);
      // The spendable figure rides the Max chip (`S6`, D-190: *`available` is
      // the number Send max means*), and BG-8's `—` is what it shows while the
      // balance has not arrived — never a fabricated zero.
      expect(find.text('—'), findsOneWidget);
      await _type(tester, '12.4');
      expect(
        _reviewReason(tester),
        isNull,
        reason: 'a number that has not arrived is not a refusal',
      );
    });

    testWidgets('a LAST-KNOWN balance says so in words, and is never quoted '
        'back as a fact (BG-8)', (tester) async {
      _phone(tester);
      final stale = ValueNotifier<bool>(false);
      addTearDown(stale.dispose);
      await tester.pumpWidget(
        _sendScreen(mature: BigInt.from(1000000000), balanceStale: stale),
      );
      await _address(tester, _addr);
      await _type(tester, '12.4');
      // Live: the shortfall is a fact the wallet can vouch for, so it says it.
      expect(find.text('10.00'), findsOneWidget);
      expect(_reviewReason(tester), 'More than you can spend');

      stale.value = true;
      await tester.pump();
      await tester.pump(KvMotion.calm);
      // **The freshness is in WORDS, and it does not dim.** BG-8's 45 % dim is
      // a large-text device (D-257) and this reading is 13 dp: multiplying it
      // would put it under AA, which BG-14 does not permit. So the figure says
      // its own state instead.
      expect(find.text('10.00 · last known'), findsOneWidget);
      // And the screen stops asserting a figure it cannot currently vouch for
      // — the P0.3 scar with a number attached.
      expect(_reviewReason(tester), isNull);
      expect(find.textContaining('You have'), findsNothing);
    });

    testWidgets('an address of the wrong length says how many characters it '
        'has', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await _address(tester, 'kaspa:qpzt3vw8x2mne4ka0000', advance: false);
      expect(
        find.text(
          'That is 26 characters. A mainnet address is 67 — or 69 for the '
          'rarer ECDSA form.',
        ),
        findsOneWidget,
      );
      expect(_reviewReason(tester), 'Check the destination address');
    });

    testWidgets('an address with the wrong scheme says so', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await _address(
        tester,
        'bitcoincash:qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq',
        advance: false,
      );
      expect(
        find.text('A mainnet Kaspa address starts with "kaspa:".'),
        findsOneWidget,
      );
      expect(_reviewReason(tester), 'Check the destination address');
    });

    testWidgets('the amount announces itself as an editable field', (
      tester,
    ) async {
      // It was a `Semantics(button:)` over two `Text` nodes, which needed a
      // hand-written phrase and a hand-wired action. As a real `TextField` it
      // announces itself, carries its own value, and is activatable by
      // TalkBack for free — the accessible answer is the one that stopped
      // pretending.
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_sendScreen());
      await _address(tester, _addr);
      await _type(tester, '12.4');
      final node = tester.getSemantics(
        find.descendant(
          of: find.byKey(SendScreen.amountTarget),
          matching: find.byType(EditableText),
        ),
      );
      expect(node.value, '12.4');
      expect(node.flagsCollection.isTextField, isTrue);
      handle.dispose();
    });

    testWidgets('the amount pad follows the KEYBOARD, not the focus', (
      tester,
    ) async {
      _phone(tester);
      // Two different facts, and the device proved they come apart: the system
      // BACK button dismisses the IME **without dropping focus**. A `hasFocus`
      // predicate therefore left the pad hidden with the keyboard already
      // gone, and the screen showed a dead void where the digits belong —
      // while the code's own comment claimed the pad "comes back when it
      // closes" (found on glass 2026-08-30; the comment was the older L121
      // shape, a law nobody re-checked).
      //
      // `viewInsets` is what the IME actually moves, so that is what the pad
      // is keyed to and what this test drives.
      void keyboard({required bool up}) {
        tester.view.viewInsets = up
            ? const FakeViewPadding(bottom: 300)
            : FakeViewPadding.zero;
      }

      await tester.pumpWidget(_sendScreen());
      await _address(tester, _addr);
      expect(find.byType(KvKeypad), findsOneWidget, reason: 'nothing focused');

      // Tapping the figure raises the IME: the pad steps aside.
      await tester.tap(find.byKey(SendScreen.amountTarget));
      keyboard(up: true);
      await tester.pump();
      expect(find.byType(KvKeypad), findsNothing);

      // BACK closes the IME and the field KEEPS focus. The pad must still come
      // back — the assertion a focus-based test could not make, and the defect
      // it could not see.
      keyboard(up: false);
      await tester.pump();
      expect(
        find.byKey(SendScreen.amountTarget),
        findsOneWidget,
        reason: 'the field is still there and still focused',
      );
      expect(
        find.byType(KvKeypad),
        findsOneWidget,
        reason: 'keyboard down means the pad is back, focus or no focus',
      );
    });
  });

  // ── L131: a clipped `Text` raises no overflow and `find.text` matches the
  // string the widget was GIVEN, so a truncation law needs a MEASUREMENT.
  group('no reading is truncated at 320dp / 1.3×', () {
    /// The floor a money FIGURE is held to, below §2's 11dp for everything
    /// else — see the reasoning in `expectNothingBelowTheReadableFloor`.
    ///
    /// **Derived from the measured worst case, and stated as such.** With the
    /// layouts on this branch the widest reading the app can produce is the
    /// ceremony headline's fraction at the whole 28.7e9 KAS supply, 320dp,
    /// 1.3×: **10.33dp**. So the guard fails below 10 and the margin is
    /// 0.33dp. **If that margin is ever spent, the layout is the fix, not this
    /// constant** — every breach found at UX-4 was a layout starving a figure
    /// of width it had, not a screen genuinely out of room.
    const double figureFloor = 10;

    /// Re-lay every `Text` in the tree through a `TextPainter` at the width it
    /// was actually given, and fail on any that exceeds its own `maxLines`.
    void expectNothingClipped(WidgetTester tester) {
      final offenders = <String>[];
      for (final element in find.byType(Text).evaluate()) {
        final widget = element.widget as Text;
        final text = widget.data;
        if (text == null || text.isEmpty) continue;
        final render = element.renderObject;
        if (render is! RenderBox || !render.hasSize) continue;
        final style = DefaultTextStyle.of(element).style.merge(widget.style);
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: TextDirection.ltr,
          maxLines: widget.maxLines,
          textScaler: MediaQuery.textScalerOf(element),
        )..layout(maxWidth: render.size.width);
        // TWO ways a reading is cut off, and `maxLines` only sees the first.
        // A `Text` with no `maxLines` never "exceeds" it — it wraps, and then
        // the box it wraps inside clips the overflow with no exception and no
        // ellipsis (the `TextField` hint is exactly this shape). So the height
        // is measured too. What this still cannot see: a reading inside a
        // widget that is not a `Text`, and one that was never built.
        final tooManyLines = painter.didExceedMaxLines;
        final tooTall = painter.height > render.size.height + 0.5;
        if (tooManyLines || tooTall) {
          offenders.add(
            '"$text" in ${render.size.width.toStringAsFixed(1)}'
            '×${render.size.height.toStringAsFixed(1)}dp '
            '(needs ${painter.height.toStringAsFixed(1)}dp)',
          );
        }
        painter.dispose();
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these readings are cut off at the worst supported geometry — a '
            'clipped Text raises no overflow, so only a measurement sees it',
      );
    }

    /// A `FittedBox` cures a clip by SHRINKING, and nothing bounds the shrink
    /// — so the measurement that proves nothing is cut off is structurally
    /// blind to the state it produces (a `Text` laid out at unbounded width
    /// never exceeds its lines). This is the other half: walk every `Text`
    /// that sits under a `FittedBox`, recover the scale the box applied, and
    /// hold the result to §2/BG-14's 11dp floor for anything a user must read.
    void expectNothingBelowTheReadableFloor(WidgetTester tester) {
      final offenders = <String>[];
      for (final element in find.byType(Text).evaluate()) {
        final widget = element.widget as Text;
        final text = widget.data;
        if (text == null || text.isEmpty) continue;
        RenderFittedBox? fitted;
        element.visitAncestorElements((ancestor) {
          final render = ancestor.renderObject;
          if (render is RenderFittedBox) {
            fitted = render;
            return false;
          }
          return true;
        });
        final box = fitted;
        final child = box?.child;
        if (box == null || child == null || !child.hasSize || !box.hasSize) {
          continue;
        }
        if (child.size.isEmpty) continue;
        final scale = math.min(
          1.0,
          math.min(
            box.size.width / child.size.width,
            box.size.height / child.size.height,
          ),
        );
        final style = DefaultTextStyle.of(element).style.merge(widget.style);
        // **A money FIGURE gets a lower floor, not an exemption** — and the
        // difference is the whole finding. BG-5 orders the trade explicitly:
        // an amount *"scales down before it clips … never wraps, never
        // ellipsizes and never truncates a digit, at any text scale"*, so
        // where an unbounded figure meets a bounded box, scaling is what the
        // law asks for and clipping is what it forbids. But an UNBOUNDED
        // exemption makes the guard structurally unable to see the class of
        // defect it was written after — a 6.70dp fee row passed it silently
        // (`ux-auditor`, UX-4). So figures are held to `figureFloor` instead.
        //
        // The predicate is TWO conditions, because one of them was falsified
        // by this same diff: tabular figures alone let `available 1,234.5`
        // through as a "figure", and that string is a sentence. The whole run
        // must read as a number as well.
        final tabular =
            style.fontFeatures?.contains(const FontFeature.tabularFigures()) ??
            false;
        final isFigure = tabular && RegExp(r'^[\d.,\s+−-]+$').hasMatch(text);
        final floor = isFigure ? figureFloor : KvAmount.readableFloor;
        final scaler = MediaQuery.textScalerOf(element);
        final rendered = scaler.scale(style.fontSize ?? 14) * scale;
        if (rendered < floor) {
          offenders.add(
            '"$text" at ${rendered.toStringAsFixed(2)}dp '
            '(floor ${floor.toStringAsFixed(0)})',
          );
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these readings are scaled below the 11dp floor — a FittedBox '
            'cures a clip by shrinking, and nothing else bounds the shrink',
      );
    }

    Widget squeeze(Widget child) => MediaQuery(
      data: const MediaQueryData(
        size: Size(320, 568),
        textScaler: TextScaler.linear(1.3),
      ),
      child: child,
    );

    /// Walk the screen's scroll from top to bottom, measuring at every step —
    /// a reading that is only built halfway down is still a reading, and at
    /// this geometry most of them are.
    ///
    /// **It starts by jumping to the top, and that line is the whole test.**
    /// `pumpWidget` reuses the element tree between configurations, so the
    /// scroll offset CARRIES OVER: measured across the ceremony's sixteen
    /// cases, only the first began at 0, two began past `maxScrollExtent` and
    /// never ran the loop at all, and the headline — where the worst reading
    /// in the app lives — went unmeasured in fifteen of them. The guard passed
    /// with its figure floor raised to 11, which is to say it could not see
    /// the one reading §9.13 was written about (`ux-auditor`, UX-4). A guard
    /// that can only pass is the same artifact as a comment that can only be
    /// believed.
    ///
    /// **`jumpTo`, not `drag`.** A drag from the top lands on a
    /// gesture-absorbing child and `pixels` never advances, so the loop never
    /// terminates — tried, and it hung.
    Future<void> measureThroughTheScroll(WidgetTester tester) async {
      // The screen's own list, named: the amount is a text field now and
      // carries a `Scrollable` of its own, so "the first Scrollable" stopped
      // meaning "the list".
      final scrollable = find.byKey(SendScreen.scrollTarget).evaluate().isEmpty
          ? find.byType(Scrollable).first
          : find
                .descendant(
                  of: find.byKey(SendScreen.scrollTarget),
                  matching: find.byType(Scrollable),
                )
                .first;
      var y = tester
          .state<ScrollableState>(scrollable)
          .position
          .minScrollExtent;
      while (true) {
        final position = tester.state<ScrollableState>(scrollable).position;
        final target = math.min(y, position.maxScrollExtent);
        position.jumpTo(target);
        await tester.pump();
        expectNothingClipped(tester);
        expectNothingBelowTheReadableFloor(tester);
        if (target >= position.maxScrollExtent) break;
        y = target + 120;
      }
    }

    testWidgets('the send screen', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        squeeze(
          _sendScreen(
            // **The SHIPPED wiring, not a convenient subset.** `prepareSweep`
            // is non-null in the app, so `Send max` is built and `available`
            // shares its row — which is the geometry that clips. An earlier
            // cut of this test omitted it and measured a layout the app never
            // ships; `ux-auditor` found the clip the guard could not (L126's
            // shape: a mechanism tested with the pressure off).
            //
            // A seven-figure balance, because that is the widest real one.
            mature: BigInt.from(123456789012345),
            prepareSweep: (_) async =>
                _summary(kind: SignableKind.sweep, utxoCount: 1),
            minimumSendable: () async => BigInt.from(2036),
          ),
        ),
      );
      await tester.pump();
      // **Both steps, at the floor.** Step 1 carries the field, the check and
      // the helper prose; step 2 carries the figure, the shares, the fee and
      // the pad. Neither is measured by measuring the other.
      await _address(tester, _addr, advance: false);
      await measureThroughTheScroll(tester);
      await _address(tester, _addr);
      // A below-floor amount, so the longest amber sentence on this screen is
      // on it while it is measured.
      await _type(tester, '0.00000042');
      await tester.pump();
      await measureThroughTheScroll(tester);
    });

    testWidgets('the send screen, at the widest amount the pad will take', (
      tester,
    ) async {
      // **A FRESH tree, and an amount that is actually wide.** The first cut
      // of this appended ten `9`s to `0.00000042` — which already carries
      // eight decimals, so `amountKeyPress` refused every one of them and the
      // "extreme" pass re-measured the dust (`ux-auditor`, UX-4). L126 twice
      // over: a guard run with the pressure off, in a test whose comment said
      // the pressure was on.
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        squeeze(
          _sendScreen(
            // **Above the amount typed below, deliberately.** With a smaller
            // balance the block ladder disables Review, `inlineReason` swaps
            // the label out, and the guard measures a reason instead of the
            // figure it exists to measure — L126, the pressure off
            // (`ux-auditor`, UX-R2). Keeping the pill LIT is what puts
            // `Review 9999999999.99999999 KAS` on the control at 320 / 1.3×.
            mature: BigInt.parse('2870000000000000000'),
            prepareSweep: (_) async =>
                _summary(kind: SignableKind.sweep, utxoCount: 1),
            minimumSendable: () async => BigInt.from(2036),
          ),
        ),
      );
      await tester.pump();
      await _address(tester, _addr);
      await _type(tester, '9999999999.99999999');
      expect(
        _reviewReason(tester),
        isNull,
        reason: 'the guard must measure a LIT pill carrying the figure',
      );
      await tester.pump();
      await measureThroughTheScroll(tester);
    });

    testWidgets('a primary pill never ellipsizes the figure in its label', (
      tester,
    ) async {
      // **BG-5's one prohibition, on the control rather than in a readout.**
      // `KvAction`'s label was `maxLines: 1, overflow: ellipsis`, and Send
      // feeds it `Review <amount> KAS`: at 320 dp / 1.3× the pill's inner
      // width is 288 dp and the string passes it from about 100,000 KAS — so a
      // money figure was cut mid-number by a control (`ux-auditor`, UX-R2).
      // The pill wraps and grows now, exactly as `KvHold` does with the same
      // string.
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        squeeze(_sendScreen(mature: BigInt.parse('2870000000000000000'))),
      );
      await _address(tester, _addr);
      await _type(tester, '123456.78901234');
      final label = tester.widget<Text>(
        find.text('Review 123456.78901234 KAS'),
      );
      expect(label.maxLines, isNull, reason: 'it wraps; it never truncates');
      expect(label.overflow, isNot(TextOverflow.ellipsis));
      expectNothingClipped(tester);
    });

    testWidgets('the ceremony, in every mode, at the widest amount', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // **The widest real figure, not a convenient one.** Kaspa's whole supply
      // is ~28.7e9 KAS, so this is the most digits any ceremony can ever
      // restate — and a guard run at 12.4 KAS is a guard run with the pressure
      // off (L126). It is what put the headline's unit at 7.89dp and the hold
      // label at 9.63dp against an 11dp law.
      final whale = BigInt.parse('2870000000000000000');
      for (final kind in SignableKind.values) {
        for (final amount in <BigInt?>[null, whale]) {
          await tester.pumpWidget(
            squeeze(
              _ceremony(
                _summary(
                  amountSompi: amount,
                  kind: kind,
                  utxoCount: 352,
                  payloadKind: 'comm',
                  payloadLen: 154,
                ),
              ),
            ),
          );
          await tester.pump();
          // **Through the scroll, not just the first screenful.** Measured at
          // the floor geometry across all sixteen configurations, the ceremony
          // runs 157.5–392.3dp of content against a 338–388dp viewport, so the
          // fee row, the total and the irreversibility line are unbuilt when
          // the screen first settles — and the headline is off the top the
          // moment anything has scrolled (`ux-auditor`, UX-4).
          await measureThroughTheScroll(tester);
        }
      }
    });
  });

  group('SigningCeremony (anti-blind-signing, B7)', () {
    testWidgets('renders Rust-decoded amount/fee/total, not the form', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_ceremony(_summary()));

      // The control's label carries the summary's amount (Rust's decode → the
      // value signed), not a form echo.
      expect(find.text('Hold to send 12.40000000 KAS'), findsOneWidget);
      // Amount + network fee + total each render through KvAmount (the exact
      // fee, never "≈ free").
      expect(find.byType(KvAmount), findsNWidgets(3));
      // Destination shown for review (chunked, prefix preserved).
      expect(find.textContaining('kaspa:'), findsOneWidget);
      // The payment default title — kind-derived, no caller string needed.
      expect(find.text('Confirm send'), findsOneWidget);
      expect(
        find.text('Once this is signed it cannot be reversed.'),
        findsOneWidget,
      );
    });

    testWidgets('the destination is restated in full as ONE run, first four '
        'and last five weighted (BG-15)', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_ceremony(_summary()));
      // **BG-15 as amended, landed at UX-R2.** The full form is *one mono run
      // wrapping on word-break* — never spaced fours on a phone width. Fours
      // survive as the weighting boundary and as what a screen reader speaks;
      // they no longer print a space, because line breaks that move with the
      // text scale make the same address look different every time it is
      // shown, on the one form whose job is comparing it against a source.
      //
      // **D-223's tail of five stands**: chunking purely in fours left a
      // 61-character payload ending `… c6jz qunt h` — one stranded character,
      // weighted bold, which is the weakest place to put the eye.
      final spans = <InlineSpan>[];
      tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byType(KvAddress),
                  matching: find.byType(Text),
                )
                .first,
          )
          .textSpan!
          .visitChildren((span) {
            spans.add(span);
            return true;
          });
      // scheme + 14 fours + the five.
      expect(spans.length, 16);
      expect(
        spans.map((s) => (s as TextSpan).text).join(),
        _addr,
        reason: 'every character of the address is on screen, in order',
      );
      final head = spans[1] as TextSpan;
      final tail = spans.last as TextSpan;
      expect(head.text!.length, 4);
      expect(tail.text!.length, 5);
      // **The MERGED axis, not the enum** (L150): on a variable face
      // `fontWeight` is a hint and `FontVariation('wght')` is the ink.
      for (final checkpoint in [head, tail]) {
        expect(checkpoint.style!.fontWeight, FontWeight.w700);
        expect(checkpoint.style!.fontVariations, KvWeight.w700);
        expect(checkpoint.style!.color, KvColor.ink);
      }
      final middle = (spans[2] as TextSpan).style!;
      expect(middle.fontWeight, FontWeight.w500);
      expect(middle.fontVariations, KvWeight.w500);
      expect(middle.color, KvColor.inkDim);
    });

    testWidgets('a chained send tells the user it is multiple transactions', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_ceremony(_summary(txCount: 3)));
      expect(find.textContaining('3 transactions'), findsOneWidget);
    });

    testWidgets('self-send rendering derives from the Rust kind, never a '
        'caller bool', (tester) async {
      _phone(tester);
      // V5: the mode rides the Rust-decoded DTO — there is no selfSend
      // parameter left for a caller to lie through.
      await tester.pumpWidget(
        _ceremony(
          _summary(
            kind: SignableKind.selfSendFrame,
            payloadLen: 154,
            payloadKind: 'comm',
          ),
        ),
      );

      // Leads with the honest cost (the fee), never the returning value.
      expect(findRuledLabel('Costs you'), findsOneWidget);
      expect(find.text('Returns to you'), findsOneWidget);
      // The raw self "To" address is dropped (D-069).
      expect(find.textContaining('kaspa:'), findsNothing);
      // The returning value is never quoted as the thing being sent.
      expect(find.textContaining('Hold to send 12.40000000'), findsNothing);
      expect(find.text('Hold to send message'), findsOneWidget);
      // Kind-derived default title.
      expect(find.text('Confirm message'), findsOneWidget);
    });

    testWidgets('a self-send still HOLDS — the one-action carve-out is not '
        'this surface to grant', (tester) async {
      _phone(tester);
      // BG-6's carve-out is bound to `SignableKind::SelfSendFrame`, and UX-6
      // ships it under eight named conditions (phase §5). Until then every
      // mode holds, and this pin is what stops the carve-out arriving early
      // through a well-meaning tidy-up.
      var commits = 0;
      await tester.pumpWidget(
        _host(
          SigningCeremony(
            summary: _summary(kind: SignableKind.selfSendFrame),
            commit: (_) async {
              commits++;
              return _ok();
            },
            abandon: () async {},
          ),
        ),
      );
      await tester.tap(find.text('Hold to send message'));
      await tester.pumpAndSettle();
      expect(commits, 0, reason: 'a tap is not a hold, in every mode');
    });

    testWidgets('payment mode renders no payload fields', (tester) async {
      _phone(tester);
      // The variant law: a payment summary structurally has no payload facts
      // (Rust sets them None) — nothing payload-ish may appear.
      await tester.pumpWidget(_ceremony(_summary()));
      expect(find.textContaining('payload'), findsNothing);
      expect(find.textContaining('Carries'), findsNothing);
    });

    testWidgets('a bond confirm renders the payload facts from the DTO, not '
        'a caller string', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _ceremony(
          _summary(
            kind: SignableKind.bond,
            payloadLen: 154,
            payloadKind: 'handshake',
          ),
        ),
      );
      // The payload line is the SCREEN's rendering of the DTO's built-tx
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
      expect(findRuledLabel('Sending'), findsOneWidget);
      expect(find.text('Leaves your wallet'), findsOneWidget);
      expect(find.text('Confirm contact request'), findsOneWidget);
    });

    testWidgets('a bond refund (accept) is not a self-send — D-069 preserved', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _ceremony(
          _summary(
            kind: SignableKind.bondRefund,
            payloadLen: 154,
            payloadKind: 'handshake',
          ),
        ),
      );
      // D-069 keeps bonds as REAL value to the counterparty: never the
      // self-send rendering.
      expect(findRuledLabel('Costs you'), findsNothing);
      expect(find.text('Returns to you'), findsNothing);
      expect(findRuledLabel('Sending'), findsOneWidget);
      expect(find.textContaining('kaspa:'), findsOneWidget);
      expect(find.text('Leaves your wallet'), findsOneWidget);
      expect(find.text('Confirm accept'), findsOneWidget);
      expect(find.text('Hold to send 12.40000000 KAS'), findsOneWidget);
    });

    testWidgets('a sweep confirms the whole-wallet exit in the DTO\'s own '
        'numbers', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _ceremony(_summary(kind: SignableKind.sweep, utxoCount: 7)),
      );
      expect(find.text('Confirm send all'), findsOneWidget);
      expect(findRuledLabel('Sending'), findsOneWidget);
      expect(find.textContaining('kaspa:'), findsOneWidget);
      expect(find.textContaining('all 7 spendable coins move'), findsOneWidget);
      expect(find.text('Leaves your wallet'), findsOneWidget);
      expect(find.text('Hold to send 12.40000000 KAS'), findsOneWidget);
    });

    testWidgets('a merge renders as returning value with the savings pair '
        'from the DTO', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _ceremony(
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
      expect(findRuledLabel('Costs you'), findsOneWidget);
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
      _phone(tester);
      await tester.pumpWidget(
        _ceremony(_summary(kind: SignableKind.consolidate, utxoCount: 5)),
      );
      expect(find.text('Confirm merge'), findsOneWidget);
      expect(find.textContaining('A typical send today'), findsNothing);
      expect(find.textContaining('Merges 5 coins into one'), findsOneWidget);
    });

    testWidgets(
      'a merge too big for one transaction promises the number it will '
      'actually leave, and names the coin count as the cause',
      (tester) async {
        _phone(tester);
        await tester.pumpWidget(
          _ceremony(
            _summary(
              kind: SignableKind.consolidate,
              utxoCount: 352,
              txCount: 4,
              resultingCoins: 4,
            ),
          ),
        );
        // The promise is the truth: 352 coins become 4, not one.
        expect(find.textContaining('Merges 352 coins into 4'), findsOneWidget);
        expect(
          find.textContaining('merging again takes it further'),
          findsOneWidget,
        );
        expect(
          find.textContaining('into one at your own address'),
          findsNothing,
        );
        // A merge splits on coin COUNT — the payment sentence would name the
        // wrong cause on this surface.
        expect(
          find.textContaining('more coins than one transaction can hold'),
          findsOneWidget,
        );
        expect(find.textContaining('your amount exceeds'), findsNothing);
      },
    );

    testWidgets(
      'a CHAINED merge still ends in one coin, and the ceremony says so — a '
      'transaction count is not a coin count',
      (tester) async {
        _phone(tester);
        // The native compound arm: many transactions, one final output
        // (`verify_drain` refuses any other shape), so Rust publishes
        // resultingCoins = 1 and the screen must not read the chain length as
        // a coin count. This is the commoner arm — every payments-only wallet
        // with no live conversations takes it.
        await tester.pumpWidget(
          _ceremony(
            _summary(
              kind: SignableKind.consolidate,
              utxoCount: 352,
              txCount: 4,
              resultingCoins: 1,
            ),
          ),
        );
        expect(
          find.textContaining('Merges 352 coins into one'),
          findsOneWidget,
        );
        expect(find.textContaining('into 4'), findsNothing);
        expect(
          find.textContaining('merging again takes it further'),
          findsNothing,
        );
        // The chain-length note is still true and still shown.
        expect(
          find.textContaining('more coins than one transaction can hold'),
          findsOneWidget,
        );
      },
    );

    testWidgets('a hypothetical P4 stake flow renders through the one '
        'ceremony, and names the stake', (tester) async {
      _phone(tester);
      // The V5 variant-coverage bar: P4's challenge/stake adds a PRODUCER,
      // never a second ceremony. A stake is value at risk to a covenant + a
      // game frame — payment-like rendering with the payload facts, through
      // the same hold.
      await tester.pumpWidget(
        _ceremony(
          _summary(
            kind: SignableKind.stake,
            payloadLen: 96,
            payloadKind: 'comm',
          ),
        ),
      );
      expect(find.text('Confirm stake'), findsOneWidget);
      expect(findRuledLabel('Sending'), findsOneWidget);
      expect(find.textContaining('kaspa:'), findsOneWidget);
      expect(
        find.text(
          'Carries: comm payload, 96 bytes '
          '(decoded from the built transaction).',
        ),
        findsOneWidget,
      );
      // The label names the ACTION and its object (BG-11): a stake is not a
      // send, and the control that fires it must not call it one.
      expect(find.text('Hold to stake 12.40000000 KAS'), findsOneWidget);
    });

    testWidgets('the ceremony is generalised across every mode, keyed off the '
        'ENUM', (tester) async {
      _phone(tester);
      // The table is written out rather than derived, so a kind that changes
      // meaning has to be re-decided here instead of inheriting a sentence
      // written for a payment. `_defaultTitle` and `_holdLabel` are both
      // exhaustive switches, so a ninth [SignableKind] is a COMPILE error
      // before it can reach this test — this pins what the eight SAY.
      const expected = <SignableKind, (String, String)>{
        SignableKind.payment: ('Confirm send', 'Hold to send 12.40000000 KAS'),
        SignableKind.bond: (
          'Confirm contact request',
          'Hold to send 12.40000000 KAS',
        ),
        SignableKind.bondRefund: (
          'Confirm accept',
          'Hold to send 12.40000000 KAS',
        ),
        SignableKind.selfSendFrame: ('Confirm message', 'Hold to send message'),
        SignableKind.stake: ('Confirm stake', 'Hold to stake 12.40000000 KAS'),
        SignableKind.bcast: (
          'Confirm broadcast',
          'Hold to broadcast 12.40000000 KAS',
        ),
        SignableKind.sweep: (
          'Confirm send all',
          'Hold to send 12.40000000 KAS',
        ),
        SignableKind.consolidate: ('Confirm merge', 'Hold to merge 2 coins'),
      };
      expect(
        expected.keys.toSet(),
        SignableKind.values.toSet(),
        reason: 'a mode exists that this table does not decide',
      );

      for (final entry in expected.entries) {
        final kind = entry.key;
        await tester.pumpWidget(_ceremony(_summary(kind: kind)));
        final (heading, label) = entry.value;
        expect(
          tester.widget<KvSheet>(find.byType(KvSheet)).title,
          heading,
          reason: '$kind heading',
        );
        expect(find.text(label), findsOneWidget, reason: '$kind label');
        // Every mode keeps the ceremony, whichever surface opened it: the
        // irreversibility line and the exact fee.
        expect(
          find.text('Once this is signed it cannot be reversed.'),
          findsOneWidget,
          reason: '$kind dropped the irreversibility line',
        );
        expect(
          find.text('Network fee'),
          findsOneWidget,
          reason: '$kind dropped the exact fee',
        );
      }
    });

    testWidgets('no fiat figure ever reaches the signing surface', (
      tester,
    ) async {
      _phone(tester);
      // BG-5 as amended (D-191): a price may sit under a balance and never
      // price a fee or size a spend. INV-8's carve-out is what permits fiat at
      // all, and this surface is where it is withdrawn.
      for (final kind in SignableKind.values) {
        await tester.pumpWidget(_ceremony(_summary(kind: kind)));
        expect(find.textContaining('≈'), findsNothing, reason: '$kind');
        expect(find.textContaining(r'$'), findsNothing, reason: '$kind');
      }
    });
  });

  group('the staged, named wait', () {
    /// A commit that never resolves, so the wait can be walked beat by beat.
    Widget hanging() => _host(
      SigningCeremony(
        summary: _summary(),
        commit: (_) => Completer<SendOutcomeDto>().future,
        abandon: () async {},
      ),
    );

    Future<void> signIt(WidgetTester tester) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold to send 12.40000000 KAS')),
      );
      await tester.pump();
      await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pump();
    }

    testWidgets('names each stage in order, and marks none of them complete', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(hanging());
      await signIt(tester);

      // All three are named from the first frame — the user can see which
      // halves are still ahead, which is the whole point of naming them.
      for (final step in [
        'Signing on this device',
        'Broadcasting to the network',
        'Waiting for a node to accept it',
      ]) {
        expect(find.text(step), findsOneWidget);
      }

      FontWeight weightOf(String s) =>
          tester.widget<Text>(find.text(s)).style!.fontWeight!;

      expect(weightOf('Signing on this device'), FontWeight.w600);
      expect(weightOf('Broadcasting to the network'), FontWeight.w400);

      await tester.pump(const Duration(milliseconds: 750));
      expect(weightOf('Signing on this device'), FontWeight.w400);
      expect(weightOf('Broadcasting to the network'), FontWeight.w600);

      await tester.pump(const Duration(milliseconds: 900));
      expect(weightOf('Broadcasting to the network'), FontWeight.w400);
      expect(weightOf('Waiting for a node to accept it'), FontWeight.w600);

      // A PASSED step reads exactly like a coming one. `send_commit` is one
      // await across the FFI, so the wallet knows the same amount about both,
      // and a green tick beside "Broadcast to the network" would contradict
      // the refusal plate that can still land two beats later.
      expect(
        weightOf('Signing on this device'),
        weightOf('Broadcasting to the network'),
      );
      // The last stage is open-ended: the real outcome ends it, not a clock.
      await tester.pump(const Duration(seconds: 5));
      expect(weightOf('Waiting for a node to accept it'), FontWeight.w600);
    });

    testWidgets('a commit that lands early skips straight to the outcome', (
      tester,
    ) async {
      _phone(tester);
      final landed = Completer<SendOutcomeDto>();
      await tester.pumpWidget(
        _host(
          SigningCeremony(
            summary: _summary(),
            commit: (_) => landed.future,
            abandon: () async {},
          ),
        ),
      );
      await signIt(tester);
      expect(find.text('Signing on this device'), findsOneWidget);
      landed.complete(_ok());
      await tester.pumpAndSettle();
      expect(find.text('Signing on this device'), findsNothing);
      // The sheet is gone: a settled ceremony is a receipt, and a receipt is a
      // place rather than a modal (`S8`).
      expect(find.byType(KvSheet), findsNothing);
      expect(find.text('Sent'), findsOneWidget);
    });
  });

  group('the outcome, in three beats', () {
    Future<void> settleWith(
      WidgetTester tester,
      Future<SendOutcomeDto> Function(BigInt) commit, {
      Future<String> Function(String txid)? explorerUrl,
      Future<bool> Function(String url)? openUrl,
    }) async {
      await tester.pumpWidget(
        _host(
          SigningCeremony(
            // A fresh key each call: `pumpWidget` reuses the State for a
            // widget of the same type at the same position, so a second
            // settle in one test would have found the screen already settled
            // and no hold control to press.
            key: UniqueKey(),
            summary: _summary(),
            commit: commit,
            abandon: () async {},
            explorerUrl: explorerUrl,
            openUrl: openUrl,
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold to send 12.40000000 KAS')),
      );
      await tester.pump();
      await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('accepted — the WHOLE screen reads as sent, not just a plate '
        'at the bottom', (tester) async {
      // Founder, on glass 2026-08-30: a settled screen whose rail still says
      // *Confirm send* and whose label still says *Sending* is a confirm form
      // with a note stuck to the bottom. The verdict has to reach the rail and
      // the label too.
      _phone(tester);
      await settleWith(tester, (_) async => _ok());
      // **The whole surface is the answer now** (`S8`): the sheet is gone, an
      // 84 dp `KvCheck` stands over a 30 dp `display`, and the verdict's body
      // sits under it. Three places became one place that is unmistakable.
      expect(find.byType(KvSheet), findsNothing);
      expect(find.byType(KvCheck), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('The network accepted it.'), findsOneWidget);
      // **No waiting language** — Kaspa accepts in about a second, and telling
      // a user to expect minutes is a false impression built from true words.
      expect(find.textContaining('next few minutes'), findsNothing);
      // **The placeholder is gone** (UX-5 discharged D-223's suspended law).
      // With no explorer seam wired there is no exit at all, which is what a
      // control with nowhere to go should do — never a card that looks live.
      expect(find.text('View in explorer'), findsNothing);
      expect(find.text('coming next'), findsNothing);
      expect(find.byType(KvExplorerExit), findsNothing);
      // **The reference number is a control, not a run of text** (`S8`, §5):
      // Copy ID takes all 64 characters, and the transaction detail is where
      // the id is read. A 64-character hash printed on a receipt is a string
      // nobody checks by eye and everybody copies.
      expect(find.text('Copy ID'), findsOneWidget);
      expect(find.textContaining('Your funds are safe'), findsNothing);
    });

    testWidgets('the explorer exit names its destination and what it hands '
        'over, before the tap', (tester) async {
      // §5: *"an explorer" cannot be a sovereignty decision*. The user picked a
      // host in Settings, and the exit says which one they picked and what it
      // will see — the identifier, and the network address they hand over
      // simply by asking. This is the wallet's one deliberate egress (INV-8),
      // so it is disclosed BEFORE the tap rather than after it.
      _phone(tester);
      String? opened;
      await settleWith(
        tester,
        (_) async => _ok(),
        explorerUrl: (txid) async => 'https://explorer.kaspa.org/txs/$txid',
        openUrl: (url) async {
          opened = url;
          return true;
        },
      );
      await tester.pumpAndSettle();
      // The exit resolves its URL after the frame that mounts it — the
      // receipt arrives in the settle above, so its own resolve lands in the
      // next one.
      await tester.pumpAndSettle();
      expect(find.text('View on explorer.kaspa.org'), findsOneWidget);
      expect(
        find.text('Shares the transaction ID and your IP address'),
        findsOneWidget,
      );
      // And the host is named ONCE — the disclosure says "it", because the
      // control above it already said which "it" (BG-19).
      expect(find.textContaining('explorer.kaspa.org'), findsOneWidget);

      await tester.tap(find.byType(KvExplorerExit));
      await tester.pumpAndSettle();
      expect(
        opened,
        'https://explorer.kaspa.org/txs/${'a' * 64}',
        reason: 'the URL opened is the one Rust resolved, unedited',
      );
    });

    testWidgets('a refused explorer template disables the exit and says why', (
      tester,
    ) async {
      // Rust keeps a stored template that no longer validates rather than
      // silently substituting ours — a user who replaced the vendor must never
      // be quietly returned to it. So the exit has a third face: not a link,
      // and it says what to fix (BG-12/BG-20).
      _phone(tester);
      var opened = false;
      await settleWith(
        tester,
        (_) async => _ok(),
        explorerUrl: (_) async =>
            throw const AppError(message: 'the explorer link is empty'),
        openUrl: (_) async {
          opened = true;
          return true;
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('The explorer link cannot be used'), findsOneWidget);
      expect(
        find.text('the explorer link is empty — set it in Settings'),
        findsOneWidget,
      );
      await tester.tap(find.byType(KvExplorerExit));
      await tester.pumpAndSettle();
      expect(opened, isFalse, reason: 'a refused link is not a live control');
    });

    testWidgets('the Accepted stamp is the CHAIN\'s moment, and absent until '
        'there is one', (tester) async {
      // `accepted_unix_ms` was carried across the FFI for this line (UX-4B).
      // The device's own observation of an acceptance is a different fact, and
      // printing it under the label `Accepted` would have been a wallet claim
      // wearing a chain's clothes — wrong by however long the wallet took to
      // hear.
      _phone(tester);
      TxStatusDto? answer;
      await tester.pumpWidget(
        _host(
          SigningCeremony(
            summary: _summary(),
            commit: (_) async => _ok(),
            abandon: () async {},
            acceptanceStatus: (_) async => answer,
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold to send 12.40000000 KAS')),
      );
      await tester.pump();
      await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pump();
      await tester.pump();

      // Nothing accepted yet: no row, and above all no invented time.
      expect(find.text('Accepted'), findsNothing);

      final at = DateTime(2026, 8, 30, 2, 48, 57);
      answer = TxStatusDto(
        kind: TxStatusKind.accepted,
        blueDepth: BigInt.from(3),
        acceptedUnixMs: BigInt.from(at.millisecondsSinceEpoch),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('30 Aug 2026, 02:48'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a PARTIAL send is never stamped Accepted, and is never even '
        'asked about', (tester) async {
      // `PreparedSend::commit` reassigns `final_txid` after EVERY successful
      // submit, so on a partial broadcast it names the last compounding leg
      // rather than the payment. That leg is accepted within about a second
      // like any other, and the stamp would then have printed a chain-vouched
      // `Accepted` directly under `Total` — beside an amount that never went
      // out, and directly above a verdict reading `Partly sent`. The figures
      // would have contradicted the verdict on a funds surface
      // (`wallet-security-auditor`, UX-4B).
      _phone(tester);
      var asked = 0;
      await tester.pumpWidget(
        _host(
          SigningCeremony(
            summary: _summary(),
            commit: (_) async => SendOutcomeDto(
              finalTxid: 'b' * 64,
              submitted: 1,
              total: 2,
              partial: true,
            ),
            abandon: () async {},
            acceptanceStatus: (_) async {
              asked++;
              return TxStatusDto(
                kind: TxStatusKind.accepted,
                blueDepth: BigInt.from(3),
                acceptedUnixMs: BigInt.from(
                  DateTime(2026, 8, 30, 2, 48, 57).millisecondsSinceEpoch,
                ),
              );
            },
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold to send 12.40000000 KAS')),
      );
      await tester.pump();
      await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pump();
      await tester.pump();

      // The screen really IS in the partial state. Without this the absences
      // below would pass on a screen that simply never got anywhere. Two
      // matches, not one: the rail and the outcome head both speak the verdict,
      // which is the point of deriving both from `_verdictFor`.
      expect(find.text('Partly sent'), findsOneWidget);

      // Well past the 1 s poll the complete path uses.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(find.text('Accepted'), findsNothing);
      // Stronger than "renders nothing": it never asks. A partial has no
      // payment id to enquire about, so the poll is gated at its one entry
      // rather than at the render, and there is no second site to keep in step.
      expect(asked, 0);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('only the EXCEPTION is marked — a successful verdict carries '
        'no lamp, a failed one does', (tester) async {
      // Green means confirmed (BG-7). A green dot on `Sent` while the burial
      // mark below reads amber `Seen 26` claimed a certainty the chain was
      // denying; past a hundred the two agreed and became one thing said
      // twice. The receipt keeps ONE indicator, and it is the one reading the
      // chain (founder, on glass 2026-08-30).
      _phone(tester);

      await settleWith(tester, (_) async => _ok());
      expect(
        find.byType(KvLamp),
        findsNothing,
        reason: 'a successful verdict must not carry a lamp',
      );
      expect(find.byType(KvCheck), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);

      // The exceptions keep theirs.
      await settleWith(
        tester,
        (_) async => SendOutcomeDto(submitted: 1, total: 2, partial: true),
      );
      expect(find.byType(KvLamp), findsWidgets);

      await settleWith(
        tester,
        (_) async =>
            SendOutcomeDto(submitted: 0, total: 1, partial: false, error: 'x'),
      );
      expect(find.byType(KvLamp), findsWidgets);
    });

    testWidgets('the irreversibility caution is GONE once it has settled', (
      tester,
    ) async {
      // Redundant beside a verdict that says what happened, and wrong in
      // tense: *"Once this is signed"* over an already-signed transaction
      // (founder, on glass 2026-08-30).
      _phone(tester);
      await tester.pumpWidget(_ceremony(_summary()));
      expect(
        find.text('Once this is signed it cannot be reversed.'),
        findsOneWidget,
        reason: 'it must be there BEFORE the hold',
      );
      await settleWith(tester, (_) async => _ok());
      expect(
        find.text('Once this is signed it cannot be reversed.'),
        findsNothing,
      );
    });

    testWidgets('the caution is AMBER, never red', (tester) async {
      // **D-222, founder call.** BG-7 gives red to money leaving or at risk;
      // at the moment this line is read nothing has been signed and nothing is
      // at risk, so it is a caution about what will become true — which is
      // amber's own definition. Red spent the strongest hue in the system on a
      // warning, one line above a control the user has not pressed.
      _phone(tester);
      await tester.pumpWidget(_ceremony(_summary()));
      final chip = tester.widget<KvStatusChip>(
        find.widgetWithText(
          KvStatusChip,
          'Once this is signed it cannot be reversed.',
        ),
      );
      expect(chip.tone, KvLampTone.warn);
    });

    testWidgets('a NOT-CONFIRMED outcome keeps the present tense', (
      tester,
    ) async {
      // The label flips on `landed` — something was submitted — never on
      // "settled". A past-tense label over an unconfirmed send would claim it
      // did not go, which is the same false claim the funds-safe sentence
      // made.
      _phone(tester);
      await settleWith(
        tester,
        (_) async =>
            SendOutcomeDto(submitted: 0, total: 1, partial: false, error: 'x'),
      );
      // The tense lives in the verdict now (`S8`): the receipt's head names
      // what is known, and *"Not confirmed"* claims neither that it went nor
      // that it did not.
      expect(find.text('Not confirmed'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);
      expect(find.byType(KvCheck), findsNothing);
    });

    testWidgets('partial says what landed and what did not', (tester) async {
      _phone(tester);
      await settleWith(
        tester,
        (_) async => SendOutcomeDto(
          submitted: 1,
          total: 2,
          partial: true,
          finalTxid: 'b' * 64,
        ),
      );
      // One place, unmistakable: the receipt's own head.
      expect(find.text('Partly sent'), findsOneWidget);
      expect(
        find.byType(KvCheck),
        findsNothing,
        reason:
            'a partial send is an exception, and only the exception is '
            'marked — a check would claim the whole thing landed',
      );
      expect(
        find.textContaining('Broadcast 1 of 2 transactions'),
        findsOneWidget,
      );
      // Not a refusal: something DID leave, so the safety sentence must not
      // appear.
      expect(find.textContaining('Your funds are safe'), findsNothing);
    });

    testWidgets('a zero-submitted outcome never claims the funds are safe', (
      tester,
    ) async {
      // **`submitted == 0` does not prove that nothing left the wallet.**
      // `PreparedSend::commit` signs first and then awaits `try_submit`, and
      // ANY error on that await returns zero — including a request timeout and
      // a socket dropped after the bytes went out, either of which can follow
      // a node that accepted and relayed the transaction. Telling that user
      // their funds are safe is how they send it a second time
      // (`wallet-security-auditor`, UX-4). The sentence needs a Rust-set
      // discriminator before it can be said again; until then it is not said.
      _phone(tester);
      await settleWith(
        tester,
        (_) async => SendOutcomeDto(
          submitted: 0,
          total: 1,
          partial: false,
          error: 'orphan transaction rejected by the node',
        ),
      );
      expect(find.text('Not confirmed'), findsOneWidget);
      expect(
        find.textContaining('Your funds are safe'),
        findsNothing,
        reason: 'the wallet cannot prove this from a zero-submitted outcome',
      );
      // The third beat is the action that actually protects them.
      expect(
        find.textContaining('Check your activity before sending again'),
        findsOneWidget,
      );
      // The headline names the OUTCOME; Rust's own reason names the cause,
      // rather than being swallowed into a bare "failed".
      expect(
        find.text('orphan transaction rejected by the node'),
        findsOneWidget,
      );
    });

    testWidgets('leaving mid-broadcast takes the user off the armed form', (
      tester,
    ) async {
      // The overrun exit pops `null`, which is what a dismissal-without-signing
      // returns too — so without a signal the send screen restores a form
      // still holding the amount and the address, one tap from a duplicate,
      // immediately after the ceremony told the user to go and check whether
      // it landed (`wallet-security-auditor`, UX-4).
      _phone(tester);
      var popped = 0;
      await tester.pumpWidget(
        _host(
          Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => _RouteSpy(
                onPop: () => popped++,
                child: SendScreen(
                  mature: ValueNotifier<BigInt?>(BigInt.from(100000000000)),
                  prepare: (_, _) async => _summary(),
                  commit: (_) => Completer<SendOutcomeDto>().future,
                  abandon: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await _address(tester, _addr);
      await _type(tester, '12.4');
      await tester.tap(find.textContaining('Review '));
      await tester.pump();
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold to send 12.40000000 KAS')),
      );
      await tester.pump();
      await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pump(const Duration(seconds: 7));

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        popped,
        1,
        reason: 'the send screen popped too, rather than restoring the form',
      );
    });

    testWidgets('the in-flight exit signals exactly once, from either door, '
        'and never on a plain dismissal', (tester) async {
      // `Navigator.pop` reaches `onPopInvokedWithResult` synchronously in the
      // same call, so a widget that ALSO calls the callback from its own back
      // target fires it twice on that door and once on the system one — two
      // exits disagreeing about how many times an event happened. Harmless
      // for today's caller, which sets a bool; not harmless for the next one
      // (`wallet-security-auditor`, UX-4).
      _phone(tester);
      var fires = 0;
      // Pushed over a base route through the public entry point, because a
      // ceremony that IS the navigator's only route cannot be popped at all.
      Future<void> open(WidgetTester tester) async {
        late BuildContext ctx;
        await tester.pumpWidget(
          _host(
            Builder(
              builder: (c) {
                ctx = c;
                return const Scaffold();
              },
            ),
          ),
        );
        unawaited(
          showSigningCeremony(
            ctx,
            summary: _summary(),
            commit: (_) => Completer<SendOutcomeDto>().future,
            abandon: () async {},
            onLeftInFlight: () => fires++,
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> holdIt(WidgetTester tester) async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Hold to send 12.40000000 KAS')),
        );
        await tester.pump();
        await tester.pump(
          KvMotion.deliberate + const Duration(milliseconds: 20),
        );
        await gesture.up();
        await tester.pump(const Duration(seconds: 7));
      }

      // The rail's back target.
      await open(tester);
      await holdIt(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fires, 1, reason: 'the rail exit signalled more than once');

      // The system back gesture.
      fires = 0;
      await open(tester);
      await holdIt(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fires, 1, reason: 'the system exit must agree with the rail');

      // A plain dismissal, before anything was signed, is not an in-flight
      // exit and must say nothing.
      fires = 0;
      await open(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fires, 0, reason: 'nothing was in flight');
    });

    testWidgets('a wait that overruns gives the exit back rather than sealing '
        'the user in', (tester) async {
      // The commit await is bounded by the pinned client's request timeout,
      // per leg — long enough that a sealed screen invites a force-kill
      // mid-broadcast (`wallet-security-auditor`, UX-4).
      _phone(tester);
      await tester.pumpWidget(
        _host(
          SigningCeremony(
            summary: _summary(),
            commit: (_) => Completer<SendOutcomeDto>().future,
            abandon: () async {},
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold to send 12.40000000 KAS')),
      );
      await tester.pump();
      await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pump();

      // Sealed while the wait still looks normal.
      expect(tester.widget<KvSheet>(find.byType(KvSheet)).onCancel, isNull);
      expect(find.textContaining('You can leave'), findsNothing);

      await tester.pump(const Duration(seconds: 7));
      expect(tester.widget<KvSheet>(find.byType(KvSheet)).onCancel, isNotNull);
      expect(find.textContaining('leaving cancels nothing'), findsOneWidget);
      // And it claims nothing about where the transaction has GOT to — the
      // reasoning that deleted the funds-safe sentence applies here too.
      expect(find.textContaining('already out of the wallet'), findsNothing);
    });

    testWidgets('a thrown commit shows its reason and claims nothing about '
        'the funds', (tester) async {
      _phone(tester);
      await settleWith(
        tester,
        (_) async =>
            throw const AppError(message: 'the wallet locked mid-send'),
      );
      expect(find.text('Not confirmed'), findsOneWidget);
      expect(find.text('the wallet locked mid-send'), findsOneWidget);
      expect(
        find.textContaining('Your funds are safe'),
        findsNothing,
        reason:
            'an exception says the call did not return, not how far it got — '
            'this is not a surface for a comforting inference',
      );
    });
  });

  group('runConfirmSend (the slow-prepare card)', () {
    /// The ceremony is a sheet now (UX-R2, `S7`); leaving it is the sheet
    /// head's Cancel, which is the door BG-6 asks for — one that says in a
    /// word that nothing was signed.
    Future<void> leaveCeremony(WidgetTester tester) async {
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }

    testWidgets('a surface that unmounts mid-prepare abandons the stash', (
      tester,
    ) async {
      _phone(tester);
      // The helper's custody hygiene: prepare stashed an unsigned plan in
      // Rust, but the surface died before the ceremony could open — nobody can
      // ever commit it, so the helper releases it instead of leaving a
      // nonce-guarded orphan (V5 wallet-security note).
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

    testWidgets('leaving the ceremony without signing abandons the stash', (
      tester,
    ) async {
      _phone(tester);
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
        prepare: () async => _summary(),
        commit: (_) async => _ok(),
        abandon: () async => abandoned++,
        preparingObject: 'message',
      );
      await tester.pumpAndSettle();
      expect(find.byType(SigningCeremony), findsOneWidget);
      await leaveCeremony(tester);
      expect(await pending, isNull);
      expect(abandoned, 1, reason: 'back always cancels safely (BG-6)');
    });

    testWidgets('a slow prepare says so instead of freezing', (tester) async {
      _phone(tester);
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
        reason: 'held back so a fast prepare never flashes a card',
      );

      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Preparing your message'), findsOneWidget);
      expect(find.text('This can take a few seconds.'), findsNothing);

      await tester.pump(const Duration(milliseconds: 2100));
      expect(find.text('This can take a few seconds.'), findsOneWidget);

      await tester.pump(const Duration(seconds: 7));
      expect(
        find.textContaining("Still working. This hasn't been sent yet"),
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
      expect(find.byType(SigningCeremony), findsOneWidget);

      await leaveCeremony(tester);
      await pending;
      semantics.dispose();
    });

    testWidgets('a prepare landing before the card builds still dismisses it', (
      tester,
    ) async {
      _phone(tester);
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
      expect(find.byType(SigningCeremony), findsOneWidget);

      await leaveCeremony(tester);
      await pending;
    });

    testWidgets('the card sits under a Material, not the error fallback', (
      tester,
    ) async {
      _phone(tester);
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
      await leaveCeremony(tester);
      await pending;
    });

    testWidgets('a fast prepare never shows the card at all', (tester) async {
      _phone(tester);
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
      expect(find.byType(SigningCeremony), findsOneWidget);

      await leaveCeremony(tester);
      await pending;
    });
  });

  group(
    'BG-23 · the live fee, where it belongs and in the face it belongs in',
    () {
      // Founder's calls, both taken from rendered comparisons (D-230/D-231): the
      // fee shows its DIGITS rather than its leading zero, and it sits with the
      // destination it prices rather than in the amount block. `_probeFee`
      // refuses without both an amount and a valid address, so the fee is the
      // cost of this send and not a property of the amount.

      testWidgets('it renders BELOW the address it prices, not above it', (
        tester,
      ) async {
        await _pumpTypedSend(tester);
        final fee = find.text('Network fee');
        expect(fee, findsOneWidget, reason: 'no fee to place');
        final feeY = tester.getTopLeft(fee).dy;
        final addressY = tester.getTopLeft(find.byType(KvAddress).first).dy;
        expect(
          feeY,
          greaterThan(addressY),
          reason:
              'the fee is at y=$feeY and the address review at y=$addressY — it '
              'is back in the amount block, where it reads as a property of the '
              'amount rather than the cost of this send',
        );
      });

      testWidgets('and it shows the digits that ARE the fee', (tester) async {
        await _pumpTypedSend(tester);
        final runs = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .toList();
        expect(
          runs,
          containsAll(['0.00', '3154']),
          reason:
              'the fee renders as one run, so the weight is on a leading zero '
              'here while the ceremony puts it on the digits: one figure, two '
              'faces (BG-21)',
        );
      });
    },
  );

  group('the 800ms ring', () {
    test('the fee-strategy field rides the DTO (senderPays, 0)', () {
      // The reserved seam (V5): present on every summary, constant today —
      // the ★ Send-UX pass gives it real choices; nothing estimates here.
      final dto = _summary();
      expect(dto.feeStrategy, FeeStrategyKind.senderPays);
      expect(dto.priorityFeeSompi, BigInt.zero);
    });

    Widget holdHost(void Function() onCommit) => _host(
      SigningCeremony(
        summary: _summary(),
        commit: (_) async {
          onCommit();
          return _ok();
        },
        abandon: () async {},
      ),
    );

    const label = 'Hold to send 12.40000000 KAS';

    testWidgets('a quick tap does NOT sign (no double-tap path)', (
      tester,
    ) async {
      _phone(tester);
      var commits = 0;
      await tester.pumpWidget(holdHost(() => commits++));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(commits, 0, reason: 'a tap is not a hold');
    });

    testWidgets('a full hold past the deliberate duration signs once', (
      tester,
    ) async {
      _phone(tester);
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

    testWidgets('releasing early cancels, and the ring falls back', (
      tester,
    ) async {
      _phone(tester);
      var commits = 0;
      await tester.pumpWidget(holdHost(() => commits++));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(label)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(commits, 0, reason: 'released early: nothing is signed');
      // And the control is still armed for a second attempt.
      expect(find.text(label), findsOneWidget);
    });

    // ---- reduced animations ------------------------------------------------
    // F1 (product-audit run 3, S1). `AnimationController` defaults to
    // `AnimationBehavior.normal`, which Flutter scales to 0.05 whenever the
    // platform reports reduced animations (animation_controller.dart:651) —
    // 800ms becomes 40ms, and the one control that broadcasts an irreversible
    // transaction fires on what the user experiences as a tap. Measured on the
    // real path before the fix: onComplete at 141ms of contact.
    //
    // Note why the two tests above cannot catch it: `tester.tap()` advances no
    // wall clock between down and up, so forward()→reverse() happens in one
    // instant at ANY scale, and the 850ms hold completes at any scale too. The
    // defect lives strictly in the middle of the window, so the fence has to
    // stand there.

    /// Turns the platform's reduced-animations flag on for one test, and proves
    /// it actually reached the binding the controller reads. Without this
    /// assertion a silent propagation failure would make the guard below pass
    /// vacuously — green, and blind to the thing it exists for.
    void withReducedAnimations(WidgetTester tester) {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      expect(
        SemanticsBinding.instance.disableAnimations,
        isTrue,
        reason:
            'precondition: the flag must reach SemanticsBinding, which is what '
            'AnimationController consults — otherwise this test proves nothing',
      );
    }

    testWidgets(
      'a hold under reduced animations still takes the full deliberate duration',
      (tester) async {
        _phone(tester);
        var commits = 0;
        withReducedAnimations(tester);
        await tester.pumpWidget(holdHost(() => commits++));
        final gesture = await tester.startGesture(
          tester.getCenter(find.text(label)),
        );
        await tester.pump(); // dispatch pointer-down → onTapDown → forward()

        // Walk the window a real finger would occupy. With the defect the
        // controller is done by 40ms, so the very first step signs.
        for (var elapsed = 50; elapsed <= 200; elapsed += 50) {
          await tester.pump(const Duration(milliseconds: 50));
          expect(
            commits,
            0,
            reason:
                'signed after only ${elapsed}ms of contact — the hold friction '
                'collapsed under reduced animations (needs '
                'AnimationBehavior.preserve)',
          );
        }

        await gesture.up();
        await tester.pumpAndSettle();
        expect(commits, 0, reason: 'released early: nothing is signed');
      },
    );

    testWidgets(
      'the hold control announces itself, and semantics still cannot sign it',
      (tester) async {
        _phone(tester);
        // Two properties, and the second is the safety one.
        //
        // The node reported `isButton=false` with no hint, so a screen-reader
        // user met an unlabelled control that never said what it needed
        // (ux-auditor + wallet-security-auditor, 2026-08-24). It is now a
        // button with a hint naming the gesture.
        //
        // But the fix must NOT make it signable by semantics: an accessibility
        // activation is one discrete action, so honouring it would collapse the
        // 800 ms friction to an instant — F1 again, with a better excuse. That
        // the control is still unsignable via TalkBack is a recorded defect
        // (D-178), not an accident, and this test is what stops a well-meaning
        // "accessibility fix" from closing it the wrong way.
        final handle = tester.ensureSemantics();
        var commits = 0;
        await tester.pumpWidget(holdHost(() => commits++));

        final node = tester.getSemantics(find.text(label));
        expect(
          node.flagsCollection.isButton,
          isTrue,
          reason: 'the control must announce itself as a button',
        );
        expect(
          node.hint,
          contains('hold'),
          reason: 'and say what gesture it needs',
        );

        // The safety half. `tester.semantics.tap` dispatches exactly what
        // TalkBack's double-tap does — SemanticsAction.tap on the node.
        tester.semantics.tap(find.semantics.byLabel(label));
        await tester.pumpAndSettle();
        expect(
          commits,
          0,
          reason:
              'a semantics activation signed a transaction — that is one '
              'discrete action standing in for an 800 ms deliberate hold',
        );
        handle.dispose();
      },
    );

    testWidgets(
      'a hold under reduced animations still signs once past the duration',
      (tester) async {
        _phone(tester);
        // The companion: preserving the duration must not mean never firing.
        // Without this, a fix that simply broke the controller passes above.
        var commits = 0;
        withReducedAnimations(tester);
        await tester.pumpWidget(holdHost(() => commits++));
        final gesture = await tester.startGesture(
          tester.getCenter(find.text(label)),
        );
        await tester.pump();
        await tester.pump(
          KvMotion.deliberate + const Duration(milliseconds: 50),
        );
        expect(
          commits,
          1,
          reason: 'a completed hold still signs, once, with the flag on',
        );
        await gesture.up();
        await tester.pumpAndSettle();
      },
    );
  });
}

/// Counts pops of the route it sits in, so a test can assert that a screen
/// took itself off the stack.
class _RouteSpy extends StatefulWidget {
  const _RouteSpy({required this.onPop, required this.child});

  final VoidCallback onPop;
  final Widget child;

  @override
  State<_RouteSpy> createState() => _RouteSpyState();
}

class _RouteSpyState extends State<_RouteSpy> {
  @override
  void dispose() {
    widget.onPop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
