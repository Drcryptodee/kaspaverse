import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Every glyph the app draws (§2). The set is **drawn, not imported**: there is
/// no icon package, and Material's `Icons.*` is not the answer either — the
/// call, and the case against it, is **D-205**.
///
/// **`Icons.*` has not been swept out of `lib/` yet, and this file does not
/// claim otherwise.** Fifty-two Material icons are still live across sixteen
/// screens; each retires in its own sub-phase, because a glyph swap is a
/// composition change and every one of those screens is having its
/// composition rebuilt anyway (`design_system.md` §9.3, divergence 3).
///
/// Adding a glyph is one enum case plus one `case` arm in [KvGlyphPainter],
/// which is deliberately the whole cost: this file is the single place a glyph
/// is chosen, so the decision stays one file wide **in both directions** — if
/// D-205 is ever reversed, this is the only file that changes.
enum KvMark {
  /// Money arriving.
  arrowIn,

  /// Money leaving.
  arrowOut,

  /// A self-send: value that never leaves the wallet.
  selfSend,

  /// The nav trigger — a 2×2 dot field, never a hamburger (§4).
  navDots,

  /// The one empty-state mark.
  diamond,

  /// "This goes somewhere." Rotate it for a back affordance.
  chevron,

  /// Destination: money.
  money,

  /// Destination: messages.
  chat,

  /// Destination: games.
  games,

  /// Destination: contracts.
  contracts,

  /// Destination: finance.
  finance,

  /// Destination: assets.
  assets,

  /// Destination: settings.
  settings,

  /// The lock, and locking.
  lock,

  /// Paste into a field.
  paste,

  /// Scan a code into a field.
  scan,

  /// History, and anything that reaches backwards in time.
  history,

  /// Overflow.
  kebab,

  /// Done. Two strokes on the 24dp grid, drawn at the same weight as every
  /// other mark — a machined tick, not a celebration (§7: the vault register
  /// does not cheer).
  check,
}

/// One glyph, painted.
///
/// **1–3 strokes on a 24dp grid at 1.75dp with square caps** (§2). The stroke
/// scales with [size] because a glyph rendered smaller is a scaled 24dp glyph,
/// not a thinner one — at the 24dp grid size the stroke is exactly the 1.75dp
/// the law names, and [strokeFor] is where any other size gets its number.
///
/// Decorative by default: without [semanticLabel] the glyph is excluded from
/// the semantics tree, because the control around it is what a screen reader
/// should name (§1.2a — a control is identified by its text, never by its
/// mark). Pass [semanticLabel] only when the glyph is the sole identification
/// of what it sits in, and then BG-14 requires [tone] to clear 3:1 as a
/// graphical object.
class KvGlyphIcon extends StatelessWidget {
  const KvGlyphIcon(
    this.mark, {
    super.key,
    this.size = KvGlyph.grid,
    this.tone = KvColor.inkMeta,
    this.semanticLabel,
  });

  final KvMark mark;

  /// Side of the square the glyph is painted into, in logical pixels. The
  /// 24dp grid is scaled to it uniformly.
  final double size;

  final Color tone;

  /// Names the glyph to a screen reader. Null (the default) excludes it.
  final String? semanticLabel;

  /// The rendered stroke width at a given glyph [size] — the 1.75dp law scaled
  /// off the 24dp grid. Exposed so a caller that must line a glyph up with a
  /// rule can ask rather than guess (item 0: geometry is computed, never
  /// asserted in a comment).
  static double strokeFor(double size) =>
      KvGlyph.stroke * (size / KvGlyph.grid);

  @override
  Widget build(BuildContext context) {
    final painted = CustomPaint(
      size: Size.square(size),
      painter: KvGlyphPainter(mark, tone: tone),
    );
    final label = semanticLabel;
    return label == null
        ? ExcludeSemantics(child: painted)
        : Semantics(label: label, image: true, child: painted);
  }
}

/// The painter behind [KvGlyphIcon]. Public so a composite surface can paint a
/// glyph into a canvas it already owns; everything else should use the widget.
///
/// Assumes a **square** canvas — the 24dp grid is scaled by `size.width`, so a
/// non-square [Size] crops rather than distorts.
class KvGlyphPainter extends CustomPainter {
  const KvGlyphPainter(this.mark, {this.tone = KvColor.inkMeta});

  final KvMark mark;
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

    // Every glyph is a list of polylines on the 24dp grid: [x0,y0, x1,y1, …].
    Path path(List<List<double>> polylines) {
      final path = Path();
      for (final seg in polylines) {
        path.moveTo(seg[0] * s, seg[1] * s);
        for (var i = 2; i < seg.length; i += 2) {
          path.lineTo(seg[i] * s, seg[i + 1] * s);
        }
      }
      return path;
    }

    // A filled dot is still one "stroke" in the §2 sense — it is a mark, not a
    // shape with an outline, and outlining a 2dp dot at 1.75dp is a blob.
    Paint filled() => Paint()..color = tone;

