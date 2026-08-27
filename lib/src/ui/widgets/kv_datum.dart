import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The datum — the engraved rule a key number sits on, and the system's
/// signature move (§1.2). It gives the void structure without a container,
/// which is how BG-1 is satisfied by a screen that still reads as built.
///
/// Two forms, and the difference is not cosmetic:
///
///  * **[graduated]** draws a *scale* — end stops in ambient teal, graduations
///    every [tickSpacing], taller every fifth. That is what makes a number read
///    as a measurement rather than a label, and it belongs where there is a
///    real scale to be measured against (the burial gauge).
///  * **plain** draws the rule only. **End stops turn a line into a scale, and
///    an amount being typed is not measured against one** (D-195) — a graduated
///    datum under a send field claims a calibration that does not exist.
///
/// The teal on the end stops is [KvColor.primaryMuted], which is ambient and
/// **not** an emission: it costs nothing against BG-2's cap of three (§1.5).
class KvDatum extends StatelessWidget {
  const KvDatum({super.key, this.graduated = false, this.width});

  /// Draw the end stops and graduations. Off by default: the plain rule is the
  /// common case and the scale is the exception that must be argued for.
  final bool graduated;

  /// Null stretches to the incoming constraint.
  final double? width;

  /// Graduations sit this far apart, and every fifth is [tallTick] high.
  static const double tickSpacing = 12;
  static const double shortTick = 2;
  static const double tallTick = 4;

  /// The rule itself is one logical pixel, drawn at the top of the box.
  static const double ruleWeight = 1;

  /// The end stops run from the top of the rule down this far — the tallest
  /// thing the painter draws, and therefore the graduated form's extent.
  static const double endStopHeight = 7;

  /// Extent for each form, derived from the marks rather than asserted
  /// (item 0 / L121). A caller that boxes the datum by hand can ask for the
  /// number instead of guessing it.
  static double heightFor({required bool graduated}) =>
      graduated ? endStopHeight : ruleWeight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width ?? double.infinity,
      height: heightFor(graduated: graduated),
      child: CustomPaint(painter: KvDatumPainter(graduated: graduated)),
    );
  }
}

/// The painter behind [KvDatum]. Public so a gauge that already owns a canvas
/// can lay its own scale on the same rule.
class KvDatumPainter extends CustomPainter {
  const KvDatumPainter({this.graduated = false});

  final bool graduated;

  @override
  void paint(Canvas canvas, Size size) {
    // `isAntiAlias: false` keeps a 1px engraved rule one pixel wide instead of
    // two half-lit ones — the difference between machined and smudged.
    final rule = Paint()
      ..color = KvColor.datum
      ..strokeWidth = KvDatum.ruleWeight
      ..isAntiAlias = false;
    canvas.drawLine(const Offset(0, 0.5), Offset(size.width, 0.5), rule);

    if (!graduated) return;

    var i = 0;
    for (double x = 0; x <= size.width; x += KvDatum.tickSpacing, i++) {
      final h = i % 5 == 0 ? KvDatum.tallTick : KvDatum.shortTick;
      canvas.drawLine(Offset(x + 0.5, 1), Offset(x + 0.5, 1 + h), rule);
    }

    // The end stops, in ambient teal: a calibration mark, structural rather
    // than decorative, and the brand sitting on the instrument itself (§1.5).
    final stop = Paint()
      ..color = KvColor.primaryMuted
      ..strokeWidth = KvDatum.ruleWeight
      ..isAntiAlias = false;
    canvas.drawLine(
      const Offset(0.5, 0),
      const Offset(0.5, KvDatum.endStopHeight),
      stop,
    );
    canvas.drawLine(
      Offset(size.width - 0.5, 0),
      Offset(size.width - 0.5, KvDatum.endStopHeight),
      stop,
    );
  }

  @override
  bool shouldRepaint(KvDatumPainter old) => old.graduated != graduated;
}
