import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **One check** (BG-29). A solid [KvColor.ok] disc carrying an [KvColor.okDeep]
/// tick, inside a ring of [KvColor.okTint].
///
/// The app's "yes" is one mark at every size and on every surface: the address
/// that validated, the option that is selected, the transaction that landed.
/// **Never teal, never bare, never a second style** — a wallet whose
/// confirmation changes shape from screen to screen is a wallet whose
/// confirmation the eye has to re-learn each time.
///
/// Sizes are the [disc] the mark is drawn at — 22 · 32 · 56 · 84 (the rungs
/// §4 and §5 name). The ring and the tick are **derived from it**, never
/// chosen: a rung added later inherits the proportions rather than re-deciding
/// them (L121 — a number picked by eye is a number nobody can re-check).
///
///  * ring = 12 % of the disc, clamped to 3…10 dp. Measured on the renders:
///    `S6b` draws 3 dp around a 20 dp disc and `S8` 10 dp around 84, which is
///    the same proportion at both ends. **BG-29's stated 3–8 dp band is
///    widened to 3–10 by that measurement** (the 84 rung is §5's, and it did
///    not exist when the band was written).
///  * tick = 55 % of the disc, stroked at [KvGlyphSpec.strokeCheck] on the
///    24 dp grid — 1.75 dp of ink at the 22 rung, 6.7 at 84.
class KvCheck extends StatelessWidget {
  const KvCheck({
    super.key,
    this.disc = small,
    this.semanticLabel,
    this.ground = KvColor.okTint,
  });

  /// The mark beside a validated field, on a selected row (§4, `S6b`).
  static const double small = 22;

  /// The mark on a settings option and a token row.
  static const double medium = 32;

  /// The mark in a sheet's verdict block.
  static const double large = 56;

  /// The receipt's mark (§5, `S8` — measured: an 84 dp disc in a 104 ring).
  static const double receipt = 84;

  /// The `ok` disc's diameter. The ring is drawn OUTSIDE it, so the widget's
  /// footprint is [outer].
  final double disc;

  /// Names the mark where nothing beside it does. Null (the default) excludes
  /// it from semantics — normally the words next to it carry the meaning.
  final String? semanticLabel;

  /// **The ground the ring blends into.**
  ///
  /// The ring's whole job is to separate the `ok` disc from what is behind it,
  /// so it has to BE what is behind it — and it was hardcoded to [KvColor.okTint],
  /// which is right on every seat that existed until UX-R3 and wrong the moment
  /// one did not. The transaction detail's lifecycle chip is a `settledTint`
  /// pill at the terminal rung (D-248 spends the fourth hue there), and an
  /// `okTint` ring on it drew a green halo around a blue pill.
  ///
  /// **The disc and the tick do not move**: BG-29 and D-248 both say the mark
  /// means *yes*, not *which rung*, so `KvCheck` stays `ok` wherever it appears.
  /// Only the ring follows its ground.
  final Color ground;

  /// Ring thickness, derived (see the class doc).
  double get ring => math.min(10, math.max(3, disc * 0.12));

  /// The whole footprint: disc plus a ring on each side.
  double get outer => disc + ring * 2;

  /// The tick's glyph box.
  double get tick => disc * 0.55;

  @override
  Widget build(BuildContext context) {
    final mark = Container(
      width: outer,
      height: outer,
      decoration: BoxDecoration(shape: BoxShape.circle, color: ground),
      child: Center(
        child: Container(
          width: disc,
          height: disc,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: KvColor.ok,
          ),
          child: Center(
            child: KvGlyphIcon(
              KvGlyph.check,
              size: tick,
              tone: KvColor.okDeep,
              stroke: KvGlyphSpec.strokeCheck,
            ),
          ),
        ),
      ),
    );
    final label = semanticLabel;
    return label == null
        ? ExcludeSemantics(child: mark)
        : Semantics(label: label, image: true, child: mark);
  }
}

/// The chip form (§4): an [KvColor.okTint] pill carrying the mark and one word
/// in [KvColor.ok] — *Final*, *Verified*, *Up to date*.
///
/// `ok` on `okTint` is 8.57:1 (§1.4), so the label is AA at the 13 dp §4 sets
/// for it.
class KvCheckChip extends StatelessWidget {
  const KvCheckChip(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 5, KvSpace.sm, 5),
      decoration: BoxDecoration(
        color: KvColor.okTint,
        borderRadius: BorderRadius.circular(KvRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const KvCheck(),
          const SizedBox(width: KvSpace.s),
          Text(
            label,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 18 / 13,
              fontWeight: FontWeight.w600,
              fontVariations: KvWeight.w600,
              color: KvColor.ok,
            ),
          ),
        ],
      ),
    );
  }
}
