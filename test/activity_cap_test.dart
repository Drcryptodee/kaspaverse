import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/home_screen.dart';

/// F29 (product-audit run 3). The activity feed is bounded at 100 rows by
/// `ACTIVITY_CAP` in `rust/chain/src/wallet_sync.rs`, applied with `.take()`
/// AFTER a newest-first sort — so the list reaches Dart already truncated and
/// the glass has no way to derive the number it must disclose. It therefore
/// mirrors the constant, and a mirror nobody checks is drift waiting to happen:
/// raise the Rust cap alone and the caption starts lying to the user about how
/// much of their own history they are being shown.
///
/// Reading the Rust source is the only check available here — Dart cannot see a
/// private Rust const across the bridge, and promoting it to the FFI surface
/// would be a T3 change to disclose a T0 caption.
void main() {
  test('the Dart feed cap mirrors ACTIVITY_CAP in wallet_sync.rs', () {
    final source = File('rust/chain/src/wallet_sync.rs').readAsStringSync();
    final match = RegExp(
      r'const\s+ACTIVITY_CAP\s*:\s*usize\s*=\s*(\d+)\s*;',
    ).firstMatch(source);

    expect(
      match,
      isNotNull,
      reason:
          'ACTIVITY_CAP has moved or been renamed in wallet_sync.rs — this pin '
          'must be repointed, not deleted: the caption on Home names this number',
    );

    expect(
      int.parse(match!.group(1)!),
      kActivityFeedCap,
      reason:
          'the Rust cap and the Dart mirror have drifted — Home would tell the '
          'user it is showing $kActivityFeedCap rows while Rust sends a '
          'different number',
    );
  });
}
