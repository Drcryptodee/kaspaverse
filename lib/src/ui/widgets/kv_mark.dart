// lib/src/ui/widgets/kv_mark.dart
// KaspaVerse mark — FINAL 2026-09-07 (Design Bible §4a / §4a.1, D-294).
// The two paths below ARE the mark, transcribed from the founder's own SVG
// artwork (D-294). Do not redraw, trace, tidy or substitute. Pure Dart: no
// asset, no icon font, no package (BG-16, BG-25).
//
// THE ARTWORK IS THE AUTHORITY, and this file is its transcription. That SVG is
// a 160 box: a disc at (80, 80) r 73.4 in `primary`, and the K on its own
// 100-unit grid placed by `translate(74 80) scale(1.18) translate(-50.5 -50)`
// at stroke 14, round caps and joins, in `plate`. Every ratio below is that
// transform solved for a disc of `size` dp, so the widget and the file agree by
// construction rather than by eye. **The one thing NOT taken from it is the
// glow** — the export blooms around the disc and the founder ruled to keep
// ours (`orbHalo`, §1.8): *"lets use our glow value but retain the exact design
// drawn."*
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
    this.haloAlpha,
  });

  /// Override the halo's strength. Null takes [KvMark.haloStrength]; the
  /// launcher tile passes [KvMark.tileHaloStrength].
  final double? haloAlpha;

  /// Disc diameter in dp. Canon: 176 · 120 · 96 · 64 · 40 · 28 · 24.
  final double size;
  final KvMarkStyle style;

  /// orbHalo in primaryMuted. Ignored below 24 dp (§1.8).
  final bool halo;

  /// Splash only: halo breathes 3.2 s. Respects disableAnimations.
  final bool breathe;

  /// The disc's diameter in the artwork's own 160 box (`r 73.4`). Every ratio
  /// on this class is the SVG's transform divided by it, so the widget cannot
  /// drift from the file it was transcribed from.
  static const double _artDisc = 146.8;

  /// The artwork's grid → SVG scale (`scale(1.18)`).
  static const double _artScale = 1.18;

  /// The 100-unit glyph grid as a fraction of the disc's diameter — the
  /// painter's box. **0.804, where it used to be 0.62**: the artwork sets the
  /// K's ink at 66 % of the disc's height, which is a nominal grid three
  /// quarters wider than the one the mark shipped with.
  static const double glyphBoxRatio = 100 * _artScale / _artDisc;

  /// How far LEFT of the disc's centre that box sits, as a fraction of the
  /// diameter. The artwork seats the K six units left of centre
  /// (`translate(74 80)` against a centre of 80) **and** its grid is centred on
  /// x 50.5 rather than 50, so the offset is `−(0.5 · 1.18 + 6) / 146.8`. It is
  /// not decoration: the K's ink is wider on the chevron's side, and the disc
  /// looks off-centre without it.
  static const double glyphShiftRatio = -(0.5 * _artScale + 6) / _artDisc;

  /// Stroke in 100-grid units: **14 at every size**, which is the number in the
  /// artwork (`stroke-width="14"`).
  ///
  /// The delivery's README asks for **16 below 40 dp** and it was drawn that
  /// way first. On the ladder it is visibly worse: the artwork's chevron apex
  /// already sits at x 64, *inside* the stem, so at 24 and 28 dp the extra two
  /// units close the counter between the arms and the K reads as one dark blob.
  /// The founder's instruction was *"retain the exact design drawn"*, and the
  /// design as drawn is 14. Same conclusion D-250 reached from the other
  /// geometry, for a different reason: there, weight ate a gap; here it eats a
  /// counter.
  static double strokeUnitsFor(double size) => 14;

  /// The halo's strength on an orb inside the app. §1.8's number.
  static const double haloStrength = 0.36;

  /// **The halo's strength on the launcher tile — a third of the app's.**
  ///
  /// Founder, on glass 2026-09-07: *"the surroundings of the orb is kinda
  /// green. could you dim the glow and make it faint so that the deep dark
  /// color can pop."* An icon is looked at against a wallpaper at 48 dp, where
  /// a halo built for a 176 dp orb on true black reads as a green wash rather
  /// than as light coming off a disc.
  static const double tileHaloStrength = 0.12;

  /// Halo per §1.8: 14 px @ 36 % at 40 dp, 8 px at 25, none below 24.
  static List<BoxShadow> orbHalo(double size, {double t = 0, double? alpha}) {
    if (size < 24) return const [];
    final blur = (size * 0.35).clamp(8.0, 40.0) + t * (size * 0.65);
    final strength = (alpha ?? haloStrength) + t * 0.22;
    return [
      BoxShadow(
        color: KvColor.primaryMuted.withValues(alpha: strength),
        blurRadius: blur,
      ),
    ];
  }

  /// The launcher tile's corner, as a fraction of its side — **measured off the
  /// founder's own icon** (the straight top edge begins at 250 of 1024). The
  /// artwork's corner is a squircle and this is a circular arc, which is the
  /// one place the tile is a reading of the picture rather than a copy: it
  /// meets the edge at the same point and eases into it a shade sooner.
  static const double tileRadiusRatio = 0.244;

  /// The disc inside that tile.
  ///
  /// **0.505 — a quarter smaller than the 0.674 measured off the artwork**
  /// (founder, on glass 2026-09-07: *"perhaps make the orb smaller. make it
  /// like 25 % smaller than it is currently on the app icon"*). It gives the
  /// `abyss` ground room to read as ground, which is the whole point of the
  /// containment, and it puts the disc comfortably inside the 66 % an adaptive
  /// mask always shows even before the halo is counted.
  static const double tileDiscRatio = 0.505;

  @override
  Widget build(BuildContext context) {
    final glyphBox = size * glyphBoxRatio;
    final units = strokeUnitsFor(size);
    switch (style) {
      case KvMarkStyle.bare:
        return RepaintBoundary(
          child: SizedBox.square(
            dimension: size,
            child: Center(
              child: _Glyph(
                size: size,
                glyphBox: glyphBox,
                units: units,
                ink: KvColor.primaryMuted,
              ),
            ),
          ),
        );
      case KvMarkStyle.tile:
        // **This IS the app icon** — the founder's own words for it: *"the logo,
        // glow, in a rounded corner containment"*. It used to be a fixed 64 dp
        // object with a `plateEdge` rim, drawn from §4a; the rim is gone because
        // the artwork has none, and the size is free because the launcher wants
        // it at five densities and the About screen wants it small. **One tile,
        // one set of ratios**: two would be how the icon on the home screen and
        // the icon in the app start disagreeing (BG-21), and the launcher
        // rasters are generated from this very widget so they cannot drift from
        // it (D-294).
        return RepaintBoundary(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: KvColor.abyss,
              borderRadius: BorderRadius.circular(size * tileRadiusRatio),
            ),
            alignment: Alignment.center,
            child: KvMark(
              size: size * tileDiscRatio,
              halo: halo,
              haloAlpha: tileHaloStrength,
            ),
          ),
        );
      case KvMarkStyle.orb:
        final disc = _Orb(
          size: size,
          glyphBox: glyphBox,
          units: units,
          halo: halo,
          alpha: haloAlpha,
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
    this.alpha,
  });
  final double size, glyphBox, units, t;
  final double? alpha;
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
          boxShadow: halo ? KvMark.orbHalo(size, t: t, alpha: alpha) : const [],
        ),
        alignment: Alignment.center,
        // **`abyss`, the Deep ground** — founder's ruling on glass
        // 2026-09-07: *"let the strokes also use that color … the ground
        // #0a0d0d color should be law for every deep cos the teal comes out
        // well against it."* The artwork paints `plate` (#121717); this is
        // four values darker and it is the one place the picture gives way, on
        // his word rather than on ours.
        child: _Glyph(
          size: size,
          glyphBox: glyphBox,
          units: units,
          ink: KvColor.abyss,
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
        glyphBox: widget.size * KvMark.glyphBoxRatio,
        units: KvMark.strokeUnitsFor(widget.size),
        halo: true,
        t: curved.value,
      ),
    );
  }
}

