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
  const QrTile({required this.data, this.size = 240, super.key});

  /// The exact string the QR encodes — for receive, the full `kaspa:…` address.
  final String data;

  /// Side length of the white tile (modules + quiet zone), in logical pixels.
  final double size;

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
        padding: const EdgeInsets.all(KvSpace.m), // 16dp quiet zone (BG-15)
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
