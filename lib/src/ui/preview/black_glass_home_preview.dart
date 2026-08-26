/// Black Glass — the money surface, as a feel test.
///
/// **This is a prototype, not the build.** It exists so the composition can be
/// judged on a real device before `Pre_P3.1` spends eight sessions on it —
/// "premium" is not a property anyone can read off a spec file. It is
/// debug-only, reachable from the dev launcher, imports nothing from the
/// shipped screens and is imported by nothing.
///
/// Everything here is deliberately in ONE file. UX-1 extracts the real
/// primitives into `widgets/` with tests; until it does, a half-designed
/// primitive sitting in `widgets/` is an invitation for a shipped screen to
/// import it (L22's shape: an unfinished destination is worse than none).
///
/// Where this goes beyond the export, and why — the export's own §2 admits it
/// "reads generic" and offers a third font as the cure, which the two-family
/// law refuses. So the character has to come from geometry instead:
///   1. **The datum carries tick marks and a decimal notch.** The export drew a
///      plain hairline. A gauge's datum is graduated, and that single move is
///      what makes the number read as a measurement rather than a label.
///   2. **Functional micro-labels**, mono caps at +1.6 tracking, sitting where
///      an instrument would silk-screen them.
///   3. **The unit and the reading time are engraved BELOW the datum**, right-
///      aligned, the way a panel meter labels its own scale.
/// Everything else follows the bible verbatim (BG-1…BG-16).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// The states the money surface has to hold (SCREEN_INVENTORY 7a–7e).
// ─────────────────────────────────────────────────────────────────────────────

enum MoneyState { empty, live, syncing, inFlight, degraded }

/// Three readings of the same number. The instrument variant is the export's
/// own; the other two exist because on glass it read as telemetry rather than
/// as money — which is a thing no spec file can tell you.
enum HeroVariant { plated, engraved, instrument }

extension on HeroVariant {
  /// Whether the whole screen wears instrument register — tracked mono caps on
  /// labels and the wordmark — or reads in plain sentence case.
  bool get instrumentRegister => this == HeroVariant.instrument;

  String get label => switch (this) {
    HeroVariant.plated => 'A plated',
    HeroVariant.engraved => 'B engraved',
    HeroVariant.instrument => 'C instrument',
  };
}

extension on MoneyState {
  String get label => switch (this) {
    MoneyState.empty => 'empty',
    MoneyState.live => 'live',
    MoneyState.syncing => 'syncing',
    MoneyState.inFlight => 'in flight',
    MoneyState.degraded => 'degraded',
  };

  /// Chain-derived values dim to 45% with a visible age when the link is not
  /// live (BG-8). Buttons never dim — they are the user's, not the chain's.
  bool get stale => this == MoneyState.degraded;

  bool get cadenceRunning =>
      this == MoneyState.live ||
      this == MoneyState.syncing ||
      this == MoneyState.inFlight;
}

class BlackGlassHomePreview extends StatefulWidget {
  const BlackGlassHomePreview({super.key});

  @override
  State<BlackGlassHomePreview> createState() => _BlackGlassHomePreviewState();
}

