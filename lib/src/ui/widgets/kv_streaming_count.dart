import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tokens.dart';

/// **A chain counter that moves at the display's refresh rate instead of the
/// poll's** — and never shows a number the chain has not reached.
///
/// The DAA score and the burial depth are read on a 1 Hz timer, so they used to
/// repaint once a second and the DAA jumped about ten at a time. The founder's
/// call (D-226): anything that streams on glass streams smoothly, at whatever
/// Hz the panel actually runs, **and it stays honest while doing it.**
///
/// ## Why the obvious implementation is a lie
///
/// The tempting fix is to predict: the DAA advances ~10/s, so extrapolate
/// forward from the last reading and let the digits run. That renders numbers
/// **the chain has not reached** — a wallet guess wearing a chain's clothes,
/// which is precisely the defect `ffi-leak-auditor` blocked when the `Accepted`
/// stamp carried the wallet's own clock.
///
/// This widget interpolates **between two observed readings** instead. Both
/// endpoints are values a node actually reported, the counter is monotonic and
/// passes through every integer between them, so **every frame shows a number
/// the chain genuinely had.** It is a replay of an interval, not a forecast.
///
/// The price, stated rather than hidden: **the display trails reality by up to
/// one poll interval.** That is the correct trade on a surface whose whole job
/// is to be believed.
///
/// ## The four laws (D-226)
///
/// 1. **Refresh rate, not poll rate.** The ticker is vsync'd, so this is 60 Hz
///    on the V60 and 120 on a panel that runs it. Never a hardcoded frame rate.
/// 2. **Never past the latest observation.** The tween's ceiling is the newest
///    reading; it arrives and stops.
/// 3. **If readings stop, motion stops.** A counter still climbing on a dead
///    link is pure prediction. [stalled] snaps to the last observed value and
///    holds — BG-8's law applied to movement.
/// 4. **Money never streams.** A balance that tweens shows amounts the user
///    does not have. This widget is for monotonic CHAIN COUNTERS only — DAA
///    scores, confirmation depth. A money figure snaps, always. The assert
///    below is not decoration: it is the one misuse that would turn a smoothing
///    primitive into a funds-surface falsehood.
class KvStreamingCount extends StatefulWidget {
  const KvStreamingCount({
    super.key,
    required this.value,
    required this.builder,
    this.interval = KvMotion.stream,
    this.stalled = false,
  });

  /// The latest OBSERVED reading, or null when there is nothing to show.
  final BigInt? value;

  /// Renders the interpolated value. Called once per frame while moving, and
  /// called with **null** when there is no reading at all.
  ///
  /// The null case is the caller's to render, deliberately: DS-1 says an
  /// unknown value shows the dash, never nothing, and a primitive that quietly
  /// returned an empty box would delete the whole line — which is exactly what
  /// the first cut of this widget did to the money plate's `DAA —`.
  final Widget Function(BuildContext context, BigInt? shown) builder;

  /// **The longest a crossing may take.** The tween actually crosses the gap
  /// the readings themselves arrived in — measured on the frame clock between
  /// the previous reading and this one, clamped to `[`[minInterval]`, this]` —
  /// so the count lands on each reading as the next one arrives.
  ///
  /// A fixed interval was the first cut, and it was wrong the moment the bridge
  /// started coalescing (UX-R3, second beat): readings at four a second against
  /// a one-second tween restarted the crossing every 250 ms, so the counter
  /// never landed and trailed reality by about seven DAA in steady state. A
  /// late reading still simply means the counter has already stopped, which is
  /// honest.
  final Duration interval;

  /// The shortest crossing worth animating: two readings inside this are one
  /// step, and a step is what a snap is for.
  static const Duration minInterval = Duration(milliseconds: 100);

  /// The link is not live, so no reading is arriving. Motion stops.
  final bool stalled;

  @override
  State<KvStreamingCount> createState() => _KvStreamingCountState();
}

class _KvStreamingCountState extends State<KvStreamingCount>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.interval,
  );

  /// The endpoints of the interval being replayed. Both are readings that
  /// actually arrived; nothing between them is invented.
  BigInt? _from;
  BigInt? _to;

  /// Beyond this, `BigInt` -> `double` would start losing integers, so the
  /// widget snaps rather than render a value it cannot compute exactly. The
  /// interpolation itself is integer-only (see [_shown]) — this guards the
  /// magnitudes where even the arithmetic below stops being cheap.
  static final BigInt _maxExact = BigInt.two.pow(53);

  /// When the previous reading arrived, on the frame clock — the scheduler's
  /// own stamp rather than the wall clock, so a test that pumps 250 ms
  /// measures 250 ms and the crossing it drives is deterministic.
  Duration? _arrivedAt;

  /// The gap the newest reading arrived in, or the ceiling when there is no
  /// previous arrival to measure from.
  Duration _gap() {
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final previous = _arrivedAt;
    _arrivedAt = now;
    if (previous == null) return widget.interval;
    final gap = now - previous;
    if (gap < KvStreamingCount.minInterval) return KvStreamingCount.minInterval;
    if (gap > widget.interval) return widget.interval;
    return gap;
  }

  @override
  void initState() {
    super.initState();
    _to = widget.value;
    _from = widget.value;
    // The first reading is an arrival too: without its stamp the second one
    // had no gap to measure and crossed over the whole ceiling.
    if (widget.value != null) {
      _arrivedAt = SchedulerBinding.instance.currentFrameTimeStamp;
    }
  }

  @override
  void didUpdateWidget(KvStreamingCount oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.value;
    if (next == oldWidget.value) return;
    if (next == null) {
      _c.stop();
      setState(() {
        _from = null;
        _to = null;
      });
      return;
    }
    final current = _shown ?? next;
    // SNAP, not tween, whenever a smooth crossing would be dishonest or
    // meaningless: the first reading (there is no interval to replay), a
    // DECREASE (a reorg is not progress and must not be animated as if it
    // were), a stalled link, reduced motion, or magnitudes past exact
    // arithmetic.
    final decreased = next < current;
    final tooBig = next.abs() > _maxExact || current.abs() > _maxExact;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final gap = _gap();
    if (_from == null || decreased || tooBig || reduced || widget.stalled) {
      _c.stop();
      setState(() {
        _from = next;
        _to = next;
      });
      return;
    }
    setState(() {
      _from = current;
      _to = next;
    });
    _c
      ..duration = gap
      ..forward(from: 0);
  }

  /// The value on screen this frame, computed in **integer arithmetic** so no
  /// double ever touches it. `t` is quantised to a thousandth of the interval,
  /// which is far finer than a frame and keeps the whole computation in
  /// `BigInt`.
  BigInt? get _shown {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return null;
    if (from == to) return to;
    final t = BigInt.from((_c.value * 1000).round());
    return from + ((to - from) * t) ~/ BigInt.from(1000);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Stalling mid-tween would leave the digits parked between two readings.
    // Land on the newest one and hold: what is on screen is then exactly what
    // was last actually read.
    if (widget.stalled && _c.isAnimating) {
      _c.stop();
      _from = _to;
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final shown = _shown;
        assert(
          shown == null || _to == null || shown <= _to!,
          'KvStreamingCount rendered $shown past the latest observation $_to — '
          'a counter must never show a number the chain has not reached.',
        );
        return widget.builder(context, shown);
      },
    );
  }
}
