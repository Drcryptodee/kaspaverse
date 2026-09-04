import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/send.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/send/signing_ceremony.dart';
import 'package:kaspaverse/src/ui/secret/secret_keyboard.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/kv_window.dart';
import 'package:kaspaverse/src/ui/widgets/kv_hold.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_amount.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_mark.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';
import 'package:kaspaverse/src/ui/widgets/kv_keypad.dart';
import 'package:kaspaverse/src/ui/widgets/tx_status_chip.dart';

/// **The teeth of the six-legend canon** (`design_system.md` §0, BG-19…BG-25,
/// D-229). Every test here fails against the code as it stood before the law
/// existed — that falsification run is the whole point, because a guard nobody
/// has seen go red is a guard nobody has tested (D-226's method, L143's lesson).
///
/// What each case pins, and what it went red on:
///
/// | Law | Pins | Was |
/// |:--|:--|:--|
/// | **BG-22** | the hold ring's swept angle IS its progress | a full circle under reduced motion — the first sample read 100% against a true 25%, Lie Factor 4, rising to 8 at 100 ms and without bound as t → 0 |
/// | **BG-24** | a burial rung crossing crossfades | a hard cut at the amber→green boundary |
/// | **BG-25** | every cap is a drawn mark or ASCII | `'⌫'`, which JetBrains Mono has no glyph for |
///
/// The two laws NOT pinned here are pinned by `ux-auditor` lines instead, and
/// that is recorded rather than quietly skipped: **BG-19** (nothing stated
/// twice) and **BG-23** (emphasis tracks information) both have live violators
/// that are escalated rather than fixed — Receive's composition is UX-5's and
/// `KvAmount` is a shared money widget whose taste call is the founder's. A
/// test asserting the *current* behaviour there would pin the violation.
void main() {
  group('BG-22 · a gauge s Lie Factor is 1', () {
    // The 800 ms hold is the app's only gauge today, and it is on the surface
    // that broadcasts an irreversible transaction. Under reduced animations the
    // ring used to be drawn as a COMPLETE circle for the whole hold, with only
    // its opacity carrying `t` — so at 100 ms of contact it read *closed* in
    // the strongest channel a ring has.
    //
    // BG-9 and §3 both except the hold from the opacity collapse. D-177
    // discharged the DURATION half of that exception; this is the EXTENT half.

    /// Every arc the ring paints, as the **fraction of the circle actually
    /// covered in ink** — sweep plus whatever the stroke cap adds beyond each
    /// end.
    ///
    /// **Measuring the `sweepAngle` argument alone is not measuring the
    /// graphic** (`ux-auditor`, D-229). The first cut of this guard did exactly
    /// that and was structurally blind to the defect it found: a
    /// `StrokeCap.round` at `strokeWidth 4.5` on a 106.81dp circumference
    /// paints 2.25dp past each end, **adding 4.21% of the ring to every
    /// reading** — Lie Factor 1.34 at 100ms — while the argument stayed
    /// perfect. BG-22 defines the ratio on the effect *shown*, so the check
    /// has to include the ink.
    List<double> ringSweeps(WidgetTester tester) {
      final spy = _ArcSpy();
      final painted = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<CustomPainter>()
          .whereType<KvHoldRing>();
      expect(
        painted,
        isNotEmpty,
        reason:
            'the sign ring was not in the tree — this test proves nothing '
            'unless it found the painter it is measuring',
      );
      for (final p in painted) {
        // The badge's own footprint (§4): a 46 dp ring around a 38 dp disc.
        p.paint(spy, const Size(KvHold.badge, KvHold.badge));
      }
      return spy.arcs.map((a) => a.inkedFractionOfCircle).toList();
    }

    void withReducedAnimations(WidgetTester tester) {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      // Without this the guard passes vacuously — green, and blind.
      expect(SemanticsBinding.instance.disableAnimations, isTrue);
    }

    /// Walks a real hold and measures the arc at each step. The whole law is
    /// one line of arithmetic: swept / 2π must equal elapsed / 800.
    Future<void> measureLieFactor(WidgetTester tester) async {
      await tester.pumpWidget(_holdHost());
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(_holdLabel)),
      );
      await tester.pump(); // pointer-down → onTapDown → forward()

      var elapsed = 0;
      for (final step in const [200, 200, 200]) {
        await tester.pump(Duration(milliseconds: step));
        elapsed += step;
        final expected = elapsed / KvMotion.deliberate.inMilliseconds;
        final shown = ringSweeps(tester).single;
        expect(
          shown,
          closeTo(expected, 0.02),
          reason:
              'at ${elapsed}ms of an 800ms hold the ring shows '
              '${(shown * 100).toStringAsFixed(0)}% where the data says '
              '${(expected * 100).toStringAsFixed(0)}% — Lie Factor '
              '${(shown / expected).toStringAsFixed(1)}',
        );
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('the swept angle is the hold s progress', (tester) async {
      await measureLieFactor(tester);
    });

    testWidgets('and the ring never RISES when the thumb lifts', (
      tester,
    ) async {
      // The fall used to take the decelerating curve on the argument that it
      // is motion rather than a reading. It is a reading: the controller does
      // not reset on release, so a re-press resumes from wherever the fall
      // reached — and the eased version jumped the arc from 50% to 88% in the
      // single frame the finger came off, then dropped it back the instant the
      // thumb returned (`ux-auditor`, D-229).
      await tester.pumpWidget(_holdHost());
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(_holdLabel)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // t = 0.5
      final held = ringSweeps(tester).single;
      expect(held, closeTo(0.5, 0.02), reason: 'precondition: half a hold');

      await gesture.up();
      await tester.pump(); // the release frame, no wall clock advanced
      final released = ringSweeps(tester).single;
      expect(
        released,
        lessThanOrEqualTo(held + 0.01),
        reason:
            'the arc rose to ${(released * 100).toStringAsFixed(0)}% at the '
            'instant the hold was ABANDONED, from '
            '${(held * 100).toStringAsFixed(0)}% — the gauge overstates what a '
            're-press would resume from',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('and it stays the progress under reduced animations', (
      tester,
    ) async {
      // The case the law was written for. Before D-229 the first sample read
      // 100% against a true 25%.
      withReducedAnimations(tester);
      await measureLieFactor(tester);
    });
  });

  group('BG-23 · emphasis tracks information', () {
    // Founder's call, taken from the rendered comparison rather than from an
    // argument (D-230): a BALANCE keeps the magnitude, because the integer is
    // what you own; a FEE takes the significant digits, because a fee is always
    // below 1 and its integer is `0` in every case the surface will ever show.
    // The rule lives on the ROLE, so a future screen-role amount inherits the
    // decision instead of re-making it.

    /// The `(text, isStrong)` runs of an amount, strong = at base size.
    List<(String, bool)> runs(WidgetTester tester) {
      final texts = tester.widgetList<Text>(
        find.descendant(of: find.byType(KvAmount), matching: find.byType(Text)),
      );
      final sizes = texts.map((t) => t.style?.fontSize ?? 0).toList();
      final base = sizes.reduce((a, b) => a > b ? a : b);
      return [
        for (final (i, t) in texts.indexed)
          if ((t.data ?? '') != 'KAS') (t.data ?? '', sizes[i] == base),
      ];
    }

    testWidgets('a fee puts the weight on the digits that ARE the fee', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(315400), role: KvAmountRole.screen)),
      );
      expect(
        runs(tester),
        [('0.00', false), ('315400', true)],
        reason:
            'the bright run is the leading zero, which is `0` for every fee '
            'this wallet will ever build',
      );
    });

    testWidgets('a balance keeps the magnitude, which is what you own', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(2597792200), role: KvAmountRole.hero)),
      );
      expect(runs(tester), [('25', true), ('.977922', false)]);
    });

    testWidgets('and above 1 every rule agrees, so a total is untouched', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(KvAmount(BigInt.from(1240315400), role: KvAmountRole.screen)),
      );
      expect(
        runs(tester),
        [('12', true), ('.40315400', false)],
        reason:
            'the sub-1 rule reached an amount above 1 — a fee must not out-shout '
            'the total it is part of',
      );
    });

    testWidgets('and the CEREMONY fee row is the surface that has to show it', (
      tester,
    ) async {
      // The rule was first put on the role, and the role was the wrong lever:
      // the ceremony's fact rows are `KvAmountRole.row`, not `screen`, so the
      // fee kept its old face while the widget test passed. That is L144 in one
      // move — the fix reached the abstraction and not the surface. This guard
      // renders the real ceremony and reads the real fee.
      await tester.pumpWidget(_holdHost());
      final feeRuns = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((t) => t.contains('315400') || t == '0.00')
          .toList();
      expect(
        feeRuns,
        containsAll(['0.00', '315400']),
        reason:
            'the fee renders as one run, so the weight is still on the leading '
            'zero: $feeRuns',
      );
    });
  });

  group('BG-24 · nothing appears or vanishes without motion', () {
    // The amber→green crossing at a hundred confirmations is the moment the
    // money becomes safe. It used to be a hard swap — a different mark returned
    // on the next rebuild with nothing in between — while `TxStatusChip`, the
    // widget this vocabulary replaced, has always crossfaded.

    testWidgets('a burial rung crossing crossfades, it does not cut', (
      tester,
    ) async {
      var confirmations = 99;
      late void Function(void Function()) rebuild;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return KvBurialMark(
                state: TxChipState.accepted,
                confirmations: confirmations,
                maturity: MaturityState.pending,
              );
            },
          ),
        ),
      );
      expect(find.textContaining('Seen'), findsOneWidget);
      expect(find.text('Confirmed'), findsNothing);

      rebuild(() => confirmations = 150);
      // Half of `fast`: mid-crossing, where both rungs must be on screen at
      // once. A hard cut has exactly one child here, always.
      await tester.pump();
      await tester.pump(KvMotion.fast ~/ 2);

      expect(
        find.text('Confirmed'),
        findsOneWidget,
        reason: 'the arriving rung is not there',
      );
      expect(
        find.textContaining('Seen'),
        findsOneWidget,
        reason:
            'the leaving rung vanished instantly — the crossing is a cut, and '
            'the user never saw the money become safe',
      );

      await tester.pumpAndSettle();
      expect(find.textContaining('Seen'), findsNothing);
      expect(find.text('Confirmed'), findsOneWidget);
    });

    testWidgets('the crossing takes its geometry immediately, not at the end', (
      tester,
    ) async {
      // A crossfade alone does not discharge BG-24 — it relocates the cut. The
      // switcher's default stack holds the LARGER of the two children for the
      // whole 160 ms and releases in one frame, so the timestamp beside the
      // mark jumped 54 dp at the END of a transition that had already finished
      // visually (`ux-auditor`, D-229). The width must land on the FIRST frame,
      // where the fade explains it.
      var confirmations = 150;
      late void Function(void Function()) rebuild;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 260,
            child: Wrap(
              children: [
                StatefulBuilder(
                  builder: (context, setState) {
                    rebuild = setState;
                    return KvBurialMark(
                      state: TxChipState.accepted,
                      confirmations: confirmations,
                      maturity: MaturityState.accepted,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );
      double width() => tester.getSize(find.byType(KvBurialMark)).width;
      final before = width();

      rebuild(() => confirmations = 1500); // Confirmed -> final, a shrink
      await tester.pump();
      // **Walk to the CROSSING, not to the arrival.** Since UX-5 the rung is
      // derived from the streamed depth rather than from the newest reading —
      // so a reading of 1500 landing over a row at 150 replays the interval
      // first and the rung changes when the COUNT passes a thousand, which is
      // also the frame the words change on. Measuring 20 ms after the reading
      // arrived measured a row that had not crossed anything yet.
      double? atStart;
      for (var i = 0; i < 80 && atStart == null; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (find.text('final').evaluate().isNotEmpty) atStart = width();
      }
      await tester.pumpAndSettle();
      final settled = width();
      expect(atStart, isNotNull, reason: 'the crossing never ran');

      expect(settled, lessThan(before), reason: 'precondition: it shrinks');
      expect(
        atStart,
        settled,
        reason:
            'the row was still $atStart dp one frame in and ends at $settled — '
            'the geometry snaps after the fade, which moves the cut rather '
            'than removing it',
      );
    });

    testWidgets('a rung going BACKWARD snaps — a reorg is not progress', (
      tester,
    ) async {
      // BG-18: a decrease snaps rather than animating backwards as if burial
      // were being undone. Two things cause one and neither is progress: a
      // reorg, and — far more often — a depth reading arriving after a maturity
      // flag already said `Confirmed`. Crossfaded, that superimposes
      // `Confirmed` over `Seen 50` for 160 ms, which is BG-20 (`ux-auditor`).
      var confirmations = 1500;
      late void Function(void Function()) rebuild;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return KvBurialMark(
                state: TxChipState.accepted,
                confirmations: confirmations,
                maturity: MaturityState.accepted,
              );
            },
          ),
        ),
      );
      expect(find.text('final'), findsOneWidget);

      rebuild(() => confirmations = 50);
      await tester.pump();
      await tester.pump(KvMotion.fast ~/ 2);
      expect(
        find.text('final'),
        findsNothing,
        reason: 'the retired rung is still on screen half a beat into a REORG',
      );
      expect(find.textContaining('Seen'), findsOneWidget);
    });

    testWidgets('a streaming depth does NOT crossfade its own digits', (
      tester,
    ) async {
      // The trap the rung key exists to avoid: a switcher keyed on the rendered
      // text would crossfade sixty times a second while BG-18 streams the
      // depth. Two different depths inside one rung are one child.
      var confirmations = 40;
      late void Function(void Function()) rebuild;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return KvBurialMark(
                state: TxChipState.accepted,
                confirmations: confirmations,
                maturity: MaturityState.pending,
              );
            },
          ),
        ),
      );
      rebuild(() => confirmations = 41);
      await tester.pump();
      await tester.pump(KvMotion.fast ~/ 2);
      expect(
        find.textContaining('Seen'),
        findsOneWidget,
        reason: 'two marks alive means the rung key is reading the digits',
      );
    });
  });

  group('BG-25 · every mark the app draws, it owns', () {
    // `JetBrainsMono-Variable.ttf` has no U+232B in its cmap, and the amount
    // pad's caps render in `KvFont.mono`. So the app's own bundled faces could
    // not draw the cap on the key that corrects a wrong amount; what appeared
    // there was whatever the platform's fallback chain supplied.
    //
    // `ux-auditor` item 14 greps for icon PACKAGES. A codepoint inside a string
    // literal is invisible to it, which is why this survived every pass.

    /// Every cap this keypad prints as type, as raw code units.
    List<String> capText(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();

    void expectEveryCapIsOwned(WidgetTester tester) {
      for (final cap in capText(tester)) {
        final foreign = cap.runes.where((r) => r > 0x7F).toList();
        expect(
          foreign,
          isEmpty,
          reason:
              'the cap "$cap" is typed, not drawn: U+'
              '${foreign.map((r) => r.toRadixString(16).toUpperCase()).join(" U+")}'
              ' comes from whichever face the platform happens to have',
        );
      }
    }

    testWidgets('the amount pad s backspace is a drawn mark', (tester) async {
      await tester.pumpWidget(
        _host(KvKeypad.amount(onChar: (_) {}, onBackspace: () {})),
      );
      expectEveryCapIsOwned(tester);
      expect(
        tester
            .widgetList<KvGlyphIcon>(find.byType(KvGlyphIcon))
            .map((g) => g.mark),
        contains(KvGlyph.backspace),
      );
      // And it still says what it is, so nothing was traded for the glyph.
      expect(find.bySemanticsLabel('Backspace'), findsOneWidget);
    });

    testWidgets('and a drawn cap still grows with the user s text size', (
      tester,
    ) async {
      // BG-14. `'⌫'` was a `Text` and scaled with everything else for free; a
      // `KvGlyphIcon` takes a fixed dp, so the swap silently made the erase key
      // the only cap on the pad that ignored the setting (`ux-auditor`, D-229).
      // A mark that is a control's sole identification is information.
      Size capAt(double scale) => tester.getSize(
        find.byWidgetPredicate(
          (w) => w is KvGlyphIcon && w.mark == KvGlyph.backspace,
        ),
      );
      await tester.pumpWidget(
        _host(KvKeypad.amount(onChar: (_) {}, onBackspace: () {})),
      );
      final normal = capAt(1.0);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: _host(KvKeypad.amount(onChar: (_) {}, onBackspace: () {})),
        ),
      );
      final scaled = capAt(1.3);
      expect(
        scaled.width,
        closeTo(normal.width * 1.3, 0.5),
        reason:
            'the erase cap is ${scaled.width} dp at 1.3x and ${normal.width} '
            'at 1.0 — it is deaf to the text-size setting the digits obey',
      );
    });

    testWidgets('and so are the secret keyboard s shift and backspace', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(SecretKeyboard(onChar: (_) {}, onBackspace: () {})),
      );
      expectEveryCapIsOwned(tester);
      final marks = tester
          .widgetList<KvGlyphIcon>(find.byType(KvGlyphIcon))
          .map((g) => g.mark);
      expect(marks, contains(KvGlyph.backspace));
      expect(marks, contains(KvGlyph.shift));
      expect(find.bySemanticsLabel('Shift'), findsOneWidget);
      expect(find.bySemanticsLabel('Backspace'), findsOneWidget);
    });
  });
}

