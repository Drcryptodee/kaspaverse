import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_loader.dart';
import 'package:kaspaverse/src/ui/widgets/kv_latency.dart';

import 'support/preview_harness.dart';

/// **The latency reading** (`T5`, §4's latency re-spec, re-ruled for glass at
/// D-332, D-333 and D-337) — a measurement, not a loader, and the distinction
/// is the reason the staircase is not [KvLoader].
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
      expect(find.bySemanticsLabel('Node reply: no reading.'), findsOneWidget);
      handle.dispose();
    });
  });

  group('the reading is one hue, and its word is spoken (BG-7, D-332)', () {
    testWidgets('number, unit and bars agree; the tier word is not drawn', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 150, path: 140)),
      );
      await tester.pump();
      expect(find.text('150'), findsOneWidget);
      expect(find.text('ms'), findsOneWidget);
      expect(_litBars(tester), 3);
      expect(
        find.text('Slow'),
        findsNothing,
        reason: 'the bars and their colour carry the tier (D-332)',
      );
      // …and the word lives on where a screen reader hears it, with the
      // path — one sentence for the whole instrument (§11). **Node reply,
      // never "latency" or "ping"** (D-337): the figure is the RPC round trip.
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          'Node reply 150 milliseconds. Slow. Path 140 milliseconds.',
        ),
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
        KvLatency(milliseconds: 1230),
        KvLatency(milliseconds: 5000, atLeast: true),
        KvLatency(milliseconds: null),
        KvLatency(milliseconds: null, measuring: true),
      ]) {
        await tester.pumpWidget(_host(seat, textScale: 1.3));
        await tester.pump();
        await tester.pump(KvMotion.calm);
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
    test('a path of a second or more is spoken in milliseconds (LINK-Q4: '
        'milliseconds only, the founder\'s ruling)', () {
      expect(
        KvLatency.spoken(1480, atLeast: false, path: 1200),
        'Node reply 1480 milliseconds. Poor. Path 1200 milliseconds.',
      );
    });

    test('the wait prints in milliseconds, floored to a hundred — a lower '
        'bound is never rounded up', () {
      expect(KvLatency.waitFloor(1800), 1800);
      expect(KvLatency.waitFloor(1899), 1800, reason: 'floored, not rounded');
      expect(KvLatency.waitFloor(5000), 5000);
      expect(KvLatency.waitFloor(1000), 1000);
      expect(KvLatency.waitFloor(1234), 1200);
    });

    testWidgets('`1800 ms` on one bar, in the poorest hue — no `>`, heard as '
        '"at least", and never the loader (LINK-Q4, ruled on glass)', (
      tester,
    ) async {
      for (final stale in [true, false]) {
        await tester.pumpWidget(
          _host(KvLatency(milliseconds: 1800, atLeast: true, stale: stale)),
        );
        await tester.pump();
        expect(find.byType(KvLoader), findsNothing, reason: 'stale: $stale');
        expect(_litBars(tester), 1, reason: 'one bar, stale: $stale');
      }
      expect(find.text('1800'), findsOneWidget);
      expect(find.text('ms'), findsOneWidget);
      expect(find.textContaining('>'), findsNothing);
      expect(find.text('s'), findsNothing);
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        expect(t.style?.color, KvColor.risk, reason: '"${t.data}"');
      }
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('Node reply: at least 1800 milliseconds. Poor.'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('LINK-UX1 · the wait is a measurement too', () {
    testWidgets('in the "at least" face the wait counts up live, floored to '
        'a tenth, never under the bound', (tester) async {
      final since = DateTime(2026, 9, 28, 12);
      var now = since.add(const Duration(milliseconds: 500));
      Widget seat() => _host(
        KvLatency(
          milliseconds: 1800,
          atLeast: true,
          waitingSince: since,
          clock: () => now,
        ),
      );
      await tester.pumpWidget(seat());
      await tester.pump();
      expect(
        find.text('1800'),
        findsOneWidget,
        reason: 'half a second out is not yet more than the bound',
      );
      now = since.add(const Duration(milliseconds: 2390));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('2300'), findsOneWidget, reason: 'floored, live');
      now = since.add(const Duration(milliseconds: 4050));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('4000'), findsOneWidget);
      expect(_litBars(tester), 1);
      expect(find.byType(KvLoader), findsNothing);
    });

    testWidgets('*measuring…* until the wait passes a second, then it counts', (
      tester,
    ) async {
      final since = DateTime(2026, 9, 28, 12);
      var now = since.add(const Duration(milliseconds: 300));
      Widget seat() => _host(
        KvLatency(
          milliseconds: null,
          measuring: true,
          waitingSince: since,
          clock: () => now,
        ),
      );
      await tester.pumpWidget(seat());
      await tester.pump();
      expect(find.text('measuring…'), findsOneWidget);
      expect(_litBars(tester), 0, reason: 'no reading lights nothing');
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Node reply: measuring.'), findsOneWidget);
      handle.dispose();
      now = since.add(const Duration(milliseconds: 1260));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('1200'), findsOneWidget);
      // The fade's first tick is the frame after the flip; then its step.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(KvMotion.calm);
      expect(find.text('measuring…'), findsNothing, reason: 'faded out');
      expect(_litBars(tester), 1, reason: 'a second unanswered is poor');
    });

    testWidgets('the live count caps at 9900 ms — a bound stated low, never '
        'high, and never wider than the floor allows', (tester) async {
      final since = DateTime(2026, 9, 28, 12);
      await tester.pumpWidget(
        _host(
          KvLatency(
            milliseconds: 1800,
            atLeast: true,
            waitingSince: since,
            clock: () => since.add(const Duration(seconds: 14)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('9900'), findsOneWidget);
    });

    testWidgets('the measuring word keeps the figure\'s line box, so the card '
        'does not step when the first answer lands', (tester) async {
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: null, measuring: true)),
      );
      await tester.pump();
      final measuring = tester.getSize(find.byType(KvLatency)).height;
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 150)));
      await tester.pump();
      final reading = tester.getSize(find.byType(KvLatency)).height;
      expect(measuring, reading);
    });

    testWidgets('no wait ticks behind a reading: the count runs only in the '
        'faces that print it', (tester) async {
      final since = DateTime(2026, 9, 28, 12);
      await tester.pumpWidget(
        _host(
          KvLatency(
            milliseconds: 150,
            waitingSince: since,
            clock: () => since.add(const Duration(seconds: 3)),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('150'), findsOneWidget);
      expect(
        tester.hasRunningAnimations,
        isFalse,
        reason:
            'one slow probe is outvoted by the median; its wait is not '
            'the reading, and must not keep a ticker alive',
      );
    });
  });

  group('D-337 · the figure glides on a critically damped spring', () {
    testWidgets('it glides to the reading and rests on it, up or down, in '
        'the display\'s own steps', (tester) async {
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 100)));
      await tester.pump();
      expect(find.text('100'), findsOneWidget);
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 60));
      final mid = int.parse(_figure(tester));
      expect(mid, greaterThan(100), reason: 'it has started');
      expect(mid, lessThan(200), reason: 'and has not arrived');
      expect(mid % 10, 0, reason: 'above 100 it moves in 10 ms steps');
      await tester.pump(const Duration(milliseconds: 500));
      expect(_figure(tester), '200', reason: 'it rests on the reading');

      await tester.pumpWidget(_host(const KvLatency(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 40));
      expect(int.parse(_figure(tester)), inExclusiveRange(150, 200));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_figure(tester), '150');
    });

    testWidgets('no frame overshoots, and none is past the newest reading — '
        'even when a new reading lands mid-glide the other way', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 100)));
      await tester.pump();
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 600)));
      final up = <int>[];
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        up.add(int.parse(_figure(tester)));
      }
      expect(up, everyElement(inInclusiveRange(100, 600)));
      expect(up, orderedEquals([...up]..sort()), reason: 'it only climbs');
      // A lower reading lands while the figure is still climbing fast: the
      // carried speed points away from it and is dropped, so the figure turns
      // at once and never rises past where it was.
      final turn = up.last;
      expect(turn, lessThan(600));
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 300)));
      final down = <int>[];
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        down.add(int.parse(_figure(tester)));
      }
      final lo = turn < 300 ? turn : 300;
      final hi = turn < 300 ? 300 : turn;
      expect(
        down,
        everyElement(inInclusiveRange(lo, hi)),
        reason:
            'every frame between the figure on the glass and the newest '
            'reading — never outside that range',
      );
      expect(down.last, 300);
    });

    test('one step never crosses the target, whatever the speed carried', () {
      for (final p in [0.0, 150.0, 480.0, 2000.0]) {
        for (final target in [100.0, 300.0, 5000.0]) {
          for (final v in [-20000.0, -500.0, 0.0, 500.0, 20000.0]) {
            for (final dt in [0.004, 0.016, 0.033, 0.1, 0.5]) {
              final (np, _) = KvLatency.glide(p, v, target, dt);
              final lo = p < target ? p : target;
              final hi = p < target ? target : p;
              // Between where it was and the target — or ON the target.
              if (!(np >= lo - 1e-9 && np <= hi + 1e-9) &&
                  (v == 0 || (target - p) * v > 0)) {
                fail('p=$p v=$v target=$target dt=$dt → $np left [$lo, $hi]');
              }
              expect(
                (np - target) * (p - target),
                greaterThanOrEqualTo(0),
                reason: 'p=$p v=$v target=$target dt=$dt crossed to $np',
              );
            }
          }
        }
      }
    });

    test('it carries its speed into a reading that lies the same way', () {
      // Half-way through a climb, the figure moving up fast, a higher reading
      // lands: carried, the figure keeps its pace — a fresh start would stall
      // and re-accelerate, the stutter the spring exists to remove.
      final (carried, _) = KvLatency.glide(300, 1500, 700, 0.05);
      final (fresh, _) = KvLatency.glide(300, 0, 700, 0.05);
      expect(carried, greaterThan(fresh));
    });

    test('it settles inside one probe interval for any move the probe can '
        'report — measured against the founder\'s cadence (p10 0.476 s)', () {
      for (final jump in [10.0, 100.0, 400.0, 2000.0, 5000.0]) {
        var p = 0.0;
        var v = 0.0;
        var t = 0.0;
        while ((jump - p).abs() > 5 && t < 5) {
          (p, v) = KvLatency.glide(p, v, jump, 1 / 60);
          t += 1 / 60;
        }
        expect(
          t,
          lessThanOrEqualTo(0.476),
          reason: 'a $jump ms move is within half a display step at $t s',
        );
      }
    });

    testWidgets('a change of face is eased, never cut — the figure and its '
        'unit cross-fade as one (BG-24)', (tester) async {
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: null, measuring: true)),
      );
      await tester.pump();
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('measuring…'), findsOneWidget, reason: 'fading out');
      expect(find.text('150'), findsOneWidget, reason: 'fading in');
      await tester.pump(KvMotion.calm);
      expect(find.text('measuring…'), findsNothing);
      expect(find.text('150'), findsOneWidget);
      expect(find.text('ms'), findsOneWidget);
    });

    testWidgets('the room a face takes is eased with it: at the floor the '
        'history never gains or loses its width in one frame', (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final history = KvLatencyHistory(
        reading: _reading([150, 152, 149]),
        now: _t(3),
      );
      await tester.pumpWidget(
        _host(KvLatency(milliseconds: 150, history: history), textScale: 1.3),
      );
      await tester.pump();
      final wide = tester.getSize(find.byType(KvLatencyHistory)).width;
      await tester.pumpWidget(
        _host(
          KvLatency(milliseconds: 1800, atLeast: true, history: history),
          textScale: 1.3,
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 60));
      final mid = tester.getSize(find.byType(KvLatencyHistory)).width;
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(KvMotion.calm);
      final narrow = tester.getSize(find.byType(KvLatencyHistory)).width;
      expect(narrow, lessThan(wide), reason: 'the bound face is wider');
      expect(mid, lessThan(wide), reason: 'it has started to give way');
      expect(mid, greaterThan(narrow), reason: 'and has not snapped');
    });

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
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 250), reducedMotion: true),
      );
      await tester.pump();
      expect(_figure(tester), '250');
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('it never glides out of nothing or into "at least"', (
      tester,
    ) async {
      // From no reading, the first figure simply appears — a count up from
      // zero would draw readings of a very fast link nobody measured.
      await tester.pumpWidget(_host(const KvLatency(milliseconds: null)));
      await tester.pump();
      await tester.pumpWidget(_host(const KvLatency(milliseconds: 300)));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.text('300'),
        findsOneWidget,
        reason: 'arrives as itself, the dash fading out beside it',
      );
      await tester.pump(KvMotion.calm);
      expect(_figure(tester), '300');
      // A timeout is a different face, not a number to glide toward.
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 1800, atLeast: true)),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('1800'), findsOneWidget);
    });
  });

  testWidgets('D-332 · the staircase and the history stand on the figure\'s '
      'baseline', (tester) async {
    final reading = _reading([170, 172, 176, 171]);
    await tester.pumpWidget(
      _host(
        KvLatency(
          milliseconds: 150,
          history: KvLatencyHistory(reading: reading, now: _t(4)),
        ),
      ),
    );
    await tester.pump();
    final paragraph = tester.renderObject<RenderParagraph>(find.text('150'));
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
    double bottomOf(Finder f) {
      final box = tester.renderObject<RenderBox>(f);
      return box.localToGlobal(Offset.zero).dy + box.size.height;
    }

    expect(
      bottomOf(
        find.byWidgetPredicate(
          (w) =>
              w is SizedBox &&
              w.height == KvLatency.height &&
              w.width == KvLatency.width,
        ),
      ),
      moreOrLessEquals(baseline, epsilon: 0.5),
      reason:
          'the bars used to stand on the row\'s bottom, the digits\' '
          'descent below the number they report',
    );
    expect(
      bottomOf(find.byType(KvLatencyHistory)),
      moreOrLessEquals(baseline, epsilon: 0.5),
      reason: 'the history is part of the same instrument',
    );
  });

  testWidgets(
    'D-333 · a carried reading dims to the region dim, its unit does not',
    (tester) async {
      await tester.pumpWidget(
        _host(
          KvLatency(
            milliseconds: 150,
            stale: true,
            history: KvLatencyHistory(
              reading: _reading([150, 150]),
              now: _t(2),
            ),
          ),
        ),
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
      expect(opacityAbove(find.text('150')), KvFreshness.opacityStaleRegion);
      expect(
        opacityAbove(find.byType(KvLatencyHistory)),
        1.0,
        reason:
            'a history is a record with its own time axis (BG-8): its age is '
            'where it stands, and the dim would take the band under 3:1',
      );
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
    // are two objects: a shape that turns and morphs while something is in
    // flight (the loader, LINK-Q4), and a staircase that stands still and
    // reports a measurement.
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

/// The seat's clock at probe [n]: the cadence apart, from a fixed origin.
DateTime _t(num n) =>
    DateTime(2026, 9, 28, 12).add(KvLatencyReading.cadence * n.toDouble());

/// Answers offered one cadence apart, continuing [from]'s clock at [start].
KvLatencyReading _reading(
  List<int> answers, {
  KvLatencyReading from = const KvLatencyReading.none(),
  int start = 0,
}) {
  var r = from;
  for (var i = 0; i < answers.length; i++) {
    r = r.offer(KvLatencySample.answered(answers[i]), at: _t(start + i + 1));
  }
  return r;
}

/// **A real minute on the founder's air** — `get_server_info` round trips
/// from LINK-Q2's capture (`e1_probes.csv`, 2026-09-28, `info` answers
/// 200–259 on `ivy`), the same minute the preview frames draw.
const List<int> _airMinute = [
  176, 172, 190, 172, 201, 181, 205, 176, 175, 171, 228, 188, 176, 171, 184, //
  173, 173, 178, 171, 171, 171, 173, 175, 171, 175, 173, 172, 171, 175, 168,
  176, 176, 171, 179, 168, 175, 179, 167, 174, 171, 172, 171, 167, 172, 171,
  167, 175, 167, 179, 171, 171, 171, 171, 171, 168, 172, 171, 176, 172, 171,
];

/// **The reading** (UX-R3, second beat; D-333; LINK-UX1): a median over the
/// window with a timeout counted at its lower bound, a One Euro filter on the
/// display grid, a time-weighted ten-second tier with hysteresis, the path
/// floor, and the minute — so the instrument moves when the link moves and
/// not when the noise does.
void latencyReadingTests() {
  group('KvLatencyReading · the figure is a filtered median, on the grid', () {
    test('the first answer is the figure; later ones pull it, never past '
        'what was measured', () {
      var r = const KvLatencyReading.none();
      expect(r.milliseconds, isNull);
      expect(r.isEmpty, isTrue);
      r = _reading([100]);
      expect(r.milliseconds, 100);
      r = _reading([140, 120, 130, 125], from: r, start: 1);
      final f = r.filtered!;
      expect(
        f,
        inInclusiveRange(100, 140),
        reason: 'a blend of the medians, never outside them (no extrapolation)',
      );
      expect(
        (r.milliseconds! - f).abs(),
        lessThanOrEqualTo(
          KvLatencyReading.step(f) * (0.5 + KvLatencyReading.stepHold),
        ),
        reason: 'the printed figure sits on the grid, within the hold',
      );
    });

    test('one spike does not take the readout with it', () {
      final r = _reading([90, 95, 900, 92]);
      expect(
        r.milliseconds,
        inInclusiveRange(90, 95),
        reason: 'the median never saw the 900: 95 · 900 · 92 → 95',
      );
    });

    test('the display grid: 1 ms under 100, 10 ms above, rounded', () {
      expect(KvLatencyReading.step(99.9), 1);
      expect(KvLatencyReading.step(100), 10);
      expect(KvLatencyReading.quantize(99.4), 99);
      expect(KvLatencyReading.quantize(104), 100);
      expect(KvLatencyReading.quantize(174.9), 170);
      expect(KvLatencyReading.quantize(175), 180, reason: 'half away');
      expect(KvLatencyReading.quantize(1487), 1490);
    });

    test('on the founder\'s real minute the figure holds still — and rests '
        'on the right step', () {
      // The three-probe median of this minute, twice over, changes 57 times;
      // the figure the user reads changes a handful. And it rests on the
      // step the filtered value rounds to: a whole step of hold kept this
      // same link at `180` for 171 ms (a standing 8 ms error).
      var r = const KvLatencyReading.none();
      var changes = 0;
      int? last;
      for (var i = 0; i < 120; i++) {
        r = r.offer(
          KvLatencySample.answered(_airMinute[i % 60]),
          at: _t(i + 1),
        );
        if (last != null && r.milliseconds != last) changes++;
        last = r.milliseconds;
      }
      expect(changes, lessThanOrEqualTo(8));
      expect(r.milliseconds, KvLatencyReading.quantize(r.filtered!));
      expect(
        (r.milliseconds! - r.filtered!).abs(),
        lessThanOrEqualTo(10 * (0.5 + KvLatencyReading.stepHold)),
      );
    });

    test('a real move passes quickly: 90 % of a 300 ms step within one '
        'second of the link moving', () {
      var r = _reading(List.filled(20, 170));
      r = _reading([470, 470], from: r, start: 20);
      expect(
        r.filtered!,
        greaterThanOrEqualTo(170 + 0.9 * 300),
        reason: 'two probes — the median needs two — and the filter follows',
      );
    });

    test('a reading is a value: the same outcomes at the same times are the '
        'same reading', () {
      final a = _reading([120, 121, 119]);
      final b = _reading([120, 121, 119]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(_reading([120, 121, 118]), isNot(a));
    });
  });

  group('KvLatencyReading · a timeout is its own lower bound (D-333)', () {
    test('one slow probe among answers is outvoted like any spike', () {
      final r = _reading([120])
          .offer(const KvLatencySample.atLeast(1500), at: _t(2))
          .offer(const KvLatencySample.answered(130), at: _t(3));
      expect(r.milliseconds, 130);
      expect(r.atLeast, isFalse);
      // …but the bars read the ten seconds by TIME, and 1.5 of these 2.1
      // seconds were a wait with no answer (coordinated omission).
      expect(r.tier, KvLatencyTier.poor);
    });

    test('two of three is the link: "at least", and the poorest tier', () {
      final r = _reading([130])
          .offer(const KvLatencySample.atLeast(1500), at: _t(2))
          .offer(const KvLatencySample.atLeast(1800), at: _t(3));
      expect(r.milliseconds, 1500);
      expect(r.atLeast, isTrue);
      expect(r.tier, KvLatencyTier.poor);
      expect(r.filtered, isNull, reason: 'the bound is never filtered');
    });

    test('a timeout sorts after an answer of the same size', () {
      final r = _reading([
        400,
      ]).offer(const KvLatencySample.atLeast(400), at: _t(2));
      expect(r.atLeast, isTrue);
    });

    test('a timeout never empties the window — only the seat does', () {
      var r = _reading([40, 42, 41]);
      r = r.offer(const KvLatencySample.atLeast(1000), at: _t(4));
      expect(r.milliseconds, inInclusiveRange(40, 42));
      expect(r.atLeast, isFalse);
      expect(r.samples, hasLength(KvLatencyReading.window));
    });

    test('back from "at least", the figure starts again at the answer — it '
        'never eases out of a bound nobody measured', () {
      var r = const KvLatencyReading.none()
          .offer(const KvLatencySample.atLeast(2000), at: _t(1))
          .offer(const KvLatencySample.atLeast(2000), at: _t(2));
      expect(r.atLeast, isTrue);
      r = _reading([120, 120], from: r, start: 2);
      expect(r.atLeast, isFalse);
      expect(r.milliseconds, 120);
    });
  });

  group('KvLatencyReading · the tier reads ten seconds, by time', () {
    test('a stall weighs its time, not its count (coordinated omission)', () {
      // Ten quick answers, then ONE probe that waited five seconds. Counted,
      // the median is 100 ms and the bars would say "good". Weighed by the
      // time each outcome stands for, most of the window was the wait.
      var r = _reading(List.filled(10, 100));
      r = r.offer(
        const KvLatencySample.atLeast(5000),
        at: _t(10).add(const Duration(seconds: 5)),
      );
      final counted = [...r.history.map((o) => o.sample.ms)]..sort();
      expect(counted[counted.length ~/ 2], 100, reason: 'by count: fast');
      expect(r.tier, KvLatencyTier.poor, reason: 'by time: a stall');
    });

    test('a span is its own round trip at least, and a gap the screen did '
        'not watch is not a stall', () {
      var r = _reading([150]);
      // Three minutes later (the app was backgrounded), one answer lands.
      r = r.offer(
        const KvLatencySample.answered(160),
        at: _t(1).add(const Duration(minutes: 3)),
      );
      expect(
        r.history.last.span,
        const Duration(milliseconds: 160) + KvLatencyReading.cadence,
      );
      // And a fixed clock (a test's) never makes a span smaller than the
      // round trip it measured.
      final same = _reading([
        150,
      ]).offer(const KvLatencySample.answered(200), at: _t(1));
      expect(same.history.last.span, const Duration(milliseconds: 200));
    });

    test('a reading hovering at a boundary never flaps', () {
      var r = _reading([148, 148, 148]);
      expect(r.tier, KvLatencyTier.good);
      final seen = <KvLatencyTier>{};
      for (var i = 0; i < 40; i++) {
        r = _reading([i.isEven ? 152 : 148], from: r, start: 3 + i);
        seen.add(r.tier);
      }
      expect(seen, {KvLatencyTier.good});
    });

    test('a genuine move crosses once it holds, and lands where the reading '
        'is — two tiers at once, never one per probe', () {
      var r = _reading(List.filled(20, 50));
      expect(r.tier, KvLatencyTier.fast);
      final seen = <KvLatencyTier>[];
      for (var i = 0; i < 20; i++) {
        r = _reading([400], from: r, start: 20 + i);
        if (seen.isEmpty || seen.last != r.tier) seen.add(r.tier);
      }
      expect(seen, [KvLatencyTier.fast, KvLatencyTier.verySlow]);
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
  });

  group('KvLatencyReading · the path is the best answer of ten seconds', () {
    test('the minimum answer, never a timeout', () {
      final r = _reading([
        180,
        172,
        190,
      ]).offer(const KvLatencySample.atLeast(100), at: _t(4));
      expect(r.pathAt(_t(4)), 172);
    });

    test('it expires: nothing answered in ten seconds is no path', () {
      final r = _reading([180, 172]);
      expect(r.pathAt(_t(2).add(const Duration(seconds: 9))), 172);
      expect(r.pathAt(_t(2).add(const Duration(seconds: 11))), isNull);
    });

    test('as printed, the path is floored to its step and never above the '
        'figure beside it — a negative queue is a value nobody measured', () {
      expect(KvLatencyReading.printedPath(175), 170, reason: 'floored');
      expect(KvLatencyReading.printedPath(99), 99, reason: '1 ms under 100');
      expect(KvLatencyReading.printedPath(1487), 1480);
      // The founder's own inversion (`ux-auditor`): filter 170, path 175 —
      // rounded, `170 ms · PATH 180`.
      expect(KvLatencyReading.printedPath(175, figure: 170), 170);
      expect(KvLatencyReading.printedPath(186, figure: 170), 170);
      expect(
        KvLatencyReading.printedPath(186, figure: 1800, atLeast: true),
        180,
        reason: 'beside "at least" the figure is a bound, not a value',
      );
      expect(KvLatencyReading.printedPath(null, figure: 170), isNull);
    });

    test('on the founder\'s capture it never prints above the figure', () {
      var r = const KvLatencyReading.none();
      for (var i = 0; i < 240; i++) {
        final ms = _airMinute[i % 60] + (i ~/ 60) * 7;
        r = r.offer(KvLatencySample.answered(ms), at: _t(i + 1));
        final path = KvLatencyReading.printedPath(
          r.pathAt(_t(i + 1)),
          figure: r.milliseconds,
        );
        expect(path, lessThanOrEqualTo(r.milliseconds!), reason: 'probe $i');
      }
    });

    test('a carried reading keeps its minute drawn and starts everything '
        'else again (D-333)', () {
      final carried = _reading([150, 150, 150]).resumed();
      expect(carried.isEmpty, isTrue);
      expect(carried.milliseconds, isNull);
      expect(carried.tier, KvLatencyTier.none);
      expect(carried.history, hasLength(3), reason: 'still drawn');
      expect(carried.history.every((o) => o.carried), isTrue);
      expect(
        carried.pathAt(_t(3)),
        isNull,
        reason: 'a remembered answer is never this screen\'s floor',
      );
      final fresh = carried.offer(
        const KvLatencySample.answered(300),
        at: _t(4),
      );
      expect(fresh.milliseconds, 300, reason: 'the first fresh answer');
      expect(fresh.tier, KvLatencyTier.verySlow, reason: 'not the carried 150');
      expect(fresh.pathAt(_t(4)), 300);
    });
  });

  group('KvLatencyReading · the minute, as columns in time', () {
    test('x is time, not sample count: a screen opened 20 s ago draws 40 s '
        'of nothing', () {
      final r = _reading(List.filled(40, 170));
      final cols = r.columns(_t(40));
      expect(cols, hasLength(60));
      expect(cols.take(38).every((c) => c.p50 == null), isTrue);
      expect(cols.skip(41).every((c) => c.p50 == 170), isTrue);
    });

    test('a timeout marks its own stretch — from when its probe went out '
        'to when it gave up, never a whole column wider', () {
      var r = _reading(List.filled(100, 170));
      // The probe went out 0.4 s after the last answer (the poll's idle
      // wait), so the outcome stands for 2.2 s and its WAIT for 1.8 — the
      // mark is the wait.
      final gaveUp = _t(100).add(_ms(2200));
      r = r.offer(const KvLatencySample.atLeast(1800), at: gaveUp);
      r = _reading(List.filled(10, 170), from: r, start: 104);
      final stalls = r.stalls(_t(114));
      expect(stalls, hasLength(1));
      final (from, to) = stalls.single;
      expect(to, gaveUp);
      expect(to.difference(from), _ms(1800), reason: 'exactly its own wait');
    });

    test('a probe still out past a second is a stall, drawn live', () {
      final r = _reading(List.filled(30, 170));
      final now = _t(30).add(_ms(3000));
      expect(r.stalls(now, waitingSince: _t(30)), [(_t(30), now)]);
      expect(
        r.stalls(_t(30).add(_ms(800)), waitingSince: _t(30)),
        isEmpty,
        reason: 'under a second, nothing is unusual yet',
      );
    });

    test('a column is drawn only where something answered inside it — the '
        'line and the floor never run on into a stall', () {
      final r = _reading(List.filled(30, 170));
      // Eight seconds after the last answer, nothing has answered since.
      final cols = r.columns(_t(30).add(const Duration(seconds: 8)));
      final last = cols.lastIndexWhere((c) => c.p50 != null);
      final after = cols.skip(last + 1).toList();
      expect(after.length, inInclusiveRange(7, 8));
      expect(after.every((c) => c.p50 == null && c.floor == null), isTrue);
    });

    test('the drawn past changes only by a whole column or a new outcome — '
        'never by the poll\'s half-second phase', () {
      final r = _reading(List.generate(60, (i) => _airMinute[i]));
      final now = KvLatencyReading.anchor(_t(60));
      List<int?> medians(DateTime t) => [for (final c in r.columns(t)) c.p50];
      expect(
        medians(now.add(KvLatencyReading.cadence)),
        medians(now),
        reason: 'no new outcome, half a second on: nothing moves',
      );
      final shifted = medians(now.add(const Duration(seconds: 1)));
      expect(
        shifted.sublist(0, 59),
        medians(now).sublist(1),
        reason: 'a second on: exactly one column scrolled',
      );
    });

    test('every mark clears 3:1 on its ground, computed from the tokens '
        '(WCAG 1.4.11, BG-14)', () {
      double ratio(Color a, Color b) {
        final la = a.computeLuminance();
        final lb = b.computeLuminance();
        final hi = la > lb ? la : lb;
        final lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      final band = Color.alphaBlend(
        KvColor.inkMeta.withValues(alpha: KvLatencyHistory.bandAlpha),
        KvColor.plate,
      );
      expect(ratio(band, KvColor.plate), greaterThanOrEqualTo(3.0));
      expect(ratio(KvColor.ink, band), greaterThanOrEqualTo(3.0));
      expect(ratio(KvColor.inkMeta, KvColor.plate), greaterThanOrEqualTo(3.0));
      expect(ratio(KvColor.risk, KvColor.plate), greaterThanOrEqualTo(3.0));
    });

    test('the band is weighted by time, and the floor is the path at that '
        'moment', () {
      final r = _reading([200, 200, 200, 150, 200, 200, 200]);
      final last = r.columns(_t(7)).last;
      expect(last.p50, 200);
      expect(last.floor, 150);
      expect(last.p10, lessThanOrEqualTo(last.p50!));
      expect(last.p90, greaterThanOrEqualTo(last.p50!));
    });
  });
}

Duration _ms(int ms) => Duration(milliseconds: ms);
