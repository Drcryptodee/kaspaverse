// lib/src/ui/widgets/kv_mark.dart
// KaspaVerse mark — LOCKED 2026-09-06 (Design Bible §4a / §4a.1, D-291).
// The two paths below ARE the mark. Do not redraw, trace, tidy or substitute.
// Pure Dart: no asset, no icon font, no package (BG-16, BG-25).
//
// NOTHING MIRRORS THESE COORDINATES. The header carried that claim from
// 2026-09-03 to 2026-09-06 naming `RevealActivity.kt` and an adaptive-icon SVG;
// neither is true. That file draws the recovery words and has no path data, and
// `android/` has no adaptive icon at all — the launcher is still five stock
// Flutter rasters (IDEAS_BACKLOG, 2026-09-06). A fence nobody can check is
// worse than none, so it is stated as it is: change this file and nothing else
// moves, until the icon beat gives it a mirror on purpose.

import 'package:flutter/material.dart';
import '../theme/tokens.dart'; // KvColor, KvMotion

enum KvMarkStyle { orb, bare, tile }

class KvMark extends StatelessWidget {
  const KvMark({
    super.key,
    required this.size,
    this.style = KvMarkStyle.orb,
    this.halo = true,
    this.breathe = false,
  });

  /// Disc diameter in dp. Canon: 176 · 120 · 96 · 64 · 40 · 28 · 24.
  final double size;
  final KvMarkStyle style;

  /// orbHalo in primaryMuted. Ignored below 24 dp (§1.8).
  final bool halo;

  /// Splash only: halo breathes 3.2 s. Respects disableAnimations.
  final bool breathe;

  /// Stroke in 100-grid units. **One weight at every size** (founder ruling,
  /// D-250, amended D-291).
  ///
  /// The v4.1 ladder climbed to 14 and 16 as the mark shrank, on the stated
  /// reasoning that a heavier stroke made "the gap survive". It does the
  /// opposite: the two paths' closest approach is **fixed at 14.374 units**, so
  /// every unit of stroke is a unit of gap spent, and at 16 they overlapped by
  /// 1.63 and the K read as one shape (Bible §9.12).
  ///
  /// **D-250's arithmetic is what chose this number; only its conclusion
  /// changed.** It set a flat 12 for *touching but not quite touching*; the
  /// founder asked on 2026-09-06 for *more weight and touch at the centre*,
  /// which is one move rather than two — two strokes centred 14.374 apart meet
  /// at exactly that width. **14.4 is a kiss**: the paths make contact at their
  /// closest point and overlap by 0.026 of a unit, which is a fortieth of a
  /// pixel at 176 dp. Chosen from fourteen rendered candidates, not argued —
  /// **D-291**, variant W2.
  /// Dial it here and nowhere else: below 14.374 the contact opens into a gap,
  /// and D-250's ceiling of 16 still holds.
  static double strokeUnitsFor(double size) => 14.4;

  /// Halo per §1.8: 14 px @ 36 % at 40 dp, 8 px at 25, none below 24.
  static List<BoxShadow> orbHalo(double size, {double t = 0}) {
    if (size < 24) return const [];
    final blur = (size * 0.35).clamp(8.0, 40.0) + t * (size * 0.65);
    final alpha = 0.36 + t * 0.22;
    return [
      BoxShadow(
        color: KvColor.primaryMuted.withValues(alpha: alpha),
        blurRadius: blur,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final glyphBox = size * 0.62;
    final units = strokeUnitsFor(size);
    switch (style) {
      case KvMarkStyle.bare:
        return RepaintBoundary(
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: CustomPaint(
                size: Size.square(glyphBox),
                painter: _KPainter(KvColor.primaryMuted, units),
              ),
            ),
          ),
        );
      case KvMarkStyle.tile:
        // **`tile` is a fixed 64 dp and ignores [size] — by spec, not by
        // oversight.** §4a defines the icon tile as one object: `abyss` 64,
        // radius 18, `plateEdge` rim, the 40 orb inside; there is no other size
        // of it. Documented rather than silently accepted (`ux-auditor`,
        // UX-R0), and asserted so a caller passing 24 finds out here instead of
        // wondering why nothing changed.
        assert(
          size == 64,
          'KvMarkStyle.tile is 64 dp by §4a; got $size. Use KvMarkStyle.orb '
          'for any other size.',
        );
        return Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: KvColor.abyss,
            // 18 is KvRadius.key — the tile shares the keypad key's rounding at
            // 27% of side, which is what §3 means by "the icon tile at 64".
            borderRadius: BorderRadius.circular(KvRadius.key),
            border: Border.all(color: KvColor.plateEdge),
          ),
          alignment: Alignment.center,
          child: const KvMark(size: 40),
        );
      case KvMarkStyle.orb:
        final disc = _Orb(
          size: size,
          glyphBox: glyphBox,
          units: units,
          halo: halo,
        );
        return breathe ? _Breathing(size: size, child: disc) : disc;
    }
  }
}

