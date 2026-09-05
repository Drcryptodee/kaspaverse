import 'package:flutter/foundation.dart';

/// **The V4 scoping primitive**: recomputes [_compute] whenever any source
/// notifies, and — because [ValueNotifier] only notifies when the new value
/// differs — swallows every tick that would not change pixels.
///
/// Promoted out of `home_screen.dart` at UX-R3's second beat, not copied: the
/// transaction detail and the node surface both needed exactly this to stop
/// rebuilding their whole body on every chain tick (184 elements per DAA tick
/// on the detail, measured with `debugOnRebuildDirtyWidget`), and a second
/// private copy is how two screens start disagreeing about what "derived"
/// means (L143). *Each region listens only to what it renders* is the law;
/// this is the one mechanism that enforces it.
///
/// ## It survives its own disposal, and that is deliberate (L162)
///
/// The money screen's `_dimmed` is **handed across route boundaries on
/// purpose** — Send and the transaction detail are given that screen's own bit
/// rather than deriving one of their own, so two surfaces can never disagree
/// about whether the wallet is connected. That makes the consumers *outlive
/// the owner* in one case the owner cannot control: a teardown of the whole
/// authenticated stack (BG-13's discard on lock, or the app closing) disposes
/// the element tree depth-first, so the money screen underneath can go first
/// and a Send screen still mounted above it then unhooks from a dead notifier.
///
/// `ChangeNotifier` asserts on that — *"was used after being disposed"*, which
/// the founder hit on Send step 2 (2026-09-04). The error is debug-only and
/// nothing was actually broken, but a red screen on a funds surface is a
/// defect regardless.
///
/// So a disposed [KvDerived] becomes **frozen rather than poisoned**: it stops
/// listening to its sources and will never notify again, its last value stays
/// readable, and hooking or unhooking is a no-op. A consumer tearing down
/// after its owner gets the last honest reading instead of an assertion, and
/// the *reason* the assertion exists — a notifier that keeps firing into dead
/// widgets — is still impossible, because the sources are unhooked first.
class KvDerived<T> extends ValueNotifier<T> {
  KvDerived(this._sources, this._compute) : super(_compute()) {
    for (final s in _sources) {
      s.addListener(_recompute);
    }
  }

  final List<Listenable> _sources;
  final T Function() _compute;
  bool _disposed = false;

  void _recompute() {
    if (_disposed) return;
    value = _compute();
  }

  @override
  void addListener(VoidCallback listener) {
    if (_disposed) return;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_disposed) return;
    super.removeListener(listener);
  }

  @override
  void dispose() {
    if (_disposed) return;
    for (final s in _sources) {
      s.removeListener(_recompute);
    }
    _disposed = true;
    super.dispose();
  }
}
