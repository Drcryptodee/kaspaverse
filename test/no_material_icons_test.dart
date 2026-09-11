import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **Every mark the app draws, it owns** (BG-25, D-205). The set is `KvGlyph`
/// — Lucide geometry transcribed onto the 24 dp grid at the house stroke —
/// and Material's `Icons.*` is not a fallback for the one it lacks: a mark
/// with no house shape is drawn and given a row in §2a, which is what UX-R8
/// did for the last seven (`duel`, `flag`, `circle`, `image`, `file`, `alert`,
/// `archive`). The sweep finished at UX-R8 and this is what keeps it finished:
/// a `Icons.` reaching `lib/` reds the gate rather than waiting for a review
/// item to notice.
///
/// The name may survive in a comment — the glyph file's own header says why
/// `Icons.*` is not the answer, and a few call sites record which Material
/// icon they retired — so the scan reads code, not prose.
void main() {
  test('no Material icon is drawn anywhere in lib/ (BG-25)', () {
    final offenders = <String>[];
    final use = RegExp(r'\bIcons\.[a-zA-Z_0-9]+');
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            // Generated bindings are not the app's drawing surface.
            .where((f) => !f.path.startsWith('lib/src/rust/'))) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final code = line.trimLeft();
        if (code.startsWith('//')) continue;
        // Strip a trailing line comment so a recorded retirement
        // (`// was Icons.lock_outline`) does not count as a use.
        final cut = line.indexOf('//');
        final source = cut < 0 ? line : line.substring(0, cut);
        if (use.hasMatch(source)) offenders.add('${file.path}:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a Material icon is drawn where the app owns every mark it draws '
          '(BG-25) — add the shape to KvGlyph with its Lucide source and a '
          '§2a row, or name the house mark that already means it',
    );
  });
}
