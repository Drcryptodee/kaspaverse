import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The cadence — five bars breathing at block rhythm.
///
/// It is the app's **one** loading indicator and its liveness tell at once, so
/// waiting reads as listening (§4). Three rules govern it and all three are
/// pinned by tests:
///
///  * **It freezes the instant the link dies** — [running] false leaves the
///    bars standing at [KvFreshness.opacityStale]. That is what makes "live" a
///    felt thing rather than a claimed one (BG-8).
///  * **It never runs on a settled screen** (BG-8 as amended at D-192). Motion
///    means something is happening; a meter animating beside a healthy balance
///    reports that nothing changed, forever, and becomes wallpaper. Callers
///    pass [running] from a real in-flight condition, never from `true`.
///  * **Reduced motion collapses it to opacity, not to nothing** (BG-9). A
///    stopped animation would render a *running* cadence identically to a
///    *frozen* one — the precise lie BG-8 exists to forbid — so under reduced
///    motion the bars hold at full brightness while running and at
///    [KvFreshness.opacityStale] while frozen. The distinction survives; only
///    the movement goes.
///
/// It emits teal, and it counts as **one** emission against BG-2's cap of
/// three per screen — an emitting object, not five bars.
///
/// Decorative to a screen reader: the words beside it carry the meaning (BG-7),
/// and a meter that announced itself would announce it on every rebuild.
class KvCadence extends StatefulWidget {
  const KvCadence({
    super.key,
    required this.running,
    this.scale = 1,
    this.tone,
  });

  /// True only while something is genuinely happening — a hunt, a sync, a
  /// pending broadcast.
  final bool running;

  /// The bars' hue. Null keeps the Black Glass teal, which is what the two
  /// unmigrated screens still wear.
  ///
  /// **A teal meter is not on BG-2's list.** Teal appears as the one primary
  /// pill, the live dot, the caret, a ghost text action, an active tab's
  /// underline and an armed glow pill's edge — a loading meter is none of
  /// those. §4's re-spec settles it the other way round: *"number, word, dot
  /// and bars share one hue"*, and the hue is the tier's. A migrated caller
  /// therefore passes the hue of the lamp the meter is explaining; UX-R3 owns
  /// re-specifying the widget itself as a latency reading (A5 / B3), at which
  /// point this parameter stops being optional.
  final Color? tone;

  /// Uniform size multiplier. The bar RATIO is the meter's identity, so this
  /// scales the whole figure rather than letting a caller pick heights — a
  /// meter with different proportions would be a second meter (§4: there is
  /// one loading indicator).
  final double scale;

  /// Bar heights, in logical pixels, left to right.
  static const List<double> barHeights = <double>[6, 10, 14, 10, 6];

  /// Width of one bar, and the gap between two.
  static const double barWidth = 3;
  static const double barGap = 3;

  /// The meter's own extent, derived from the bars rather than asserted
  /// (item 0 / L121: rendered geometry is computed, never claimed).
  static double get height => barHeights.reduce((a, b) => a > b ? a : b);
  static double get width =>
      barHeights.length * barWidth + (barHeights.length - 1) * barGap;

  /// The same two numbers at a given [scale], so a caller never multiplies
  /// them by hand and drifts.
  static double heightAt(double scale) => height * scale;
  static double widthAt(double scale) => width * scale;

  /// The dimmest a running bar goes at the bottom of its cycle. Above zero so
  /// the meter reads as five bars breathing rather than as bars appearing.
  static const double troughOpacity = 0.15;

  @override
  State<KvCadence> createState() => _KvCadenceState();
}

class _KvCadenceState extends State<KvCadence>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: KvMotion.breath,
  );

  bool _reduced = false;

  /// Sync lives here and in [didUpdateWidget] rather than in `build`: starting
  /// a controller during build schedules a listener notification inside the
  /// build phase, and `didChangeDependencies` is also where a MediaQuery change
  /// (the reduced-motion toggle) actually arrives.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(KvCadence old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final shouldRun = widget.running && !_reduced;
    if (shouldRun && !_c.isAnimating) {
      _c.repeat();
    } else if (!shouldRun && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// A cosine wave per bar, offset by [KvMotion.cadenceStagger], so the meter
  /// travels rather than pulsing as a block.
  double _alphaAt(int i) {
    if (!widget.running) return KvFreshness.opacityStale;
    if (_reduced) return 1;
    final stagger =
        KvMotion.cadenceStagger.inMilliseconds / KvMotion.breath.inMilliseconds;
    final phase = (_c.value - i * stagger) % 1.0;
    final wave = (0.5 - 0.5 * math.cos(2 * math.pi * phase)).clamp(0.0, 1.0);
    return KvCadence.troughOpacity + (1 - KvCadence.troughOpacity) * wave;
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        height: KvCadence.heightAt(widget.scale),
        width: KvCadence.widthAt(widget.scale),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < KvCadence.barHeights.length; i++) ...[
                if (i > 0) SizedBox(width: KvCadence.barGap * widget.scale),
                Container(
                  width: KvCadence.barWidth * widget.scale,
                  height: KvCadence.barHeights[i] * widget.scale,
                  color: (widget.tone ?? KvColor.primary).withValues(
                    alpha: _alphaAt(i),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
