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
  Path chevron(double k) => Path()
    ..moveTo(32 * k, 20.5 * k)
    ..lineTo(59 * k, 49.5 * k)
    ..lineTo(29.5 * k, 81 * k);

  group('KvMark — the locked geometry (§4a)', () {
    test('the stroke ladder is exactly as §4a.1 declares it', () {
      // §4a.1's ladder, pinned. **Its stated rationale is wrong** — see the
      // clearance test below and Bible §9.12 — but the ladder is what ships
      // and the mark is LOCKED, so this pins the shipped values rather than
      // the values the rationale implies.
      expect(KvMark.strokeUnitsFor(176), 12);
      expect(KvMark.strokeUnitsFor(96), 12);
      expect(KvMark.strokeUnitsFor(64), 14);
      expect(KvMark.strokeUnitsFor(40), 14);
      expect(KvMark.strokeUnitsFor(28), 16);
      expect(KvMark.strokeUnitsFor(24), 16);
      for (var s = 24.0; s <= 176; s += 1) {
        expect(
          KvMark.strokeUnitsFor(s),
          lessThanOrEqualTo(KvMark.strokeUnitsFor(s - 1) + 0.0001),
          reason: 'stroke must be monotonically non-increasing in size at $s',
        );
      }
    });

    test('the clearance between stem and chevron, measured and pinned', () {
      // **§4a defines the mark as "two strokes that never touch." At strokes 14
      // and 16 they touch, and at 16 they overlap.** Measured here rather than
      // asserted, and pinned to what the LOCKED geometry actually delivers —
      // not to §4a.1's ">= 2 units at every size", which the shipped mark fails
      // at four of its seven canon sizes. Recorded as Bible §9.12; the mark is
      // locked, so the ladder is a founder decision and not this test's to make.
      //
      // The guard still bites: any change to either path, or to the stroke
      // ladder, moves these numbers and reddens.
      const grid = 1.0; // measure in raw grid units
      final chevPoints = <Offset>[];
      for (final metric in chevron(grid).computeMetrics()) {
        for (var d = 0.0; d <= metric.length; d += 0.25) {
          chevPoints.add(metric.getTangentForOffset(d)!.position);
        }
      }
      var centreline = double.infinity;
      for (final metric in stem(grid).computeMetrics()) {
        for (var d = 0.0; d <= metric.length; d += 0.25) {
          final p = metric.getTangentForOffset(d)!.position;
          for (final q in chevPoints) {
            final gap = (p - q).distance;
            if (gap < centreline) centreline = gap;
          }
        }
      }
      // The two paths' closest approach, centre to centre. §4a says "≈ 15".
      // Flutter flattens a cubic into segments, so this lands a few hundredths off
      // the analytic 14.3737. The tolerance is set at 0.15 — two orders tighter
      // than any real change to either path would produce.
      expect(centreline, closeTo(14.374, 0.15));

      // Clearance = centreline - stroke (half a stroke painted from each side).
      double clearance(double size) => centreline - KvMark.strokeUnitsFor(size);

      expect(clearance(176), closeTo(2.374, 0.15));
      expect(clearance(96), closeTo(2.374, 0.15));
      expect(clearance(64), closeTo(0.374, 0.15)); // a hairline
      expect(clearance(40), closeTo(0.374, 0.15));
      expect(clearance(28), closeTo(-1.626, 0.15)); // OVERLAPPING
      expect(clearance(24), closeTo(-1.626, 0.15));

      // The finding, stated as an executable claim so it cannot be forgotten:
      // the ladder's stated purpose is inverted. Climbing the weight CLOSES the
      // gap, because the centreline distance is fixed.
      expect(
        clearance(24),
        lessThan(clearance(176)),
        reason:
            'the small mark has LESS clearance, not more (§4a\'s rationale '
            'says the climb makes "the gap survive"; it does the opposite)',
      );
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
        // And the two locked path strings are actually the ones in the file.
        expect(src, contains('moveTo(71.5 * k, 15.5 * k)'));
        expect(
          src,
          contains(
            'cubicTo(74 * k, 39 * k, 74 * k, 62 * k, 71.5 * k, 84.5 * k)',
          ),
        );
        expect(src, contains('moveTo(32 * k, 20.5 * k)'));
        expect(src, contains('lineTo(59 * k, 49.5 * k)'));
        expect(src, contains('lineTo(29.5 * k, 81 * k)'));
      },
    );
  });
}