// ---------------------------------------------------------------------------

/// `KvWindow` above the `Navigator`, exactly as `main.dart` mounts it — the
/// ceremony is a sheet now and a sheet reads the window class (BG-33).
Widget _host(Widget child) => MaterialApp(
  theme: kvDarkTheme(),
  builder: (context, page) => KvWindow(child: page!),
  home: Scaffold(
    backgroundColor: KvColor.abyss,
    body: Center(child: child),
  ),
);

const String _holdLabel = 'Hold to send 12.40000000 KAS';

Widget _holdHost() => _host(
  SigningCeremony(
    summary: _summary(),
    commit: (_) async => _outcome(),
    abandon: () async {},
  ),
);

SignableSummaryDto _summary() => SignableSummaryDto(
  kind: SignableKind.payment,
  destination:
      'kaspa:qz5a8jtqt3l3nf8zxve9eu0qtrkewc5e0yn465djghw4438jqdecc6jzqunth',
  amountSompi: BigInt.from(1240000000),
  feeSompi: BigInt.from(315400),
  totalSompi: BigInt.from(1240315400),
  mass: BigInt.from(2036),
  txCount: 1,
  utxoCount: 2,
  payloadLen: 0,
  payloadKind: 'none',
  nonce: BigInt.one,
  resultingCoins: 1,
  feeStrategy: FeeStrategyKind.senderPays,
  priorityFeeSompi: BigInt.zero,
);