class _BlackGlassHomePreviewState extends State<BlackGlassHomePreview> {
  MoneyState _state = MoneyState.live;
  HeroVariant _variant = HeroVariant.plated;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // BG-14: the top 52dp belongs to the real status bar. Nothing is
            // painted there and no status bar is ever drawn.
            const SizedBox(height: KvSpace.statusBarReserve),
            _TopRail(variant: _variant),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  const SizedBox(height: KvSpace.l),
                  _Hero(state: _state, variant: _variant),
                  const SizedBox(height: KvSpace.m),
                  // The plated variant carries its own trust line inside the
                  // plate, so it is not repeated below.
                  if (_variant != HeroVariant.plated) _TrustLine(state: _state),
                  if (_state == MoneyState.degraded) ...[
                    const SizedBox(height: KvSpace.l),
                    const _DegradedNotice(),
                  ],
                  const SizedBox(height: KvSpace.l),
                  _Feed(state: _state, variant: _variant),
                  const SizedBox(height: KvSpace.l),
                ],
              ),
            ),
            _ThumbActions(state: _state),
            _Switcher(
              values: MoneyState.values,
              value: _state,
              label: (s) => s.label,
              onChanged: (s) => setState(() => _state = s),
            ),
            _Switcher(
              values: HeroVariant.values,
              value: _variant,
              label: (v) => v.label,
              onChanged: (v) => setState(() => _variant = v),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top rail — the nav trigger and nothing else. A 44dp glyph inside a 48dp
// target, stated here because BG-12 requires the smaller visual to be declared.
// ─────────────────────────────────────────────────────────────────────────────

class _TopRail extends StatelessWidget {
  const _TopRail({required this.variant});

  final HeroVariant variant;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.m,
        KvSpace.s,
        KvSpace.m,
        KvSpace.xs,
      ),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Open navigation',
            child: SizedBox(
              width: KvSpace.touchTarget,
              height: KvSpace.touchTarget,
              child: Center(
                child: CustomPaint(
                  size: const Size(KvGlyph.grid, KvGlyph.grid),
                  painter: const _GlyphPainter(_Glyph.navDots),
                ),
              ),
            ),
          ),
          const Spacer(),
          // The wordmark, engraved rather than set: mono caps, wide tracking,
          // sitting at the same optical weight as a silk-screened panel label.
          if (variant.instrumentRegister)
            const Text(
              'KASPAVERSE',
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 11,
                height: 16 / 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 2.4,
                color: KvColor.inkMeta,
              ),
            )
          else
            const Text(
              'KaspaVerse',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
                color: KvColor.inkNav,
              ),
            ),
          const SizedBox(width: KvSpace.s),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The hero — the instrument face.
// ─────────────────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  const _Hero({required this.state, required this.variant});

  final MoneyState state;
  final HeroVariant variant;

  static const _integer = '1,284';
  static const _fraction = '5027';

  @override
  Widget build(BuildContext context) {
    final empty = state == MoneyState.empty;
    // BG-5: a real zero renders as a real zero; it is never a skeleton and
    // never a fabricated number standing in for an unknown one.
    final integer = empty ? '0' : _integer;
    final fraction = empty ? '0000' : _fraction;

    final body = switch (variant) {
      HeroVariant.plated => _Plated(
        state: state,
        integer: integer,
        fraction: fraction,
      ),
      HeroVariant.engraved => _Engraved(
        state: state,
        integer: integer,
        fraction: fraction,
      ),
      HeroVariant.instrument => _Instrument(
        state: state,
        integer: integer,
        fraction: fraction,
      ),
    };

    return Opacity(
      opacity: state.stale ? KvFreshness.opacityStale : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: empty ? 'Balance zero KAS' : 'Balance 1,284.5027 KAS',
              child: ExcludeSemantics(child: body),
            ),
            if (state == MoneyState.inFlight) ...[
              const SizedBox(height: KvSpace.sm),
              const _InFlightLine(),
            ],
          ],
        ),
      ),
    );
  }
}

/// The number itself. Same in all three variants — what changes around it is
/// how much technical furniture it wears.
class _Figure extends StatelessWidget {
  const _Figure({required this.integer, required this.fraction});

  final String integer;
  final String fraction;

  /// The plated and engraved variants both read at 42 — one step down from the
  /// instrument's 46, because the unit now sits beside the number instead of
  /// being engraved under it, and the line has to hold both.
  static const double size = 42;

  @override
  Widget build(BuildContext context) {
    // A number scales down before it ever truncates (BG-5), which is also what
    // carries it through 1.3x text scale at 320dp.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            integer,
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: size,
              height: 1.14,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.5,
              color: KvColor.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            '.$fraction',
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: size * 0.48,
              fontWeight: FontWeight.w400,
              color: KvColor.inkDim,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: KvSpace.s),
          // The unit sits WITH the number, the way a price is written — not
          // engraved beneath it as a scale label. This is most of what makes
          // the plated and engraved variants read as money.
          Text(
            'KAS',
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: size * 0.33,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.6,
              color: KvColor.inkMeta,
            ),
          ),
        ],
      ),
    );
  }
}

/// **A · Plated.** The balance earns a container, and the trust statement lives
/// inside it beside the number it vouches for. Sentence case throughout; the
/// only rule is a hairline separating the figure from its provenance. Warmest
/// of the three, and the closest to something a person reads as their money.
class _Plated extends StatelessWidget {
  const _Plated({
    required this.state,
    required this.integer,
    required this.fraction,
  });

