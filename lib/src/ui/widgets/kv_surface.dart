import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The surface tones of §1.1 a `KvSurface` can wear, each with the job it
/// exists for and the edge the table pairs it with.
///
/// One tone, one job: the enum is what makes "is this the right surface?"
/// answerable at a call site instead of by comparing hexes. The v3.1 tones
/// that only carried a legacy alias (`notice`, `key`, `keyPressed`, `summoned`)
/// went with the aliases at UX-R8; `well` stays because `KvAddress` plates an
/// address in it and its `hairline` edge is the one a sunken entry keeps.
enum KvSurfaceTone {
  /// The ground. An absence, not a surface — it takes no edge and no radius
  /// (BG-1). Painting it deliberately is how a screen states that it is void.
  abyss,

  /// Sunken entry: fields, masked dots, word cells.
  well,

  /// Chips, pills, activity rows, secondary controls.
  chip,

  /// A bounded, earned panel.
  plate,
}

extension KvSurfaceToneTokens on KvSurfaceTone {
  /// The fill from §1.1.
  Color get fill => switch (this) {
    KvSurfaceTone.abyss => KvColor.abyss,
    KvSurfaceTone.well => KvColor.plate,
    KvSurfaceTone.chip => KvColor.chip,
    KvSurfaceTone.plate => KvColor.plate,
  };

  /// The edge §1.1 pairs with the tone. Null on [abyss], which is not a
  /// surface and so has no boundary to draw.
  ///
  /// `chip` is listed with two — `plateDivider` for a row or a plate's inner
  /// division, `edgeHi` for a nearer layer such as a control. The quiet one is
  /// the default and the loud one is passed explicitly.
  Color? get edge => switch (this) {
    KvSurfaceTone.abyss => null,
    KvSurfaceTone.well => KvColor.hairline,
    KvSurfaceTone.chip => KvColor.hairline,
    KvSurfaceTone.plate => KvColor.plateEdge,
  };

  /// The machined radius each tone rests at (§3). Small and deliberate —
  /// **surfaces are milled and controls are pills**, and the separation does
  /// the work a second colour would otherwise have to do (D-194).
  double get radius => switch (this) {
    KvSurfaceTone.abyss => 0,
    KvSurfaceTone.well => KvRadius.plate,
    KvSurfaceTone.chip => KvRadius.control,
    KvSurfaceTone.plate => KvRadius.plate,
  };
}

/// A surface: **one tone, and one honest edge where an edge is real** (BG-4).
///
/// There is no elevation, shadow, gradient, bevel or inner highlight here and
/// there is no parameter to add one — nearer is one step lighter, a recess one
/// step darker, and anything that fakes a material fails the honesty test on a
/// canvas that is literally off.
///
/// **A container is earned** (BG-1). This widget makes an earned container
/// cheap to draw correctly; it does not make one necessary. A plate that exists
/// because content needed somewhere to sit is a finding whichever primitive
/// drew it.
class KvSurface extends StatelessWidget {
  const KvSurface({
    super.key,
    this.tone = KvSurfaceTone.plate,
    this.radius,
    this.edge,
    this.edgeWidth = 1,
    this.padding,
    this.width,
    this.height,
    this.alignment,
    this.child,
  });

  final KvSurfaceTone tone;

  /// Null takes the tone's machined radius.
  final double? radius;

  /// Null takes the tone's paired edge; pass [Colors.transparent] for a
  /// surface that genuinely has no boundary to draw.
  final Color? edge;

  final double edgeWidth;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;
  final Widget? child;

  /// The radius this surface will actually paint at.
  double get resolvedRadius => radius ?? tone.radius;

  /// The edge this surface will actually paint, or null for none.
  Color? get resolvedEdge {
    final e = edge ?? tone.edge;
    return e == null || e.a == 0 ? null : e;
  }

  @override
  Widget build(BuildContext context) {
    final stroke = resolvedEdge;
    return Container(
      width: width,
      height: height,
      padding: padding,
      alignment: alignment,
      decoration: BoxDecoration(
        color: tone.fill,
        borderRadius: BorderRadius.circular(resolvedRadius),
        border: stroke == null
            ? null
            : Border.all(color: stroke, width: edgeWidth),
      ),
      child: child,
    );
  }
}
