import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The §8 KvBreath primitive (v2.2): the ONE way a live-attention dot
/// breathes. A single repeating controller drives opacity through a full
/// sine period ([KvMotion.breath]): 1.0 → [KvFreshness.opacityStale] → 1.0,
/// seamless — a true breath, not a tick-driven square wave.
///
/// Rationed by the doc to the StatusBeacon connected dot and the
/// TxStatusChip pending dot. Gates: [active] false or
/// `MediaQuery.disableAnimations` render the child plain with the controller
/// STOPPED (no frame production); covered routes mute the ticker for free
/// (`TickerMode`).
class KvBreath extends StatefulWidget {
  const KvBreath({super.key, required this.child, this.active = true});

  final Widget child;

  /// The honesty gate (DS-1): breathe only while the state the dot reports
  /// is genuinely live/pending — a resolved state stops the motion.
  final bool active;

  @override
  State<KvBreath> createState() => _KvBreathState();
}

class _KvBreathState extends State<KvBreath>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: KvMotion.breath);
    _opacity = _controller.drive(_SineBreath());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(KvBreath oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _sync() {
    final breathe = widget.active && !_reduced;
    if (breathe && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!breathe && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0; // rest at full opacity
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || _reduced) return widget.child;
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}

/// t ∈ [0,1] → one cosine period of opacity: full at both ends, dimmest at
/// the midpoint — so the loop point is seamless and the dot wakes bright.
class _SineBreath extends Animatable<double> {
  static const double _dim = KvFreshness.opacityStale;

  @override
  double transform(double t) {
    final wave = 0.5 - 0.5 * math.cos(2 * math.pi * t); // 0 → 1 → 0
    return 1.0 - (1.0 - _dim) * wave;
  }
}