  final MoneyState state;
  final String integer;
  final String fraction;

  @override
  Widget build(BuildContext context) {
    final (Color lamp, String words) = _trust(state);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        KvSpace.l,
        KvSpace.m,
        KvSpace.l,
        KvSpace.sm,
      ),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.panel),
        border: Border.all(color: KvColor.plateEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SoftLabel('Total balance'),
          const SizedBox(height: KvSpace.s),
          _Figure(integer: integer, fraction: fraction),
          const SizedBox(height: KvSpace.m),
          Container(height: 1, color: KvColor.plateDivider),
          const SizedBox(height: KvSpace.sm),
          Row(
            children: [
              _Lamp(lamp),
              const SizedBox(width: KvSpace.s),
              Expanded(
                child: Text(
                  words,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 13,
                    height: 18 / 13,
                    color: KvColor.inkDim,
                  ),
                ),
              ),
              const SizedBox(width: KvSpace.s),
              _Cadence(running: state.cadenceRunning),
            ],
          ),
        ],
      ),
    );
  }
}

/// **B · Engraved.** No container — the figure still floats in void, but the
/// telemetry furniture is gone: sentence case, the unit with the number, and a
/// datum that is a clean rule with end stops rather than a graduated scale.
class _Engraved extends StatelessWidget {
  const _Engraved({
    required this.state,
    required this.integer,
    required this.fraction,
  });

  final MoneyState state;
  final String integer;
  final String fraction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SoftLabel('Total balance'),
        const SizedBox(height: KvSpace.s),
        _Figure(integer: integer, fraction: fraction),
        const SizedBox(height: KvSpace.sm),
        const SizedBox(
          height: 5,
          width: double.infinity,
          child: CustomPaint(painter: _DatumPainter(graduated: false)),
        ),
        const SizedBox(height: KvSpace.s),
        Text(
          switch (state) {
            MoneyState.degraded => 'As of 14:02:41 · 3 m ago',
            MoneyState.syncing => 'Still counting',
            _ => 'Updated just now',
          },
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 12,
            height: 16 / 12,
            color: state.stale ? KvColor.warn : KvColor.inkMetaLow,
          ),
        ),
      ],
    );
  }
}

/// **C · Instrument.** The export's own reading, kept for comparison: tracked
/// mono caps, a graduated datum, the unit and the reading time engraved beneath
/// the scale. Precise, and on glass it reads as telemetry rather than money.
class _Instrument extends StatelessWidget {
  const _Instrument({
    required this.state,
    required this.integer,
    required this.fraction,
  });

  final MoneyState state;
  final String integer;
  final String fraction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _MicroLabel('TOTAL BALANCE'),
        const SizedBox(height: KvSpace.sm),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                integer,
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 46,
                  height: 52 / 46,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.5,
                  color: KvColor.ink,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                '.$fraction',
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 22,
                  fontWeight: FontWeight.w400,
                  color: KvColor.inkDim,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: KvSpace.s),
        const SizedBox(
          height: 7,
          width: double.infinity,
          child: CustomPaint(painter: _DatumPainter()),
        ),
        const SizedBox(height: KvSpace.s),
        Row(
          children: [
            const _MicroLabel('KAS'),
            const Spacer(),
            _MicroLabel(switch (state) {
              MoneyState.degraded => 'AS OF 14:02:41 · 3 M AGO',
              MoneyState.syncing => 'STILL COUNTING',
              _ => 'UPDATED JUST NOW',
            }, tone: state.stale ? KvColor.warn : KvColor.inkMetaLow),
          ],
        ),
      ],
    );
  }
}

(Color, String) _trust(MoneyState state) => switch (state) {
  MoneyState.degraded => (KvColor.warn, 'Link lost — showing last known'),
  MoneyState.syncing => (KvColor.warn, 'Counting your coins'),
  _ => (KvColor.ok, 'Node responding'),
};

/// Sentence case, Inter, no tracking — a label a person reads, not one an
/// instrument wears.
class _SoftLabel extends StatelessWidget {
  const _SoftLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 13,
      height: 18 / 13,
      color: KvColor.inkDim,
    ),
  );
}

