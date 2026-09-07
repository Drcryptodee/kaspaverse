import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_mark.dart';

import '../support/preview_harness.dart';

/// **The launcher icon, generated from the widget the app itself draws** (D-294).
///
/// Not a traced export and not a designer's raster: the same `KvMark` the About
/// screen and the splash paint, rendered at each density. So the icon on the
/// home screen and the mark inside the app cannot drift — the failure this
/// exists to remove is a launcher still showing Flutter's stock blue logo
/// because nothing connected it to the mark (it did, from 12 Jun until today).
///
/// **The glow is ours, not the artwork's.** Founder's ruling, 2026-09-07:
/// *"lets use our glow value but retain the exact design drawn."* The export
/// blooms about 14 % of the disc's diameter; `orbHalo` at the canon **176 dp**
/// orb blurs 40 dp on a 176 dp disc, which is 23 % — wider and softer, and it
/// is the halo the app already wears. Every density renders the same logical
/// composition at its own `pixelRatio`, so the glow is proportionally identical
/// at 48 px and at 432, and nothing is ever resampled.
///
/// **`withShadows` is load-bearing here.** `flutter_test` sets
/// `debugDisableShadows = true` for every test so a golden cannot drift with a
/// rasteriser's blur — which meant the first pass of this exporter wrote five
/// densities of an icon with **no glow at all**, and the same flag has been
/// quietly flattening every frame in the preview catalogue.
///
/// Run: `KV_PREVIEW=1 flutter test test/preview/app_icon_export_test.dart
/// --update-goldens`.
void main() {
  setUpAll(loadBundledFonts);

  /// The orb the icon is built around — the largest canon size, so `orbHalo`
  /// lands on its clamp exactly as it does on the splash.
  const disc = 176.0;

  /// Legacy launcher rasters, in `mipmap-<density>/ic_launcher.png`.
  const legacy = <String, double>{
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };

  /// Adaptive foreground: a 108 dp canvas at each density.
  const adaptive = <String, double>{
    'mdpi': 108,
    'hdpi': 162,
    'xhdpi': 216,
    'xxhdpi': 324,
    'xxxhdpi': 432,
  };

  /// Render `child` inside a `side × side` logical box and write it out at each
  /// density's pixel width. One vector render per density; nothing is scaled.
  Future<void> export(
    WidgetTester tester, {
    required Widget child,
    required double side,
    required Map<String, double> sizes,
    required String file,
  }) async {
    final key = GlobalKey();
    tester.view.physicalSize = Size(side, side);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData.fromView(tester.view),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: SizedBox.square(dimension: side, child: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    for (final entry in sizes.entries) {
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: entry.value / side);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final out = Directory('android/app/src/main/res/mipmap-${entry.key}');
        out.createSync(recursive: true);
        File('${out.path}/$file').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  }

  testWidgets('export: the launcher icon at five densities', (tester) async {
    await withShadows(
      () => export(
        tester,
        // The tile takes the canvas; the artwork seats a 67.4 % disc in it.
        side: disc / KvMark.tileDiscRatio,
        sizes: legacy,
        file: 'ic_launcher.png',
        child: KvMark(
          size: disc / KvMark.tileDiscRatio,
          style: KvMarkStyle.tile,
        ),
      ),
    );
    for (final density in legacy.keys) {
      expect(
        File(
          'android/app/src/main/res/mipmap-$density/ic_launcher.png',
        ).existsSync(),
        isTrue,
      );
    }
  }, skip: !previewRequested);

  testWidgets('export: the adaptive foreground at five densities', (
    tester,
  ) async {
    await withShadows(
      () => export(
        tester,
        // 56.8 % of the 108 dp canvas, measured off the artwork's own
        // foreground — comfortably inside the 66 % the launcher mask always
        // shows, with the halo free to bleed past it, which is exactly the
        // thing a mask may eat.
        side: disc / 0.568,
        sizes: adaptive,
        file: 'ic_launcher_foreground.png',
        // Transparent ground: the background layer is `kv_abyss`, declared in
        // `values/colors.xml` and already mirrored from `KvColor.abyss` there.
        child: const Center(child: KvMark(size: disc)),
      ),
    );
    for (final density in adaptive.keys) {
      expect(
        File(
          'android/app/src/main/res/mipmap-$density/ic_launcher_foreground.png',
        ).existsSync(),
        isTrue,
      );
    }
  }, skip: !previewRequested);

  testWidgets('export: a look at what shipped', (tester) async {
    // The sheet the founder confirms: the tile at the five density sizes, the
    // mark's own ladder, the bare form, and the mask's safe zone over the
    // adaptive foreground.
    await withShadows(
      () => renderSurface(
        tester,
        name: 'app_icon__sheet',
        size: const PreviewSize('sheet', Size(800, 470), 1.0),
        child: ColoredBox(
          color: KvColor.shelf,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final side in const [192.0, 144.0, 96.0, 72.0, 48.0])
                      Padding(
                        padding: const EdgeInsets.only(right: 20),
                        child: KvMark(size: side, style: KvMarkStyle.tile),
                      ),
                  ],
                ),
                const SizedBox(height: 28),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final side in const [
                      120.0,
                      96.0,
                      64.0,
                      40.0,
                      28.0,
                      24.0,
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 20),
                        child: KvMark(size: side),
                      ),
                    const SizedBox(width: 12),
                    const KvMark(size: 64, style: KvMarkStyle.bare),
                    const SizedBox(width: 20),
                    // The mask's floor: 66 % of the 108 dp canvas is always
                    // visible, and the disc must sit inside it.
                    SizedBox.square(
                      dimension: 132,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const ColoredBox(
                            color: KvColor.plate,
                            child: SizedBox.expand(),
                          ),
                          const KvMark(size: 132 * 0.568),
                          Container(
                            width: 132 * 0.667,
                            height: 132 * 0.667,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: KvColor.risk),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }, skip: !previewRequested);
}
