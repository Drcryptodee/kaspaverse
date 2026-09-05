import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Every glyph the app draws (§2, §2a). The set is **drawn, not imported**:
/// there is no icon package, and Material's `Icons.*` is not the answer either
/// — the call, and the case against it, is **D-205**.
///
/// **The geometry is Lucide's, transcribed** (§2a, founder ruling 2026-09-04,
/// D-259/D-261: *"the icons used as seen in the screenshots, exactly"*). Every
/// mark below carries the Lucide name it was taken from and its path data
/// verbatim, so a reviewer can put it beside lucide.dev and see one shape. The
/// three tweaks §2a names are applied at paint time, never to the data: stroke
/// 2.5 instead of 2, round caps and joins, and no fill — a dot is a zero-length
/// round-capped stroke (`h.01`), exactly as Lucide draws it.
///
/// **`Icons.*` has not been swept out of `lib/` yet, and this file does not
/// claim otherwise.** Fifty-two Material icons are still live across sixteen
/// screens; each retires in its own sub-phase, because a glyph swap is a
/// composition change and every one of those screens is having its
/// composition rebuilt anyway (`design_system.md` §9.3, divergence 3).
///
/// Adding a glyph is one enum case plus one `case` arm in [KvGlyphPainter] —
/// the Lucide outline, pasted — which is deliberately the whole cost: this file
/// is the single place a glyph is chosen, so the decision stays one file wide
/// **in both directions**.
enum KvGlyph {
  /// Money arriving. Lucide `arrow-down-left`.
  arrowIn,

  /// Money leaving. Lucide `arrow-up-right`.
  arrowOut,

  /// A self-send: value that never leaves the wallet. Lucide `repeat`.
  selfSend,

  /// The one empty-state mark. Lucide `gem`.
  diamond,

  /// "This goes somewhere." Lucide `chevron-right`; rotate it for back.
  chevron,

  /// Destination: the wallet. Lucide `wallet` — the billfold with a clasp
  /// (render `S2 · Drawer`).
  money,

  /// Destination: messages. Lucide `message-circle`.
  chat,

  /// Destination: games. Lucide `gamepad-2`.
  games,

  /// Destination: contracts. Lucide `file-text`.
  contracts,

  /// Destination: finance. Lucide `chart-line`.
  finance,

  /// Tokens. Lucide `coins`.
  assets,

  /// Destination: settings. Lucide `sliders-horizontal` — three rails with a
  /// thumb on each, which is what a setting is; a cog is a machine.
  settings,

  /// Destination: identity — **who you are to other people**, as distinct
  /// from [settings], which is how the app behaves. Lucide `user-round`: a
  /// head and a pair of shoulders (render `S2 · Drawer`).
  identity,

  /// Destination: the node and the link. Lucide `radio`.
  network,

  /// Destination: security; a trust statement. Lucide `shield-check`.
  shield,

  /// Destination: help. Lucide `circle-question-mark`.
  help,

  /// The lock, and locking. Lucide `lock`.
  lock,

  /// Paste into a field. Lucide `clipboard`.
  paste,

  /// Open the camera. Lucide `scan-line` (render `S1 · Home`, top right).
  scan,

  /// History, and anything that reaches backwards in time. Lucide `history`.
  history,

  /// Overflow. Lucide `ellipsis` — three dots, each a zero-length stroke.
  kebab,

  /// Done. Lucide `check`, drawn at the same weight as every other mark — a
  /// machined tick, not a celebration (§7: the vault register does not cheer).
  check,

  /// Delete the character to the left. Lucide `delete` — the wedge with a
  /// cross, the form every keyboard on earth uses — and **drawn rather than
  /// borrowed** (BG-25, D-229): `JetBrainsMono-Variable.ttf` has no U+232B.
  backspace,

  /// Shift, on the secret keyboard. Lucide `arrow-big-up`, one closed stroke.
  shift,

