import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../theme/tokens.dart';

/// A scannable QR tile for a Kaspa address (BG-15 / design_system §8).
///
/// **Always dark modules on a light tile, regardless of app theme** — a
/// dark-themed QR defeats scanners, and scanability is the entire function
/// (D-045b). The colours are [KvColor.qrModule] on [KvColor.qrTile], which sit
/// deliberately outside the dark palette. The ≥16dp white margin (quiet zone)
/// is part of the spec — a QR without it fails many scanners.
///
/// The matrix is encoded by the pinned pure-Dart `qr` package (INV-7) once on
/// init; we paint it ourselves so the dark-on-light rule can never be themed
/// away, and so the screen-entrance transition never re-encodes (§10).
class QrTile extends StatefulWidget {
  const QrTile({required this.data, this.size = side, super.key});

  /// The tile's side, named once so **every state of the Receive screen can
  /// reserve the same footprint**. A layout that jumps when the address
  /// arrives, or when it fails to, moves the tile out from under a hand that
  /// is already aiming a camera at it.
  static const double side = 240;

  /// The exact string the QR encodes — for receive, the full `kaspa:…` address.
  final String data;

  /// Side length of the white tile (modules + quiet zone), in logical pixels.
  final double size;

  /// **The quiet zone, computed rather than asserted** (item 0 / L121).
  ///
  /// The spec is four modules of clear margin on every side, and a QR without
  /// it fails many scanners. Solving `q >= 4 * (side - 2q) / modules` for `q`
  /// gives `4 * side / (modules + 8)` — so the margin is derived from the
  /// matrix the address actually produced, and a longer payload (more modules,
  /// smaller cells) cannot silently erode it. The 16 dp in the design bible is
  /// the floor, not the rule — **and the floor never binds for a real address.**
  ///
  /// Measured on glass 2026-08-31 and confirmed against the pinned encoder: a
  /// 67-character `kaspa:` address is **37 modules**, so the requirement is
  /// `4 * 240 / 45 = 21.33 dp` and the rendered tile carries exactly that on all
  /// four sides (64px at density 3.0, `quiet/cell = 4.000`). An earlier version
  /// of this comment said *53 modules* and *15.74 dp*, and concluded that 16 dp
  /// "has held" — both numbers wrong and the reasoning inverted. It mattered:
  /// anyone trusting it and simplifying back to a fixed 16 dp would ship **3.0
  /// modules** of quiet zone, under spec, which is the exact regression this
  /// function exists to prevent.
  static double quietZone(int modules, double side) {
    final needed = 4 * side / (modules + 8);
    return needed > KvSpace.m ? needed : KvSpace.m;
  }

  @override
  State<QrTile> createState() => _QrTileState();
}

class _QrTileState extends State<QrTile> {
  late QrImage _image;

  @override
  void initState() {
    super.initState();
    _image = _encode(widget.data);
  }

  @override
  void didUpdateWidget(QrTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _image = _encode(widget.data);
  }

  // Error-correction M (~15%): the address is short and the screen is static
  // and well-lit; M balances density against resilience without inflating the
  // module count (which would shrink each cell on a phone).
  static QrImage _encode(String data) => QrImage(
    QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'QR code for your receive address',
      image: true,
      child: Container(
        width: widget.size,
        height: widget.size,
        padding: EdgeInsets.all(
          QrTile.quietZone(_image.moduleCount, widget.size),
        ),
        decoration: BoxDecoration(
          color: KvColor.qrTile,
          borderRadius: BorderRadius.circular(KvRadius.card),
        ),
        child: CustomPaint(painter: _QrPainter(_image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount;
    if (count == 0) return;
    final cell = size.width / count;
    final paint = Paint()
      ..color = KvColor.qrModule
      ..isAntiAlias =
          false // crisp module edges scan better
      ..style = PaintingStyle.fill;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (!image.isDark(row, col)) continue;
        // +0.5 overdraw closes the hairline seams sub-pixel rounding opens
        // between adjacent modules (a scanner reads a seam as light). row→y,
        // col→x.
        canvas.drawRect(
          Rect.fromLTWH(col * cell, row * cell, cell + 0.5, cell + 0.5),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}