SendOutcomeDto _outcome() => SendOutcomeDto(
  finalTxid: 'e154009eae73d2ef9cab0a80dc42a62ebb91f93cbdeab514a57ca3b01d7e5d34',
  submitted: 1,
  total: 1,
  partial: false,
);

/// One painted arc, kept with everything that decides how much ink lands.
class _Arc {
  const _Arc(this.rect, this.sweep, this.strokeWidth, this.cap);

  final Rect rect;
  final double sweep;
  final double strokeWidth;
  final StrokeCap cap;

  /// What the eye actually sees, as a fraction of the whole circle.
  ///
  /// `round` and `square` both extend the painted line by half a stroke width
  /// at **each** end, so they add one full stroke width of arc length; `butt`
  /// stops exactly where the sweep does and adds nothing.
  double get inkedFractionOfCircle {
    final circumference = 2 * math.pi * (rect.width / 2);
    final overhang = cap == StrokeCap.butt ? 0.0 : strokeWidth;
    return sweep / (2 * math.pi) + overhang / circumference;
  }
}

/// Records every arc drawn and swallows the rest of `Canvas`. `implements
/// Canvas` with a `noSuchMethod` sink so the spy stays short — nothing but the
/// arc is of interest.
class _ArcSpy implements Canvas {
  final List<_Arc> arcs = [];

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) => arcs.add(_Arc(rect, sweepAngle, paint.strokeWidth, paint.strokeCap));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
