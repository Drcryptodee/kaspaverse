import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'kv_glyph.dart';

/// **The glow pill** (§4): `abyss` at rest inside a 1.5 dp [KvColor.controlEdge]
/// hairline; `armed` fill, a [KvColor.primary] border and [KvGlass.armedGlow]
/// while a hand is on it.
///
/// It is the form for a **deliberate, weighty** action — the hold, *Switch
/// node*, a control committing an edit (BG-27) — and it is never the primary
/// pill's job. The primary pill is the lit one thing on a screen; this one asks
/// to be pressed on purpose.
///
/// One of exactly two things in the app that glow (BG-32); the other is the
/// orb's halo.
class KvGlowPill extends StatelessWidget {
  const KvGlowPill({
    super.key,
    required this.child,
    this.armed = false,
    this.height = KvSpace.control,
  });

  final Widget child;

  /// A hand is on it. 160 ms each way (`KvMotion.fast`, §1.8).
  final bool armed;

  /// **A MINIMUM, not a fixed height.** The label is a sentence carrying an
  /// amount, and at 320 dp / 1.3× the whole-supply figure needs three lines in
  /// the width the badge leaves it. A fixed box clips the last string a user
  /// reads before an irreversible transaction; this one grows instead (BG-14,
  /// and the measurement that found it: `"Hold to send 12.40000000 KAS"` in
  /// 151.0 × 52.0 dp).
  final double height;

  /// §4: 1.5 dp, so the resting edge reads at 12 % white without becoming a
  /// structure (§1.2 — a control is identified by its text, not its boundary).
  static const double edge = 1.5;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: KvMotion.fast,
      curve: KvMotion.curve,
      constraints: BoxConstraints(minHeight: height),
      decoration: BoxDecoration(
        color: armed ? KvColor.armed : KvColor.abyss,
        borderRadius: BorderRadius.circular(KvRadius.control),
        border: Border.all(
          color: armed ? KvColor.primary : KvColor.controlEdge,
          width: edge,
        ),
        boxShadow: armed ? KvGlass.armedGlow : const [],
      ),
      child: child,
    );
  }
}

/// **Hold to send** (BG-6, §4) — the anti-blind-signing control.
///
/// A [KvGlowPill] carrying a **46 dp ring badge at far left**: a
/// [KvColor.chipPressed] track with the [KvColor.primary] arc sweeping over it,
/// and a [KvColor.plate] 38 dp disc inside holding the fingerprint. The label
/// is centred on the pill (`S7`, measured — §4's "centred in the remaining
/// width" is the transcription; the render centres on the control).
///
/// **800 ms, linear, `AnimationBehavior.preserve`, butt caps, and the
/// background never fills.** Every one of those is load-bearing:
///
///  * *linear* — the ring is a gauge and BG-22 gives its Lie Factor as 1. On
///    the app's easing it would read 61 % closed at 200 ms, so the last 320 ms
///    of safety friction would render as the final 7 % of arc.
///  * *butt caps* — a round cap on a measuring stroke overstates the reading by
///    half a stroke at each end (BG-22).
///  * *preserve* — Flutter scales a `normal` controller to 5 % under the
///    platform's reduced-animation setting, which would turn the one control
///    that broadcasts an irreversible transaction into a 40 ms tap.
///  * *the background never fills* — the reading is the ring. A pill that
///    filled would put the same fact in two channels and let the louder one
///    (a 343 dp bar) be read while the honest one is ignored.
///
/// The **arc is measured as ink, not as the value handed to the painter**
/// (L145): [KvHoldRing.sweepFor] is the one place the value becomes an angle,
/// and the guard reads it back through a spy canvas.
class KvHold extends StatelessWidget {
  const KvHold({
    super.key,
    required this.label,
    required this.progress,
    required this.enabled,
    required this.onDown,
    required this.onUp,
    this.height = KvSpace.control,
  });

  /// Names the action **and its object** (BG-11) — "Hold to send 12.40000000
  /// KAS", never "Confirm".
  final String label;

  /// 0 → 1 over [KvMotion.deliberate]. Owned by the surface, because the
  /// surface is what fires on completion.
  final Animation<double> progress;

  final bool enabled;
  final void Function(TapDownDetails) onDown;
  final void Function([Object?]) onUp;
  final double height;

  /// §4: the badge's outer diameter.
  static const double badge = 46;

  /// The `plate` disc inside it (§4).
  static const double badgeDisc = 38;

