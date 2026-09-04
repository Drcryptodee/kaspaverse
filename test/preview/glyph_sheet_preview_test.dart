import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';

import '../support/preview_harness.dart';

/// Every mark in the set, at the 20 dp drawer seat scaled 3× so a stroke can
/// be judged, on the drawer's ground. Looked at against the intake renders'
/// glyph crops (D-261) — the sheet is what "transcribed from Lucide" is proven
/// by, not the path strings.
void main() {
  setUpAll(loadBundledFonts);
  testWidgets('glyph sheet', (tester) async {
    await renderSurface(
      tester,
      name: 'glyphs',
      size: const PreviewSize('sheet', Size(720, 360), 1.0),
      child: ColoredBox(
        color: KvColor.shelf,
        child: Wrap(
          children: [
            for (final mark in KvGlyph.values)
              SizedBox(
                width: 90,
                height: 90,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    KvGlyphIcon(mark, size: 60, tone: KvColor.inkDim),
                    Text(
                      mark.name,
                      style: const TextStyle(
                        fontSize: 9,
                        color: KvColor.inkMeta,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }, skip: !previewRequested);
}