/// The K, in the seat the artwork gives it: a `glyphBox` square shifted left of
/// the disc's centre by [KvMark.glyphShiftRatio]. Extracted so the orb, the bare
/// mark and the breathing splash cannot each place it slightly differently.
class _Glyph extends StatelessWidget {
  const _Glyph({
    required this.size,
    required this.glyphBox,
    required this.units,
    required this.ink,
  });

  final double size, glyphBox, units;
  final Color ink;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: Offset(size * KvMark.glyphShiftRatio, 0),
    child: CustomPaint(
      size: Size.square(glyphBox),
      painter: _KPainter(ink, units),
    ),
  );
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

    // Chevron — **straight, and its apex reaches INTO the stem** (D-294,
    // `kaspaverse-mark.svg`: `M32 20.5 64 49.5 29.5 81`). The apex at x 64 with
    // a 14-unit stroke overlaps the stem's own band, so the two paths make a
    // join rather than a kiss — which is why the stroke may thicken at small
    // sizes without the K closing into one shape.
    //
    // The founder drew this and ruled it final on 2026-09-07: *"The logo is not
    // wrong. that is the perfect design i came up with."* It supersedes W2, the
    // curve-curve variant chosen from the rendered candidates at D-291 — an
    // earlier round of the same question, settled by the artwork.
    final chevron = Path()
      ..moveTo(32 * k, 20.5 * k)
      ..lineTo(64 * k, 49.5 * k)
      ..lineTo(29.5 * k, 81 * k);

    c.drawPath(stem, p);
    c.drawPath(chevron, p);
  }

  @override
  bool shouldRepaint(_KPainter o) =>
      o.ink != ink || o.strokeUnits != strokeUnits;
}
