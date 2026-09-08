import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// The quiet emblem of a custody surface: a house mark on a `plate` disc.
///
/// **It takes a [KvGlyph], and that is the point of this file.** It used to
/// take an `IconData`, which made it the seam Material came back in through —
/// three onboarding call sites were handing `Icons.fingerprint` and
/// `Icons.shield_outlined` to the one part the design system exists to draw a
/// mark with, so BG-25's *every mark the app draws, it owns* was being broken
/// by the widget that enforces it. Closing the seam retires those call sites
/// by construction rather than one at a time (UX-R6).
///
/// **The disc is `plate`, measured** (`O6`, sampled at 4×: `#121717` under
/// both marks, the face `#49EACB` and the fingerprint `#A6B0AE`). It had been
/// `primaryMuted` at 12 % — a tinted disc from the era of eight surface tones
/// §1.1 retired, and about a step greener than the ground the render draws.
///
/// Vault-calm (BG-9): a plate, not a glow. §3 rations glow to primary actions
/// and live data. Decorative — excluded from semantics; the heading beside it
/// carries the meaning.
class CeremonyMark extends StatelessWidget {
  const CeremonyMark(
    this.mark, {
    super.key,
    this.size = solo,
    this.tone = KvColor.primaryMuted,
  });

  final KvGlyph mark;

  /// The disc's diameter. `O6` draws the biometrics pair at [disc].
  final double size;

  /// The glyph's ink.
  ///
  /// **`primaryMuted` by default, and `O6`'s lit half is the exception that
  /// passes `primary`.** §1.5 does not seat an illustrative ceremony mark
  /// among `primary`'s places, and a default of `primary` silently re-toned
  /// the locked-vault surface — a screen outside this group with no frame in
  /// this run. An exception belongs at the call site that earns it
  /// (`ux-auditor`, UX-R6).
  final Color tone;

  /// `O6` measured: two 104 dp discs across 192 dp — the pair's rung.
  static const double disc = 104;

  /// A mark standing alone keeps the 72 it has always had (the locked-vault
  /// surface, R7's). `O6` is the only seat that draws the bigger rung.
  static const double solo = KvSpace.xxl + KvSpace.l;

  /// The glyph's share of the disc — `O6`'s marks measure ~40 dp of ink, which
  /// on Lucide's 24 grid is a 52 dp box (both of these marks leave a margin
  /// inside the grid).
  static const double glyphRatio = 0.5;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: KvColor.plate,
      ),
      child: KvGlyphIcon(
        mark,
        size: size * glyphRatio,
        tone: tone,
        // §2a's weights by job: `fingerprint` and `face` are the two
        // illustrative marks, and at 52 dp the 2.5 default draws them as wire.
        stroke: _illustrative(mark) ? KvGlyphSpec.strokeIllustrative : null,
      ),
    ),
  );

  static bool _illustrative(KvGlyph mark) =>
      mark == KvGlyph.fingerprint || mark == KvGlyph.face;
}

/// **The biometrics pair** — `O6`'s two overlapping discs, face then finger.
///
/// One object rather than two, because the overlap IS the composition: the
/// render seats two 104 dp discs across 192 dp, so they share 16, and the
/// left mark is lit while the right is stated in `inkDim`.
///
/// **Neither disc is dropped when a phone has only one modality**, and that is
/// deliberate rather than lazy: `biometricStatus` answers `ready` /
/// `none_enrolled` / `no_hardware` and nothing finer, so a pair that dimmed
/// one disc would be claiming knowledge the app does not have. What the pair
/// says is *whatever this phone offers*, which is the sentence underneath it.
class CeremonyMarkPair extends StatelessWidget {
  const CeremonyMarkPair({
    super.key,
    this.size = CeremonyMark.disc,
    this.overlap = 16,
  });

  final double size;
  final double overlap;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: size * 2 - overlap,
      height: size,
      child: Stack(
        children: [
          Positioned(
            right: 0,
            child: CeremonyMark(
              KvGlyph.fingerprint,
              size: size,
              tone: KvColor.inkDim,
            ),
          ),
          Positioned(
            left: 0,
            child: CeremonyMark(
              KvGlyph.face,
              size: size,
              // The lit half — the offer this screen is making.
              tone: KvColor.primary,
            ),
          ),
        ],
      ),
    ),
  );
}
