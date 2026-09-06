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
      size: const PreviewSize('sheet', Size(1290, 500), 1.0),
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
  });

  final String label;
  final String note;

  /// Stroke in grid units. Contact begins at 14.374.
  final double stroke;

  /// The chevron's two free ends. Its apex is fixed at (59, 49.5) in every
  /// candidate — moving it would move the contact point and make the stroke
  /// comparison dishonest.
  final Offset upper, lower;

  /// Units of bow off each arm's chord. **Positive bows toward the stem**
  /// (convex right, an arrowhead); negative bows away (concave right).
  final double bow;

  static const apex = Offset(59, 49.5);

  /// The upper arm's lean off vertical, in degrees — the number "steeper" means.
  double get upperAngle =>
      math.atan((apex.dx - upper.dx) / (apex.dy - upper.dy)) * 180 / math.pi;
}

const _candidates = <_Geo>[
  _Geo(
    label: 'A · shipped',
    note: 'stroke 12 · straight · 2.37 clear',
    stroke: 12,
    upper: Offset(32, 20.5),
    lower: Offset(29.5, 81),
  ),
  _Geo(
    label: 'B · his ask',
    note: 'stroke 14.4 · kisses · bow toward the stem',
    stroke: 14.4,
    upper: Offset(32, 16),
    lower: Offset(29.5, 84),
    bow: 1,
  ),
  _Geo(
    label: 'C · B, bowed away',
    note: 'the same, curved the other way',
    stroke: 14.4,
    upper: Offset(32, 16),
    lower: Offset(29.5, 84),
    bow: -1,
  ),
  _Geo(
    label: 'D · stronger',
    note: 'stroke 15 · steeper again · bow toward',
    stroke: 15,
    upper: Offset(34.5, 15.5),
    lower: Offset(32, 84.5),
    bow: 1,
  ),
  _Geo(
    label: 'E · steeper only',
    note: "stroke 14.4 · D's angle at B's weight",
    stroke: 14.4,
    upper: Offset(34.5, 15.5),
    lower: Offset(32, 84.5),
    bow: 1,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Tile 0: the REAL widget, so the painter below is checkable.
              _Tile(
                label: 'real KvMark',
                note: 'the shipped widget itself',
                child: const KvMark(size: 176, halo: false),
              ),
              for (final geo in _candidates)
                _Tile(
                  label: geo.label,
                  note: '${geo.note} · ${geo.upperAngle.toStringAsFixed(1)}°',
                  child: _Candidate(geo: geo, size: 176),
                ),
            ],
          ),
          const Spacer(),
          // The same five at the smallest canon size, magnified 5x. D-250's
          // whole reason for a flat stroke was that 24 dp is where the gap
          // dies; now that contact is WANTED, 24 dp is where it can blob.
          Row(
            children: [
              _Small(
                label: '24 dp ×5',
                child: const KvMark(size: 24, halo: false),
              ),
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
    width: 208,
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
    width: 208,
    child: Column(
      children: [
        SizedBox(
          height: 124,
          child: Center(child: Transform.scale(scale: 5, child: child)),
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
    c.drawPath(_arm(_Geo.apex, geo.lower, geo.bow, k), p);
  }

  @override
  bool shouldRepaint(_GeoPainter o) => o.geo != geo;
}
