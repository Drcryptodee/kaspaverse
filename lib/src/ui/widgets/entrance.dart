import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The §6 entrance law: an element arrives with `translateY(24 dp) + fade`,
/// decelerate-only (vault register), staggered 75 ms per [index]. Plays once
/// on mount. Reduced motion (`MediaQuery.disableAnimations`) drops the
/// translation — opacity-only, per the §6 rule.
///
/// Purely decorative: it never gates hit-testing or semantics, so tests and
/// screen readers see the child immediately.
class Entrance extends StatelessWidget {
  const Entrance({super.key, required this.child, this.index = 0});

  final Widget child;

  /// Position in the stagger order (0 = first, each step +75 ms).
  final int index;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final delay = KvMotion.stagger * index;
    final total = KvMotion.normal + delay;
    final start = delay.inMilliseconds / total.inMilliseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: KvMotion.out),
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: reduced
            ? child
            : Transform.translate(
                offset: Offset(0, (1 - t) * KvMotion.entranceOffset),
                child: child,
              ),
      ),
    );
  }
}
