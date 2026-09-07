import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/widgets/kv_mark.dart';

import '../support/preview_harness.dart';

/// **The mark, at the artwork's own scale, so the transcription can be proved
/// rather than eyeballed** (§2a rule 5's method, applied to the mark).
///
/// `kaspaverse-mark.svg` is a 160 box whose disc is `r 73.4`, exported at
/// 1024 px — so the disc is `1024 × 146.8 / 160 = 939.52` px across, centred.
/// This renders exactly that, with the halo off (the SVG has none), onto a
/// transparent ground. `tools/mark_diff.py` differences the two.
void main() {
  setUpAll(loadBundledFonts);

  testWidgets('probe: the mark against its own artwork', (tester) async {
    await renderSurface(
      tester,
      name: 'probe__mark_artwork',
      size: const PreviewSize('probe', Size(1024, 1024), 1.0),
      child: const Center(child: KvMark(size: 939.52, halo: false)),
    );
  }, skip: !previewRequested);

  testWidgets('probe: the app icon against its own artwork', (tester) async {
    await renderSurface(
      tester,
      name: 'probe__app_icon',
      size: const PreviewSize('probe', Size(1024, 1024), 1.0),
      child: const KvMark(size: 1024, style: KvMarkStyle.tile),
    );
  }, skip: !previewRequested);
}
