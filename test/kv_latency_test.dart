import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_cadence.dart';
import 'package:kaspaverse/src/ui/widgets/kv_latency.dart';

import 'support/preview_harness.dart';

/// **The latency reading** (`T5`, §4's latency re-spec) — a measurement, not a
/// loader, and the distinction is the reason this is not [KvCadence].
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
      // The law and the picture were checked against each other rather than
      // one being assumed (D-266).
      final tier = KvLatency.tierFor(151);
      expect(tier.bars, 3);
      expect(tier.hue, KvColor.warn);
      expect(tier.word, 'Slow');
    });

    test(
      'the bars are the render\'s staircase, not the Bible\'s transcription',
      () {
        // `T5`, measured: 24 · 30 · 36 · 42 · 48 dp, 6 wide, gap 4. §4 said
        // `12→36`; the render is the original and wins (D-259).
        expect(KvLatency.barHeights, [24, 30, 36, 42, 48]);
        expect(KvLatency.barWidth, 6);
        expect(KvLatency.barGap, 4);
        // A rising staircase, so the meter reads as strength before a colour is
        // seen (BG-25) — and it is derived, never asserted (L121).
        expect(KvLatency.height, 48);
        expect(KvLatency.width, 5 * 6 + 4 * 4);
      },
    );
  });

  group('BG-8 · an absent reading is its own face', () {
    test('null is no reading, never a zero', () {
      final tier = KvLatency.tierFor(null);
      expect(
        tier.bars,
        0,
        reason: 'nothing is lit for a measurement nobody has',
      );
      expect(tier.word, 'No reading');
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

    testWidgets('the figure renders a dash and the staircase is dark', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KvLatency(milliseconds: null)));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      final lit = _litBars(tester);
      expect(lit, 0);
    });

    testWidgets('the dot stops breathing when there is nothing to report', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const KvLatencyWord(milliseconds: null)));
      await tester.pump();
      expect(find.text('No reading'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the reading is one hue across four channels (BG-7)', () {
    testWidgets('number, unit, word, dot and bars agree', (tester) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: [
              KvLatencyWord(milliseconds: 151),
              KvLatency(milliseconds: 151),
            ],
          ),
        ),
      );
      // `pump`, not `pumpAndSettle`: the dot breathes for as long as there is
      // a reading, which is the widget doing its job (BG-8) and would hang a
      // settle forever.
      await tester.pump();
      expect(find.text('Slow'), findsOneWidget);
      // **The figure is a rolling readout**, so it is one slot per character
      // and no single `Text` carries `151`. The widget speaks the whole reading
      // as one sentence — a screen reader must not hear digit soup (§11) — and
      // that sentence is what a test can hold onto.
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        find.bySemanticsLabel('Connection latency 151 milliseconds. Slow.'),
        findsOneWidget,
      );
      handle.dispose();
      expect(find.text('ms'), findsOneWidget);
      expect(_litBars(tester), 3);
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        final d = t.data ?? '';
        if (d == 'ms' || d == 'Slow' || RegExp(r'^[0-9]$').hasMatch(d)) {
          expect(
            t.style?.color,
            KvColor.warn,
            reason: '"$d" is not in the tier\'s hue',
          );
        }
      }
    });

    testWidgets('every label clears the 11dp floor at 1.3x / 320dp', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(const KvLatency(milliseconds: 1234), textScale: 1.3),
      );
      await tester.pumpAndSettle();
      for (final t in tester.widgetList<Text>(find.byType(Text))) {
        expect(
          t.style?.fontSize ?? 11,
          greaterThanOrEqualTo(11),
          reason: '"${t.data}" renders under the readable floor (BG-14)',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  test('it is a different instrument from the loading meter (BG-21)', () {
    // One name for two meanings is what BG-21 forbids, and these two genuinely
    // are two objects: a hill that breathes while something is in flight, and a
    // staircase that stands still and reports a measurement.
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

/// Bars that are lit. **Scoped by geometry, not by colour alone** — the tier
/// dot is a `Container` too, and counting it made a three-bar reading assert
/// four.
int _litBars(WidgetTester tester) =>
    tester.widgetList<Container>(find.byType(Container)).where((c) {
      final d = c.decoration;
      if (d is! BoxDecoration || d.shape != BoxShape.rectangle) return false;
      if (c.constraints?.maxWidth != KvLatency.barWidth) return false;
      // The unlit tone is read from the widget, never restated here — it moved
      // off `etch` at UX-R3 because `etch` is 2.35:1 and the staircase's dark
      // bars are what make "three lit" readable as three OF FIVE (L164).
      return d.color != null && d.color != KvLatency.unlit;
    }).length;

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
