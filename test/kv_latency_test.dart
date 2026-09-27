import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_cadence.dart';
import 'package:kaspaverse/src/ui/widgets/kv_latency.dart';

import 'support/preview_harness.dart';

/// **The latency reading** (`T5`, §4's latency re-spec, re-ruled for glass at
/// D-332 and D-333) — a measurement, not a loader, and the distinction is the
/// reason this is not [KvCadence].
void main() {
  setUpAll(loadBundledFonts);

  group('§4 · the tiers, and the render agrees with them', () {
    test('the ladder is 60 · 150 · 300 · 500', () {
      expect(KvLatency.tierFor(0).bars, 5);
      expect(KvLatency.tierFor(59).bars, 5);
      expect(KvLatency.tierFor(60).bars, 4);
      expect(KvLatency.tierFor(149).bars, 4);
      expect(KvLatency.tierFor(150).bars, 3);
      expect(KvLatency.tierFor(299).bars, 3);
      expect(KvLatency.tierFor(300).bars, 2);
      expect(KvLatency.tierFor(499).bars, 2);
      expect(KvLatency.tierFor(500).bars, 1);
      expect(KvLatency.tierFor(5000).bars, 1);
    });

    test('the hue ladder is ok · ok · warn · warn · risk', () {
      expect(KvLatency.tierFor(10).hue, KvColor.ok);
      expect(KvLatency.tierFor(100).hue, KvColor.ok);
      expect(KvLatency.tierFor(200).hue, KvColor.warn);
      expect(KvLatency.tierFor(400).hue, KvColor.warn);
      expect(KvLatency.tierFor(900).hue, KvColor.risk);
    });

    test('`T5`\'s own reading lands where the law puts it', () {
      // The render draws **151 ms with three amber bars and the word `Slow`**.
      // The word is spoken now, not drawn (D-332), but the tier is the same.
      final tier = KvLatency.tierFor(151);
      expect(tier.bars, 3);
      expect(tier.hue, KvColor.warn);
      expect(tier.word, 'Slow');
    });

    test('the bars are a staircase, and the shape is in the ratio', () {
      // `T5` measured 24 · 30 · 36 · 42 · 48, and the founder overruled it on
      // glass (2026-09-05, D-278): *"the lines are too long so its not giving
      // a perfect network bar shape"*.
      expect(KvLatency.barHeights, [10, 16, 22, 28, 34]);
      expect(KvLatency.barWidth, 6);
      expect(KvLatency.barGap, 4);
      final steps = [
        for (var i = 1; i < KvLatency.barHeights.length; i++)
          KvLatency.barHeights[i] - KvLatency.barHeights[i - 1],
      ];
      expect(steps, everyElement(6), reason: 'one even climb');
      expect(
        KvLatency.barHeights.first / KvLatency.barHeights.last,
        lessThan(1 / 3),
        reason: 'the poorest bar has to look poor',
      );
      // Derived, never asserted (L121).
      expect(KvLatency.height, KvLatency.barHeights.last);
      expect(KvLatency.width, 5 * 6 + 4 * 4);
    });
  });

  group('BG-8 · an absent reading is its own face — and needs no colour', () {
    test('null is no reading, never a zero', () {
      final tier = KvLatency.tierFor(null);
      expect(
        tier.bars,
        0,
        reason: 'nothing is lit for a measurement nobody has',
      );
      expect(
        tier.hue,
        KvColor.inkMeta,
        reason:
            'a null must not borrow a tier hue — an unread meter that looked '
            'green would be the confidently-wrong-number failure',
      );
      // A zero IS a reading, and the fastest one there is.
      expect(KvLatency.tierFor(0).bars, 5);
    });

    testWidgets('the figure is a dash, the staircase dark, and no word', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KvLatency(milliseconds: null)));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(_litBars(tester), 0);
      // **No `No reading` on the glass** (D-332): the dash and the unlit
      // staircase say it without a word and without a colour.
      expect(find.text('No reading'), findsNothing);
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Connection latency: no reading.'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('the reading is one hue, and its word is spoken (BG-7, D-332)', () {
    testWidgets('number, unit and bars agree; the tier word is not drawn', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 151)));
      await tester.pump();
      expect(find.text('151'), findsOneWidget);
      expect(find.text('ms'), findsOneWidget);
      expect(_litBars(tester), 3);
      expect(
        find.text('Slow'),
        findsNothing,
        reason: 'the bars and their colour carry the tier (D-332)',
      );
      // …and the word lives on where a screen reader hears it.
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Connection latency 151 milliseconds. Slow.'),
        findsOneWidget,
      );
      handle.dispose();
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        expect(
          t.style?.color,
          KvColor.warn,
          reason: '"${t.data}" is not in the tier\'s hue',
        );
      }
    });

    testWidgets('every label clears the 11dp floor at 1.3x / 320dp', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final seat in const [
        KvLatency(milliseconds: 1234),
        KvLatency(milliseconds: 5000, atLeast: true),
        KvLatency(milliseconds: null),
      ]) {
        await tester.pumpWidget(_host(seat, textScale: 1.3));
        await tester.pumpAndSettle();
        for (final t in tester.widgetList<Text>(find.byType(Text))) {
          expect(
            t.style?.fontSize ?? 11,
            greaterThanOrEqualTo(11),
            reason: '"${t.data}" renders under the readable floor (BG-14)',
          );
        }
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('D-333 · a timeout is "at least", never "nothing"', () {
    test(
      'the deadline prints in seconds, floored — a bound never overstated',
      () {
        expect(KvLatency.seconds(1800), '1.8');
        expect(KvLatency.seconds(1899), '1.8', reason: 'floored, not rounded');
        expect(KvLatency.seconds(5000), '5');
        expect(KvLatency.seconds(1000), '1');
        expect(KvLatency.seconds(1234), '1.2');
      },
    );

    testWidgets('`> 1.8 s` on one bar, in the poorest hue', (tester) async {
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 1800, atLeast: true)),
      );
      await tester.pump();
      expect(find.text('> 1.8'), findsOneWidget);
      expect(find.text('s'), findsOneWidget);
      expect(_litBars(tester), 1);
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        expect(t.style?.color, KvColor.risk, reason: '"${t.data}"');
      }
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          'Connection latency: at least 1.8 seconds. Poor.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('D-332 · the figure counts, and rests on the reading', () {
    testWidgets('it counts through the integers between, up or down', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 100)));
      await tester.pump();
      expect(find.text('100'), findsOneWidget);
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 60));
      final mid = int.parse(_figure(tester));
      expect(mid, greaterThan(100), reason: 'it has started to count');
      expect(mid, lessThan(200), reason: 'and has not arrived');
      await tester.pump(KvLatency.countFor);
      expect(_figure(tester), '200', reason: 'it rests on the measured value');

      // Down, too — and from wherever the eye is, never a jump back.
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 60));
      final down = int.parse(_figure(tester));
      expect(down, inExclusiveRange(150, 200));
      await tester.pump(KvLatency.countFor);
      expect(_figure(tester), '150');
    });

    testWidgets(
      'after the first count it streams: each change replays the interval '
      'since the one before, capped (D-226, the founder on glass 2026-09-27)',
      (tester) async {
        await tester.pumpWidget(_host(const KvLatency(milliseconds: 100)));
        await tester.pump();
        // The first change: the quarter-second count.
        await tester.pumpWidget(_host(const KvLatency(milliseconds: 200)));
        await tester.pump(KvLatency.countFor);
        expect(_figure(tester), '200');

        // The next reading lands 800 ms after that change: it is replayed
        // over those 800 ms at an even pace — still moving at half-way, never
        // frozen then jumping.
        await tester.pump(const Duration(milliseconds: 560));
        await tester.pumpWidget(_host(const KvLatency(milliseconds: 600)));
        await tester.pump(const Duration(milliseconds: 400));
        final halfway = int.parse(_figure(tester));
        expect(halfway, inInclusiveRange(380, 420), reason: 'an even pace');
        await tester.pump(const Duration(milliseconds: 420));
        expect(_figure(tester), '600', reason: 'it rests on the reading');

        // A long gap is a stall, not a cadence: the replay is capped.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpWidget(_host(const KvLatency(milliseconds: 300)));
        await tester.pump(
          KvLatency.replayCap - const Duration(milliseconds: 20),
        );
        expect(_figure(tester), isNot('300'), reason: 'still gliding');
        await tester.pump(const Duration(milliseconds: 40));
        expect(_figure(tester), '300', reason: 'arrived within the cap');
      },
    );

    testWidgets('a reading that does not change does not move', (tester) async {
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 120)));
      await tester.pump();
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 120)));
      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason: 'nothing jitters on its own',
      );
    });

    testWidgets('under reduced motion it becomes the reading at once', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 100), reducedMotion: true),
      );
      await tester.pump();
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 400), reducedMotion: true),
      );
      await tester.pump();
      expect(_figure(tester), '400');
      expect(tester.hasRunningAnimations, isFalse);
      // And every later change too — the replay never runs under reduced
      // motion, not only the first count (`ux-auditor`).
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 250), reducedMotion: true),
      );
      await tester.pump();
      expect(_figure(tester), '250');
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('it never counts out of nothing or into "at least"', (
      tester,
    ) async {
      // From no reading, the first figure simply appears — a count up from
      // zero would draw readings of a very fast link nobody measured.
      await tester.pumpWidget(_host(const KvLatency(milliseconds: null)));
      await tester.pump();
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_figure(tester), '300');
      // A timeout is a different face, not a number to count toward.
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 1800, atLeast: true)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('> 1.8'), findsOneWidget);
    });
  });

  testWidgets('D-332 · the staircase stands on the figure\'s baseline', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const KvLatency(milliseconds: 151)));
    await tester.pump();
    final paragraph = tester.renderObject<RenderParagraph>(find.text('151'));
    // The paragraph's own text, style and scale, re-laid by a painter — its
    // baseline is the laid-out figure's (L131's method; a render object's
    // baseline may only be asked for by its parent mid-layout).
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
    )..layout();
    final baseline =
        paragraph.localToGlobal(Offset.zero).dy +
        painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    painter.dispose();
    final bars = tester.renderObject<RenderBox>(
      find.byWidgetPredicate(
        (w) =>
            w is SizedBox &&
            w.height == KvLatency.height &&
            w.width == KvLatency.width,
      ),
    );
    final barsBottom = bars.localToGlobal(Offset.zero).dy + bars.size.height;
    expect(
      barsBottom,
      moreOrLessEquals(baseline, epsilon: 0.5),
      reason:
          'the bars used to stand on the row\'s bottom, the digits\' '
          'descent below the number they report',
    );
  });

  testWidgets(
    'D-333 · a carried reading dims to the region dim, its unit does not',
    (tester) async {
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 151, stale: true)),
      );
      await tester.pump();
      // The dim is eased (BG-24), so it is read off the eased opacities'
      // targets — which an implicit animation's first frame is already at.
      double opacityAbove(Finder finder) {
        final opacities = tester
            .widgetList<AnimatedOpacity>(
              find.ancestor(of: finder, matching: find.byType(AnimatedOpacity)),
            )
            .map((o) => o.opacity);
        return opacities.fold(1.0, (a, b) => a * b);
      }

      // At 0.45 an amber figure measures 2.81:1 and a red one 2.18:1 on
      // `plate` — under the 3.0 bar. The region dim keeps every tier legal
      // (red at 3.88:1, the unlit ground at 3.16:1).
      expect(opacityAbove(find.text('151')), KvFreshness.opacityStaleRegion);
      expect(
        opacityAbove(find.text('ms')),
        1.0,
        reason: 'a 15 dp unit is body size, and body size never dims (BG-8)',
      );
    },
  );

  latencyReadingTests();

  test('it is a different instrument from the loading meter (BG-21)', () {
    // One name for two meanings is what BG-21 forbids, and these two genuinely
    // are two objects: a hill that breathes while something is in flight, and
    // a staircase that stands still and reports a measurement.
    expect(
      KvLatency.barHeights,
      isNot(KvCadence.barHeights),
      reason: 'if the geometry were the same, this would be a second copy',
    );
    expect(KvCadence.barHeights, [6, 10, 14, 10, 6], reason: 'a hill');
    expect(
      KvLatency.barHeights,
      orderedEquals(<double>[...KvLatency.barHeights]..sort()),
      reason: 'a staircase only ever rises',
    );
  });
}