/// The graduated datum. Long risers mark the ends, a taller notch marks the
/// decimal, and short graduations run between — a gauge's zero mark, at the
/// one place in the app a number needs to read as an instrument reading.
class _DatumPainter extends CustomPainter {
  const _DatumPainter({this.graduated = true});

  /// A graduated datum reads as a measuring scale. Ungraduated, it is simply
  /// the rule the figure stands on — which is what a balance actually wants.
  final bool graduated;

  @override
  void paint(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = KvColor.datum
      ..strokeWidth = 1
      ..isAntiAlias = false;
    canvas.drawLine(Offset(0, 0.5), Offset(size.width, 0.5), rule);

    if (!graduated) {
      final stop = Paint()
        ..color = KvColor.tick
        ..strokeWidth = 1
        ..isAntiAlias = false;
      canvas.drawLine(const Offset(0.5, 0), const Offset(0.5, 5), stop);
      canvas.drawLine(
        Offset(size.width - 0.5, 0),
        Offset(size.width - 0.5, 5),
        stop,
      );
      return;
    }

    // Graduations every 12dp, taller every fifth — the rhythm of a scale.
    final tick = Paint()
      ..color = KvColor.datum
      ..strokeWidth = 1
      ..isAntiAlias = false;
    var i = 0;
    for (double x = 0; x <= size.width; x += 12, i++) {
      final h = i % 5 == 0 ? 4.0 : 2.0;
      canvas.drawLine(Offset(x + 0.5, 1), Offset(x + 0.5, 1 + h), tick);
    }

    // The end stops, brighter, so the scale has a beginning and an end.
    final stop = Paint()
      ..color = KvColor.tick
      ..strokeWidth = 1
      ..isAntiAlias = false;
    canvas.drawLine(const Offset(0.5, 0), const Offset(0.5, 7), stop);
    canvas.drawLine(
      Offset(size.width - 0.5, 0),
      Offset(size.width - 0.5, 7),
      stop,
    );
  }

  @override
  bool shouldRepaint(_DatumPainter old) => old.graduated != graduated;
}

class _InFlightLine extends StatelessWidget {
  const _InFlightLine();

  @override
  Widget build(BuildContext context) {
    // BG-8: money in flight lives on a surface that stays until it settles.
    // Never a toast.
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.sm,
      ),
      decoration: BoxDecoration(
        color: KvColor.chip,
        borderRadius: BorderRadius.circular(KvRadius.plate),
        border: Border.all(color: KvColor.plateDivider),
      ),
      child: Row(
        children: [
          const _Lamp(KvColor.warn),
          const SizedBox(width: KvSpace.sm),
          const Expanded(
            child: Text(
              'Leaving now',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: KvColor.inkDim,
              ),
            ),
          ),
          Text(
            '− 12.40000000',
            style: const TextStyle(
              fontFamily: KvFont.mono,
              fontSize: 13,
              color: KvColor.risk,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Trust line — a lamp, plain English, and the cadence.
// ─────────────────────────────────────────────────────────────────────────────

class _TrustLine extends StatelessWidget {
  const _TrustLine({required this.state});

  final MoneyState state;

  @override
  Widget build(BuildContext context) {
    final (Color lamp, String words) = switch (state) {
      MoneyState.degraded => (KvColor.warn, 'Link lost — showing last known'),
      MoneyState.syncing => (KvColor.warn, 'Counting your coins'),
      _ => (KvColor.ok, 'Node responding'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      child: Row(
        children: [
          _Lamp(lamp),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: Text(
              words,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w500,
                color: KvColor.inkDim,
              ),
            ),
          ),
          const SizedBox(width: KvSpace.sm),
          _Cadence(running: state.cadenceRunning),
        ],
      ),
    );
  }
}

/// A 6dp lamp under an 8dp bloom, no spread — §1.5's only simulated light
/// besides the cadence and the sign ring. The words beside it carry the
/// meaning; the lamp is never alone (BG-7).
class _Lamp extends StatelessWidget {
  const _Lamp(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) {
    final bloom = switch (color) {
      KvColor.ok => KvColor.okBloom,
      KvColor.risk => KvColor.riskBloom,
      _ => KvColor.warnBloom,
    };
    return ExcludeSemantics(
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: bloom, blurRadius: 8)],
        ),
      ),
    );
  }
}

