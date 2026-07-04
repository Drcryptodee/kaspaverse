import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The §8 GlassPanel: 3% white fill over a σ16 backdrop blur, 1 dp hairline
/// border, card radius. **Budget: at most ONE live blur per screen, never
/// inside a scrollable** (saveLayer cost on mid-range GPUs) — and a blur only
/// earns its cost when real content sits behind it (a sheet over a screen);
/// over flat `abyss` it is invisible. Everywhere else use the spec's own
/// fallback, `frosted: false`: solid `surface-alt`, same layout, lesser
/// shimmer.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.frosted = false,
    this.padding = const EdgeInsets.all(KvSpace.l),
    this.radius = const BorderRadius.all(Radius.circular(KvRadius.card)),
  });

  final Widget child;

  /// True = the live blur (spend the screen's blur budget consciously).
  final bool frosted;

  final EdgeInsetsGeometry padding;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    final border = Border.all(color: KvColor.border);
    if (!frosted) {
      return Container(
        decoration: BoxDecoration(
          color: KvColor.surfaceAlt,
          borderRadius: radius,
          border: border,
        ),
        child: content,
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: KvGlass.blurSigma,
          sigmaY: KvGlass.blurSigma,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: KvColor.glassFill,
            borderRadius: radius,
            border: border,
          ),
          child: content,
        ),
      ),
    );
  }
}
