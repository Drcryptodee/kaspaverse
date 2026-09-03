import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// **The live dot's pulse** — one of exactly two ambient loops in the app
/// (BG-9; the other is the orb's halo, and it belongs to `KvMark`).
///
/// A single repeating controller drives one full sine period of
/// [KvMotion.pulse] (1600 ms): **scale 1 → .7 and opacity 1 → .55** (§3),
/// seamless — a true breath, not a tick-driven square wave. v3.1 ran it at
/// 1100 ms on opacity alone and dimmed to [KvFreshness.opacityStale], which is
/// the *stale* step and meant a live dot and a dead reading reached the same
/// tone twice a second.
///
/// Rationed to the live dot and nothing else. Gates: [active] false or
/// `MediaQuery.disableAnimations` render the child plain with the controller
/// STOPPED (no frame production); covered routes mute the ticker for free
/// (`TickerMode`).
class KvBreath extends StatefulWidget {
  const KvBreath({super.key, required this.child, this.active = true});

  final Widget child;

  /// The honesty gate (BG-8): breathe only while the state the dot reports
  /// is genuinely live/pending — a resolved state stops the motion.
  final bool active;

  @override
  State<KvBreath> createState() => _KvBreathState();
}

class _KvBreathState extends State<KvBreath>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: KvMotion.pulse);
    _opacity = _controller.drive(const _SineBreath(_KvBreathState.dimOpacity));
    _scale = _controller.drive(const _SineBreath(_KvBreathState.dimScale));
  }

  /// §3: the dot fades to 55% at the trough.
  static const double dimOpacity = 0.55;

  /// §3: and shrinks to 70%.
  static const double dimScale = 0.7;

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
    // Reduced motion collapses to opacity everywhere except the hold (BG-9),
    // and the branch above has already returned for it — so both channels run
    // together or neither does.
    return FadeTransition(
      opacity: _opacity,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

/// t ∈ [0,1] → one cosine period between 1 and [_dim]: full at both ends,
/// least at the midpoint — so the loop point is seamless and the dot wakes
/// bright. One curve drives both channels, which is what keeps the scale and
/// the fade in phase.
class _SineBreath extends Animatable<double> {
  const _SineBreath(this._dim);

  final double _dim;

  @override
  double transform(double t) {
    final wave = 0.5 - 0.5 * math.cos(2 * math.pi * t); // 0 → 1 → 0
    return 1.0 - (1.0 - _dim) * wave;
  }
}
