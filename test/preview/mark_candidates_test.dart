import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_mark.dart';

import '../support/preview_harness.dart';

/// **The mark, up for judgement** — the founder's four asks drawn as candidates
/// beside the shipped mark, at 176 and again at 24, so he chooses from pictures
/// rather than from arithmetic.
///
/// His words (2026-09-06): *"make the strokes have a little more weight and
/// touch at the center, and the `>` gets a little more steep in the angle and
/// the `>` gets 1% curve, not the other `|` which already has a suitable
/// curve."*
///
/// **Weight and contact are one move.** D-250 measured the two locked paths'
/// closest approach at **14.374 units** — apex (59, 49.5) to the stem's own
/// midpoint (73.375, 50.375). Two strokes centred that far apart touch at
/// exactly width 14.374, so raising the stroke from the shipped flat 12 to
/// ≈14.4 buys both asks at once. D-250 also recorded that **16 overlapped by
/// 1.63 and the K read as one shape**, which fixes the ceiling: the whole
/// usable window is 14.4 (a kiss) to about 15.2 (deliberate contact).
///
/// **Steeper** is spent on length, not on width: lengthening the arms toward
/// the stem's own span (15.5 → 84.5) steepens them AND squares the chevron up
/// against the stem, where pulling their ends inward would steepen them by
/// making the mark narrower under a heavier stroke.
///
/// **The 1% curve** is a bow of one grid unit off each arm's chord — about half
/// the stem's own 1.9, which is what "not the other `|`" asks for. Its
/// DIRECTION is the one thing his words do not settle, so `B` and `C` are the
/// same candidate bowed each way and the sheet asks the question.
///
/// This file is a probe, not a fixture: it draws its own paths so `kv_mark.dart`
/// stays LOCKED until he rules. Tile 0 is the **real widget**, so the shipped
/// mark and this painter's copy of it sit side by side — if they differ, the
/// painter is lying and the sheet is worthless (L157).
void main() {
  setUpAll(loadBundledFonts);

  testWidgets('probe: the mark, candidates for judgement', (tester) async {
    await renderSurface(
      tester,
      name: 'probe__mark_candidates',
      size: const PreviewSize('sheet', Size(1160, 860), 1.0),
      child: const _Sheet(),
    );
  }, skip: !previewRequested);
}

/// One candidate's geometry on the 100-unit grid. The stem is not here: it is
/// identical in every candidate, because he is keeping its curve.
class _Geo {
  const _Geo({
    required this.label,
    required this.note,
    required this.stroke,
    required this.upper,
    required this.lower,
    this.bow = 0,
    double? bowLower,
  }) : _bowLower = bowLower;

  final String label;
  final String note;

  /// Stroke in grid units. Contact begins at 14.374.
  final double stroke;

  /// The chevron's two free ends. Its apex is fixed at (59, 49.5) in every
  /// candidate — moving it would move the contact point and make the stroke
  /// comparison dishonest.
  final Offset upper, lower;

  /// Units of bow off the UPPER arm's chord. **Positive bows toward the stem**
  /// (convex right, an arrowhead); negative bows away (concave right).
  final double bow;

  final double? _bowLower;

  /// The lower arm's bow; defaults to the upper's, so a symmetric mark states
  /// one number.
  double get bowLower => _bowLower ?? bow;

  static const apex = Offset(59, 49.5);

  /// The upper arm's lean off vertical, in degrees — the number "steeper" means.
  double get upperAngle =>
      math.atan((apex.dx - upper.dx) / (apex.dy - upper.dy)) * 180 / math.pi;
}

