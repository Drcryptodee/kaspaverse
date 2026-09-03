import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/kv_theme.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';

/// §2's weight column, pinned. Nothing guarded it before D-241, which is how a
/// ramp-wide weight change reached a preview sheet before it reached a test.
///
/// **The axis, not the enum, is what moves a variable face.** Both bundled
/// faces are variable, so `FontWeight` is only the semantic hint some platforms
/// read — `FontVariation('wght')` is the value that renders. A guard that
/// asserts on `fontWeight` alone would pass on 450 and on 400 identically,
/// because `FontWeight.values[(450 ~/ 100) - 1]` is `w400`.
double _wght(TextStyle s) =>
    s.fontVariations!.firstWhere((v) => v.axis == 'wght').value;

void main() {
  final t = kvTextTheme();

  group('§2 type ramp', () {
    // **D-241's ground compensation is WITHDRAWN** (v4.2 §2, D-247). The
    // 450 / 550 lifts corrected for light glyphs optically thinning on a pure
    // `#000000`; on the tinted `abyss` the effect is not visible on the V60 at
    // 1x, so the slots return to whole weights. Re-measure if the ground moves
    // again — the correction was real for the ground it was made against.
    //
    // This test pinned the retired values and would therefore have stayed green
    // on superseded law while reddening on the correction. Caught by
    // `ux-auditor` at the UX-R0 landing.
    test('the reading slots are whole weights — D-241 withdrawn', () {
      expect(_wght(t.bodyMedium!), 400, reason: 'body copy');
      expect(_wght(t.bodySmall!), 500, reason: 'address / hash');
      expect(_wght(t.displayMedium!), 600, reason: 'balance hero');
      expect(_wght(t.displaySmall!), 600, reason: 'screen amount');
      for (final slot in [
        t.bodyMedium!,
        t.bodySmall!,
        t.displayMedium!,
        t.displaySmall!,
      ]) {
        expect(
          _wght(slot) % 100,
          0,
          reason: 'no half-step survives the withdrawal',
        );
      }
    });

    // The one slot deliberately left at nominal. BG-7 spends rowAmount's weight
    // on DIRECTION (incoming 600 / outgoing 400), and BG-26 took the colour out
    // of the figure, so weight now carries more of that load rather than less.
    // Compensating this slot would buy legibility with a meaning.
    test('rowAmount is excluded, because its weight is a semantic channel', () {
      expect(_wght(t.bodyLarge!), 400);
    });

    test('two faces, never three', () {
      final families = {
        for (final s in [
          t.displayMedium!,
          t.displaySmall!,
          t.headlineSmall!,
          t.titleMedium!,
          t.titleSmall!,
          t.labelLarge!,
          t.bodyLarge!,
          t.bodyMedium!,
          t.bodySmall!,
          t.labelSmall!,
        ])
          s.fontFamily,
      };
      expect(families, {KvFont.ui, KvFont.mono});
    });

    // A variable face reads the axis; the enum is the hint. If a slot ever pins
    // one without the other, the rendered weight and the declared weight can
    // disagree silently — which is exactly the failure this file exists for.
    test('every slot pins BOTH the axis and the enum', () {
      for (final s in [
        t.displayMedium!,
        t.displaySmall!,
        t.headlineSmall!,
        t.titleMedium!,
        t.titleSmall!,
        t.labelLarge!,
        t.bodyLarge!,
        t.bodyMedium!,
        t.bodySmall!,
        t.labelSmall!,
      ]) {
        expect(s.fontVariations, isNotNull);
        expect(s.fontWeight, isNotNull);
        expect(
          s.fontVariations!.any((FontVariation v) => v.axis == 'wght'),
          isTrue,
        );
      }
    });
  });
}
