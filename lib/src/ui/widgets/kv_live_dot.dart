import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// **The link's live dot, and its ping** — one of exactly two ambient loops in
/// the app (BG-9; the other is the orb's halo, and it belongs to `KvMark`).
///
/// A bare [size] dot: `ok` while the link is live, `warn` while it is not —
/// never a third state. The drawer's Network row drew it first, and the
/// founder took that one for every seat (2026-09-27, D-335): the plate's chip,
/// the short bar, the drawer and the Network screen's DAA figure. The 8 dp
/// [KvLamp] with its ring stays what it is — a *state* lamp — and never pings.
///
/// While [live], the dot itself never moves. Behind it a ghost disc in `ok`
/// starts at the dot's size and 75% opacity, and over the first three quarters
/// of each [period] grows to [pingScale]× while fading to nothing; the last
/// quarter is empty, so the rings arrive as a heartbeat rather than a stream.
/// That is Tailwind's `animate-ping`, number for number — `ping 1s
/// cubic-bezier(0, 0, 0.2, 1) infinite`, `75%, 100% { scale(2); opacity: 0 }`,
/// on an `opacity-75` ghost.
///
/// **[curve] is not the one UI curve, deliberately** (BG-9 as amended, D-335).
/// `Cubic(0.2, 0, 0, 1)` leaves at zero velocity; a ping has to leave the dot
/// at full speed or it reads as a swell instead of a pulse going out, and
/// `(0, 0, 0.2, 1)` still only decelerates.
///
/// The ghost is painted, never rebuilt — a frame of the ping is a repaint
/// inside its own boundary — and it paints past the dot's box without taking
/// layout. Decorative to semantics: the words beside it carry the state.
/// Gates: `MediaQuery.disableAnimations` renders the dot plain with the
/// controller STOPPED (no frame production); covered routes mute the ticker
/// for free (`TickerMode`).
class KvLiveDot extends StatefulWidget {
  const KvLiveDot({super.key, required this.live});

  /// The honesty gate (BG-8): green and pinging only while the link is
  /// genuinely live; amber and still otherwise.
  final bool live;

  /// The dot's diameter.
  static const double size = 6;

  /// One ping, arrival to arrival.
  static const Duration period = KvMotion.ping;

  /// The share of [period] the ring spends travelling; the rest is rest.
  static const double travel = 0.75;

  /// The ring's easing — Tailwind's `ease-out`.
  static const Curve curve = KvMotion.pingCurve;

  /// How far the ring travels, as a multiple of the dot.
  static const double pingScale = 2;

  /// The ghost's opacity as it leaves the dot.
  static const double pingOpacity = 0.75;

  @override
  State<KvLiveDot> createState() => _KvLiveDotState();
}

class _KvLiveDotState extends State<KvLiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: KvLiveDot.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(KvLiveDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  bool get _reduced => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  bool get _pings => widget.live && !_reduced;

  void _sync() {
    if (_pings && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!_pings && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = SizedBox.square(
      dimension: KvLiveDot.size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.live ? KvColor.ok : KvColor.warn,
        ),
      ),
    );
    if (!_pings) return ExcludeSemantics(child: dot);
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: CustomPaint(painter: _PingPainter(_controller), child: dot),
      ),
    );
  }
}

/// Where the ring is at loop phase [t] ∈ [0, 1]: its size as a multiple of
/// the dot and its opacity. Pure, so the Tailwind numbers are tested as
/// numbers.
({double scale, double opacity}) kvPingAt(double t) {
  final e = const Interval(
    0,
    KvLiveDot.travel,
    curve: KvLiveDot.curve,
  ).transform(t);
  return (
    scale: 1 + (KvLiveDot.pingScale - 1) * e,
    opacity: KvLiveDot.pingOpacity * (1 - e),
  );
}

/// The ghost disc, centred on the dot and drawn behind it.
class _PingPainter extends CustomPainter {
  _PingPainter(this._t) : super(repaint: _t);

  final Animation<double> _t;

  @override
  void paint(Canvas canvas, Size size) {
    final at = kvPingAt(_t.value);
    if (at.opacity <= 0) return;
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide / 2 * at.scale,
      Paint()..color = KvColor.ok.withValues(alpha: at.opacity),
    );
  }

  @override
  bool shouldRepaint(_PingPainter old) => false;
}
