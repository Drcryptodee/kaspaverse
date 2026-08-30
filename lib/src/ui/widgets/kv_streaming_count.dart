import 'package:flutter/material.dart';

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

  /// Renders the interpolated value. Called once per frame while moving.
  final Widget Function(BuildContext context, BigInt shown) builder;

  /// How long to take crossing one reading-to-reading gap. Match it to the
  /// poll cadence so the tween lands just as the next reading arrives; a late
  /// reading simply means the counter has already stopped, which is honest.
  final Duration interval;

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

  @override
  void initState() {
    super.initState();
    _to = widget.value;
    _from = widget.value;
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
      ..duration = widget.interval
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
        if (shown == null) return const SizedBox.shrink();
        assert(
          _to == null || shown <= _to!,
          'KvStreamingCount rendered $shown past the latest observation $_to — '
          'a counter must never show a number the chain has not reached.',
        );
        return widget.builder(context, shown);
      },
    );
  }
}
