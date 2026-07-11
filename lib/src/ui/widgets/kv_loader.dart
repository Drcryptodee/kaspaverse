import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The §8 KvLoader primitive (v2.2): the ONE indeterminate spinner. Colour
/// comes from the theme (`progressIndicatorTheme` → `primary-muted`), stroke
/// is always 2 — screens choose only the calibre:
///
/// - [KvLoader.new] — the 24 dp **mark**, for a body/splash with no cached
///   structure to show yet (§6: cached truth dimmed beats shimmer).
/// - [KvLoader.inline] — the 16 dp **inline** spinner, inside a busy control
///   (a submitting button keeps its own label).
///
/// A raw `CircularProgressIndicator` in a screen is a drift.
class KvLoader extends StatelessWidget {
  /// The standalone 24 dp mark.
  const KvLoader({super.key}) : _size = KvSpace.l;

  /// The 16 dp in-control spinner.
  const KvLoader.inline({super.key}) : _size = KvSpace.m;

  final double _size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: _size,
      child: const CircularProgressIndicator(
        strokeWidth: 2,
        semanticsLabel: 'loading',
      ),
    );
  }
}
