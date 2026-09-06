import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/kv_glyph.dart';

import '../support/preview_harness.dart';

/// The merge mark at `T4`'s own glyph size, on a bare ground, so its ink can be
/// measured against the render's crop pixel for pixel (§2a rule 5: transcribed
/// and proved, never traced by eye).
void main() {
  setUpAll(loadBundledFonts);
  testWidgets('probe: merge mark against T4', (tester) async {
    await renderSurface(
      tester,
      name: 'probe__merge_glyph',
      size: const PreviewSize('probe', Size(120, 120), 1.0),
      child: const ColoredBox(
        color: KvColor.plate,
        // 20 dp is what `KvRowDisc` passes (rowDisc 40 × 0.5), rendered at 4x
        // so one logical dp is four pixels — the render's own scale.
        child: Center(
          child: SizedBox.square(
            dimension: 80,
            child: KvGlyphIcon(KvGlyph.merge, size: 80, tone: KvColor.ink),
          ),
        ),
      ),
    );
  }, skip: !previewRequested);
}
