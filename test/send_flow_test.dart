import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/error.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/ui/send/confirm_send_flow.dart';
import 'package:kaspaverse/src/ui/send/send_screen.dart';
import 'package:kaspaverse/src/ui/send/signing_ceremony.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_amount.dart';
import 'package:kaspaverse/src/ui/widgets/kv_chrome.dart';
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';
import 'package:kaspaverse/src/ui/widgets/kv_status_chip.dart';

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

Widget _host(Widget child) => MaterialApp(theme: kvDarkTheme(), home: child);

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
Future<void> _type(WidgetTester tester, String keys) async {
  for (final k in keys.split('')) {
    final key = find.descendant(
      of: find.byType(KvKeypad),
      matching: find.text(k),
    );
    if (key.evaluate().isEmpty) {
      // Not built yet — the floor geometry puts the pad below the fold.
      // `.first` is the screen's own ListView; a focused TextField adds a
      // second Scrollable of its own.
      await tester.scrollUntilVisible(
        key,
        120,
        scrollable: find.byType(Scrollable).first,
      );
    } else {
      await tester.ensureVisible(key);
    }
    await tester.pump();
    await tester.tap(key);
    await tester.pump();
  }
}

/// Put the destination in, then hand focus back to the amount pad the way a
/// user does — by tapping the figure.
Future<void> _address(WidgetTester tester, String address) async {
  if (find.byType(TextField).evaluate().isEmpty) {
    // The floor geometry can leave the field above the fold after the pad has
    // been scrolled to.
    await tester.scrollUntilVisible(
      find.byType(TextField),
      -120,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.enterText(find.byType(TextField), address);
  await tester.pump();
  // The figure is pinned above the scroll, so this target is always built.
  await tester.tap(find.byKey(SendScreen.amountTarget));
  await tester.pump();
}

/// The reason printed under a disabled Review, or null when it is live.
String? _reviewReason(WidgetTester tester) => tester
    .widget<KvAction>(find.widgetWithText(KvAction, 'Review this send'))
    .disabledReason;

/// Sentinel, so a test can pass an explicit `null` balance and mean *unknown*
/// rather than *defaulted*.
const Object _unset = Object();

Widget _sendScreen({
  Object? mature = _unset,
  ValueListenable<bool>? balanceStale,
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
    prepare: prepare ?? (_, _) async => _summary(),
    commit: commit ?? (_) async => _ok(),
    abandon: abandon ?? () async {},
    prepareSweep: prepareSweep,
    minimumSendable: minimumSendable,
  ),
);

/// The bundled faces, so a width measured here is a width about Inter and
/// JetBrains Mono rather than about the test fallback — whose glyphs are square
/// em-boxes and overstate every label by roughly a factor of two. A 320dp /
/// 1.3x claim measured in Ahem is a claim about Ahem.
///
/// Called from `setUpAll`, NEVER from inside `testWidgets`: the test body runs
/// in a fake-async zone where real file I/O never completes.
Future<void> loadBundledFonts() async {
  for (final font in const {
    'Inter': 'assets/fonts/Inter-Variable.ttf',
    'JetBrainsMono': 'assets/fonts/JetBrainsMono-Variable.ttf',
  }.entries) {
    final bytes = await File(font.value).readAsBytes();
    await (FontLoader(
      font.key,
    )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  }
}

void main() {
  setUpAll(loadBundledFonts);

  group('SendScreen', () {
    testWidgets('the amount is typed on the secure keypad — no system '
        'keyboard is ever offered for it', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      // ONE TextField on the screen, and it is the address. The amount has no
      // editable text widget at all, which is what makes the no-system-IME
      // guarantee structural rather than a promise (D-189).
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(KvKeypad), findsOneWidget);
      await _type(tester, '12.4');
      expect(find.text('12.4'), findsOneWidget);
    });

    testWidgets('Review is disabled until a valid amount and address', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      expect(
        _reviewReason(tester),
        'Enter an amount and a destination',
        reason: 'BG-12: a disabled control always says why',
      );

      await _type(tester, '12.4');
      expect(_reviewReason(tester), 'Enter a destination address');

      await _address(tester, _addr);
      expect(_reviewReason(tester), isNull, reason: 'live once valid');
      expect(
        find.text('Nothing is signed until you hold to send.'),
        findsOneWidget,
      );
    });

    testWidgets('the keypad refuses a ninth decimal rather than taking it and '
        'rejecting the amount later', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await _type(tester, '1.123456789');
      expect(find.text('1.12345678'), findsOneWidget);
      await _address(tester, _addr);
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

      // The exit is on screen and TAPPABLE even while both fields are empty —
      // a wallet the anti-dust floor has trapped types no amount at all, and a
      // control that greyed out silently would not say what it needs. That
      // rule travelled with the affordance when D-190 moved it beside
      // `available`.
      await tester.tap(find.text('Send max'));
      await tester.pump();
      expect(sweepPrepares, 0, reason: 'no address yet — nothing prepared');
      expect(
        find.textContaining('Enter the destination address first'),
        findsOneWidget,
        reason: 'the chip answers with words, never a silent grey',
      );

      await _address(tester, _addr);
      await tester.tap(find.text('Send max'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sweepPrepares, 1);
      expect(paymentPrepares, 0, reason: 'the sweep never rides prepare()');
      expect(sweptTo, _addr);
      // The one signing surface opened over the sweep summary.
      expect(find.text('Confirm send all'), findsOneWidget);
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
      await _type(tester, '12.4');
      await _address(tester, _addr);
      await tester.tap(find.text('Review this send'));
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
      await _type(tester, '0.00000042');
      await _address(tester, _addr);

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

    testWidgets('a below-floor amount does not unlock Review on a form with '
        'no address', (tester) async {
      // The floor WARNS and never blocks — but an advisory branch that
      // `return`s is an early exit for every blocking check after it, and this
      // one skipped all three address checks. Found by `consensus-auditor`;
      // the existing floor test always typed an address, so it could not see
      // it.
      _phone(tester);
      await tester.pumpWidget(
        _sendScreen(minimumSendable: () async => BigInt.from(2036)),
      );
      await tester.pump();
      await _type(tester, '0.00000042');
      expect(
        _reviewReason(tester),
        'Enter a destination address',
        reason: 'the advisory floor must not unlock a form with no address',
      );
      // And the floor's own sentence is still shown alongside it.
      expect(find.textContaining('will not relay less than'), findsOneWidget);
    });

    testWidgets('no minimum provider ⇒ no floor notice', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await tester.pump();
      await _type(tester, '0.00000042');
      await _address(tester, _addr);
      expect(find.textContaining('will not relay less than'), findsNothing);
      expect(_reviewReason(tester), isNull);
    });

    testWidgets('more than the spendable balance blocks, with the exact '
        'shortfall', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _sendScreen(mature: BigInt.from(1000000000)), // 10 KAS
      );
      await _type(tester, '12.4');
      await _address(tester, _addr);
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
      expect(find.text('available —'), findsOneWidget);
      await _type(tester, '12.4');
      await _address(tester, _addr);
      expect(
        _reviewReason(tester),
        isNull,
        reason: 'a number that has not arrived is not a refusal',
      );
    });

    testWidgets('a LAST-KNOWN balance dims, says so, and is never quoted back '
        'as a fact (BG-8)', (tester) async {
      _phone(tester);
      final stale = ValueNotifier<bool>(false);
      addTearDown(stale.dispose);
      await tester.pumpWidget(
        _sendScreen(mature: BigInt.from(1000000000), balanceStale: stale),
      );
      await _type(tester, '12.4');
      await _address(tester, _addr);
      // Live: the shortfall is a fact the wallet can vouch for, so it says it.
      expect(find.text('available 10.00'), findsOneWidget);
      expect(_reviewReason(tester), 'More than you can spend');

      stale.value = true;
      await tester.pump();
      await tester.pump(KvMotion.instant);
      // Dimmed, and the freshness is in WORDS as well as opacity so it
      // survives greyscale and a screen reader.
      expect(find.text('available 10.00'), findsOneWidget);
      expect(find.text('not live — last known'), findsOneWidget);
      final opacity = tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .map((w) => w.opacity);
      expect(opacity, contains(KvFreshness.opacityStale));
      // And the screen stops asserting a figure it cannot currently vouch for
      // — the P0.3 scar with a number attached.
      expect(_reviewReason(tester), isNull);
      expect(find.textContaining('You have'), findsNothing);
    });

    testWidgets('an address of the wrong length says how many characters it '
        'has', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_sendScreen());
      await _type(tester, '12.4');
      await _address(tester, 'kaspa:qpzt3vw8x2mne4ka0000');
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
      await _type(tester, '12.4');
      await _address(tester, 'bitcoincash:qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq');
      expect(
        find.text('A mainnet Kaspa address starts with "kaspa:".'),
        findsOneWidget,
      );
      expect(_reviewReason(tester), 'Check the destination address');
    });

    testWidgets('the typed amount is SPOKEN, and its target can be activated', (
      tester,
    ) async {
      // The wallet's only spending path: a screen-reader user has to be able
      // to hear the amount they are about to send (BG-14 / item 22), and the
      // control that gives the pad back must actually do something when
      // TalkBack activates it (BG-12). `excludeSemantics` drops the whole
      // subtree, so both have to live on this one node — a label pushed down
      // into the figure would be dead code.
      _phone(tester);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_sendScreen());
      expect(
        tester.getSemantics(find.byKey(SendScreen.amountTarget)).label,
        'Amount, none entered. Edit the amount',
      );
      await _type(tester, '12.4');
      final node = tester.getSemantics(find.byKey(SendScreen.amountTarget));
      expect(node.label, 'Amount, 12.4 KAS. Edit the amount');
      expect(node.flagsCollection.isButton, isTrue);
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'a button with no action is inert under TalkBack',
      );
      handle.dispose();
    });

    testWidgets('Send max is a CHIP — it hugs its label rather than taking the '
        'row', (tester) async {
      // `KvSurface` is a `Container`, and a `Container` given an `alignment`
      // expands to its incoming constraints. In a `Row` beside an `Expanded`
      // that was invisible; in the `Wrap` that cured the figure's shrink the
      // chip was handed the whole gutter and rendered as a full-width button —
      // a second primary action competing with the one teal control, which
      // inverts D-190's reason for pairing it with `available`. Found on
      // glass, device sitting 2026-08-30; no host test could see it because
      // every assertion was about text, not width.
      _phone(tester);
      await tester.pumpWidget(
        _sendScreen(
          prepareSweep: (_) async =>
              _summary(kind: SignableKind.sweep, utxoCount: 1),
        ),
      );
      final chip = tester.getSize(find.widgetWithText(InkWell, 'Send max'));
      final screen = tester.getSize(find.byType(Scaffold));
      expect(
        chip.width,
        lessThan(screen.width / 2),
        reason: 'Send max is a chip, not a second primary action',
      );
      // And it still clears the touch-target floor.
      expect(chip.height, greaterThanOrEqualTo(KvSpace.touchTarget));
    });

    testWidgets('the amount pad comes back after the address field takes '
        'focus', (tester) async {
      _phone(tester);
      // The pad steps aside for the system IME while the address is typed. If
      // nothing gave it back, the pad would be reachable exactly once.
      await tester.pumpWidget(_sendScreen());
      await tester.enterText(find.byType(TextField), _addr);
      await tester.pump();
      expect(find.byType(KvKeypad), findsNothing);
      await tester.tap(find.byKey(SendScreen.amountTarget));
      await tester.pump();
      expect(find.byType(KvKeypad), findsOneWidget);
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
      final scrollable = find.byType(Scrollable).first;
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
      // A below-floor amount, so the longest amber sentence on this screen is
      // on it while it is measured.
      await _type(tester, '0.00000042');
      await _address(tester, _addr);
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
            mature: BigInt.from(123456789012345),
            prepareSweep: (_) async =>
                _summary(kind: SignableKind.sweep, utxoCount: 1),
            minimumSendable: () async => BigInt.from(2036),
          ),
        ),
      );
      await tester.pump();
      await _type(tester, '9999999999.99999999');
      await _address(tester, _addr);
      await tester.pump();
      await measureThroughTheScroll(tester);
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

    testWidgets('the destination is restated in full, chunked in fours, with '
        'the first and last groups weighted', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_ceremony(_summary()));
      // Every character of the 61-char payload is on screen, in 16 groups —
      // 15 of four and one of one. An address-poisoning attack buys a prefix
      // and a suffix that look right, so the weighting puts the eye exactly
      // where the attack has to succeed (BG-15).
      final payload = _addr.substring(_addr.indexOf(':') + 1);
      final groups = <String>[
        for (var i = 0; i < payload.length; i += 4)
          payload.substring(i, i + 4 > payload.length ? payload.length : i + 4),
      ];
      expect(groups.length, 16);
      for (final g in groups) {
        expect(find.text(g), findsOneWidget, reason: 'group "$g" is missing');
      }
      for (final i in [0, groups.length - 1]) {
        final style = tester.widget<Text>(find.text(groups[i])).style!;
        expect(style.fontWeight, FontWeight.w600);
        expect(style.color, KvColor.ink);
      }
      final middle = tester.widget<Text>(find.text(groups[1])).style!;
      expect(middle.fontWeight, FontWeight.w400);
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
      expect(find.text('Sending'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
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
      _phone(tester);
      await tester.pumpWidget(
        _ceremony(_summary(kind: SignableKind.sweep, utxoCount: 7)),
      );
      expect(find.text('Confirm send all'), findsOneWidget);
      expect(find.text('Sending'), findsOneWidget);
      expect(find.textContaining('kaspa:'), findsOneWidget);
      expect(find.textContaining('all 7 spendable coins move'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
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
      expect(find.text('Sending'), findsOneWidget);
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
          tester.widget<KvRail>(find.byType(KvRail)).title,
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
      expect(tester.widget<KvRail>(find.byType(KvRail)).title, 'Sent');
    });
  });

  group('the outcome, in three beats', () {
    Future<void> settleWith(
      WidgetTester tester,
      Future<SendOutcomeDto> Function(BigInt) commit,
    ) async {
      await tester.pumpWidget(
        _host(
          SigningCeremony(
            summary: _summary(),
            commit: commit,
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
      expect(
        tester.widget<KvRail>(find.byType(KvRail)).title,
        'Sent',
        reason: 'the rail still names the question, not the answer',
      );
      // Three deliberate places: the rail, the verdict head, the ruled label.
      expect(find.text('Sent'), findsNWidgets(3));
      expect(find.textContaining('The network accepted it'), findsOneWidget);
      // And it points at where the settling can actually be watched.
      expect(find.textContaining('follow it in your activity'), findsOneWidget);
      expect(find.text('a' * 64), findsOneWidget);
      expect(find.textContaining('Your funds are safe'), findsNothing);
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
      expect(find.text('Sending'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);
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
      // The rail and the verdict head both say it.
      expect(find.text('Partly sent'), findsNWidgets(2));
      expect(tester.widget<KvRail>(find.byType(KvRail)).title, 'Partly sent');
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
      expect(find.text('Not confirmed'), findsNWidgets(2));
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
      await _type(tester, '12.4');
      await _address(tester, _addr);
      await tester.tap(find.text('Review this send'));
      await tester.pump();
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Hold to send 12.40000000 KAS')),
      );
      await tester.pump();
      await tester.pump(KvMotion.deliberate + const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pump(const Duration(seconds: 7));

      await tester.tap(
        find.descendant(
          of: find.byType(KvRail),
          matching: find.byType(InkWell),
        ),
      );
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
      await tester.tap(
        find.descendant(
          of: find.byType(KvRail),
          matching: find.byType(InkWell),
        ),
      );
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
      await tester.tap(
        find.descendant(
          of: find.byType(KvRail),
          matching: find.byType(InkWell),
        ),
      );
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
      expect(tester.widget<KvRail>(find.byType(KvRail)).onBack, isNull);
      expect(find.textContaining('You can leave'), findsNothing);

      await tester.pump(const Duration(seconds: 7));
      expect(tester.widget<KvRail>(find.byType(KvRail)).onBack, isNotNull);
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
      expect(find.text('Not confirmed'), findsNWidgets(2));
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
    /// The ceremony is a full screen now; leaving it is the rail's back
    /// target, which is the only InkWell KvRail draws.
    Future<void> leaveCeremony(WidgetTester tester) async {
      await tester.tap(
        find.descendant(
          of: find.byType(KvRail),
          matching: find.byType(InkWell),
        ),
      );
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