  /// Copy this — an address, a transaction id. Lucide `copy`.
  copy,

  /// This leaves the app. Lucide `external-link`.
  external,

  /// Hand this to another app. Lucide `share-2`.
  share,

  /// Hand this out of the app — `S9`'s own mark at the top right (founder, on
  /// glass 2026-09-05). Lucide `share`: a tray with the arrow leaving it.
  shareUp,

  /// The hold's badge, and biometrics. Lucide `fingerprint` (shipped in this
  /// Lucide build under the name `fingerprint-pattern`). **Illustrative**, so
  /// it takes [KvGlyphSpec.strokeIllustrative] rather than the 2.5 default —
  /// nine contours at 2.5 in a 20 dp box read as a smudge (§2a, weights by job).
  fingerprint,

  /// Dismiss, clear, close. Lucide `x`.
  close,
}

/// One glyph, painted.
///
/// **Lucide geometry on the 24 dp grid at 2.5 dp with round caps** (§2, §2a).
/// The stroke scales with [size] because a glyph rendered smaller is a scaled
/// 24 dp glyph, not a thinner one — at the grid size the stroke is exactly the
/// 2.5 dp the law names, and [strokeFor] is where any other size gets its
/// number.
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
    this.size = KvGlyphSpec.grid,
    this.tone = KvColor.inkMeta,
    this.semanticLabel,
    this.stroke,
  });

  final KvGlyph mark;

  /// Side of the square the glyph is painted into, in logical pixels. The
  /// 24dp grid is scaled to it uniformly.
  final double size;

  final Color tone;

  /// Names the glyph to a screen reader. Null (the default) excludes it.
  final String? semanticLabel;

  /// The stroke **on the 24 dp grid**, before [size] scales it. Null takes
  /// [KvGlyphSpec.stroke]; BG-25 names exactly three other values —
  /// [KvGlyphSpec.strokeArrow] for a direction arrow inside a value disc,
  /// [KvGlyphSpec.strokeCheck] for the check, and
  /// [KvGlyphSpec.strokeIllustrative] where a mark is illustration rather than
  /// icon. Anything else is a finding.
  final double? stroke;

  /// The rendered stroke width at a given glyph [size] — [KvGlyphSpec.stroke]
  /// scaled off the 24 dp grid (2.5 dp round-capped since v4.2, BG-25).
  /// Exposed so a caller that must line a glyph up with a rule can ask rather
  /// than guess (item 0: geometry is computed, never asserted).
  static double strokeFor(double size, {double? stroke}) =>
      (stroke ?? KvGlyphSpec.stroke) * (size / KvGlyphSpec.grid);

  @override
  Widget build(BuildContext context) {
    final painted = CustomPaint(
      size: Size.square(size),
      painter: KvGlyphPainter(mark, tone: tone, stroke: stroke),
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
  const KvGlyphPainter(this.mark, {this.tone = KvColor.inkMeta, this.stroke});

  final KvGlyph mark;
  final Color tone;

  /// The stroke on the 24 dp grid; null takes [KvGlyphSpec.stroke].
  final double? stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / KvGlyphSpec.grid;
    final p = Paint()
      ..color = tone
      ..style = PaintingStyle.stroke
      ..strokeWidth = (stroke ?? KvGlyphSpec.stroke) * s
      ..strokeCap = KvGlyphSpec.cap
      ..strokeJoin = KvGlyphSpec.join;

    // One Lucide `<path d>` (or several, one contour each), stroked.
    void path(List<String> data) {
      for (final d in data) {
        canvas.drawPath(kvSvgPath(d, s), p);
      }
    }

    // A Lucide `<circle>`, stroked — never filled (§2a rule 4).
    void circle(double cx, double cy, double r) =>
        canvas.drawCircle(Offset(cx * s, cy * s), r * s, p);

    // A Lucide `<rect rx>`, stroked.
    void rect(double x, double y, double w, double h, double rx) =>
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x * s, y * s, w * s, h * s),
            Radius.circular(rx * s),
          ),
          p,
        );

    // A Lucide `<line>`.
    void line(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(x1 * s, y1 * s), Offset(x2 * s, y2 * s), p);

    switch (mark) {
      case KvGlyph.arrowIn:
        path(const ['M17 7 7 17', 'M17 17H7V7']);
      case KvGlyph.arrowOut:
        path(const ['M7 7h10v10', 'M7 17 17 7']);
      case KvGlyph.selfSend:
        path(const [
          'm17 2 4 4-4 4',
          'M3 11v-1a4 4 0 0 1 4-4h14',
          'm7 22-4-4 4-4',
          'M21 13v1a4 4 0 0 1-4 4H3',
        ]);
      case KvGlyph.diamond:
        path(const [
          'M10.5 3 8 9l4 13 4-13-2.5-6',
          'M17 3a2 2 0 0 1 1.6.8l3 4a2 2 0 0 1 .013 2.382l-7.99 10.986a2 2 0 '
              '0 1-3.247 0l-7.99-10.986A2 2 0 0 1 2.4 7.8l2.998-3.997A2 2 0 0 '
              '1 7 3z',
          'M2 9h20',
        ]);
      case KvGlyph.chevron:
        path(const ['m9 18 6-6-6-6']);
      case KvGlyph.money:
        path(const [
          'M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 '
              '0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1',
          'M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4',
        ]);
      case KvGlyph.chat:
        path(const [
          'M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 '
              '1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719',
        ]);
      case KvGlyph.games:
        line(6, 11, 10, 11);
        line(8, 9, 8, 13);
        line(15, 12, 15.01, 12);
        line(18, 10, 18.01, 10);
        path(const [
          'M17.32 5H6.68a4 4 0 0 0-3.978 3.59c-.006.052-.01.101-.017.152C2.604 '
              '9.416 2 14.456 2 16a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.414-1.414A2 '
              '2 0 0 1 9.828 16h4.344a2 2 0 0 1 1.414.586L17 18c.5.5 1 1 2 1a3 '
              '3 0 0 0 3-3c0-1.545-.604-6.584-.685-7.258-.007-.05-.011-.1-.017'
              '-.151A4 4 0 0 0 17.32 5z',
        ]);
      case KvGlyph.contracts:
        path(const [
          'M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 '
              '3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z',
          'M14 2v5a1 1 0 0 0 1 1h5',
          'M10 9H8',
          'M16 13H8',
          'M16 17H8',
        ]);
      case KvGlyph.finance:
        path(const ['M3 3v16a2 2 0 0 0 2 2h16', 'm19 9-5 5-4-4-3 3']);
      case KvGlyph.assets:
        path(const [
          'M13.744 17.736a6 6 0 1 1-7.48-7.48',
          'M15 6h1v4',
          'm6.134 14.768.866-.5 2 3.464',
        ]);
        circle(16, 8, 6);
      case KvGlyph.settings:
        path(const [
          'M10 5H3',
          'M12 19H3',
          'M14 3v4',
          'M16 17v4',
          'M21 12h-9',
          'M21 19h-5',
          'M21 5h-7',
          'M8 10v4',
          'M8 12H3',
        ]);
      case KvGlyph.identity:
        circle(12, 8, 5);
        path(const ['M20 21a8 8 0 0 0-16 0']);
      case KvGlyph.network:
        path(const [
          'M16.247 7.761a6 6 0 0 1 0 8.478',
          'M19.075 4.933a10 10 0 0 1 0 14.134',
          'M4.925 19.067a10 10 0 0 1 0-14.134',
          'M7.753 16.239a6 6 0 0 1 0-8.478',
        ]);
        circle(12, 12, 2);
      case KvGlyph.shield:
        path(const [
          'M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 '
              '13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 '
              '0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z',
          'm9 12 2 2 4-4',
        ]);
      case KvGlyph.help:
        circle(12, 12, 10);
        path(const ['M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3', 'M12 17h.01']);
      case KvGlyph.lock:
        rect(3, 11, 18, 11, 2);
        path(const ['M7 11V7a5 5 0 0 1 10 0v4']);
      case KvGlyph.paste:
        rect(8, 2, 8, 4, 1);
        path(const [
          'M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 '
              '2-2h2',
        ]);
      case KvGlyph.scan:
        path(const [
          'M3 7V5a2 2 0 0 1 2-2h2',
          'M17 3h2a2 2 0 0 1 2 2v2',
          'M21 17v2a2 2 0 0 1-2 2h-2',
          'M7 21H5a2 2 0 0 1-2-2v-2',
          'M7 12h10',
        ]);
      case KvGlyph.history:
        path(const [
          'M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8',
          'M3 3v5h5',
          'M12 7v5l4 2',
        ]);
      case KvGlyph.kebab:
        // Lucide's own r = 1 circles, stroked — the pin, not a reading of it.
        circle(12, 12, 1);
        circle(19, 12, 1);
        circle(5, 12, 1);
      case KvGlyph.check:
        path(const ['M20 6 9 17l-5-5']);
      case KvGlyph.backspace:
        path(const [
          'M10 5a2 2 0 0 0-1.344.519l-6.328 5.74a1 1 0 0 0 0 1.481l6.328 '
              '5.741A2 2 0 0 0 10 19h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2z',
          'm12 9 6 6',
          'm18 9-6 6',
        ]);
      case KvGlyph.shift:
        path(const [
          'M9 13a1 1 0 0 0-1-1H5.061a1 1 0 0 1-.75-1.811l6.836-6.835a1.207 '
              '1.207 0 0 1 1.707 0l6.835 6.835a1 1 0 0 1-.75 1.811H16a1 1 0 0 '
              '0-1 1v6a1 1 0 0 1-1 1h-4a1 1 0 0 1-1-1z',
        ]);
      case KvGlyph.copy:
        rect(8, 8, 14, 14, 2);
        path(const ['M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2']);
      case KvGlyph.external:
        path(const [
          'M15 3h6v6',
          'M10 14 21 3',
          'M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6',
        ]);
      case KvGlyph.shareUp:
        path(const [
          'M12 2V15',
          'M16 6L12 2L8 6',
          'M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8',
        ]);
      case KvGlyph.share:
        circle(18, 5, 3);
        circle(6, 12, 3);
        circle(18, 19, 3);
        line(8.59, 13.51, 15.42, 17.49);
        line(15.41, 6.51, 8.59, 10.49);
      case KvGlyph.fingerprint:
        path(const [
          'M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4',
          'M14 13.12c0 2.38 0 6.38-1 8.88',
          'M17.29 21.02c.12-.6.43-2.3.5-3.02',
          'M2 12a10 10 0 0 1 18-6',
          'M2 16h.01',
          'M21.8 16c.2-2 .131-5.354 0-6',
          'M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2',
          'M8.65 22c.21-.66.45-1.32.57-2',
          'M9 6.8a6 6 0 0 1 9 5.2v2',
        ]);
      case KvGlyph.close:
        path(const ['M18 6 6 18', 'm6 6 12 12']);
    }
  }

  @override
  bool shouldRepaint(KvGlyphPainter old) =>
      old.mark != mark || old.tone != tone || old.stroke != stroke;
}