/// The figure the seat is showing right now.
String _figure(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((d) => d != 'ms' && d != 's')
      .toList();
  expect(texts, hasLength(1));
  return texts.single;
}

/// Bars that are lit. Scoped by geometry, not by colour alone.
int _litBars(WidgetTester tester) =>
    tester.widgetList<Container>(find.byType(Container)).where((c) {
      final d = c.decoration;
      if (d is! BoxDecoration || d.shape != BoxShape.rectangle) return false;
      if (c.constraints?.maxWidth != KvLatency.barWidth) return false;
      // The unlit tone is read from the widget, never restated here (L164).
      return d.color != null && d.color != KvLatency.unlit;
    }).length;

Widget _host(
  Widget child, {
  double textScale = 1,
  bool reducedMotion = false,
}) => MediaQuery(
  data: MediaQueryData(
    textScaler: TextScaler.linear(textScale),
    disableAnimations: reducedMotion,
  ),
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

KvLatencyReading _offer(KvLatencyReading r, List<int> answers) {
  for (final ms in answers) {
    r = r.offer(KvLatencySample.answered(ms));
  }
  return r;
}

/// **The stable reading** (UX-R3, second beat; D-333): a median over the
/// window — a timeout counted at its lower bound — and hysteresis at the tier
/// boundaries, so the instrument moves when the link moves and not when the
/// noise does.
void latencyReadingTests() {
  group('KvLatencyReading · the figure is an observed sample', () {
    test('the median of the window, never an average', () {
      var r = const KvLatencyReading.none();
      expect(r.milliseconds, isNull);
      r = _offer(r, [100]);
      expect(r.milliseconds, 100);
      // Two samples: the slower one — the side the user would rather hear.
      r = _offer(r, [140]);
      expect(r.milliseconds, 140);
      r = _offer(r, [120]);
      expect(r.milliseconds, 120, reason: 'median of 100 · 140 · 120');
      // Every figure ever printed is one of the samples.
      expect(r.samples.map((s) => s.ms), contains(r.milliseconds));
    });

    test('one spike does not take the readout with it', () {
      final r = _offer(const KvLatencyReading.none(), [90, 95, 900, 92]);
      expect(r.milliseconds, 95, reason: 'median of 95 · 900 · 92');
      expect(r.tier, KvLatencyTier.good);
    });

    test('an identical outcome is the same reading — nothing notifies', () {
      final a = _offer(const KvLatencyReading.none(), [120, 120, 120]);
      final b = a.offer(const KvLatencySample.answered(120));
      expect(b, a, reason: 'a steady link twice a second rebuilds nothing');
      expect(b.hashCode, a.hashCode);
      expect(a.offer(const KvLatencySample.answered(121)), isNot(a));
    });
  });

  group('KvLatencyReading · a timeout is its own lower bound (D-333)', () {
    test('one slow probe among answers is outvoted like any spike', () {
      final r = _offer(const KvLatencyReading.none(), [120])
          .offer(const KvLatencySample.atLeast(1500))
          .offer(const KvLatencySample.answered(130));
      expect(r.milliseconds, 130);
      expect(r.atLeast, isFalse);
      expect(r.tier, KvLatencyTier.good);
    });

    test('two of three is the link: "at least", one bar, the poorest hue', () {
      final r = _offer(const KvLatencyReading.none(), [130])
          .offer(const KvLatencySample.atLeast(1500))
          .offer(const KvLatencySample.atLeast(1800));
      expect(r.milliseconds, 1500);
      expect(r.atLeast, isTrue);
      expect(r.tier, KvLatencyTier.poor);
    });

    test('a timeout sorts after an answer of the same size', () {
      // Two samples take the slower; a censored 400 is at least 400, so it is
      // the slower of the two.
      final r = _offer(const KvLatencyReading.none(), [
        400,
      ]).offer(const KvLatencySample.atLeast(400));
      expect(r.atLeast, isTrue);
    });

    test('a timeout never empties the window — only the seat does', () {
      var r = _offer(const KvLatencyReading.none(), [40, 42, 41]);
      expect(r.tier, KvLatencyTier.fast);
      r = r.offer(const KvLatencySample.atLeast(1000));
      expect(
        r.milliseconds,
        42,
        reason:
            'a lower bound is a sample, and one of three is outvoted: the '
            'median of 42 · 41 · ≥1000 (the window slid past the 40)',
      );
      expect(r.atLeast, isFalse);
      expect(r.samples, hasLength(KvLatencyReading.window));
    });

    test('an answer after "at least" leaves the poor tier by the ladder', () {
      var r = const KvLatencyReading.none()
          .offer(const KvLatencySample.atLeast(2000))
          .offer(const KvLatencySample.atLeast(2000));
      expect(r.tier, KvLatencyTier.poor);
      r = _offer(r, [120, 120]);
      expect(r.atLeast, isFalse);
      expect(r.tier, KvLatencyTier.good, reason: 'well clear of 500 × 0.9');
    });
  });

  group('KvLatencyTier · hysteresis at the boundaries', () {
    test('a reading hovering at a boundary never flaps', () {
      var r = _offer(const KvLatencyReading.none(), [148, 148, 148]);
      expect(r.tier, KvLatencyTier.good);
      // 148 · 152 · 148 · 152 … — the first cut flipped green ↔ amber on
      // every other probe.
      final seen = <KvLatencyTier>{};
      for (var i = 0; i < 20; i++) {
        r = _offer(r, [i.isEven ? 152 : 148]);
        seen.add(r.tier);
      }
      expect(seen, {KvLatencyTier.good});
    });

    test('a genuine move crosses, and lands where the reading is', () {
      var r = _offer(const KvLatencyReading.none(), [50, 50, 50]);
      expect(r.tier, KvLatencyTier.fast);
      r = _offer(r, [400, 400]);
      expect(
        r.tier,
        KvLatencyTier.verySlow,
        reason: 'two tiers at once, not one per probe',
      );
      r = _offer(r, [30, 30, 30]);
      expect(r.tier, KvLatencyTier.fast);
    });

    test('the margin is a tenth of the boundary, both ways', () {
      expect(
        KvLatency.tierFor(164, held: KvLatencyTier.good),
        KvLatencyTier.good,
      );
      expect(
        KvLatency.tierFor(165, held: KvLatencyTier.good),
        KvLatencyTier.slow,
      );
      expect(
        KvLatency.tierFor(135, held: KvLatencyTier.slow),
        KvLatencyTier.slow,
      );
      expect(
        KvLatency.tierFor(134, held: KvLatencyTier.slow),
        KvLatencyTier.good,
      );
      expect(KvLatency.tierFor(151), KvLatencyTier.slow);
      expect(
        KvLatency.tierFor(151, held: KvLatencyTier.none),
        KvLatencyTier.slow,
      );
    });

    test('the seat passes its held tier to the glass', () {
      final held = KvLatencyTier.good;
      expect(KvLatency.tierFor(160), KvLatencyTier.slow);
      expect(KvLatency.tierFor(160, held: held), held);
    });
  });
}
