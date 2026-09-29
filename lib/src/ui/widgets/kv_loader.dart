import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/tokens.dart';

/// **The app's one loader** — a soft shape that turns while it morphs through
/// seven rounded forms (the founder's ruling at LINK-Q4, 2026-09-29: the five
/// rolling bars and the plain circle were "for the old abyss ui … change it
/// and stick to it"; he chose this one).
///
/// **Prior art, taken at its numbers** (D-343): Material 3 Expressive's
/// loading indicator (Google, 2025; AOSP `LoadingIndicator.kt`), which
/// replaces the indeterminate circular spinner for short waits — the shape
/// sequence SoftBurst → Cookie9Sided → Pentagon → Pill → Sunny → Cookie4Sided
/// → Oval, one morph every [morphMs] driven by a spring (damping
/// [springDamping], stiffness [springStiffness]) that also adds a quarter
/// turn, over a steady turn of 360° every [turnMs]; a 38 dp shape in a 48 dp
/// box ([activeRatio]). Drawn here as polar outlines, so nothing is imported
/// (INV-7).
///
/// **Three rules, carried over from the cadence it replaces** (§4):
///  * **It runs only while something is genuinely in flight** — a hunt, a
///    sync, a probe past its deadline, a broadcast. Callers pass [running]
///    from a real condition.
///  * **Frozen is dimmed, never hidden** — [running] false stands the shape
///    still at [KvFreshness.opacityStale] (BG-8).
///  * **Reduced motion keeps the distinction** — the shape stands still, at
///    full brightness while running and dimmed while frozen (BG-9).
///
/// **Its colour says what kind of wait it is, never how serious** (the
/// founder at LINK-Q4: *"grey for when to indicate offline and teal for when
/// to actually load into something meaningful"*):
///  * **working** — teal, [colour]: the app is doing something that will
///    land (a hunt with a network, a sync, a sign, a send, a page).
///  * **waiting** ([waiting]) — grey, [waitingColour], still moving: the app
///    is ready but blocked on something outside it, and carries on by itself
///    when it returns (the phone has no network).
///  * **stopped** ([running] false) — grey, dimmed, still: nothing is
///    happening; the words beside it say why.
/// **It keeps the colour it appeared in until it leaves** (the founder:
/// *"the color it started with should also be the color it is until it
/// disappears"*): the look is chosen once, when the loader mounts — grey if it
/// is waiting or stopped, teal if working — and a change of state while it
/// stands dims or moves it, never re-colours it. A new loader chooses afresh.
/// Never a status hue: amber, red and green say *state*, and they live on the
/// lamp and in the words. Prior art: Material 3 draws active loading in
/// `primary`; Apple's default indicator is grey, a brand tint opt-in;
/// Telegram's "Waiting for network…" spins neutral. Teal muted because BG-2
/// keeps full teal for its six named uses. There is no hue parameter — two
/// flags, three looks, held by type. A standalone loader is announced as
/// [label]; one beside words passes `label: null` and stays decorative (BG-7).
class KvLoader extends StatefulWidget {
  /// The 24 dp mark, for a body with no cached structure to show yet.
  const KvLoader({
    super.key,
    this.size = KvSpace.l,
    this.running = true,
    this.waiting = false,
    this.label = 'loading',
  });

  /// The 16 dp loader, inside a busy control or beside a line of text.
  const KvLoader.inline({
    super.key,
    this.running = true,
    this.waiting = false,
    this.label = 'loading',
  }) : size = KvSpace.m;

  /// The box it draws in; the shape is [activeRatio] of it.
  final double size;

  /// Blocked on something outside the app, and carrying on by itself when it
  /// returns: grey, still moving (see the class note).
  final bool waiting;

  /// Working: the house teal in its loader role.
  static const Color colour = KvColor.primaryMuted;

  /// Waiting or stopped: grey.
  static const Color waitingColour = KvColor.inkMeta;

  /// True only while something is genuinely in flight.
  final bool running;

  /// What a screen reader hears; null keeps it decorative.
  final String? label;

  /// One morph, in ms (AOSP `MorphIntervalMillis`).
  static const int morphMs = 650;

  /// One full turn, in ms (AOSP `GlobalRotationDurationMillis`).
  static const int turnMs = 4666;

  /// The morph's spring (AOSP): damping ratio and stiffness.
  static const double springDamping = 0.6;
  static const double springStiffness = 200;

  /// The shape's share of its box (AOSP: a 38 dp shape in a 48 dp box).
  static const double activeRatio = 38 / 48;

  /// Points around each outline — smooth at every size the app draws.
  static const int samples = 96;

