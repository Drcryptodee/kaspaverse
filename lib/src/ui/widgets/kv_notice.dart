import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **The notice plate** — §4's `KvNotice`, built at UX-R6 because the law
/// named it and nothing in `lib/` implemented it.
///
/// One tinted plate in the whole language: `warnTint` at [KvRadius.notice],
/// a `warn` `info` mark, `warnInk` body. `O5` measured at 4× and every value
/// is a token the render was drawn from — ground `#2E2510`, ink `#F3D9A0`,
/// mark `#E0B15C`, plate 85 dp tall for three lines at 13 / 19 inside 14 dp
/// of vertical air and 16 of horizontal.
///
/// **Amber is earned, not decorative** (BG-7): *not yet certain — check this*.
/// `O5`'s notice is the one sentence a user who loses their 25th word cannot
/// be told twice, and it is deliberately not `risk`, which §3 rations to fund
/// risk and destruction — nothing has gone wrong yet, and a red plate on a
/// screen offering an optional feature would spend the colour the ceremony
/// needs later.
///
/// **It never goes behind a disclosure mark.** BG-34 hides EXPLANATION; a
/// warning about what cannot be undone is the surface's subject, and hiding
/// the subject behind a tap is the dark pattern the law's own test names.
class KvNotice extends StatelessWidget {
  const KvNotice({
    super.key,
    required this.text,
    this.lead,
    this.tone = KvNoticeTone.warn,
    this.mark = KvGlyph.info,
  });

  /// The sentence. Plain words; the plate carries no action.
  final String text;

  /// An optional first clause set at 700, for a notice whose first sentence is
  /// the one that matters — `O5`'s *Write it on the same paper, apart from the
  /// words.* Same ink, more weight: hierarchy is weight and scale, never
  /// colour (§2).
  final String? lead;

  final KvNoticeTone tone;
  final KvGlyph mark;

  /// `O5` measured: 16 across, 14 down.
  static const EdgeInsets pad = EdgeInsets.symmetric(
    horizontal: KvSpace.m,
    vertical: KvSpace.s14,
  );

  /// The mark's box, and the air between it and the words (`O5`: the glyph
  /// starts 16.8 dp inside the plate, the words at 69 — a 16 dp mark and 12
  /// of gap).
  static const double glyph = 16;

  @override
  Widget build(BuildContext context) {
    final warn = tone == KvNoticeTone.warn;
    final body = TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 13,
      height: 19 / 13,
      color: warn ? KvColor.warnInk : KvColor.inkDim,
    );
    return Container(
      width: double.infinity,
      padding: pad,
      decoration: BoxDecoration(
        color: warn ? KvColor.warnTint : KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.notice),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // The mark rides the first line's optical centre, not the box's
            // top — a 16 dp ring against a 19 dp line sits 1.5 dp down.
            padding: const EdgeInsets.only(top: 1.5),
            child: KvGlyphIcon(
              mark,
              size: glyph,
              tone: warn ? KvColor.warn : KvColor.inkMeta,
            ),
          ),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (lead != null)
                    TextSpan(
                      text: '$lead ',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontVariations: KvWeight.w700,
                      ),
                    ),
                  TextSpan(text: text),
                ],
              ),
              style: body,
            ),
          ),
        ],
      ),
    );
  }
}

/// The two grounds §4 gives the notice plate.
enum KvNoticeTone {
  /// `warnTint` — *not yet certain, check this* (BG-7).
  warn,

  /// `plate` with an `inkMeta` mark and `inkDim` body: a fact that needs a
  /// container, carrying no alarm.
  neutral,
}
