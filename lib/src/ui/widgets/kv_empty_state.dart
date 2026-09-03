import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **The one empty state**: etched glyph · one truth · one nudge (§4).
///
/// Emptiness is a real state of a real wallet — never an apology, never an
/// illustration, and never a spinner pretending something is still coming.
///
/// The glyph is [KvColor.etch] at 3.04:1, which is **below AA by design**: it
/// is decoration, and the two lines of copy carry every bit of the meaning. If
/// a caller ever needs the mark itself to be information, it takes a readable
/// tone instead — the law is that nothing below `inkMetaLow` carries meaning,
/// not that nothing below it is drawn.
class KvEmptyState extends StatelessWidget {
  const KvEmptyState({
    super.key,
    required this.mark,
    required this.truth,
    required this.nudge,
  });

  final KvGlyph mark;

  /// What is true. One sentence, no exclamation mark, no apology.
  final String truth;

  /// What to do about it. One sentence.
  final String nudge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.gutter,
        vertical: KvSpace.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvGlyphIcon(mark, tone: KvColor.etch),
          const SizedBox(height: KvSpace.m),
          Text(
            truth,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 15,
              height: 22 / 15,
              color: KvColor.inkDim,
            ),
          ),
          const SizedBox(height: KvSpace.xs),
          Text(
            nudge,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkMetaLow,
            ),
          ),
        ],
      ),
    );
  }
}
