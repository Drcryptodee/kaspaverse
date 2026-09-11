import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';

import '../support/preview_harness.dart';

/// Every mark in the set, at the 20 dp drawer seat scaled 3× so a stroke can
/// be judged, on the drawer's ground. Looked at against the intake renders'
/// glyph crops (D-261) — the sheet is what "transcribed from Lucide" is proven
/// by, not the path strings.
///
/// The sheet is as tall as the set needs: eight marks to a row, 90 dp a row.
/// It was fixed at 360 and had been clipping the last eighteen marks since the
/// set passed thirty-two — a sheet that shows the marks it was built to prove
/// only up to a fold is L211's instrument again (found at UX-R8, drawing the
/// seven marks the thread needed).
void main() {
  setUpAll(loadBundledFonts);
  testWidgets('glyph sheet', (tester) async {
    const perRow = 8;
    const cell = 90.0;
    final rows = (KvGlyph.values.length + perRow - 1) ~/ perRow;
    await renderSurface(
      tester,
      name: 'glyphs',
      size: PreviewSize('sheet', Size(perRow * cell, rows * cell), 1.0),
      child: ColoredBox(
        color: KvColor.shelf,
        child: Wrap(
          children: [
            for (final mark in KvGlyph.values)
              SizedBox(
                width: cell,
                height: cell,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    KvGlyphIcon(mark, size: 60, tone: KvColor.inkDim),
                    Text(
                      mark.name,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
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