  /// Ring stroke — **derived**: `(badge - badgeDisc) / 2`, so the track exactly
  /// fills the gap between the two circles §4 names.
  static const double ringStroke = (badge - badgeDisc) / 2;

  /// The fingerprint's box inside the disc. Illustrative weight (§2a).
  static const double glyph = 20;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // DESCRIPTIVE ONLY — no `onTap`, and that omission is the design. A
      // semantics activation is ONE discrete action, so wiring it would
      // collapse the 800 ms hold to an instant: the blind-signing defect
      // wearing an accessibility badge. The control is therefore not signable
      // under TalkBack, which is a recorded defect (D-178) awaiting a ceremony
      // that keeps the friction rather than a shortcut past it.
      button: true,
      hint:
          'Press and hold for ${KvMotion.deliberate.inMilliseconds} '
          'milliseconds to sign',
      child: GestureDetector(
        onTapDown: enabled ? onDown : null,
        onTapUp: enabled ? onUp : null,
        onTapCancel: enabled ? () => onUp() : null,
        child: AnimatedBuilder(
          animation: progress,
          builder: (context, _) {
            final t = progress.value;
            return KvGlowPill(
              armed: t > 0,
              height: height,
              child: Row(
                // The badge sits against the top of a grown pill rather than
                // floating in the middle of three lines of label.
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(width: (height - badge) / 2),
                  // The badge is a fixed square whatever the pill grows to.
                  SizedBox.square(
                    dimension: badge,
                    child: CustomPaint(
                      painter: KvHoldRing(t),
                      child: Center(
                        child: Container(
                          width: badgeDisc,
                          height: badgeDisc,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: KvColor.plate,
                          ),
                          child: Center(
                            child: KvGlyphIcon(
                              KvGlyph.fingerprint,
                              size: glyph,
                              tone: t > 0 ? KvColor.primary : KvColor.inkDim,
                              stroke: KvGlyphSpec.strokeIllustrative,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // **Centred in the width the badge leaves it** (§4). `S7`
                  // measures the label at the pill's own centre — but it
                  // measures a short one, where the two readings sit 22 dp
                  // apart and either looks centred. The real label carries an
                  // eight-decimal amount, and mirroring the badge's 51 dp on
                  // the right wraps it to two lines at the reference width
                  // (rendered and looked at). The law's own words win where
                  // the render cannot show the case.
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: KvSpace.s,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: KvSpace.s,
                        ),
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          // **Unbounded.** At 320 dp / 1.3× the whole-supply
                          // figure needs four lines in the width the badge
                          // leaves; any cap is a number that clips the string
                          // this control exists to state (BG-14, measured).
                          maxLines: null,
                          // **It wraps; it never shrinks.** The label carries an
                          // amount, and the last string a user reads before an
                          // irreversible transaction may not land under the
                          // 11 dp floor (BG-14). The wrap falls at a space, so
                          // the figure and its unit stay on one line.
                          style: TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 16,
                            height: 20 / 16,
                            fontWeight: FontWeight.w600,
                            fontVariations: KvWeight.w600,
                            color: enabled ? KvColor.ink : KvColor.inkMeta,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: (height - badge) / 2),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The badge's ring: a [KvColor.chipPressed] track with the [KvColor.primary]
/// arc over it, **from twelve o'clock, clockwise, linear, butt-capped**.
class KvHoldRing extends CustomPainter {
  const KvHoldRing(this.t);

  /// 0 → 1.
  final double t;

  /// Twelve o'clock, in canvas angles.
  static const double start = -math.pi / 2;

  /// **The one place a value becomes an angle** (BG-22 / L145). A guard reads
  /// the painted sweep back through this rather than trusting the input.
  static double sweepFor(double t) => 2 * math.pi * t.clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final r = (size.width - KvHold.ringStroke) / 2;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: r,
    );
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = KvHold.ringStroke
      // BG-22: butt caps on a measuring stroke. A round cap adds half a stroke
      // of ink at each end — at this radius, 3.5° of overstatement per end.
      ..strokeCap = StrokeCap.butt
      ..color = KvColor.chipPressed;
    canvas.drawCircle(rect.center, r, p);
    if (t <= 0) return;
    canvas.drawArc(rect, start, sweepFor(t), false, p..color = KvColor.primary);
  }

  @override
  bool shouldRepaint(KvHoldRing old) => old.t != t;
}
