import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// **A figure whose digits change in place** — each character position that
/// actually changed slides to its new glyph; the rest do not move.
///
/// ## What the founder asked for, and why it is not `KvStreamingCount`
///
/// *"the numbers change as a whole, not like the digit sliding… if the number
/// was `0.00356` and it changes to `0.00546`, its the increment or decrement
/// that user sees changing… so its not like the number and KAS is going out
/// and coming in"* (on glass, 2026-09-04). The first cut crossfaded the whole
/// figure — the number left and a different number arrived — which reads as a
/// swap rather than as a change.
///
/// **And it is still not a counter.** `KvStreamingCount`'s fourth law is that
/// **money never streams**: interpolating a *value* renders amounts nobody
/// quoted, which on a fee is a number the Generator never priced. This
/// animates **glyph positions, never a value**. Exactly two glyphs exist in a
/// slot during a transition — the one that was there and the one that arrived,
/// both from real quoted figures — and nothing computes anything in between.
/// `0.00356 → 0.00546` moves the `3` to a `5` and the `5` to a `4`; it never
/// renders `0.00400`.
///
/// ## Why per character rather than per run
///
/// Slot identity is the position, so a digit that did not change is not
/// rebuilt and does not move. That is the whole effect: the eye sees *which*
/// digits changed. Keying on the character instead would restart every slot
/// whenever any of them changed.
///
/// **Mono only.** A slot is a fixed advance, which is true of `KvFont.mono`
/// with tabular figures and false of a proportional face — under Jakarta the
/// slots would jitter as glyph widths changed. Money is mono anyway (BG-5).
class KvRollingText extends StatelessWidget {
  const KvRollingText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  /// Short: this is a change of state, not a transition between screens. Long
  /// enough to be seen as movement, short enough that a fee never looks like
  /// it is still settling when the user reaches for Review.
  static const Duration duration = KvMotion.fast;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // Read aloud as one figure. Without this a screen reader would announce
      // it character by character, which is digit soup (§11).
      label: text,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          for (var i = 0; i < text.length; i++)
            _Slot(
              key: ValueKey<int>(i),
              character: text[i],
              style: style,
              // A figure that grows a digit — 0.9 → 1.0 — must not roll every
              // slot because the string got longer. The new slot simply
              // appears; the ones that were already there keep their identity.
              animate: true,
            ),
        ],
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({
    super.key,
    required this.character,
    required this.style,
    required this.animate,
  });

  final String character;
  final TextStyle style;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final glyph = Text(
      character,
      key: ValueKey<String>(character),
      style: style,
      maxLines: 1,
    );
    if (!animate) return glyph;
    return AnimatedSwitcher(
      duration: KvRollingText.duration,
      switchInCurve: KvMotion.curve,
      switchOutCurve: KvMotion.curve,
      // **The outgoing glyph sizes nothing.** A stack that measured both would
      // widen the slot for the length of the transition and shove every digit
      // to its right — the jitter this widget exists to remove.
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.hardEdge,
        children: [
          for (final old in previous)
            Positioned(left: 0, right: 0, top: 0, bottom: 0, child: old),
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) {
        // Up and out, up and in — the direction reads as a roll rather than a
        // fade. Both halves ride the one easing (BG-9/BG-24).
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.6),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: glyph,
    );
  }
}