/// **SVG path data → [Path]**, scaled by [scale], for the subset Lucide uses:
/// `M L H V C S A Z` in absolute and relative forms. It exists so a mark can
/// be carried as the string lucide.dev publishes rather than as a hand
/// re-typed polyline — the transcription is then a copy, not an interpretation
/// (§2a rule 5), and a wrong glyph is a diff against one public string.
///
/// Arcs map onto [Path.arcToPoint] one-to-one (SVG's sweep flag is Flutter's
/// `clockwise`). Not supported, because Lucide never emits them: `Q T`
/// quadratics.
@visibleForTesting
Path kvSvgPath(String d, double scale) {
  final path = Path();
  final tokens = _svgTokens.allMatches(d).map((m) => m.group(0)!).toList();
  var i = 0;
  var cmd = '';
  // Current point, subpath start and the last cubic control point (for `S`).
  var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0;
  double? cx, cy;
  double num() => double.parse(tokens[i++]);
  bool more() => i < tokens.length && !_isCommand(tokens[i]);

  while (i < tokens.length) {
    if (_isCommand(tokens[i])) cmd = tokens[i++];
    final rel = cmd == cmd.toLowerCase() && cmd != 'z' && cmd != 'Z';
    double ax(double v) => rel ? x + v : v;
    double ay(double v) => rel ? y + v : v;
    switch (cmd.toUpperCase()) {
      case 'M':
        x = ax(num());
        y = ay(num());
        sx = x;
        sy = y;
        path.moveTo(x * scale, y * scale);
        cx = cy = null;
        // Subsequent pairs after a moveto are implicit linetos.
        while (more()) {
          x = ax(num());
          y = ay(num());
          path.lineTo(x * scale, y * scale);
        }
      case 'L':
        do {
          x = ax(num());
          y = ay(num());
          path.lineTo(x * scale, y * scale);
        } while (more());
        cx = cy = null;
      case 'H':
        do {
          x = ax(num());
          path.lineTo(x * scale, y * scale);
        } while (more());
        cx = cy = null;
      case 'V':
        do {
          y = ay(num());
          path.lineTo(x * scale, y * scale);
        } while (more());
        cx = cy = null;
      case 'C':
        do {
          final x1 = ax(num()), y1 = ay(num());
          final x2 = ax(num()), y2 = ay(num());
          final ex = ax(num()), ey = ay(num());
          path.cubicTo(
            x1 * scale,
            y1 * scale,
            x2 * scale,
            y2 * scale,
            ex * scale,
            ey * scale,
          );
          cx = x2;
          cy = y2;
          x = ex;
          y = ey;
        } while (more());
      case 'S':
        do {
          // The first control point reflects the previous cubic's second
          // control point through the current point; absent one, it is the
          // current point (SVG 1.1 §8.3.6).
          final x1 = cx == null ? x : 2 * x - cx;
          final y1 = cy == null ? y : 2 * y - cy;
          final x2 = ax(num()), y2 = ay(num());
          final ex = ax(num()), ey = ay(num());
          path.cubicTo(
            x1 * scale,
            y1 * scale,
            x2 * scale,
            y2 * scale,
            ex * scale,
            ey * scale,
          );
          cx = x2;
          cy = y2;
          x = ex;
          y = ey;
        } while (more());
      case 'A':
        do {
          final rx = num(), ry = num();
          final rotation = num();
          final large = num() != 0;
          final sweep = num() != 0;
          final ex = ax(num()), ey = ay(num());
          path.arcToPoint(
            Offset(ex * scale, ey * scale),
            radius: Radius.elliptical(rx * scale, ry * scale),
            rotation: rotation,
            largeArc: large,
            clockwise: sweep,
          );
          x = ex;
          y = ey;
        } while (more());
        cx = cy = null;
      case 'Z':
        path.close();
        x = sx;
        y = sy;
        cx = cy = null;
      default:
        throw ArgumentError.value(d, 'd', 'unsupported path command $cmd');
    }
  }
  return path;
}

final RegExp _svgTokens = RegExp(r'[MmLlHhVvCcSsAaZz]|-?(?:\d+\.?\d*|\.\d+)');

bool _isCommand(String t) => t.length == 1 && RegExp('[A-Za-z]').hasMatch(t);