/// Ten candidates across three axes — **weight**, **angle**, **curve** — so the
/// founder chooses from pictures rather than from arithmetic, and so each axis
/// can be judged with the other two held still.
///
/// `A` is what ships. `J` is the minimal move: contact and nothing else. `F`
/// is his second ask verbatim — *"a variation where the `>` stroke is straight
/// instead of curved but the other stroke `|` retains its curve"* — and `G`,
/// `H` are that straight arm at the steeper angle and at more weight.
/// **The form matrix.** Weight is settled — every candidate here is at 14.4,
/// the stroke at which the two paths touch — so what is being chosen is
/// SHAPE: how far apart the chevron's two ends sit, and which arms curve.
///
/// The founder's new ask (2026-09-06): *"a variant where the `>` stroke is
/// brought closer together instead of wide — the angle brings the two strokes
/// together instead of apart."* That is the `tight` and `tighter` rows. He
/// also asked for the curve combinations by name: *"straight, curved, straight
/// and curve or curve curve, etc."*
///
/// Read it as a grid: **spread** down the rows (wide · tight · tighter),
/// **curve** across (straight · both toward · upper only · lower only · both
/// away).
const _candidates = <_Geo>[
  // ── wide: the ends at the stem's own span, 16 → 84 ──────────────────────
  _Geo(
    label: 'W1 · wide, straight',
    note: 'both arms straight',
    stroke: 14.4,
    upper: Offset(32, 16),
    lower: Offset(29.5, 84),
  ),
  _Geo(
    label: 'W2 · wide, curve curve',
    note: 'both bowed toward the stem',
    stroke: 14.4,
    upper: Offset(32, 16),
    lower: Offset(29.5, 84),
    bow: 1,
  ),
  _Geo(
    label: 'W3 · wide, curve + straight',
    note: 'upper bowed, lower straight',
    stroke: 14.4,
    upper: Offset(32, 16),
    lower: Offset(29.5, 84),
    bow: 1,
    bowLower: 0,
  ),
  _Geo(
    label: 'W4 · wide, straight + curve',
    note: 'upper straight, lower bowed',
    stroke: 14.4,
    upper: Offset(32, 16),
    lower: Offset(29.5, 84),
    bow: 0,
    bowLower: 1,
  ),
  _Geo(
    label: 'W5 · wide, bowed away',
    note: 'both curved outward',
    stroke: 14.4,
    upper: Offset(32, 16),
    lower: Offset(29.5, 84),
    bow: -1,
  ),
  // ── tight: the ends brought toward each other, 26 → 74 ──────────────────
  _Geo(
    label: 'T1 · tight, straight',
    note: 'his ask — ends drawn together',
    stroke: 14.4,
    upper: Offset(32, 26),
    lower: Offset(29.5, 74),
  ),
  _Geo(
    label: 'T2 · tight, curve curve',
    note: 'the same, both bowed',
    stroke: 14.4,
    upper: Offset(32, 26),
    lower: Offset(29.5, 74),
    bow: 1,
  ),
  _Geo(
    label: 'T3 · tight, curve + straight',
    note: 'upper bowed only',
    stroke: 14.4,
    upper: Offset(32, 26),
    lower: Offset(29.5, 74),
    bow: 1,
    bowLower: 0,
  ),
  _Geo(
    label: 'T4 · tight + long',
    note: 'ends together AND pushed left',
    stroke: 14.4,
    upper: Offset(24, 26),
    lower: Offset(21, 74),
  ),
  _Geo(
    label: 'T5 · tight + long, curved',
    note: 'the same, both bowed',
    stroke: 14.4,
    upper: Offset(24, 26),
    lower: Offset(21, 74),
    bow: 1,
  ),
  // ── tighter: 34 → 66, a properly acute V ────────────────────────────────
  _Geo(
    label: 'X1 · tighter, straight',
    note: 'ends closer still',
    stroke: 14.4,
    upper: Offset(32, 34),
    lower: Offset(29.5, 66),
  ),
  _Geo(
    label: 'X2 · tighter + long',
    note: 'acute, and reaching left',
    stroke: 14.4,
    upper: Offset(20, 34),
    lower: Offset(17, 66),
  ),
  _Geo(
    label: 'X3 · tighter + long, curved',
    note: 'the same, bowed toward',
    stroke: 14.4,
    upper: Offset(20, 34),
    lower: Offset(17, 66),
    bow: 1,
  ),
  _Geo(
    label: 'A · shipped',
    note: 'stroke 12, straight, clear',
    stroke: 12,
    upper: Offset(32, 20.5),
    lower: Offset(29.5, 81),
  ),
];

