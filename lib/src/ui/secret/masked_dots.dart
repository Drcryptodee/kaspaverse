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
/// Two forms, because a mask answers two different questions:
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
class KvMaskDots extends StatelessWidget {
  /// One dot per character of a live buffer.
  const KvMaskDots.length(
    this.count, {
    super.key,
    this.size = wellSize,
    this.gap = wellGap,
    this.tone = KvColor.primary,
    this.alignment = WrapAlignment.center,
  });

  /// The fixed mask: [words] dots, no matter what is behind them.
  const KvMaskDots.fixed({
    super.key,
    this.size = wordSize,
    this.gap = wordGap,
    this.tone = KvColor.etch,
    this.alignment = WrapAlignment.start,
  }) : count = words;

  final int count;
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
            decoration: BoxDecoration(shape: BoxShape.circle, color: tone),
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
    this.size = KvMaskDots.wellSize,
    this.gap = KvMaskDots.wellGap,
    this.tone = KvColor.primary,
    this.alignment = WrapAlignment.center,
  });

  final ValueListenable<int> length;

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
