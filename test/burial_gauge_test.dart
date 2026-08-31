import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/rust/api/wallet.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_gauge.dart';
import 'package:kaspaverse/src/ui/widgets/kv_burial_mark.dart';
import 'package:kaspaverse/src/ui/widgets/tx_status_chip.dart';

import 'support/preview_harness.dart';

/// **The burial gauge under BG-22**, and every assertion here measures the
/// **ink** rather than an argument the code handed the canvas.
///
/// That distinction is L145, and it is the scar the canon session produced
/// about its own first guard: the sign ring's guard recorded `drawArc`'s
/// `sweepAngle` parameter and was structurally blind to a `StrokeCap.round`
/// painting 4.21% of the circle past every reading. So [_Ink] below replays the
/// real painter onto a spy canvas and reconstructs what the eye would cover —
/// rectangles by their bounds, strokes by their length plus whatever their cap
/// adds — and the painter is deliberately given **the depth** rather than a
/// pre-computed fraction, so there is no intermediate number for a test to
/// confirm instead of the drawing.
///
/// Each group names the defect it was proven red against; the falsification
/// runs are recorded in the session summary.
void main() {
  setUpAll(loadBundledFonts);

  group('BG-22 · the declared scale', () {
    test(
      'every graduation is a decade of the ratified ladder, plus its origin',
      () {
        expect(KvBurialGauge.graduations, [0, 1, 10, 100, 1000]);
        // The two thresholds D-192 settled are marks on the axis, not thresholds
        // the reader has to be told about somewhere else.
        expect(KvBurialGauge.graduations, contains(KvBurial.safe));
        expect(KvBurialGauge.graduations, contains(KvBurial.settled));
      },
    );

    test('the marks are evenly spaced, which is what declares a log axis', () {
      final xs = KvBurialGauge.graduations
          .map(KvBurialGauge.positionFor)
          .toList();
      expect(xs, [0, 0.25, 0.5, 0.75, 1.0]);
    });

    test('a decade of data is a quarter of the track, at every decade', () {
      // The Lie Factor identity on the DECLARED scale: equal ratios in the
      // data are equal distances in the graphic.
      for (final (a, b) in const [(1, 10), (10, 100), (100, 1000)]) {
        expect(
          KvBurialGauge.positionFor(b) - KvBurialGauge.positionFor(a),
          closeTo(0.25, 1e-12),
          reason: '$a → $b is one decade and must be one quarter of the track',
        );
      }
    });

    test('the scale ends where finality does, and never runs past it', () {
      expect(KvBurialGauge.positionFor(999), lessThan(1));
      expect(KvBurialGauge.positionFor(1000), 1);
      expect(KvBurialGauge.positionFor(100000), 1);
      expect(KvBurialGauge.positionFor(0), 0);
      expect(KvBurialGauge.positionFor(-5), 0);
    });
  });

  group('BG-22 · the ink is the reading', () {
    testWidgets('the painted fill IS the declared position, at every decade', (
      tester,
    ) async {
      for (final depth in const [0, 1, 3, 10, 42, 100, 340, 999, 1000, 5000]) {
        await tester.pumpWidget(_host(_gauge(depth, key: ValueKey(depth))));
        // A fresh gauge snaps to its first reading, so one pump settles it.
        await tester.pump();
        final ink = _Ink.of(tester);
        expect(
          ink.filledFraction,
          closeTo(KvBurialGauge.positionFor(depth), 0.001),
          reason:
              'at $depth blocks the gauge covers '
              '${(ink.filledFraction * 100).toStringAsFixed(1)}% of the track '
              'where the declared scale says '
              '${(KvBurialGauge.positionFor(depth) * 100).toStringAsFixed(1)}% '
              '— Lie Factor '
              '${(ink.filledFraction / KvBurialGauge.positionFor(depth)).toStringAsFixed(2)}',
        );
      }
    });

    testWidgets('no stroke cap paints past any reading', (tester) async {
      await tester.pumpWidget(_host(_gauge(42)));
      await tester.pump();
      final ink = _Ink.of(tester);
      expect(ink.lines, isNotEmpty, reason: 'the track was never drawn');
      for (final line in ink.lines) {
        expect(
          line.cap,
          ui.StrokeCap.butt,
          reason:
              'a ${line.cap} cap paints half a stroke width past BOTH ends of '
              'every stroke on this gauge — a mark may overhang, a measurement '
              'may not (BG-22)',
        );
      }
    });

    testWidgets('nothing is filled for a depth nobody has', (tester) async {
      await tester.pumpWidget(
        _host(
          const KvBurialGauge(
            state: TxChipState.accepted,
            confirmations: null,
            maturity: MaturityState.confirmed,
          ),
        ),
      );
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        0,
        reason:
            'an extent drawn for an unknown quantity is a fabricated reading '
            '(BG-8); the words carry the dash instead',
      );
    });

    testWidgets('a stalled submit plots no depth', (tester) async {
      await tester.pumpWidget(
        _host(
          const KvBurialGauge(
            state: TxChipState.stalled,
            confirmations: 40,
            maturity: MaturityState.pending,
          ),
        ),
      );
      await tester.pump();
      expect(_Ink.of(tester).filledFraction, 0);
      expect(find.text('Not accepted yet'), findsOneWidget);
    });
  });

  group('BG-22 · a gauge is never eased, in either direction', () {
    testWidgets('the ink tracks the streamed reading frame by frame', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_gauge(20)));
      await tester.pump();
      // A second reading arrives: the count replays the interval between two
      // observations, linearly, and the gauge is drawn at whatever integer the
      // replay is on. Both readings sit inside the `seen` rung, which is where
      // the words carry the depth — so the ink has something independent of
      // the painter to be checked against.
      await tester.pumpWidget(_host(_gauge(95)));
      await tester.pump();

      var moved = 0;
      var previous = _Ink.of(tester).filledFraction;
      for (var step = 0; step < 8; step++) {
        await tester.pump(const Duration(milliseconds: 100));
        final ink = _Ink.of(tester);
        // **The reading is read off the WORDS, not off the painter.** The two
        // registers are built from one value inside one builder; if the ink
        // and the printed number ever disagree, one of them is lying.
        final shown = _shownDepth(tester);
        expect(
          ink.filledFraction,
          closeTo(KvBurialGauge.positionFor(shown), 0.002),
          reason:
              'the gauge reads ${(ink.filledFraction * 100).toStringAsFixed(1)}%'
              ' while the line beside it says $shown blocks',
        );
        if ((ink.filledFraction - previous).abs() > 1e-9) moved++;
        previous = ink.filledFraction;
      }
      expect(
        moved,
        greaterThan(2),
        reason:
            'an extent may not be pinned while its quantity moves (BG-22) — '
            'the fill never changed while the count climbed 20 → 95',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('a fall snaps rather than sliding backwards', (tester) async {
      await tester.pumpWidget(_host(_gauge(500)));
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        closeTo(KvBurialGauge.positionFor(500), 0.001),
      );
      // A reorg, or a depth reading arriving over a maturity flag. BG-18 says
      // a decrease snaps; a gauge that slid back would animate burial being
      // undone.
      await tester.pumpWidget(_host(_gauge(20)));
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        closeTo(KvBurialGauge.positionFor(20), 0.001),
        reason: 'the fall must be on the new reading in one frame',
      );
    });

    testWidgets('reduced animations do not leave the gauge full', (
      tester,
    ) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      expect(SemanticsBinding.instance.disableAnimations, isTrue);

      await tester.pumpWidget(_host(_gauge(4)));
      await tester.pump();
      expect(
        _Ink.of(tester).filledFraction,
        closeTo(KvBurialGauge.positionFor(4), 0.001),
        reason:
            'the sign ring drew a COMPLETE circle under this flag with only '
            'its opacity carrying the reading (D-229) — the extent half of the '
            'same exception is the one that reads as closed',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('nothing is ever drawn strictly between the 0 and 1 marks', (
      tester,
    ) async {
      // A depth is a count of whole blocks and the streamed count passes
      // through integers, so no frame may land inside the origin step.
      await tester.pumpWidget(_host(_gauge(0)));
      await tester.pump();
      await tester.pumpWidget(_host(_gauge(30)));
      await tester.pump();
      for (var step = 0; step < 12; step++) {
        final f = _Ink.of(tester).filledFraction;
        expect(
          f == 0 || f >= KvBurialGauge.positionFor(1) - 1e-9,
          isTrue,
          reason:
              'the gauge showed ${(f * 100).toStringAsFixed(1)}%, which is '
              'inside the unlabelled origin step — BG-22 forbids interpolating '
              'between marks nothing names',
        );
        await tester.pump(const Duration(milliseconds: 80));
      }
      await tester.pumpAndSettle();
    });
  });

  group('BG-20 · an unread scale does not look like a measured zero', () {
    testWidgets('the ink differs between "0 blocks deep" and "no reading"', (
      tester,
    ) async {
      // With the `0` origin labelled, an empty track reads as a measurement AT
      // zero. Both states fill nothing, so the graphic asserted the stronger of
      // the two for a reading nobody has (`consensus-auditor`, UX-5). The words
      // already differ — `Seen 0` against `Seen —` — and the ink now does too.
      await tester.pumpWidget(_host(_gauge(0, key: const ValueKey('zero'))));
      await tester.pump();
      expect(_reading('Seen 0'), findsOneWidget);
      final measured = _Ink.of(tester).tickTones;

      await tester.pumpWidget(
        _host(
          const KvBurialGauge(
            key: ValueKey('unknown'),
            state: TxChipState.accepted,
            confirmations: null,
            maturity: MaturityState.pending,
          ),
        ),
      );
      await tester.pump();
      expect(_reading('Seen —'), findsOneWidget);
      final unread = _Ink.of(tester).tickTones;

      expect(measured, isNotEmpty);
      expect(
        unread,
        isNot(measured),
        reason:
            'an empty track at a live zero and an empty track at an unknown '
            'depth painted the same pixels',
      );
      // Neither is filled — the difference is in the scale, not in a fabricated
      // extent (BG-22 is untouched).
      expect(_Ink.of(tester).filledFraction, 0);
    });
  });

  group('BG-24 · the crossings are accounted for', () {
    testWidgets('the word flips in the same frame the fill crosses the mark', (
      tester,
    ) async {
      // **The coherence property, and it is why the rung is derived from the
      // DRAWN depth.** It used to come from the newest reading, so a poll
      // arriving at 150 over a wallet showing 99 printed `Confirmed`
      // immediately and left the bar below the hundred mark for the rest of the
      // second — the word and the extent disagreeing about which side of the
      // safe threshold the money was on, on the surface built to answer exactly
      // that question.
      await tester.pumpWidget(_host(_gauge(60)));
      await tester.pump();
      await tester.pumpWidget(_host(_gauge(400)));
      await tester.pump();

      var sawSeen = false;
      var sawConfirmed = false;
      final safeMark = KvBurialGauge.positionFor(KvBurial.safe);
      for (var step = 0; step < 14; step++) {
        final fill = _Ink.of(tester).filledFraction;
        final confirmed = _reading('Confirmed').evaluate().isNotEmpty;
        if (confirmed) {
          sawConfirmed = true;
          expect(
            fill,
            greaterThanOrEqualTo(safeMark - 1e-6),
            reason:
                'the words say the money is safe while the bar is still short '
                'of the hundred mark',
          );
        } else {
          sawSeen = true;
          expect(
            fill,
            lessThan(safeMark),
            reason:
                'the bar is past the hundred mark while the words still count',
          );
        }
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(sawSeen && sawConfirmed, isTrue, reason: 'the crossing never ran');
      await tester.pumpAndSettle();
    });

    testWidgets('a rung crossing crossfades and a fall snaps', (tester) async {
      await tester.pumpWidget(_host(_gauge(998)));
      await tester.pump();
      expect(_reading('Confirmed'), findsOneWidget);

      // Up: both rungs are on the glass together while one hands over to the
      // other. `KvBurialMark` has crossfaded since D-229 and the gauge cut.
      await tester.pumpWidget(_host(_gauge(1400)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        _reading('Confirmed'),
        findsOneWidget,
        reason: 'the outgoing rung is still fading',
      );
      expect(_reading('final'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(_reading('Confirmed'), findsNothing);

      // Down: a reorg is not progress and must not animate as if it were.
      await tester.pumpWidget(_host(_gauge(300)));
      await tester.pump();
      expect(
        _reading('final'),
        findsNothing,
        reason: 'BG-18 wins over BG-24 on a decrease — it snaps',
      );
      expect(_reading('Confirmed'), findsOneWidget);
    });
  });

  group('BG-22 · the thousand mark declares the end of the scale', () {
    testWidgets('it is the tallest mark on the axis', (tester) async {
      await tester.pumpWidget(_host(_gauge(42)));
      await tester.pump();
      final ink = _Ink.of(tester);
      final ticks = ink.verticalTicks;
      expect(ticks, hasLength(KvBurialGauge.graduations.length));
      final last = ticks.last;
      for (final tick in ticks.take(ticks.length - 1)) {
        expect(
          last.length,
          greaterThan(tick.length),
          reason: '1,000 is a taller labelled mark than every other decade',
        );
      }
    });

    testWidgets('the bracket closes only once the money is final', (
      tester,
    ) async {
      await tester.pumpWidget(_host(_gauge(999)));
      await tester.pump();
      expect(
        _Ink.of(tester).bracketArms,
        1,
        reason: 'below a thousand the bracket is open — a hook, not a bracket',
      );

      await tester.pumpWidget(_host(_gauge(1200)));
      await tester.pumpAndSettle();
      expect(
        _Ink.of(tester).bracketArms,
        2,
        reason:
            'finality is carried by the thousand mark CLOSING, never by a '
            'fourth hue the palette does not have (§5)',
      );
      // Shape, not colour: with hue removed the two states must still differ
      // (BG-25). The arm count is that difference.
    });
  });

  group('BG-20 · every state has a face of its own', () {
    testWidgets('an unknown depth never wears a measured one', (tester) async {
      await tester.pumpWidget(
        _host(
          const KvBurialGauge(
            state: TxChipState.accepted,
            confirmations: null,
            maturity: MaturityState.confirmed,
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('Confirmed —'),
        findsOneWidget,
        reason:
            '`Confirmed` alone meant both "100–999 blocks deep" and "we cannot '
            'tell", and the shared face wore the stronger of the two',
      );
      expect(find.text('Confirmed'), findsNothing);
    });

    testWidgets('a measured hundred says so without a dash', (tester) async {
      await tester.pumpWidget(_host(_gauge(340)));
      await tester.pump();
      expect(find.text('Confirmed'), findsOneWidget);
    });

    test('the mark and the gauge read one implementation of the ladder', () {
      // BG-21: two registers, one law. If these ever diverge, the ledger row
      // and the detail screen are two widgets disagreeing about one number.
      expect(KvBurialMark.safe, KvBurial.safe);
      expect(KvBurialMark.settled, KvBurial.settled);
      expect(KvBurial.words(KvBurialRung.seen, depth: null), 'Seen —');
      expect(KvBurial.words(KvBurialRung.seen, depth: 7), 'Seen 7');
      expect(KvBurial.words(KvBurialRung.settled), 'final');
    });
  });

  group('the depth arithmetic — one implementation, three lanes', () {
    ActivityRecord row(
      ActivityDirection direction, {
      BigInt? accepted,
      int block = 1000,
    }) => ActivityRecord(
      txid: 'a' * 64,
      valueSompi: BigInt.from(1),
      blockDaaScore: BigInt.from(block),
      acceptedDaaScore: accepted,
      direction: direction,
      isCoinbase: false,
      maturity: MaturityState.pending,
      stalled: false,
    );

    final tip = BigInt.from(3500);

    test('a deposit counts from its own inclusion score', () {
      expect(
        KvBurial.depthOf(row(ActivityDirection.incoming), tip, stale: false),
        2500,
      );
    });

    test('a send counts from DAG acceptance, never from submit time', () {
      expect(
        KvBurial.depthOf(
          row(ActivityDirection.outgoing, accepted: BigInt.from(3000)),
          tip,
          stale: false,
        ),
        500,
      );
      expect(
        KvBurial.depthOf(row(ActivityDirection.outgoing), tip, stale: false),
        isNull,
        reason: 'a send the DAG has not accepted has no depth at all',
      );
    });

    test('a chained-send leg is a spend and counts like one', () {
      // `ActivityDirection.change` is `TransactionData::Batch` — the
      // compounding leg of a >100k-mass chained send — and Rust surfaces its
      // `accepted_daa_score` exactly as it does for a payment. Anchored on
      // `blockDaaScore` instead, a leg the DAG never accepted accrued 2,500
      // blocks of burial off the wall clock and the gauge rendered `final`
      // over a Pending record (`consensus-auditor`, UX-5).
      expect(
        KvBurial.depthOf(row(ActivityDirection.change), tip, stale: false),
        isNull,
      );
      expect(
        KvBurial.depthOf(
          row(ActivityDirection.change, accepted: BigInt.from(3400)),
          tip,
          stale: false,
        ),
        100,
      );
    });

    test('a stale link never counts, whatever the lane', () {
      for (final d in ActivityDirection.values) {
        expect(
          KvBurial.depthOf(
            row(d, accepted: BigInt.from(3000)),
            tip,
            stale: true,
          ),
          isNull,
        );
      }
    });

    testWidgets('and the gauge does not claim finality on a never-accepted leg', (
      tester,
    ) async {
      // The end-to-end shape of the same defect: the words and the closed
      // bracket both asserted finality over a record wallet-core calls Pending.
      final record = row(ActivityDirection.change);
      final depth = KvBurial.depthOf(record, tip, stale: false);
      await tester.pumpWidget(
        _host(
          KvBurialGauge(
            state: TxChipState.accepted,
            confirmations: depth,
            maturity: record.maturity,
          ),
        ),
      );
      await tester.pump();
      expect(_reading('final'), findsNothing);
      expect(_reading('Seen —'), findsOneWidget);
      expect(_Ink.of(tester).bracketArms, 1);
    });
  });

  group('BG-21 · the ledger row reads the same law the gauge does', () {
    testWidgets('the row s count does not stop short of the mark it crosses', (
      tester,
    ) async {
      // The mark used to take its rung from `widget.confirmations` while the
      // count streamed from the last reading, so a poll of 106 arriving over a
      // row showing 96 abandoned the streaming branch outright: the number
      // stopped dead at 96 and was replaced by `Confirmed` — the row claiming
      // to have crossed a hundred while the last figure it ever showed was
      // ninety-six. Fixed on the gauge first; this is the second register, and
      // a rule swept once is a rule swept nowhere (L144).
      await tester.pumpWidget(_host(_mark(96)));
      await tester.pump();
      expect(find.text('Seen 96'), findsOneWidget);

      await tester.pumpWidget(_host(_mark(106)));
      await tester.pump();
      var highest = 96;
      for (var i = 0; i < 20; i++) {
        for (final t in tester.widgetList<Text>(find.byType(Text))) {
          final m = RegExp(r'^Seen (\d+)$').firstMatch(t.data ?? '');
          if (m != null) {
            highest = math.max(highest, int.parse(m.group(1)!));
          }
        }
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(
        highest,
        greaterThanOrEqualTo(KvBurial.safe - 1),
        reason:
            'the count stopped at $highest and the row then said it was past '
            '${KvBurial.safe}',
      );
      await tester.pumpAndSettle();
      expect(find.text('Confirmed'), findsOneWidget);
    });
  });

  group('BG-22 · the axis names itself', () {
    testWidgets('a screen reader hears the depth even where the words drop it', (
      tester,
    ) async {
      // Past the safe mark the words carry no number and the FILL carries the
      // reading — so a label built from the words gave a screen-reader user no
      // depth at all exactly where a sighted user reads one off the track. It
      // also dangled the axis into a sentence that does not take it:
      // *"Confirmed blocks deep"* (`ux-auditor`, UX-5).
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(_gauge(340, key: const ValueKey(340))));
      await tester.pump();
      expect(
        _reading('Confirmed'),
        findsOneWidget,
        reason: 'precondition: the words print no number at this depth',
      );
      expect(
        find.bySemanticsLabel(RegExp(r'340 blocks deep')),
        findsOneWidget,
        reason: 'the reading is inaudible where only the fill carries it',
      );
      expect(find.bySemanticsLabel(RegExp(r'Confirmed blocks')), findsNothing);
      // Disposed in the body, not in a tear-down: the framework verifies the
      // handle at the END of the test body, before tear-downs run.
      handle.dispose();
    });

    testWidgets('the name and every decade are on the glass', (tester) async {
      await tester.pumpWidget(_host(_gauge(42)));
      await tester.pump();
      expect(find.text(KvBurialGauge.axisName), findsOneWidget);
      for (final label in const ['0', '1', '10', '100', '1,000']) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: 'a log scale is honest only where every decade is labelled',
        );
      }
      // Both thresholds are named where they fall (D-192, §5).
      expect(find.text('safe'), findsOneWidget);
      expect(find.text('final'), findsOneWidget);
    });

    testWidgets('every label clears the 11dp floor at 1.3x on a 320dp screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(_gauge(42), textScale: 1.3));
      await tester.pump();
      final texts = tester.widgetList<Text>(find.byType(Text));
      expect(texts, isNotEmpty);
      for (final text in texts) {
        final size = text.style?.fontSize ?? 0;
        expect(
          size,
          greaterThanOrEqualTo(11),
          reason: '"${text.data}" renders under the readable floor (BG-14)',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────

/// [key] is how a case asks for a **fresh** gauge. `pumpWidget` reuses the
/// element tree, so a second call with a new depth is an UPDATE — the streamed
/// count then replays the interval between the two readings and the first frame
/// still shows the old one. That is exactly what the streaming cases want and
/// exactly what a decade-by-decade sweep must not have (L140).
/// The reading line's own words, told apart from the axis label that happens to
/// carry the same threshold name. `final` is both a rung and a graduation, so a
/// bare `find.text` matches two things that mean different things.
Finder _reading(String words) => find.byWidgetPredicate(
  (w) => w is Text && w.data == words && (w.style?.fontSize ?? 0) > 11,
);

Widget _mark(int depth) => KvBurialMark(
  state: TxChipState.accepted,
  confirmations: depth,
  maturity: MaturityState.pending,
);

Widget _gauge(int depth, {Key? key}) => KvBurialGauge(
  key: key,
  state: TxChipState.accepted,
  confirmations: depth,
  maturity: MaturityState.pending,
);

Widget _host(Widget child, {double textScale = 1}) => MediaQuery(
  data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
  child: MaterialApp(
    theme: kvDarkTheme(),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
          child: child,
        ),
      ),
    ),
  ),
);

/// The depth the READING LINE is currently printing — read off the rendered
/// words, so the ink can be checked against something the painter did not
/// produce.
int _shownDepth(WidgetTester tester) {
  final words = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .firstWhere((s) => s.startsWith('Seen ') || s.startsWith('Confirmed'));
  final digits = RegExp(r'\d+').firstMatch(words);
  return digits == null ? 0 : int.parse(digits.group(0)!);
}

/// What the gauge actually painted, replayed onto a spy canvas at the size the
/// widget was really laid out at.
class _Ink {
  _Ink._(this._spy, this._size);

  final _CanvasSpy _spy;
  final Size _size;

  static _Ink of(WidgetTester tester) {
    final finder = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is KvBurialGaugePainter,
    );
    expect(
      finder,
      findsOneWidget,
      reason:
          'the gauge painter was not in the tree — this test proves nothing '
          'unless it found the thing it is measuring',
    );
    final size = tester.getSize(finder);
    final painter =
        tester.widget<CustomPaint>(finder).painter! as KvBurialGaugePainter;
    final spy = _CanvasSpy();
    painter.paint(spy, size);
    return _Ink._(spy, size);
  }

  List<_Line> get lines => _spy.lines;

  /// The tones the painter uses for **structure** — the track's rule and its
  /// graduations. Everything else it paints is a reading.
  ///
  /// The polarity is deliberate: ink the guard does not recognise counts
  /// against the reading and fails loudly, rather than being quietly ignored.
  /// Alpha is masked off so the thousand mark's fading arm is still structure.
  static const List<Color> _structure = [KvColor.etch, KvColor.inkMetaLow];

  static bool _isStructure(Color c) {
    final rgb = c.toARGB32() & 0x00FFFFFF;
    return _structure.any((s) => (s.toARGB32() & 0x00FFFFFF) == rgb);
  }

  /// How much of the track is covered in reading ink, as a fraction —
  /// rectangles by their right edge, strokes by their end **plus whatever
  /// their cap paints past it**.
  double get filledFraction {
    var right = 0.0;
    for (final rect in _spy.rects) {
      right = math.max(right, rect.right);
    }
    for (final line in _spy.lines) {
      if (_isStructure(line.colour)) continue;
      final overhang = line.cap == ui.StrokeCap.butt ? 0.0 : line.width / 2;
      right = math.max(right, math.max(line.from.dx, line.to.dx) + overhang);
    }
    return right / _size.width;
  }

  /// The tones the graduation strokes are painted in — the channel that tells
  /// a live scale from an unread one.
  Set<int> get tickTones =>
      verticalTicks.map((l) => l.colour.toARGB32() & 0x00FFFFFF).toSet();

  /// The graduation strokes, ordered left to right.
  List<_Line> get verticalTicks =>
      _spy.lines.where((l) => l.from.dx == l.to.dx).toList()
        ..sort((a, b) => a.from.dx.compareTo(b.from.dx));

  /// Horizontal strokes at the right-hand end that sit below the band — the
  /// bracket's arms. One is an open hook; two is a closed bracket.
  int get bracketArms => _spy.lines
      .where(
        (l) =>
            l.from.dy == l.to.dy &&
            l.from.dx > _size.width / 2 &&
            l.from.dy > KvBurialGaugePainter.band - 1,
      )
      .length;
}

class _Line {
  const _Line(this.from, this.to, this.width, this.cap, this.colour);

  final Offset from;
  final Offset to;
  final double width;
  final ui.StrokeCap cap;
  final Color colour;

  double get length => (to - from).distance;
}

/// Records every mark the painter makes and swallows the rest of `Canvas`.
class _CanvasSpy implements Canvas {
  final List<_Line> lines = [];
  final List<Rect> rects = [];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add(_Line(p1, p2, paint.strokeWidth, paint.strokeCap, paint.color));

  @override
  void drawRect(Rect rect, Paint paint) => rects.add(rect);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