class _Orb extends StatelessWidget {
  const _Orb({
    required this.size,
    required this.glyphBox,
    required this.units,
    required this.halo,
    this.t = 0,
  });
  final double size, glyphBox, units, t;
  final bool halo;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: KvColor.primary, // flat — no radial, highlight or rim (BG-4)
          boxShadow: halo ? KvMark.orbHalo(size, t: t) : const [],
        ),
        alignment: Alignment.center,
        child: CustomPaint(
          size: Size.square(glyphBox),
          painter: _KPainter(KvColor.abyss, units),
        ),
      ),
    );
  }
}

/// Splash-only halo breathing — 1.6 s each way, KvMotion.curve (BG-9).
class _Breathing extends StatefulWidget {
  const _Breathing({required this.size, required this.child});
  final double size;
  final Widget child;
  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing>
    with SingleTickerProviderStateMixin {
  // Half of KvMotion.breathe: the halo's ROUND TRIP is 3.2 s (§3) and this
  // controller reverses, so one leg is 1.6 s. Derived from the token rather
  // than restated, so a change to the breathe tempo reaches the splash.
  static const _leg = Duration(milliseconds: KvMotion.breatheMs ~/ 2);

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _leg,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: KvMotion.curve);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, _) => _Orb(
        size: widget.size,
        glyphBox: widget.size * 0.62,
        units: KvMark.strokeUnitsFor(widget.size),
        halo: true,
        t: curved.value,
      ),
    );
  }
}

class _KPainter extends CustomPainter {
  const _KPainter(this.ink, this.strokeUnits);
  final Color ink;
  final double strokeUnits;

  @override
  void paint(Canvas c, Size s) {
    final k = s.width / 100; // 100-unit grid → dp
    final p = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeUnits * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Stem — a gentle bow: ends tuck toward the chevron, middle sits away.
    // **Untouched by D-291**, at the founder's word: *"the `|` already has a
    // suitable curve."*
    final stem = Path()
      ..moveTo(71.5 * k, 15.5 * k)
      ..cubicTo(74 * k, 39 * k, 74 * k, 62 * k, 71.5 * k, 84.5 * k);

    // Chevron — **W2** (D-291). Two moves from the straight polyline it was:
    // the arms reach the stem's own span (15.5 → 84.5 rather than 20.5 → 81),
    // which steepens them 43.0° → 38.9° off vertical; and each carries a
    // one-unit bow **toward the stem**, so the mark reads as a drawn arrowhead
    // rather than a folded line. Half the stem's own 1.9, which is what *"the
    // `>` gets 1% curve, not the other `|`"* asked for.
    //
    // The apex stays at (59, 49.5) — moving it would move the contact point,
    // and the contact is the whole reason the stroke is 14.4.
    final chevron = Path()
      ..moveTo(32 * k, 16 * k)
      ..cubicTo(42.04 * k, 26.33 * k, 51.04 * k, 37.5 * k, 59 * k, 49.5 * k)
      ..cubicTo(50.18 * k, 61.87 * k, 40.35 * k, 73.37 * k, 29.5 * k, 84 * k);

    c.drawPath(stem, p);
    c.drawPath(chevron, p);
  }

  @override
  bool shouldRepaint(_KPainter o) =>
      o.ink != ink || o.strokeUnits != strokeUnits;
}
