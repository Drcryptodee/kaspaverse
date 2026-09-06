import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_mark.dart';

/// **`KvMark` is LOCKED** (Bible §4a, 2026-09-03, D-247). The two paths below
/// are the mark; they are not to be redrawn, traced, "cleaned up", optically
/// corrected or replaced with a font glyph, in Dart, Kotlin or SVG.
///
/// A lock with no test is a wish. These are the guards §4a.1 asks for, minus
/// the golden comparison against the adaptive-icon SVG — that raster does not
/// exist yet and is recorded as owed rather than faked (`UX_R_REGISTER.md` §5).
void main() {
  /// The two path strings from §4a, restated here **on purpose**. This is the
  /// one place in the codebase permitted to duplicate them: a guard that reads
  /// the value from the thing it guards cannot fail. If this test and
  /// `kv_mark.dart` disagree, the diff is the finding.
  Path stem(double k) => Path()
    ..moveTo(71.5 * k, 15.5 * k)
    ..cubicTo(74 * k, 39 * k, 74 * k, 62 * k, 71.5 * k, 84.5 * k);
  // **W2** (D-291): the arms reach the stem's own span and each carries a
  // one-unit bow toward the stem. Kept in step with `kv_mark.dart` by hand —
  // which is the point of measuring rather than asserting below.
  Path chevron(double k) => Path()
    ..moveTo(32 * k, 16 * k)
    ..cubicTo(42.04 * k, 26.33 * k, 51.04 * k, 37.5 * k, 59 * k, 49.5 * k)
    ..cubicTo(50.18 * k, 61.87 * k, 40.35 * k, 73.37 * k, 29.5 * k, 84 * k);

  group('KvMark — the locked geometry (§4a)', () {
    test('one stroke weight at every size (D-250, amended D-291)', () {
      // The v4.1 ladder (12 / 14 / 16) closed the gap it claimed to protect;
      // §9.12 has the measurement. One weight, and D-291 raises it to the
      // width at which the two paths MEET rather than clear each other.
      for (final size in const <double>[176, 120, 96, 64, 40, 28, 24]) {
        expect(
          KvMark.strokeUnitsFor(size),
          14.4,
          reason: 'the mark has one stroke weight; $size dp disagreed',
        );
      }
      // Constant, not a ladder that happens to agree on the canon sizes.
      for (var s = 20.0; s <= 200; s += 0.5) {
        expect(KvMark.strokeUnitsFor(s), 14.4, reason: 'at $s dp');
      }
    });

    test('the two strokes TOUCH, and the contact is measured (D-291)', () {
      // **§4a used to define the mark as "two strokes that never touch"** and
      // D-291 reverses that on the founder's word: *more weight, and touch at
      // the centre.* The property is the same shape as before — measured off
      // the paths, never asserted — with the sign flipped: what was a
      // clearance of 2.374 is now an overlap, and it is the SAME 14.374 that
      // decides both. D-250's arithmetic chose D-291's number.
      const grid = 1.0; // measure in raw grid units
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
      // The closest approach, centre to centre. The apex is unmoved at
      // (59, 49.5) and the stem is untouched, so this is still D-250's own
      // number — which is exactly why the stroke could be set from it.
      //
      // **Sampled at 0.1, not 0.25.** The coarser step missed the true minimum
      // by 0.04 and reported a CLEARANCE where the analytic geometry has an
      // overlap — the instrument disagreeing with the thing it measures, which
      // is the one failure a measured test must not have. The minimum sits at
      // the chevron's apex (an exact cubic endpoint, always sampled) against
      // the stem's own bow at (73.37, 49.46); analytically 14.37374.
      expect(
        centreline,
        closeTo(14.374, 0.15),
        reason: 'moving the apex would move the contact and unmake the stroke',
      );

      // Clearance = centreline - stroke (half a stroke painted from each
      // side). NEGATIVE now, by design: the strokes overlap.
      double clearance(double size) => centreline - KvMark.strokeUnitsFor(size);

      for (final size in const <double>[176, 120, 96, 64, 40, 28, 24]) {
        expect(
          clearance(size),
          lessThanOrEqualTo(0),
          reason: 'the two strokes must MEET at $size dp (§4a, D-291)',
        );
        // ...and only just. D-250 measured 16 as an overlap of 1.63 units,
        // where "the K read as one shape"; this is a fortieth of that, and the
        // guard is what keeps a future nudge from drifting toward it.
        expect(
          clearance(size).abs(),
          lessThan(0.2),
          reason: 'a KISS, not a weld; $size dp overlapped too far',
        );
      }
      // On glass at the tightest canon size the overlap is about
      // `0.026 * 24 * 0.0062` dp — four thousandths of a pixel. The contact is
      // real in the geometry and invisible as a blob, which is the brief.
      expect(clearance(24).abs() * 24 * 0.0062, lessThan(0.01));
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

    test('the mark reaches for no font, asset or icon package (BG-16, BG-25)', () {
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
      // And the two locked path strings are actually the ones in the file.
      expect(src, contains('moveTo(71.5 * k, 15.5 * k)'));
      expect(
        src,
        contains('cubicTo(74 * k, 39 * k, 74 * k, 62 * k, 71.5 * k, 84.5 * k)'),
      );
      // W2 (D-291): two cubics, not a polyline. The `lineTo` pair that
      // used to be here is gone on purpose — a chevron that reverted to
      // straight arms would pass every OTHER assertion in this file, so the
      // source strings are what pin the curve.
      expect(src, contains('moveTo(32 * k, 16 * k)'));
      expect(
        src,
        contains(
          'cubicTo(42.04 * k, 26.33 * k, 51.04 * k, 37.5 * k, 59 * k, 49.5 * k)',
        ),
      );
      expect(
        src,
        contains(
          'cubicTo(50.18 * k, 61.87 * k, 40.35 * k, 73.37 * k, 29.5 * k, 84 * k)',
        ),
      );
      expect(
        src,
        isNot(contains('lineTo')),
        reason: 'the chevron is drawn, not folded',
      );
    });
  });
}
