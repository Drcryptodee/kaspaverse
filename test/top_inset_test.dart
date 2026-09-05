import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **The system inset, and nothing more** (D-262 §9.22; founder on glass
/// 2026-09-05). Send and Home take the top inset from `SafeArea`; Network,
/// Transaction, Settings and Roadmap reserved a fixed 52 dp above their bars
/// and sat visibly lower — *"the proximity the height is from the top of the
/// back button to the roof of the screen … every screen has to have it."*
/// A screen that reserves the strip is a finding; the retired Black Glass
/// prototype is the one exemption, by name.
void main() {
  test('no screen reserves the status-bar strip; SafeArea owns the inset', () {
    final offenders = <String>[];
    for (final file
        in Directory('lib/src/ui')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (file.path.contains('/preview/')) continue;
      if (file.path.endsWith('theme/tokens.dart')) continue;
      final source = file.readAsStringSync();
      if (source.contains('statusBarReserve')) offenders.add(file.path);
      // A `SafeArea(top: false)` under a `Scaffold` body is the same reserve
      // by another door — the screen would have to draw the inset itself.
      if (RegExp(r'body: SafeArea\(\s*top: false').hasMatch(source)) {
        offenders.add('${file.path} (SafeArea(top: false) on a body)');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a screen reserves the status-bar strip instead of taking the system '
          'inset from SafeArea, so its bar sits lower than Send and Home (D-262)',
    );
  });
}
