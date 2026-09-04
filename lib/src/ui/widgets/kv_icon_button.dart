import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **A 44 dp disc inside a 52 dp target** (§4, BG-12).
///
/// The one icon control in Deep V6: [KvColor.plate] disc, [KvColor.ink] glyph
/// at 20 dp, pressed [KvColor.chip]. The smaller *visual* is permitted because
/// the code states it; the target never shrinks, and the gap to its neighbour
/// is [KvSpace.touchGap].
///
/// A screen reader reads [label], never the mark: a control is identified by
/// its words, never by its glyph (§1.2a), so the glyph itself stays decorative.
class KvIconButton extends StatefulWidget {
  const KvIconButton({
    super.key,
    required this.mark,
    required this.label,
    required this.onTap,
    this.quarterTurns = 0,
    this.tone,
  });

  final KvGlyph mark;

  /// Quarter-turns applied to the mark. The back chevron is `chevron` turned
  /// twice — one glyph, two directions, rather than a second path (BG-25).
  final int quarterTurns;

  /// The mark's ink. Null takes `ink` — the bar passes `inkNav`, and `etch`
  /// where the way out is closed.
  final Color? tone;

  /// What a screen reader says. Verb plus object (BG-11).
  final String label;

  /// Null ⇒ **not a control at all**, and it renders as a plain disc rather
  /// than as a live-looking button that swallows a tap (BG-12).
  final VoidCallback? onTap;

  @override
  State<KvIconButton> createState() => _KvIconButtonState();
}

class _KvIconButtonState extends State<KvIconButton> {
  bool _down = false;

  /// The glyph's own box. 20 on the 24 dp grid, so the stroke arrives at
  /// 2.08 rather than being thinned by hand (BG-25).
  static const double glyph = 20;

  @override
  Widget build(BuildContext context) {
    final disc = AnimatedContainer(
      duration: KvMotion.fast,
      curve: KvMotion.curve,
      width: KvSpace.iconButton,
      height: KvSpace.iconButton,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _down ? KvColor.chip : KvColor.plate,
        shape: BoxShape.circle,
      ),
      child: const SizedBox.shrink(),
    );
    final content = Stack(
      alignment: Alignment.center,
      children: [
        disc,
        RotatedBox(
          quarterTurns: widget.quarterTurns,
          child: KvGlyphIcon(
            widget.mark,
            size: glyph,
            tone: widget.tone ?? KvColor.ink,
          ),
        ),
      ],
    );
    final tap = widget.onTap;
    if (tap == null) {
      return SizedBox.square(
        dimension: KvSpace.touchTarget,
        child: Center(child: content),
      );
    }
    return Semantics(
      button: true,
      label: widget.label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tap,
          onTapDown: (_) => setState(() => _down = true),
          onTapUp: (_) => setState(() => _down = false),
          onTapCancel: () => setState(() => _down = false),
          child: SizedBox.square(
            dimension: KvSpace.touchTarget,
            child: Center(child: content),
          ),
        ),
      ),
    );
  }
}