    switch (mark) {
      case KvMark.arrowIn:
        canvas.drawPath(
          path([
            [12, 4, 12, 15],
            [7, 10, 12, 15, 17, 10],
            [5, 20, 19, 20],
          ]),
          p,
        );
      case KvMark.arrowOut:
        canvas.drawPath(
          path([
            [12, 20, 12, 9],
            [7, 14, 12, 9, 17, 14],
            [5, 4, 19, 4],
          ]),
          p,
        );
      case KvMark.selfSend:
        canvas.drawPath(
          path([
            [5, 8, 16, 8],
            [13, 5, 16, 8, 13, 11],
            [19, 16, 8, 16],
            [11, 19, 8, 16, 11, 13],
          ]),
          p,
        );
      case KvMark.navDots:
        final dot = filled();
        for (final c in const [
          Offset(7.5, 7.5),
          Offset(16.5, 7.5),
          Offset(7.5, 16.5),
          Offset(16.5, 16.5),
        ]) {
          canvas.drawCircle(Offset(c.dx * s, c.dy * s), 2.5 * s, dot);
        }
      case KvMark.money:
        // A note, not a coin: a circle with strokes through it reads as a
        // symbol to be decoded, and a glyph you decode has already failed.
        canvas.drawPath(
          path([
            [3.5, 6.5, 20.5, 6.5, 20.5, 17.5, 3.5, 17.5, 3.5, 6.5],
          ]),
          p,
        );
        canvas.drawCircle(Offset(12 * s, 12 * s), 2.6 * s, p);
      case KvMark.chat:
        canvas.drawPath(
          path([
            [4.5, 5.5, 19.5, 5.5, 19.5, 15.5, 9.5, 15.5, 5.5, 19.5, 5.5, 5.5],
          ]),
          p,
        );
      case KvMark.games:
        canvas.drawPath(
          path([
            [5, 5, 19, 5, 19, 19, 5, 19, 5, 5],
          ]),
          p,
        );
        final dot = filled();
        for (final c in const [
          Offset(9, 9),
          Offset(15, 9),
          Offset(9, 15),
          Offset(15, 15),
        ]) {
          canvas.drawCircle(Offset(c.dx * s, c.dy * s), 1.4 * s, dot);
        }
      case KvMark.contracts:
        canvas.drawPath(
          path([
            [7, 4, 17, 4, 17, 20, 7, 20, 7, 4],
            [10, 9, 14, 9],
            [10, 13, 14, 13],
          ]),
          p,
        );
      case KvMark.finance:
        // A trend on a baseline. The export's three-bar mark read as "++".
        canvas.drawPath(
          path([
            [4, 19, 20, 19],
            [5, 15, 9.5, 10.5, 13.5, 13.5, 19, 7],
            [15, 7, 19, 7, 19, 11],
          ]),
          p,
        );
      case KvMark.assets:
        canvas.drawPath(
          path([
            [12, 4, 20, 8.5, 20, 15.5, 12, 20, 4, 15.5, 4, 8.5, 12, 4],
          ]),
          p,
        );
      case KvMark.settings:
        // Sliders. A cross-haired dot is a target, not a setting.
        canvas.drawPath(
          path([
            [4, 7, 20, 7],
            [4, 12, 20, 12],
            [4, 17, 20, 17],
          ]),
          p,
        );
        final knob = filled();
        for (final c in const [Offset(9, 7), Offset(15, 12), Offset(11, 17)]) {
          canvas.drawCircle(Offset(c.dx * s, c.dy * s), 2.1 * s, knob);
        }
      case KvMark.lock:
        canvas.drawPath(
          path([
            [6, 11, 18, 11, 18, 20, 6, 20, 6, 11],
          ]),
          p,
        );
        final shackle = Path()
          ..addArc(
            Rect.fromCircle(center: Offset(12 * s, 11 * s), radius: 4 * s),
            math.pi,
            math.pi,
          );
        canvas.drawPath(shackle, p);
      case KvMark.paste:
        canvas.drawPath(
          path([
            [6, 6, 18, 6, 18, 20, 6, 20, 6, 6],
            [9.5, 3.5, 14.5, 3.5, 14.5, 7.5, 9.5, 7.5, 9.5, 3.5],
          ]),
          p,
        );
      case KvMark.scan:
        // A viewfinder: four corners and nothing between them.
        canvas.drawPath(
          path([
            [4, 9, 4, 4, 9, 4],
            [15, 4, 20, 4, 20, 9],
            [20, 15, 20, 20, 15, 20],
            [9, 20, 4, 20, 4, 15],
          ]),
          p,
        );
      case KvMark.history:
        canvas.drawPath(
          path([
            [12, 7, 12, 12, 16, 14],
            [4, 8, 4, 4, 8, 8],
          ]),
          p,
        );
        canvas.drawArc(
          Rect.fromCircle(center: Offset(12 * s, 12 * s), radius: 8 * s),
          -2.5,
          5.4,
          false,
          p,
        );
      case KvMark.kebab:
        final d = filled();
        for (final y in const [6.5, 12.0, 17.5]) {
          canvas.drawCircle(Offset(12 * s, y * s), 1.7 * s, d);
        }
      case KvMark.chevron:
        canvas.drawPath(
          path([
            [9, 5, 16, 12, 9, 19],
          ]),
          p,
        );
      case KvMark.diamond:
        canvas.drawPath(
          path([
            [12, 4, 20, 12, 12, 20, 4, 12, 12, 4],
          ]),
          p,
        );
      case KvMark.check:
        canvas.drawPath(
          path([
            [5, 12.5, 10, 17.5, 19, 6.5],
          ]),
          p,
        );
    }
  }

  @override
  bool shouldRepaint(KvGlyphPainter old) =>
      old.mark != mark || old.tone != tone;
}
