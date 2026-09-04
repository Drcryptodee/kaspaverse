import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../theme/tokens.dart';
import 'kv_status_chip.dart';

/// **The QR tile** (§4, §1.7, BG-15) — dark modules on a **white** tile,
/// radius 24, **never themed**.
///
/// A dark-themed QR defeats scanners, and scannability is the entire function
/// (D-045b), so [KvColor.qrTile] and [KvColor.qrModule] sit deliberately
/// outside the palette and no state of this widget may tint them.
///
/// **Three states, one footprint** (§4, BG-20): the matrix, a live dot while
/// the address is being derived, and a dashed placeholder when it could not be.
/// The tile never changes size between them — a layout that jumps when the
/// address arrives moves the target out from under a hand already aiming a
/// camera at it.
///
/// The matrix is encoded by the pinned pure-Dart `qr` package (INV-7, no
/// network, no plugin) once on init; it is painted here so the dark-on-light
/// rule cannot be themed away and the entrance transition never re-encodes.
class KvQr extends StatefulWidget {
  const KvQr({required this.data, this.onTap, super.key});

  /// The exact string the QR encodes — for receive, the full `kaspa:…`
  /// address, and nothing appended to it.
  final String data;

  /// The QR **is** the address, so the surface that renders it is a legitimate
  /// way to take it. Expected to route through the one copy path.
  final VoidCallback? onTap;

  /// **The quiet zone is four modules on every side, and it is drawn by the
  /// painter rather than reserved by the layout** (item 0 / L121 — geometry is
  /// computed, never asserted).
  ///
  /// The spec is four modules of clear margin; a QR without it fails many
  /// scanners. Expressed in modules the requirement is scale-free — the tile
  /// divides its side into `moduleCount + 8` cells and spends four of them a
  /// side — so a longer payload (more modules, smaller cells) cannot erode it,
  /// and neither can a narrower window.
  ///
  /// §1.7's *"padding 18"* is the **render's** number and is a floor, not the
  /// rule: `S5` measures a 256 dp tile with an 18 dp pad, which for a
  /// 67-character `kaspa:` address (37 modules) is **3.03 modules** — under
  /// spec. A picture cannot encode a scanner's requirement, so this is the one
  /// place the render does not win (D-259 governs design, not function).
  static const int quietModules = 4;

  /// The quiet zone in dp for a given matrix and tile side — exposed so a
  /// guard can read the geometry back rather than trust it.
  static double quietZone(int modules, double side) =>
      quietModules * side / (modules + quietModules * 2);

  @override
  State<KvQr> createState() => _KvQrState();
}

class _KvQrState extends State<KvQr> {
  late QrImage _image;

  @override
  void initState() {
    super.initState();
    _encode();
  }

  @override
  void didUpdateWidget(KvQr old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data) _encode();
  }

  // Error-correction M (~15%): the address is short and the screen is static
  // and well-lit; M balances density against resilience without inflating the
  // module count, which would shrink each cell on a phone.
  void _encode() => _image = QrImage(
    QrCode(
      payload: QrPayload.fromString(widget.data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return KvQrFrame(
      onTap: widget.onTap,
      // `button` when it copies, because a tile that acts is not an image to a
      // screen reader — `image` and `button` are different promises.
      semanticLabel: widget.onTap == null
          ? 'QR code for your receive address'
          : 'QR code for your receive address. Copies the address',
      child: CustomPaint(painter: _KvQrPainter(_image)),
    );
  }
}

/// The tile every state shares: a square, white, radius 24.
///
/// Public because the loading and error faces are compositions over the same
/// footprint rather than three widgets that happen to agree about a number.
class KvQrFrame extends StatelessWidget {
  const KvQrFrame({
    super.key,
    required this.child,
    this.onTap,
    this.ground = KvColor.qrTile,
    this.dashed = false,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color ground;

  /// The error face: a dashed [KvColor.edgeHi] rim on the same footprint
  /// (§4). The tile is `shelf` then, not white — there is no code to scan and
  /// a blank white square invites a camera at nothing (§1.1).
  final bool dashed;

  final String? semanticLabel;

  /// The tile's largest side. It takes the width it is given up to this, and is
  /// square by construction — so the floor geometry narrows it instead of
  /// overflowing, and no widget below the root reads a width (BG-33).
  static const double maxSide = 256;

  @override
  Widget build(BuildContext context) {
    Widget tile = AspectRatio(
      aspectRatio: 1,
      child: Container(
        decoration: BoxDecoration(
          color: ground,
          borderRadius: BorderRadius.circular(KvRadius.inner + 2),
        ),
        foregroundDecoration: dashed ? const _DashedRim() : null,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
    if (onTap != null) {
      tile = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: tile,
      );
    }
    final label = semanticLabel;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxSide),
        child: label == null
            ? ExcludeSemantics(child: tile)
            : Semantics(
                label: label,
                image: onTap == null,
                button: onTap != null,
                onTap: onTap,
                child: tile,
              ),
      ),
    );
  }
}

/// While the address is being derived: the live dot, centred on the tile's own
/// footprint (§4). Never a spinner — nothing on a settled screen spins (BG-8).
class KvQrWaiting extends StatelessWidget {
  const KvQrWaiting({super.key});

  @override
  Widget build(BuildContext context) => const KvQrFrame(
    ground: KvColor.shelf,
    child: Center(child: KvLamp(KvLampTone.live)),
  );
}

/// When no address could be derived: the same footprint, dashed, and the
/// sentence that says why lives beside it rather than inside it (BG-11).
class KvQrFailed extends StatelessWidget {
  const KvQrFailed({super.key});

  @override
  Widget build(BuildContext context) =>
      const KvQrFrame(ground: KvColor.shelf, dashed: true, child: SizedBox());
}

class _DashedRim extends Decoration {
  const _DashedRim();

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _DashedRimPainter();
}

class _DashedRimPainter extends BoxPainter {
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration cfg) {
    final size = cfg.size!;
    final rect = RRect.fromRectAndRadius(
      (offset & size).deflate(1),
      const Radius.circular(KvRadius.inner + 2),
    );
    final paint = Paint()
      ..color = KvColor.edgeHi
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()..addRRect(rect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, (d + 8).clamp(0.0, metric.length)),
          paint,
        );
        d += 14;
      }
    }
  }
}

class _KvQrPainter extends CustomPainter {
  const _KvQrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = image.moduleCount;
    if (count == 0) return;
    // The side buys `count + 8` cells and spends four a side on the quiet
    // zone — see [KvQr.quietModules].
    final cell = size.width / (count + KvQr.quietModules * 2);
    final origin = cell * KvQr.quietModules;
    final paint = Paint()
      ..color = KvColor.qrModule
      // Crisp module edges scan better than smoothed ones.
      ..isAntiAlias = false
      ..style = PaintingStyle.fill;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (!image.isDark(row, col)) continue;
        // +0.5 overdraw closes the hairline seams sub-pixel rounding opens
        // between adjacent modules — a scanner reads a seam as light.
        canvas.drawRect(
          Rect.fromLTWH(
            origin + col * cell,
            origin + row * cell,
            cell + 0.5,
            cell + 0.5,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_KvQrPainter old) => old.image != image;
}
