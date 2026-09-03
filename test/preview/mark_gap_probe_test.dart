import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/widgets/kv_mark.dart';

import '../support/preview_harness.dart';

/// A throwaway probe: the mark at its three stroke tiers, magnified 6x, so the
/// stem/chevron clearance can be SEEN and not only computed (§4a.1's gap guard).
void main() {
  setUpAll(loadBundledFonts);
  testWidgets('probe: mark gap at each stroke tier', (tester) async {
    await renderSurface(
      tester,
      name: 'probe__mark_gap',
      child: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Each row: the mark at a canon size, magnified so that all three
              // land at the same on-screen diameter. Same painted geometry,
              // fairly compared — only the stroke tier differs.
              for (final tier in const [
                [96.0, 2.4], // stroke 12
                [40.0, 5.76], // stroke 14
                [24.0, 9.6], // stroke 16
              ])
                SizedBox(
                  width: 230,
                  height: 230,
                  child: Center(
                    child: Transform.scale(
                      scale: tier[1],
                      child: KvMark(size: tier[0], halo: false),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }, skip: !previewRequested);
}