class _Sheet extends StatelessWidget {
  const _Sheet();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: KvColor.abyss,
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var row = 0; row < 3; row++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final geo in _candidates.skip(row * 5).take(5))
                  _Tile(
                    label: geo.label,
                    note: '${geo.note} · ${geo.upperAngle.toStringAsFixed(1)}°',
                    child: _Candidate(geo: geo, size: 140),
                  ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          const Spacer(),
          // Every candidate at the smallest canon size: 24 dp is where a
          // contact point can blob.
          Row(
            children: [
              // The REAL widget beside the painter's copy of it: if `A` and
              // `real` differ, this sheet is lying and nothing on it can be
              // judged (L157).
              _Small(label: 'real', child: const KvMark(size: 24, halo: false)),
              for (final geo in _candidates)
                _Small(
                  label: geo.label.split(' · ').first,
                  child: _Candidate(geo: geo, size: 24),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.note, required this.child});
  final String label, note;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 222,
    child: Column(
      children: [
        child,
        const SizedBox(height: 10),
        Text(label, style: _title),
        const SizedBox(height: 2),
        Text(note, textAlign: TextAlign.center, style: _meta),
      ],
    ),
  );
}

class _Small extends StatelessWidget {
  const _Small({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 74,
    child: Column(
      children: [
        SizedBox(
          height: 104,
          child: Center(child: Transform.scale(scale: 4, child: child)),
        ),
        Text(label, style: _meta),
      ],
    ),
  );
}

const _title = TextStyle(
  fontFamily: KvFont.ui,
  fontSize: 14,
  fontWeight: FontWeight.w600,
  color: KvColor.ink,
);
const _meta = TextStyle(
  fontFamily: KvFont.mono,
  fontSize: 11,
  height: 15 / 11,
  color: KvColor.inkMeta,
);

/// The orb, drawn exactly as `KvMark` draws it, over this file's own paths.
class _Candidate extends StatelessWidget {
  const _Candidate({required this.geo, required this.size});
  final _Geo geo;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      color: KvColor.primary,
    ),
    alignment: Alignment.center,
    child: CustomPaint(
      size: Size.square(size * 0.62),
      painter: _GeoPainter(geo),
    ),
  );
}

class _GeoPainter extends CustomPainter {
  const _GeoPainter(this.geo);
  final _Geo geo;

  /// A cubic from [a] to [b] whose midpoint sits [bow] units off the chord,
  /// on the side facing the stem. A cubic's midpoint deviation is 3/4 of its
  /// control offset, so the control points take 4/3 of the bow.
  Path _arm(Offset a, Offset b, double bow, double k) {
    final d = b - a;
    final len = d.distance;
    // (dy, -dx) is the normal pointing toward the stem for BOTH arms — the
    // upper arm leans down-right and the lower one down-left, and the rotation
    // lands right-of-travel in each case.
    final n = Offset(d.dy, -d.dx) / len * (bow * 4 / 3);
    final c1 = a + d / 3 + n;
    final c2 = a + d * (2 / 3) + n;
    return Path()
      ..moveTo(a.dx * k, a.dy * k)
      ..cubicTo(c1.dx * k, c1.dy * k, c2.dx * k, c2.dy * k, b.dx * k, b.dy * k);
  }

  @override
  void paint(Canvas c, Size s) {
    final k = s.width / 100;
    final p = Paint()
      ..color = KvColor.abyss
      ..style = PaintingStyle.stroke
      ..strokeWidth = geo.stroke * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // The stem, byte for byte as `kv_mark.dart` draws it — he is keeping it.
    c.drawPath(
      Path()
        ..moveTo(71.5 * k, 15.5 * k)
        ..cubicTo(74 * k, 39 * k, 74 * k, 62 * k, 71.5 * k, 84.5 * k),
      p,
    );
    c.drawPath(_arm(geo.upper, _Geo.apex, geo.bow, k), p);
    c.drawPath(_arm(_Geo.apex, geo.lower, geo.bowLower, k), p);
  }

  @override
  bool shouldRepaint(_GeoPainter o) => o.geo != geo;
}
