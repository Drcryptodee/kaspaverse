import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The §6 entrance law: an element arrives with `translateY(24 dp) + fade`,
/// decelerate-only (vault register), staggered 75 ms per [index]. Plays once
/// on mount. Reduced motion (`MediaQuery.disableAnimations`) drops the
/// translation — opacity-only, per the §6 rule.
///
/// Purely decorative: it never gates hit-testing or semantics, so tests and
/// screen readers see the child immediately.
///
/// Stateful since V4: the controller, curve and offsets are allocated ONCE
/// on mount — a parent rebuild re-parents [child] without reallocating any
/// animation object (or replaying the entrance). [index] is read at mount
/// only; entrances don't reorder mid-flight.
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.index = 0});

  final Widget child;

  /// Position in the stagger order (0 = first, each step +75 ms).
  final int index;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    final delay = KvMotion.stagger * widget.index;
    final total = KvMotion.normal + delay;
    final start = delay.inMilliseconds / total.inMilliseconds;
    _controller = AnimationController(vsync: this, duration: total)..forward();
    _t = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, 1, curve: KvMotion.out),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: reduced
            ? child
            : Transform.translate(
                offset: Offset(0, (1 - _t.value) * KvMotion.entranceOffset),
                child: child,
              ),
      ),
    );
  }
}
