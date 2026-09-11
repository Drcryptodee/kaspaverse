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

  /// The paints of zero-length lines — dots, the one stroke that may carry a
  /// second weight (§2a rule 6).
  final List<Paint> dots = <Paint>[];

  @override
  void drawPath(Path path, Paint paint) => paints.add(paint);

  @override
  void drawCircle(Offset c, double radius, Paint paint) => paints.add(paint);

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    paints.add(paint);
    if ((p2 - p1).distance < 0.05 * KvGlyphSpec.grid) dots.add(paint);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) => paints.add(paint);

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
  void drawRRect(RRect rrect, Paint paint) => contours += 1;

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
    test(
      'strokes are 2.5dp round-capped on the 24dp grid (BG-25, v4.2) — '
      'and a dot is the one stroke that may be heavier, bounded (§2a rule 6)',
      () {
        expect(KvGlyphSpec.stroke, 2.5);
        expect(KvGlyphSpec.cap, StrokeCap.round);
        expect(KvGlyphSpec.join, StrokeJoin.round);
        expect(KvGlyphSpec.dotWeightMax, 1.5);
        for (final mark in KvGlyph.values) {
          final canvas = _RecordingCanvas();
          KvGlyphPainter(
            mark,
          ).paint(canvas, const Size.square(KvGlyphSpec.grid));
          final stroked = canvas.paints.where(
            (p) => p.style == PaintingStyle.stroke,
          );
          for (final paint in stroked) {
            if (canvas.dots.contains(paint)) {
              // A zero-length stroke — a dot. The founder ruled the render's
              // keyhole over the one-weight law (2026-09-11); the fence is that
              // only a dot may take a second weight, and no more than this.
              expect(
                paint.strokeWidth,
                inInclusiveRange(
                  KvGlyphSpec.stroke,
                  KvGlyphSpec.stroke * KvGlyphSpec.dotWeightMax,
                ),
                reason: '$mark: a dot heavier than rule 6 allows',
              );
            } else {
              expect(paint.strokeWidth, KvGlyphSpec.stroke, reason: '$mark');
            }
            expect(paint.strokeCap, KvGlyphSpec.cap, reason: '$mark');
            expect(paint.strokeJoin, KvGlyphSpec.join, reason: '$mark');
          }
        }
      },
    );

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
      // The set is Lucide's own geometry, transcribed (§2a, D-261), so the
      // ceiling is where Lucide sits: `sliders-horizontal` is nine strokes and
      // is the densest mark the renders use. This does NOT pretend to check a
      // law. It is a **drift ceiling**, one step above the set today (max 9
      // contours, max 4 dots), so a glyph that grows past it reds here and
      // gets looked at on glass.
      for (final mark in KvGlyph.values) {
        final census = _censusOf(mark);
        expect(
          census.contours + census.arcs,
          lessThanOrEqualTo(10),
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

  group('kvSvgPath — the transcription is a copy (§2a rule 5)', () {
    // Both forms exist so a mark can be carried as lucide.dev publishes it.
    // The compact one is how `swords` writes its arcs; a tokeniser that read
    // `013` as thirteen would desync every number after it and draw a
    // different blade, silently.
    test('arc flags may run into the next number (SVG 1.1 §8.3.8)', () {
      final spaced = kvSvgPath('M3 5A2 2 0 0 1 3 5.172V3', 1);
      final compact = kvSvgPath('M3 5A2 2 0 013 5.172V3', 1);
      expect(compact.getBounds(), spaced.getBounds());
      expect(
        compact.computeMetrics().fold<double>(0, (a, m) => a + m.length),
        closeTo(
          spaced.computeMetrics().fold<double>(0, (a, m) => a + m.length),
          1e-9,
        ),
      );
    });

    test('a quadratic segment draws, absolute and relative', () {
      // Lucide's `flag` is the first mark in the set to use `q`; the parser
      // used to refuse it with "unsupported path command".
      final q = kvSvgPath('M4 4Q8 0 12 4q4 4 8 0', 1);
      expect(q.getBounds().width, closeTo(16, 1e-9));
      expect(q.computeMetrics().isNotEmpty, isTrue);
    });

    test('an unsupported command still refuses, by name', () {
      expect(
        () => kvSvgPath('M0 0T4 4', 1),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('unsupported path command T'),
          ),
        ),
      );
    });
  });
}
