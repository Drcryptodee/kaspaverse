import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_mark.dart';

/// **`KvMark` is FINAL** (Bible §4a, D-294, founder's own artwork). The two
/// paths below are the mark; they are not to be redrawn, traced, "cleaned up",
/// optically corrected or replaced with a font glyph, in Dart, Kotlin or SVG.
///
/// A lock with no test is a wish. These are the guards §4a.1 asks for — and the
/// one §5 recorded as owed, the comparison against the artwork raster, is now
/// **built**: `test/preview/mark_artwork_probe_test.dart` renders the mark at
/// the SVG's own scale and `tools/mark_diff.py` differences the two. The last
/// run put the K's ink within **0.034 %** of the artwork's.
void main() {
  /// The two path strings from §4a, restated here **on purpose**. This is the
  /// one place in the codebase permitted to duplicate them: a guard that reads
  /// the value from the thing it guards cannot fail. If this test and
  /// `kv_mark.dart` disagree, the diff is the finding.
  Path stem(double k) => Path()
    ..moveTo(71.5 * k, 15.5 * k)
    ..cubicTo(74 * k, 39 * k, 74 * k, 62 * k, 71.5 * k, 84.5 * k);
  // The artwork's own polyline (`M32 20.5 64 49.5 29.5 81`). Kept in step with
  // `kv_mark.dart` by hand — which is the point of measuring rather than
  // asserting below.
  Path chevron(double k) => Path()
    ..moveTo(32 * k, 20.5 * k)
    ..lineTo(64 * k, 49.5 * k)
    ..lineTo(29.5 * k, 81 * k);

  group('KvMark — the locked geometry (§4a)', () {
    test('the stroke is 13, flat, at every size', () {
      // **The artwork draws 14; the founder took it to 13 on 2026-09-09** —
      // *"maybe the inverted k stroke a little smaller? just a tiny bit
      // smaller"* — which is one unit on the 100-grid, the smallest change it
      // can express.
      //
      // What this test has always been FOR is the flatness, not the number.
      // The delivery's README asks for 16 below 40 dp and the mark was drawn
      // that way first; it reads as a blob at 24 and 28, because the artwork's
      // apex sits inside the stem so extra weight closes the counter between
      // the chevron's arms. Thirteen moves the other way and the small end
      // gets better — which is checked, not assumed, by the join assertion
      // below and by `mark_candidates_test`'s ladder.
      for (final size in const <double>[176, 120, 96, 64, 40, 28, 24, 16]) {
        expect(KvMark.strokeUnitsFor(size), 13, reason: 'at $size dp');
      }
      // Flat, not a ladder that happens to agree on the canon sizes.
      for (var s = 16.0; s <= 200; s += 0.5) {
        expect(KvMark.strokeUnitsFor(s), 13, reason: 'at $s dp');
      }
    });

    test('the K sits where the artwork puts it, not where it is convenient', () {
      // `translate(74 80) scale(1.18) translate(-50.5 -50)` inside a 160 box
      // whose disc is r 73.4, solved for a disc of `size` dp. Restated here on
      // purpose — a guard that reads its expectation from the thing it guards
      // cannot fail.
      expect(KvMark.glyphBoxRatio, closeTo(100 * 1.18 / 146.8, 1e-12));
      expect(KvMark.glyphShiftRatio, closeTo(-(0.59 + 6) / 146.8, 1e-12));
      // Which is to say: a grid three quarters wider than the 0.62 the mark
      // shipped with, seated 4.5 % of the diameter left of centre because the
      // K's ink is wider on the chevron's side.
      expect(KvMark.glyphBoxRatio, closeTo(0.8038, 0.0002));
      expect(KvMark.glyphShiftRatio, closeTo(-0.0449, 0.0002));
    });

    test('the chevron JOINS the stem, and the overlap is measured', () {
      // **The artwork's apex reaches into the stem.** Measured off the paths,
      // never asserted: the closest centre-to-centre approach is well inside
      // one stroke width, so the two shapes fuse at the join at every size —
      // which is what lets the stroke thicken at 24 dp without the K reading as
      // one blob (the thing D-250's ladder actually got wrong was a geometry
      // where the paths merely kissed).
      //
      // Sampled at 0.1. The coarser 0.25 step once missed a true minimum by
      // 0.04 and reported a clearance where the geometry had an overlap — the
      // instrument disagreeing with the thing it measures.
      const grid = 1.0;
      final chevPoints = <Offset>[];
      for (final metric in chevron(grid).computeMetrics()) {
        for (var d = 0.0; d <= metric.length; d += 0.1) {
          chevPoints.add(metric.getTangentForOffset(d)!.position);
        }
      }
      var centreline = double.infinity;
      for (final metric in stem(grid).computeMetrics()) {
        for (var d = 0.0; d <= metric.length; d += 0.1) {
          final p = metric.getTangentForOffset(d)!.position;
          for (final q in chevPoints) {
            final gap = (p - q).distance;
            if (gap < centreline) centreline = gap;
          }
        }
      }
      // The apex (64, 49.5) against the stem's own bow at about (73.4, 49.5).
      expect(
        centreline,
        closeTo(9.4, 0.3),
        reason: 'moving the apex changes what kind of mark this is',
      );

      // Overlap = stroke − centreline, half a stroke painted from each side.
      // Positive at every canon size, which is what "join" means — and this is
      // the assertion that makes a stroke change safe to take on his word: at
      // 13 the overlap is 3.6 units, so the chevron still MEETS the stem. It is
      // also the floor a further thinning would hit first.
      for (final size in const <double>[176, 120, 96, 64, 40, 28, 24]) {
        expect(
          KvMark.strokeUnitsFor(size) - centreline,
          greaterThan(3),
          reason: 'the chevron must MEET the stem at $size dp (§4a, D-294)',
        );
      }
    });

    testWidgets('the orb is FLAT — no gradient, highlight or rim (BG-4)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: KvMark(size: 96))),
        ),
      );
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(KvMark),
              matching: find.byType(Container),
            )
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.shape, BoxShape.circle);
      expect(decoration.color, KvColor.primary);
      expect(decoration.gradient, isNull, reason: 'no radial (BG-4, §8)');
      expect(decoration.border, isNull, reason: 'no rim (BG-4, §8)');
      // The halo is the ONE shadow permitted here, and it is primaryMuted —
      // never primary (§1.8: the light around the mark is softer than the mark).
      for (final shadow in decoration.boxShadow ?? const <BoxShadow>[]) {
        expect(
          shadow.color.toARGB32() & 0x00FFFFFF,
          KvColor.primaryMuted.toARGB32() & 0x00FFFFFF,
          reason: 'the halo is primaryMuted, never primary (§1.8, BG-32)',
        );
        expect(
          shadow.spreadRadius,
          0,
          reason: 'a halo blurs, it does not spread',
        );
      }
    });

    testWidgets('below 24 dp the halo is gone entirely (§1.8)', (tester) async {
      expect(KvMark.orbHalo(23), isEmpty);
      expect(KvMark.orbHalo(24), isNotEmpty);
    });

    testWidgets('the K is painted, never a font glyph (BG-16, BG-25)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: KvMark(size: 96))),
        ),
      );
      // A `Text` anywhere inside the mark would mean a typeface decides what the
      // brand looks like — the thing §4a exists to forbid.
      expect(
        find.descendant(of: find.byType(KvMark), matching: find.byType(Text)),
        findsNothing,
      );
      expect(
        find.descendant(of: find.byType(KvMark), matching: find.byType(Image)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(KvMark),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });

    test(
      'the mark reaches for no font, asset or icon package (BG-16, BG-25)',
      () {
        // BG-25's lint in the form the project can run: the K has one
        // implementation and it is two paths. Read the shipped file rather than
        // trusting a memory of it (item 0).
        final src = File('lib/src/ui/widgets/kv_mark.dart').readAsStringSync();
        for (final forbidden in const [
          'Icons.',
          'AssetImage',
          'SvgPicture',
          'IconData',
          'package:flutter_svg',
        ]) {
          expect(
            src.contains(forbidden),
            isFalse,
            reason:
                'kv_mark.dart must not reach for $forbidden — the K is two paths',
          );
        }
        // And the artwork's two path strings are actually the ones in the file:
        // `M71.5 15.5 C74 39 74 62 71.5 84.5` and `M32 20.5 64 49.5 29.5 81`.
        expect(src, contains('moveTo(71.5 * k, 15.5 * k)'));
        expect(
          src,
          contains(
            'cubicTo(74 * k, 39 * k, 74 * k, 62 * k, 71.5 * k, 84.5 * k)',
          ),
        );
        expect(src, contains('moveTo(32 * k, 20.5 * k)'));
        expect(src, contains('lineTo(64 * k, 49.5 * k)'));
        expect(src, contains('lineTo(29.5 * k, 81 * k)'));
      },
    );
  });
}
