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
    // D-241: on a #000000 ground light glyphs optically thin, so the reading
    // slots sit half a step above nominal. A legibility correction, not taste.
    test('the reading slots carry the ground compensation', () {
      expect(_wght(t.bodyMedium!), 450, reason: 'body copy');
      expect(_wght(t.bodySmall!), 450, reason: 'address / hash');
      expect(_wght(t.displayMedium!), 550, reason: 'balance hero');
      expect(_wght(t.displaySmall!), 550, reason: 'screen amount');
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
