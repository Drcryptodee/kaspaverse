import 'package:flutter/material.dart';

import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import 'kv_chrome.dart';
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
                    // **The tag WRAPS with the name, it does not sit beside
                    // the column** (`ux-auditor` BLOCK, UX-R7).
                    //
                    // `_Tag` was an intrinsic-width sibling of the whole text
                    // column, so at 320 dp / 1.3x inside a sheet it took ~105
                    // of a 232 dp row and left the words ~63 — and a 19.5 dp
                    // `wallet` broke mid-word: *More / than / one / walle / t*,
                    // "Ad ding", "sw itching". BG-14 forbids that outright.
                    // Every earlier caller was a full-width page or used the
                    // short default sentence, so the narrow column is this
                    // sitting's first, and the fix belongs in the part.
                    //
                    // In a `Wrap` the tag rides the name's line when there is
                    // room and drops to its own when there is not; the name
                    // keeps the whole width either way.
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: KvSpace.s,
                      runSpacing: KvSpace.xs,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 15,
                            height: 20 / 15,
                            fontVariations: KvWeight.w600,
                            color: KvColor.ink,
                          ),
                        ),
                        _Tag(tag),
                      ],
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
            fontVariations: KvWeight.w600,
            // inkDim, not inkMeta: this sits on `chip`, where inkMeta measures
            // 4.30 and fails AA (§1.4, BG-14).
            color: KvColor.inkDim,
          ),
        ),
      ),
    );
  }
}

/// **A destination that is not built yet, as a page** (D-261, render `S2 ·
/// Drawer`).
///
/// The render seats Games, Finance, Identity and Help as ordinary rows — no
/// tag, the same weight as the rows beside them. §8 still forbids a control
/// that answers a tap and does nothing, so the row does not go dead: it opens
/// this, which is [KvComingSoon] standing exactly where the feature will
/// stand, with the bar the feature will have. The user learns two true things
/// — that the seat exists, and that nothing is behind it yet — instead of one
/// false one.
class KvComingSoonPage extends StatelessWidget {
  const KvComingSoonPage({
    super.key,
    required this.mark,
    required this.name,
    this.sentence = 'Not built yet. It will live here.',
  });

  final KvGlyph mark;
  final String name;
  final String sentence;

  @override
  Widget build(BuildContext context) {
    // The class's own gutter and the one-column cap (BG-33, §3a.2): a page
    // pushed at 1180 dp is a 560 column, not an 1148 dp plate.
    final metrics = KvWindow.of(context);
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: KvLayout.columnMax),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KvTopBar(
                  title: name,
                  onBack: () => Navigator.of(context).pop(),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    metrics.gutter,
                    KvSpace.m,
                    metrics.gutter,
                    0,
                  ),
                  child: KvComingSoon(
                    mark: mark,
                    name: name,
                    sentence: sentence,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
