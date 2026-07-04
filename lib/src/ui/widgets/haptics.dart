import 'package:flutter/services.dart';

/// The §7 haptic grammar — call sites name the *event*, so the law is legible
/// where it fires. Haptics accompany state changes **the user caused**;
/// ambient chain events (new block, score tick) never buzz — at ~10 bps that
/// is a phone that never stops vibrating.
abstract final class KvHaptic {
  /// Picker / toggle / word-select (both registers).
  static void selection() => HapticFeedback.selectionClick();

  /// Hold-to-sign threshold reached (vault register).
  static void holdThreshold() => HapticFeedback.mediumImpact();

  /// Broadcast accepted by the node — the money moment (vault register).
  static void moneyMoment() => HapticFeedback.heavyImpact();

  /// Destructive confirm armed (vault register).
  static void destructiveArmed() => HapticFeedback.heavyImpact();
}
