import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/app_version.dart';

void main() {
  test('kAppVersion mirrors pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final line = pubspec.firstWhere((l) => l.startsWith('version:'));
    final version = line.split(':')[1].trim().split('+').first;
    expect(
      kAppVersion,
      version,
      reason: 'the drawer prints kAppVersion; pubspec.yaml is the truth',
    );
  });
}
