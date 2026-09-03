import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **A feature that exists in the product's intent but not in the build**
/// (Bible §4, D-247).
///
/// A designed surface, **never a `TODO`**. It renders, it sits on the contact
/// sheet, and it stands exactly where the feature will live — in the drawer
/// socket, the tab, the row — so that the shape of what is missing is visible
/// at a glance rather than buried in a tracker.
///
/// **It is deliberately quiet.** No teal emission (BG-2 counts three per screen
/// and an unbuilt feature earns none of them), no glow (BG-32 seats exactly
/// two), and **not tappable** — a control that responds and then does nothing
/// is the dead-destination anti-pattern (§8). The socket glyph carries the
/// brand in [KvColor.primaryMuted], which is uncounted (§1.5): this is *ours*,
/// not *alive*.
///
/// The copy obeys §7.1: one fact per sentence, the verb leading, no apology and
/// no timing tag the project cannot keep ("Next · Q1", never "Soon").
class KvComingSoon extends StatelessWidget {
  const KvComingSoon({
    super.key,
    required this.mark,
    required this.name,
    this.sentence = 'Not built yet. It will live here.',
    this.tag = 'Coming soon',
  });

  /// The feature's own glyph — the same one it will wear once it is built, so
  /// the placeholder and the finished thing are recognisably the same seat.
  final KvGlyph mark;

  /// What the feature is called. One or two words, the product's own noun.
  final String name;

  /// The house sentence. Overridden only to say something *more* specific about
  /// this feature, never to soften or to promise a date.
  final String sentence;

  /// The chip's words. [KvColor.inkDim], never a value hue — an unbuilt feature
  /// is not a state of the user's money.
  final String tag;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$name. $sentence',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: KvColor.plate,
          borderRadius: BorderRadius.circular(KvRadius.plate),
          // No edge: a plate on the ground has none (BG-4).
        ),
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.s20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The 40 dp socket — tealTint disc, primaryMuted glyph (§4).
              Container(
                width: KvSpace.rowDisc,
                height: KvSpace.rowDisc,
                decoration: const BoxDecoration(
                  color: KvColor.tealTint,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: KvGlyphIcon(mark, size: 18, tone: KvColor.primaryMuted),
              ),
              const SizedBox(width: KvSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 15,
                        height: 20 / 15,
                        fontVariations: [FontVariation('wght', 600)],
                        color: KvColor.ink,
                      ),
                    ),
                    const SizedBox(height: KvSpace.xs),
                    Text(
                      sentence,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 13,
                        height: 18 / 13,
                        color: KvColor.inkMeta,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: KvSpace.sm),
              _Tag(tag),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.words);

  final String words;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: KvColor.chip,
        borderRadius: BorderRadius.circular(KvRadius.control),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: KvSpace.s10,
          vertical: KvSpace.xs,
        ),
        child: Text(
          words,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 11,
            height: 16 / 11,
            fontVariations: [FontVariation('wght', 600)],
            // inkDim, not inkMeta: this sits on `chip`, where inkMeta measures
            // 4.30 and fails AA (§1.4, BG-14).
            color: KvColor.inkDim,
          ),
        ),
      ),
    );
  }
}
