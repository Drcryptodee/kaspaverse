import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// **A figure whose digits ROLL in place** — each character position that
/// actually changed turns over like an odometer wheel; the rest do not move.
///
/// ## What the founder asked for, and the two cuts it took to get it
///
/// *"the numbers change as a whole… if the number was `0.00356` and it changes
/// to `0.00546`, its the increment or decrement that user sees changing… so
/// its not like the number and KAS is going out and coming in"* (on glass,
/// 2026-09-04).
///
/// **Cut one crossfaded the whole figure.** The number left and a different
/// number arrived: a swap, not a change. **Cut two crossfaded each character**
/// — narrower, same defect, and he named it exactly: *"you made it that when
/// the fee number changes, it disappears and comes back withing tiny
/// milliseconds."* An opacity animation always reads as a blink, however small
/// the box it happens in.
///
/// **What reads as a change is movement at full opacity.** Both glyphs stay
/// solid and travel in the same direction inside a clip, so the eye follows a
/// digit *turning over* rather than watching one vanish and another appear.
/// That is the whole difference, and it is why nothing here fades.
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
              // A figure that grows a digit — 0.9 → 1.0 — must not roll every
              // slot because the string got longer. Keying on the POSITION
              // means the new slot simply appears and the ones that were
              // already there keep their identity and their glyph.
              key: ValueKey<int>(i),
              character: text[i],
              style: style,
            ),
        ],
      ),
    );
  }
}

/// One character position. It **rolls**: the glyph leaving travels out of the
/// box while the glyph arriving travels in behind it, both in the same
/// direction, clipped so exactly one is fully in view at rest.
///
/// **The first cut of this was a crossfade and the founder rejected it** —
/// *"you made it that when the fee number changes, it disappears and comes
/// back"*. That is what a fade does: the outgoing and the incoming both change
/// opacity in place, so the eye reads a blink rather than a movement. A roll
/// keeps both glyphs at full opacity and moves them, which is the only thing
/// that reads as a digit *changing* rather than being *replaced*.
///
/// **Up for a larger digit, down for a smaller one.** The direction carries the
/// increment, which is the part he asked for by name; an odometer that always
/// rolled one way would animate the change without saying which way it went.
class _Slot extends StatefulWidget {
  const _Slot({super.key, required this.character, required this.style});

  final String character;
  final TextStyle style;

  @override
  State<_Slot> createState() => _SlotState();
}

class _SlotState extends State<_Slot> with SingleTickerProviderStateMixin {
  /// **Built in `initState`, not lazily.** A `late final` controller is created
  /// on first touch — and for a slot whose glyph never changed, the first
  /// touch is `dispose()`. `SingleTickerProviderStateMixin.createTicker` reads
  /// `TickerMode` off the context, so creating it there threw *"Looking up a
  /// deactivated widget's ancestor is unsafe"* on every teardown of a fee row
  /// that had only ever shown one figure. The suite caught it: the tests
  /// passed one at a time and failed in the full run, which is the signature
  /// of a teardown fault.
  late final AnimationController _c;

  late String _shown = widget.character;

  /// The glyph on its way out, or null when the slot is at rest. At rest the
  /// slot is a plain `Text` — no clip, no stack, nothing to composite.
  String? _leaving;

  /// True when the new glyph is the larger one, so the column rolls upward.
  bool _up = true;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: KvRollingText.duration)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed && mounted) {
          setState(() => _leaving = null);
        }
      });
  }

  @override
  void didUpdateWidget(_Slot old) {
    super.didUpdateWidget(old);
    if (widget.character == _shown) return;
    final from = _shown;
    final to = widget.character;
    // Reduced motion snaps: a user who asked for less movement gets less
    // movement, not a faster version of it.
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() {
        _shown = to;
        _leaving = null;
      });
      _c.stop();
      return;
    }
    setState(() {
      _leaving = from;
      _shown = to;
      _up = _rank(to) >= _rank(from);
    });
    _c.forward(from: 0);
  }

  /// Digits order by value; anything else (a point, a grouping comma, a minus)
  /// sorts below every digit, so a separator appearing rolls in from the same
  /// side each time rather than picking a direction from its code unit.
  static int _rank(String c) {
    final u = c.codeUnitAt(0);
    return u >= 0x30 && u <= 0x39 ? u - 0x30 : -1;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final leaving = _leaving;
    final glyph = Text(_shown, style: widget.style, maxLines: 1);
    if (leaving == null) return glyph;
    return ClipRect(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = KvMotion.curve.transform(_c.value);
          final sign = _up ? -1.0 : 1.0;
          return Stack(
            children: [
              // The one leaving, travelling out of the box.
              FractionalTranslation(
                translation: Offset(0, sign * t),
                child: Text(leaving, style: widget.style, maxLines: 1),
              ),
              // The one arriving, travelling in behind it — the same
              // direction, one box-height away, landing exactly as the other
              // clears.
              FractionalTranslation(
                translation: Offset(0, sign * (t - 1)),
                child: glyph,
              ),
            ],
          );
        },
      ),
    );
  }
}
