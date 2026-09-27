import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';

/// **The silence deadline and the lamp's hold are one budget in two
/// languages** (LINK-Q1, D-334; the ruling D-331(b)).
///
/// Rust starts a find-then-swap hunt behind a bound socket that has gone
/// `link::SILENCE_DEADLINE` without a DAA tick; Dart holds the lamp live on a
/// bound socket for `KvFreshness.liveHoldBound`. The whole point of the pair is
/// the sentence in the ruling — *a swap that lands in 1–2 s is covered, so the
/// user never sees amber* — and that sentence is arithmetic across the
/// bridge: the deadline, plus a hunt that lands, plus the new socket's first
/// score, must fit inside the hold. Move either constant alone and the
/// promise breaks silently — the L135 shape, a watcher keyed to its
/// neighbour's old value. So the Rust constant is read from its source, the
/// way `activity_cap_test.dart` reads `ACTIVITY_CAP`: Dart cannot see a Rust
/// const across the FFI, and promoting it to the surface would be a T3 change
/// for a T0 check.
void main() {
  test('a silence swap that lands fits inside the lamp\'s hold', () {
    final source = File('rust/chain/src/link.rs').readAsStringSync();
    final match = RegExp(
      r'pub const SILENCE_DEADLINE: std::time::Duration = '
      r'std::time::Duration::from_secs\((\d+)\);',
    ).firstMatch(source);
    expect(
      match,
      isNotNull,
      reason:
          'SILENCE_DEADLINE has moved or changed shape in link.rs — repoint '
          'this pin, never delete it: the lamp\'s hold is sized against it',
    );
    final deadline = Duration(seconds: int.parse(match!.group(1)!));

    // CONN-F1's measurements (`CONNECTIVITY_PASS.md` §12): a swap hunt that
    // finds a node lands in 1–2 s (race winner ~1.1–1.4 s, then a bind of
    // median 0.91 s over 749 dials), and a fresh socket's first score came at
    // p99 3.09 s over 569 connects. The budget takes the top of each.
    const swapLands = Duration(seconds: 2);
    const firstScoreP99 = Duration(milliseconds: 3090);
    expect(
      deadline + swapLands + firstScoreP99,
      lessThan(KvFreshness.liveHoldBound),
      reason:
          'the silence deadline ($deadline) plus a hunt that lands and the '
          'new socket\'s first score no longer fit inside the lamp\'s hold '
          '(${KvFreshness.liveHoldBound}) — the user would see amber for a '
          'swap the ruling promised to cover',
    );

    // And the deadline must start after the longest stall that recovered by
    // itself (7.50 s) — a hunt started inside a recovering stall is a swap
    // the link did not need.
    expect(deadline, greaterThan(const Duration(milliseconds: 7500)));

    // The data's own clock is untouched by either (D-331(b): the ruling moved
    // the lamp, not the balance's honesty).
    expect(KvFreshness.staleAfter, const Duration(seconds: 5));
    expect(KvFreshness.staleAfter, lessThan(KvFreshness.liveHoldBound));
  });
}
