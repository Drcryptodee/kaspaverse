import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// **A mask, drawn** — the dots that stand in for a secret, painted by this
/// app rather than borrowed from a font or an icon set (BG-25).
///
/// It replaces two things at once. `MaskedDots` used to render
/// `Icon(Icons.circle)`, which is a Material glyph on a secret surface; and
/// `restore_screen.dart` masked each picked recovery word as the six literal
/// characters `••••••`, which the register carried as an explicit debt into
/// UX-R6. Both are the same defect — a mask whose shape the design system does
/// not own — and the second is worse, because a text mask's width tracks the
/// FONT rather than the law, and §4's rule is *fixed four dots* precisely so
/// that a mask cannot leak how long the word behind it is.
///
/// Three forms, because a mask answers three different questions:
///
/// * [KvMaskDots.length] — **how much have I typed?** One dot per character,
///   growing as the buffer grows. The length is already the only thing
///   [SecretByteBuffer] exposes, and showing it is the entry feedback: with no
///   dots a user typing on a keyboard that echoes nothing cannot tell whether
///   the key registered. `O2` draws these as 18 dp `primary` wells; `O5` draws
///   the smaller `ink` run inside a field.
/// * [KvMaskDots.fixed] — **a secret is here, and its length is not yours to
///   read.** Always [words] dots, `etch`, whatever the word is. `O3`'s grid
///   and `O7`'s picked-word chips.
/// * [KvMaskDots.slots] — **how many more?** A known total, filled from the
///   left; the rest are rings. Only a secret whose length the app fixes in
///   advance has this form, which is the 6-digit PIN and nothing else (D-312).
class KvMaskDots extends StatelessWidget {
  /// One dot per character of a live buffer.
  const KvMaskDots.length(
    this.count, {
    super.key,
    this.size = wellSize,
    this.gap = wellGap,
    this.tone = KvColor.primary,
    this.alignment = WrapAlignment.center,
  }) : filled = count;

  /// The fixed mask: [words] dots, no matter what is behind them.
  const KvMaskDots.fixed({
    super.key,
    this.size = wordSize,
    this.gap = wordGap,
    this.tone = KvColor.etch,
    this.alignment = WrapAlignment.start,
  }) : count = words,
       filled = words;

  /// **A known number of slots, some of them filled** — `O2`'s six wells.
  ///
  /// The third question a mask can answer, and the one the other two cannot:
  /// **how many more?** A PIN has a length the app knows in advance, so an empty
  /// slot is a real place rather than an absence, and drawing it as a ring says
  /// *six* without a sentence. The length form has no target and therefore no
  /// rings — with no known total an empty well would be a slot that does not
  /// exist.
  const KvMaskDots.slots(
    this.count,
    this.filled, {
    super.key,
    this.size = wellSize,
    this.gap = wellGap,
    this.tone = KvColor.primary,
    this.alignment = WrapAlignment.center,
  });

  final int count;

  /// How many of [count] are filled. Equal to [count] for the other two forms,
  /// which have no unfilled state.
  final int filled;
  final double size;
  final double gap;
  final Color tone;
  final WrapAlignment alignment;

  /// §4: the recovery-word mask is **four** dots, and the number is the law's,
  /// not the word's.
  static const int words = 4;

  /// `O3` measured at 4×: 6 dp dots on a 10.7 pitch (so 4.7 of gap).
  static const double wordSize = 6;
  static const double wordGap = 4.7;

  /// `O2` measured: 18 dp wells on a 32 pitch.
  static const double wellSize = 18;
  static const double wellGap = 14;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Wrap(
      spacing: gap,
      runSpacing: gap,
      alignment: alignment,
      children: [
        for (var i = 0; i < count; i++)
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // An unfilled slot is a ring, not a paler disc: `O2` draws it
              // that way, and a tinted disc would read as a *dimmer value*
              // rather than as an empty place (BG-8).
              //
              // **`edgeHi` at 1 dp, sampled off `O2` rather than argued.** The
              // law contradicts itself on the empty ring — §1.2 seats `edgeHi`
              // for "an empty radio ring", §4's selection-sheet row (D-284)
              // says `KvRadio` is an `etch` one — so the render settles this
              // object: `#2a3433` is `edgeHi`, at ~1.0 dp on an 18 dp well
              // (both of which the build already matches). The conflict itself
              // is named in `design_system.md` rather than quietly resolved
              // here (`ux-auditor`, D-312).
              color: i < filled ? tone : null,
              border: i < filled
                  ? null
                  : Border.all(color: KvColor.edgeHi, width: 1),
            ),
          ),
      ],
    ),
  );
}

/// The live form of [KvMaskDots.length], bound to a buffer's length notifier.
///
/// **It reads the `ValueNotifier<int>` and nothing else** — the buffer exposes
/// no other channel, which is the property that makes this widget safe to put
/// on a secret screen at all (INV-3: the UI can see how long the secret is,
/// never what it is).
class MaskedDots extends StatelessWidget {
  const MaskedDots({
    super.key,
    required this.length,
    this.emptyHint = 'Use the keyboard below',
    this.slots,
    this.size = KvMaskDots.wellSize,
    this.gap = KvMaskDots.wellGap,
    this.tone = KvColor.primary,
    this.alignment = WrapAlignment.center,
  });

  final ValueListenable<int> length;

  /// **The known total, when there is one** (`O2`'s six). With it the run draws
  /// [KvMaskDots.slots] and there is no empty hint, because six rings already
  /// say what the sentence would. Without it the run grows a dot at a time and
  /// the hint stands in before the first keystroke.
  final int? slots;

  /// What stands in the dots' place before the first keystroke. It is a
  /// PLACEHOLDER, not information (§1.3), so it takes `inkMeta` — and it says
  /// what to do rather than describing the emptiness.
  final String emptyHint;

  final double size;
  final double gap;
  final Color tone;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: length,
      builder: (context, n, _) {
        final slots = this.slots;
        if (slots != null) {
          return Semantics(
            label: '$n of $slots digits entered',
            child: KvMaskDots.slots(
              slots,
              n > slots ? slots : n,
              size: size,
              gap: gap,
              tone: tone,
              alignment: alignment,
            ),
          );
        }
        if (n == 0) {
          return Text(
            emptyHint,
            textAlign: alignment == WrapAlignment.center
                ? TextAlign.center
                : TextAlign.start,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 15,
              height: 22 / 15,
              fontWeight: FontWeight.w400,
              fontVariations: KvWeight.w400,
              color: KvColor.inkMeta,
            ),
          );
        }
        return Semantics(
          label: '$n characters entered',
          child: KvMaskDots.length(
            n,
            size: size,
            gap: gap,
            tone: tone,
            alignment: alignment,
          ),
        );
      },
    );
  }
}
