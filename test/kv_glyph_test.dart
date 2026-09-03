import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';

/// Records what a painter actually asked the canvas to draw, which is the only
/// way to assert the §2 stroke law and the "every mark honours its tone" rule
/// without a golden file — and a golden could not tell a tinted stroke from an
/// untinted one anyway, because a wrong tone is still a valid image.
class _RecordingCanvas implements Canvas {
  final List<Paint> paints = <Paint>[];

  @override
  void drawPath(Path path, Paint paint) => paints.add(paint);

  @override
  void drawCircle(Offset c, double radius, Paint paint) => paints.add(paint);

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => paints.add(paint);

  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) => paints.add(paint);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<Paint> _paintsFor(
  KvGlyph mark, {
  Color tone = KvColor.inkMeta,
  double size = KvGlyphSpec.grid,
}) {
  final canvas = _RecordingCanvas();
  KvGlyphPainter(mark, tone: tone).paint(canvas, Size.square(size));
  return canvas.paints;
}

/// Counts the marks a glyph actually lays down: one per path contour, one per
/// arc, and every dot in a dot field.
class _Census implements Canvas {
  int contours = 0;
  int arcs = 0;
  int dots = 0;

  @override
  void drawPath(Path path, Paint paint) =>
      contours += path.computeMetrics().length;

  @override
  void drawCircle(Offset c, double radius, Paint paint) => dots += 1;

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => contours += 1;

  @override
  void drawArc(Rect r, double s, double sw, bool useCenter, Paint paint) =>
      arcs += 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

_Census _censusOf(KvGlyph mark) {
  final canvas = _Census();
  KvGlyphPainter(mark).paint(canvas, const Size.square(KvGlyphSpec.grid));
  return canvas;
}

void main() {
  group('KvGlyphSpec — the drawn set (§2, D-205)', () {
    test('every mark paints something', () {
      for (final mark in KvGlyph.values) {
        expect(
          _paintsFor(mark),
          isNotEmpty,
          reason: '$mark drew nothing — an enum case with no arm',
        );
      }
    });

    test('every mark honours its tone, in every paint it makes', () {
      // The scar this pins: `navDots` painted its dots with a hard-coded
      // colour while every other mark took `tone`, so a dimmed nav mark
      // rendered at full brightness with no error anywhere.
      const tone = KvColor.etch;
      for (final mark in KvGlyph.values) {
        for (final paint in _paintsFor(mark, tone: tone)) {
          expect(
            paint.color.toARGB32(),
            tone.toARGB32(),
            reason: '$mark painted with a colour that is not its tone',
          );
        }
      }
    });

    // BG-25 was amended in v4.2 (D-247): Lucide's 2 dp nominal thins on the
    // tinted dark, so the set is redrawn at 2.5 with ROUND caps and joins.
    // v3.1's 1.75 square-capped machined stroke is retired. The cap and join
    // are read from KvGlyphSpec rather than restated, so the law has one home.
    test('strokes are 2.5dp round-capped on the 24dp grid (BG-25, v4.2)', () {
      expect(KvGlyphSpec.stroke, 2.5);
      expect(KvGlyphSpec.cap, StrokeCap.round);
      expect(KvGlyphSpec.join, StrokeJoin.round);
      for (final mark in KvGlyph.values) {
        final stroked = _paintsFor(
          mark,
        ).where((p) => p.style == PaintingStyle.stroke);
        for (final paint in stroked) {
          expect(paint.strokeWidth, KvGlyphSpec.stroke, reason: '$mark');
          expect(paint.strokeCap, KvGlyphSpec.cap, reason: '$mark');
          expect(paint.strokeJoin, KvGlyphSpec.join, reason: '$mark');
        }
      }
    });

    test('the stroke scales with the glyph, and is computed not asserted', () {
      // A glyph rendered smaller is a scaled 24dp glyph, not a thinner one.
      expect(KvGlyphIcon.strokeFor(KvGlyphSpec.grid), KvGlyphSpec.stroke);
      expect(
        KvGlyphIcon.strokeFor(KvGlyphSpec.grid / 2),
        KvGlyphSpec.stroke / 2,
      );
      final half = _paintsFor(
        KvGlyph.chevron,
        size: KvGlyphSpec.grid / 2,
      ).single;
      expect(half.strokeWidth, KvGlyphIcon.strokeFor(KvGlyphSpec.grid / 2));
    });

    test('no mark drifts into an illustration', () {
      // §2 says "1–3 strokes", and that is a design judgement a device settles
      // — `selfSend` is two arrows a person reads as one gesture and four
      // polylines a canvas reads as four. So this does NOT pretend to check
      // the law. It is a **drift ceiling**, set one step above where the
      // set actually sits today (max 4 contours, max 4 dots), so a glyph that
      // grows a fifth line reds here and gets looked at on glass.
      for (final mark in KvGlyph.values) {
        final census = _censusOf(mark);
        expect(
          census.contours + census.arcs,
          lessThanOrEqualTo(4),
          reason:
              '$mark draws ${census.contours} lines and ${census.arcs} '
              'arcs — take it back to the device before raising this',
        );
        expect(census.dots, lessThanOrEqualTo(4), reason: '$mark');
      }
    });

    testWidgets('decorative by default, named only when asked', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              KvGlyphIcon(KvGlyph.money),
              KvGlyphIcon(KvGlyph.lock, semanticLabel: 'Locked'),
            ],
          ),
        ),
      );
      expect(find.bySemanticsLabel('Locked'), findsOneWidget);
      // The undecorated one contributes no node at all — a mark that announced
      // itself would announce it beside the words that already say it (BG-7).
      expect(find.bySemanticsLabel('money'), findsNothing);
      handle.dispose();
    });

    testWidgets('renders at the size it is given', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: KvGlyphIcon(KvGlyph.diamond, size: 18)),
        ),
      );
      expect(tester.getSize(find.byType(CustomPaint).last), const Size(18, 18));
    });

    test('shouldRepaint tracks both inputs', () {
      const a = KvGlyphPainter(KvGlyph.money);
      expect(a.shouldRepaint(const KvGlyphPainter(KvGlyph.chat)), isTrue);
      expect(
        a.shouldRepaint(const KvGlyphPainter(KvGlyph.money, tone: KvColor.ink)),
        isTrue,
      );
      expect(a.shouldRepaint(const KvGlyphPainter(KvGlyph.money)), isFalse);
    });
  });
}
