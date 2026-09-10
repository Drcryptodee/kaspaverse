import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **The locked vault's emblem** — a `lock` inside a thin ring, under a faint
/// halo (`Unlock-selection.png`, founder 2026-09-09: *"a lock icon and a ring
/// around it, all with faint glow, its there"*).
///
/// **Why this is not [CeremonyMark].** That part draws a house mark on a
/// filled `plate` disc: the emblem of a custody *surface*. This draws a STATE
/// — the vault is sealed — and the render composes it the other way round: no
/// fill, a hairline ring, and light coming off it. Handing `CeremonyMark` a
/// ring and a glow would have made one part answer to two compositions, which
/// is the seam BG-21 closes. It is also not [KvMark]: that is the app's own
/// orb, and the app is not a state.
///
/// **The glow, and BG-32.** The law seats exactly two lights — the orb's halo
/// and an armed control's edge — and *if a third thing glows, the mark stops
/// being the mark*. This is not a third: the locked surface draws **no orb**,
/// and this stands in the orb's seat as the one emblem on the screen, so the
/// count the law protects is unchanged. It therefore wears the orb's own
/// light — `orbHalo`, `primaryMuted`, §1.8 — and nothing else on the screen
/// glows (the Unlock pill is a primary pill, not a glow pill). §1.8 is amended
/// to name this seat rather than the widget bent to fit it (D-259: the render
/// wins, and the Bible is what gets corrected).
///
/// **Measured off the render at 4×** (786 × 1704 = 393 × 852 dp):
///
/// - ring Ø **121 dp** measured → [size] **120**, the mark canon's own rung
///   (§4a.1: 176 · 120 · 96 · 64 · 40 · 28 · 24). A measurement inside a
///   pixel of a rung on the scale is that rung, not a new number.
/// - ring stroke 2 px = **1 dp**, `tealTint` (`#0F2E28`; sampled `#14312C`
///   over its own halo, which is the same colour lifted by the light it sits
///   in — `tealTintEdge` at `#164A40` is half again too bright to be it).
/// - glyph `primary` `#49EACB`, ink 34 × 39 dp.
/// - the bloom's HUE was solved against `primary` (α ≈ 0.05) and against
///   `primaryMuted` (α ≈ 0.065); the two differ by 3.6/255 in red at this
///   strength, below anything an eye or a screenshot can separate. **So
///   §1.8's rule decides it** — *the halo is `primaryMuted`, never `primary`*
///   — and the render is matched to within a rounding error while the law
///   stays whole. Where a render cannot distinguish two readings the law
///   picks; where it can, the render picks.
/// - its FALLOFF was solved against the frame, not estimated. The green/blue
///   delta over `abyss`, render against build, at radii from the ring's
///   centre:
///
///   | r dp |  24  |  32  |  40  |  56  |  72  |  88  | 104 | 120 | 136 |
///   |:--|--|--|--|--|--|--|--|--|--|
///   | render | 15 | 12 | 10 | 9 | 6 | 3 | 2 | 1 | 0 |
///   | build  | 13 | 12 | 11 | 8 | 4 | 3 | 1 | 1 | 0 |
///
///   Every sample is within 2/255. **The first cut was not**: it claimed the
///   bloom reached ground at ~135 dp and it actually died at ~97, because the
///   estimate was written from `orbHalo`'s spec rather than read off a frame —
///   and no frame could have contradicted it, since `renderSurface` painted
///   the whole catalogue with `debugDisableShadows` on until this sitting
///   fixed it (`ux-auditor`, UX-R7; L121 — "fine" is not a measurement).
class KvLockMark extends StatelessWidget {
  const KvLockMark({super.key, this.size = ring});

  /// The ring's diameter. The canon rung the render measures at.
  static const double ring = 120;

  /// The ring's stroke — a hairline, at every size.
  static const double stroke = 1;

  /// The glyph's box as a share of the ring.
  ///
  /// **Solved against the frame, not derived from the grid.** The render's
  /// padlock measures **33 x 38 dp of ink**; the first build drew 44 x 48 and
  /// the founder read the difference on glass. The redrawn `lock` path spans
  /// 19.74 of its 24 units, so 38 dp of ink needs a **46.2 dp box** — this is
  /// that, over the 120 dp ring.
  static const double glyphRatio = 0.385;

  /// **The bloom's radius, as a share of the ring** — the render is still lit
  /// at 120 dp from centre and reaches ground by about 136.
  static const double bloomRatio = 136 / ring * 2;

  /// **The falloff, as measured stops rather than as two summed blurs.**
  ///
  /// *Faint* is the founder's own word for this light — the same correction he
  /// made to the launcher tile on 2026-09-07 (*"could you dim the glow and
  /// make it faint so that the deep dark color can pop"*).
  ///
  /// **Why a gradient and not `BoxShadow`.** The first build stacked two
  /// `orbHalo`-family shadows, and on glass the founder read exactly what that
  /// costs: *"i can see some radial gradient but not fine and very smoothly in
  /// texture look"* (2026-09-10). Two gaussians summed on `abyss` band twice —
  /// once where each one's own 8-bit alpha steps, and again at the seam where
  /// they overlap — and at these alphas every step is a visible ring, because
  /// a delta of 1/255 is a whole quantisation level when the whole bloom is
  /// only 15. A single radial with the measured profile as its stops has one
  /// interpolation and no seam.
  ///
  /// Each stop is `alpha = greenDelta / (primaryMuted.g - abyss.g)` = the
  /// render's own measured green delta over 186, at that radius. The shape is
  /// therefore the render's, not a curve chosen to look like it.
  static const List<double> bloomStops = [
    0.0,
    24 / 136,
    32 / 136,
    40 / 136,
    56 / 136,
    72 / 136,
    88 / 136,
    104 / 136,
    120 / 136,
    1.0,
  ];

  static const List<double> bloomAlphas = [
    0.085,
    0.081,
    0.065,
    0.054,
    0.048,
    0.032,
    0.016,
    0.011,
    0.005,
    0.0,
  ];

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // **The bloom costs no layout.** It is more than twice the ring
          // across, and the door's rhythm is measured off the RING — an
          // emblem that reserved its own light would push the chip and the
          // `Locked at` line 150 dp down the screen.
          OverflowBox(
            // **`min` as well as `max`.** A `DecoratedBox` with no child takes
            // the SMALLEST size its constraints allow, and `OverflowBox`
            // leaves the minimum at zero — so the first cut painted a bloom
            // 0 dp across and the glow vanished entirely. Pinning both makes
            // the box the size it is being asked to be.
            minWidth: size * bloomRatio,
            minHeight: size * bloomRatio,
            maxWidth: size * bloomRatio,
            maxHeight: size * bloomRatio,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  stops: bloomStops,
                  colors: [
                    for (final a in bloomAlphas)
                      KvColor.primaryMuted.withValues(alpha: a),
                  ],
                ),
              ),
            ),
          ),
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              // No fill. The render draws ground inside the ring, and a plate
              // here would make this the ceremony mark it is deliberately not.
              border: Border.fromBorderSide(
                BorderSide(color: KvColor.tealTint, width: stroke),
              ),
            ),
            child: KvGlyphIcon(
              KvGlyph.lock,
              size: size * glyphRatio,
              tone: KvColor.primary,
              // The render's own weight. See [KvGlyphSpec.strokeFine].
              stroke: KvGlyphSpec.strokeFine,
            ),
          ),
        ],
      ),
    ),
  );
}