/// The cadence — five bars breathing at block rhythm. It is the app's ONE
/// loading indicator and its liveness signal at once, and it **freezes** the
/// instant the link dies, which is what makes "live" a felt thing rather than
/// a claimed one (BG-8).
class _Cadence extends StatefulWidget {
  const _Cadence({required this.running});

  final bool running;

  @override
  State<_Cadence> createState() => _CadenceState();
}

class _CadenceState extends State<_Cadence>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: KvMotion.breath,
  );

  static const _heights = <double>[6, 10, 14, 10, 6];

  @override
  void initState() {
    super.initState();
    if (widget.running) _c.repeat();
  }

  @override
  void didUpdateWidget(_Cadence old) {
    super.didUpdateWidget(old);
    if (widget.running && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.running && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stagger =
        KvMotion.cadenceStagger.inMilliseconds / KvMotion.breath.inMilliseconds;
    return ExcludeSemantics(
      child: SizedBox(
        height: 14,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _heights.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Container(
                  width: 3,
                  height: _heights[i],
                  color: KvColor.primary.withValues(
                    alpha: widget.running
                        ? 0.15 +
                              0.85 *
                                  (0.5 -
                                          0.5 *
                                              math.cos(
                                                2 *
                                                    math.pi *
                                                    ((_c.value - i * stagger) %
                                                        1.0),
                                              ))
                                      .clamp(0.0, 1.0)
                        : KvFreshness.opacityStale,
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

class _DegradedNotice extends StatelessWidget {
  const _DegradedNotice();

  @override
  Widget build(BuildContext context) {
    // Amber, because the truth is incomplete — not red, which would claim
    // money is at risk when none is (BG-7).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: KvSpace.m,
          vertical: KvSpace.sm,
        ),
        decoration: BoxDecoration(
          color: KvColor.noticeWarnFill,
          borderRadius: BorderRadius.circular(KvRadius.plate),
          border: Border.all(color: KvColor.noticeWarnEdge),
        ),
        child: Row(
          children: [
            const _Lamp(KvColor.warn),
            const SizedBox(width: KvSpace.sm),
            const Expanded(
              child: Text(
                'Your money is safe. This is the last balance the network '
                'confirmed — it may have moved since.',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 19 / 13,
                  color: KvColor.inkDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The feed — a ledger, not cards. Rhythm from spacing (BG-1).
// ─────────────────────────────────────────────────────────────────────────────

class _Entry {
  const _Entry(
    this.glyph,
    this.title,
    this.peer,
    this.amount,
    this.tone,
    this.weight,
    this.status,
    this.statusLamp,
    this.age,
  );

  final _Glyph glyph;
  final String title;
  final String peer;
  final String amount;
  final Color tone;
  final FontWeight weight;
  final String status;
  final Color statusLamp;
  final String age;
}

const _entries = <_Entry>[
  _Entry(
    _Glyph.arrowIn,
    'Received',
    'from kaspa:qz0k4vnr…s8fjm2wa',
    '+ 24.00',
    KvColor.ok,
    FontWeight.w600,
    'final',
    KvColor.ok,
    '12 s',
  ),
  _Entry(
    _Glyph.arrowOut,
    'Sent',
    'to kaspa:qpzt3vw8…x2mne4ka',
    '− 12.40',
    KvColor.risk,
    FontWeight.w400,
    'settling 4/10',
    KvColor.warn,
    '1 m',
  ),
  _Entry(
    _Glyph.arrowIn,
    'Received',
    'from kaspa:qz0k4vnr…s8fjm2wa',
    '+ 180.00',
    KvColor.ok,
    FontWeight.w600,
    'final',
    KvColor.ok,
    '2 h',
  ),
  _Entry(
    _Glyph.selfSend,
    'Consolidated',
    'internal · coins merged',
    '0.00',
    KvColor.inkDim,
    FontWeight.w400,
    'final · fee 0.00001',
    KvColor.ok,
    '1 d',
  ),
];

class _Feed extends StatelessWidget {
  const _Feed({required this.state, required this.variant});

  final MoneyState state;
  final HeroVariant variant;

  @override
  Widget build(BuildContext context) {
    if (state == MoneyState.empty) return const _EmptyState();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
          child: Row(
            children: [
              if (variant.instrumentRegister) ...[
                Container(width: 2, height: 10, color: KvColor.tick),
                const SizedBox(width: KvSpace.s),
                const _MicroLabel('ACTIVITY'),
              ] else
                const Text(
                  'Activity',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w600,
                    color: KvColor.ink,
                  ),
                ),
              if (state == MoneyState.degraded) ...[
                const Spacer(),
                if (variant.instrumentRegister)
                  const _MicroLabel('COMPLETE TO 14:02', tone: KvColor.warn)
                else
                  const Text(
                    'Complete to 14:02',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 12,
                      height: 16 / 12,
                      color: KvColor.warn,
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: KvSpace.m),
        for (final e in _entries) _Row(entry: e, stale: state.stale),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry, required this.stale});

  final _Entry entry;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: stale ? KvFreshness.opacityStale : 1,
      child: Padding(
        // 20dp rhythm, no dividers in motion — the ledger reads by spacing.
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          10,
          KvSpace.gutter,
          10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: CustomPaint(
                size: const Size(KvGlyph.grid, KvGlyph.grid),
                painter: _GlyphPainter(entry.glyph, tone: entry.tone),
              ),
            ),
            const SizedBox(width: KvSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 15,
                      height: 20 / 15,
                      fontWeight: FontWeight.w500,
                      color: KvColor.ink,
                    ),
                  ),
                  const SizedBox(height: 1),
                  // Full width, so the compact form is never truncated twice.
                  Text(
                    entry.peer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 12,
                      height: 16 / 12,
                      color: KvColor.inkMeta,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Lamp(entry.statusLamp),
                      const SizedBox(width: 5),
                      Text(
                        '${entry.status} · ${entry.age}',
                        style: const TextStyle(
                          fontFamily: KvFont.mono,
                          fontSize: 11,
                          height: 15 / 11,
                          color: KvColor.inkMetaLow,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: KvSpace.sm),
            // Direction rides four ways at once — word, sign, colour and
            // weight — so the row survives greyscale, colour-blindness and a
            // screen reader (BG-7).
            Text(
              entry.amount,
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: entry.weight,
                color: entry.tone,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one empty-state pattern: etched glyph, one truth, one nudge. Emptiness
/// is a real state of a real wallet — never an apology, never an illustration.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.gutter,
        KvSpace.xl,
        KvSpace.gutter,
        0,
      ),
      child: Column(
        children: [
          const CustomPaint(
            size: Size(KvGlyph.grid, KvGlyph.grid),
            painter: _GlyphPainter(_Glyph.diamond, tone: KvColor.etch),
          ),
          const SizedBox(height: KvSpace.m),
          const Text(
            'Nothing has moved yet',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 15,
              height: 22 / 15,
              color: KvColor.inkDim,
            ),
          ),
          const SizedBox(height: KvSpace.xs),
          const Text(
            'Your address is ready to receive.',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkMetaLow,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Thumb arc — Send and Receive. On an empty wallet the light flips to Receive,
// because the brightest thing on screen is always the most sensible next act.
// ─────────────────────────────────────────────────────────────────────────────

class _ThumbActions extends StatelessWidget {
  const _ThumbActions({required this.state});

  final MoneyState state;

  @override
  Widget build(BuildContext context) {
    final empty = state == MoneyState.empty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.gutter,
        KvSpace.sm,
        KvSpace.gutter,
        KvSpace.m,
      ),
      child: Row(
        children: [
          Expanded(
            child: _Action(label: 'Receive', primary: empty, onTap: () {}),
          ),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: _Action(
              label: 'Send',
              primary: !empty,
              // BG-12: a disabled control always says why, in words.
              disabledReason: empty ? 'Nothing to send yet' : null,
              onTap: () {},
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.primary,
    required this.onTap,
    this.disabledReason,
  });

  final String label;
  final bool primary;
  final VoidCallback onTap;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final disabled = disabledReason != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          enabled: !disabled,
          child: InkWell(
            onTap: disabled ? null : onTap,
            borderRadius: BorderRadius.circular(KvRadius.panel),
            child: Container(
              height: KvSpace.control,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // Teal fills exactly one thing on this screen: the single
                // primary action (BG-2).
                color: primary && !disabled ? KvColor.primary : KvColor.chip,
                borderRadius: BorderRadius.circular(KvRadius.panel),
                border: primary && !disabled
                    ? null
                    : Border.all(color: KvColor.edgeHi),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  color: primary && !disabled
                      ? KvColor.onPrimary
                      : (disabled ? KvColor.inkMeta : KvColor.ink),
                ),
              ),
            ),
          ),
        ),
        if (disabled) ...[
          const SizedBox(height: KvSpace.xs),
          Text(
            disabledReason!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              color: KvColor.inkMetaLow,
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits.
// ─────────────────────────────────────────────────────────────────────────────

/// Silk-screened panel labelling: mono caps, wide tracking, smallest tone that
/// still clears AA on every surface it can land on.
class _MicroLabel extends StatelessWidget {
  const _MicroLabel(this.text, {this.tone = KvColor.inkMetaLow});

  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontFamily: KvFont.mono,
      fontSize: 11,
      height: 16 / 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.6,
      color: tone,
    ),
  );
}

enum _Glyph { arrowIn, arrowOut, selfSend, navDots, diamond }

/// Every glyph is 1–3 strokes on a 24dp grid at 1.75dp with square caps — the
/// icon set is drawn, not imported, which is a supply-chain decision (INV-7)
/// as much as a visual one. This is also where most of the machined character
/// actually lives, so the stroke discipline is not negotiable.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, {this.tone = KvColor.inkMeta});

  final _Glyph glyph;
  final Color tone;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / KvGlyph.grid;
    final p = Paint()
      ..color = tone
      ..style = PaintingStyle.stroke
      ..strokeWidth = KvGlyph.stroke * s
      ..strokeCap = KvGlyph.cap
      ..strokeJoin = StrokeJoin.miter;

    Path path(List<List<double>> pts) {
      final path = Path();
      for (final seg in pts) {
        path.moveTo(seg[0] * s, seg[1] * s);
        for (var i = 2; i < seg.length; i += 2) {
          path.lineTo(seg[i] * s, seg[i + 1] * s);
        }
      }
      return path;
    }

    switch (glyph) {
      case _Glyph.arrowIn:
        canvas.drawPath(
          path([
            [12, 4, 12, 15],
            [7, 10, 12, 15, 17, 10],
            [5, 20, 19, 20],
          ]),
          p,
        );
      case _Glyph.arrowOut:
        canvas.drawPath(
          path([
            [12, 20, 12, 9],
            [7, 14, 12, 9, 17, 14],
            [5, 4, 19, 4],
          ]),
          p,
        );
      case _Glyph.selfSend:
        canvas.drawPath(
          path([
            [5, 8, 16, 8],
            [13, 5, 16, 8, 13, 11],
            [19, 16, 8, 16],
            [11, 19, 8, 16, 11, 13],
          ]),
          p,
        );
      case _Glyph.navDots:
        final dot = Paint()..color = KvColor.ink;
        for (final c in const [
          Offset(7.5, 7.5),
          Offset(16.5, 7.5),
          Offset(7.5, 16.5),
          Offset(16.5, 16.5),
        ]) {
          canvas.drawCircle(Offset(c.dx * s, c.dy * s), 2.5 * s, dot);
        }
      case _Glyph.diamond:
        canvas.drawPath(
          path([
            [12, 4, 20, 12, 12, 20, 4, 12, 12, 4],
          ]),
          p,
        );
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.tone != tone;
}

/// Debug-only. Not part of the design — it exists so every state and every
/// balance treatment can be compared in one sitting instead of five builds.
class _Switcher<T> extends StatelessWidget {
  const _Switcher({
    required this.values,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final List<T> values;
  final T value;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: KvColor.well,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
        child: Row(
          children: [
            for (final v in values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: InkWell(
                  onTap: () => onChanged(v),
                  borderRadius: BorderRadius.circular(KvRadius.chip),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: v == value ? KvColor.keyPressed : KvColor.abyss,
                      borderRadius: BorderRadius.circular(KvRadius.chip),
                      border: Border.all(
                        color: v == value ? KvColor.edgeHi : KvColor.hairline,
                      ),
                    ),
                    child: Text(
                      label(v),
                      style: TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 11,
                        color: v == value ? KvColor.ink : KvColor.inkMeta,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
