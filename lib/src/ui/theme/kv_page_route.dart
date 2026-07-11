import 'package:flutter/material.dart';

import 'tokens.dart';

/// The DS route factory (§6 v2.2): every screen push in the app goes through
/// this, so transition DURATION is token-law (`slow` in, `normal` back —
/// leaving is lighter than arriving) instead of Material's own 300 ms.
///
/// Geometry stays owned ONCE by [KvPageTransitionsBuilder] in the theme
/// (fade + a 3% decelerating rise — the §6 entrance law at screen scale,
/// opacity-only under reduced motion), which this route delegates to via
/// `MaterialPageRoute`. A raw `MaterialPageRoute` anywhere in `lib/` is a
/// drift the ux-auditor flags.
class KvPageRoute<T> extends MaterialPageRoute<T> {
  KvPageRoute({required super.builder, super.settings, super.fullscreenDialog});

  @override
  Duration get transitionDuration => KvMotion.slow;

  @override
  Duration get reverseTransitionDuration => KvMotion.normal;
}