  /// The morph's progress [t] seconds into a morph: an underdamped spring
  /// from 0 to 1 (it overshoots by about 9 % and settles well inside
  /// [morphMs]). Pure, so the claim is provable without a frame.
  static double spring(double t) {
    if (t <= 0) return 0;
    final w0 = math.sqrt(springStiffness);
    const z = springDamping;
    final wd = w0 * math.sqrt(1 - z * z);
    final e = math.exp(-z * w0 * t);
    return 1 -
        e * (math.cos(wd * t) + z / math.sqrt(1 - z * z) * math.sin(wd * t));
  }

  /// The seven outlines, as radii at [samples] even angles, each scaled so
  /// its widest point is 1.
  static final List<List<double>> shapes = [
    _polar((a) => 1 + 0.055 * math.cos(10 * a)), // SoftBurst
    _polar((a) => 1 + 0.075 * math.cos(9 * a)), // Cookie9Sided
    _polar((a) => 0.72 * _polygon(5, a) + 0.28), // Pentagon, rounded
    _polar((a) => _superellipse(a, 1, 0.6, 3.2)), // Pill
    _polar((a) => 1 + 0.1 * math.cos(8 * a)), // Sunny
    _polar((a) => 1 + 0.14 * math.cos(4 * a)), // Cookie4Sided
    _polar((a) => _superellipse(a - math.pi / 4, 1, 0.74, 2)), // Oval
  ];

  static List<double> _polar(double Function(double) r) {
    final raw = [
      for (var i = 0; i < samples; i++) r(2 * math.pi * i / samples),
    ];
    final top = raw.reduce(math.max);
    return [for (final v in raw) v / top];
  }

  /// A regular [n]-gon's radius at angle [a], a vertex straight up.
  static double _polygon(int n, double a) {
    final seg = 2 * math.pi / n;
    final x = ((a + math.pi / 2) % seg + seg) % seg - seg / 2;
    return math.cos(seg / 2) / math.cos(x);
  }

  /// A superellipse's radius at angle [a]: semi-axes [w], [h], exponent [p].
  static double _superellipse(double a, double w, double h, double p) {
    final c = (math.cos(a) / w).abs();
    final s = (math.sin(a) / h).abs();
    return math.pow(math.pow(c, p) + math.pow(s, p), -1 / p).toDouble();
  }

  @override
  State<KvLoader> createState() => _KvLoaderState();
}

class _KvLoaderState extends State<KvLoader>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  Duration _elapsed = Duration.zero;
  bool _reduced = false;

  /// The colour it appeared in, kept until it leaves (see the class note).
  late final Color _colour = widget.waiting || !widget.running
      ? KvLoader.waitingColour
      : KvLoader.colour;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(KvLoader old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.running && !_reduced;
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) => setState(() => _elapsed = elapsed);

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ms = _elapsed.inMicroseconds / 1000;
    final index = ms ~/ KvLoader.morphMs;
    final local = (ms - index * KvLoader.morphMs) / 1000;
    final p = KvLoader.spring(local);
    final turn =
        2 * math.pi * (ms / KvLoader.turnMs) + math.pi / 2 * (index + p);
    final opacity = widget.running ? 1.0 : KvFreshness.opacityStale;
    final Widget paint = SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: KvLoaderShape(
          from: KvLoader.shapes[index % KvLoader.shapes.length],
          to: KvLoader.shapes[(index + 1) % KvLoader.shapes.length],
          progress: p,
          turn: turn,
          color: _colour.withValues(alpha: opacity),
        ),
      ),
    );
    final label = widget.label;
    return label == null
        ? ExcludeSemantics(child: paint)
        : Semantics(
            label: label,
            child: ExcludeSemantics(child: paint),
          );
  }
}

/// The loader's painter, public so a test can read what it draws.
@visibleForTesting
class KvLoaderShape extends CustomPainter {
  KvLoaderShape({
    required this.from,
    required this.to,
    required this.progress,
    required this.turn,
    required this.color,
  });

  final List<double> from;
  final List<double> to;
  final double progress;
  final double turn;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 * KvLoader.activeRatio;
    final path = Path();
    for (var i = 0; i < KvLoader.samples; i++) {
      final k = math.max(0.05, from[i] + (to[i] - from[i]) * progress);
      final a = turn + 2 * math.pi * i / KvLoader.samples;
      final o = c + Offset(math.cos(a), math.sin(a)) * (k * r);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(KvLoaderShape old) =>
      old.progress != progress ||
      old.turn != turn ||
      old.color != color ||
      !identical(old.from, from);
}
