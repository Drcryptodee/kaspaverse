// Perf baseline harness — pre-P3 hardening V0 (PRE_P3_HARDENING_V2.md §V0).
//
// Measurement infrastructure ONLY (HP2): this file drives the real app on the
// reference device (LG V60, profile build) and traces frame build/raster for
// the four baseline surfaces:
//
//   1. startup      — launch → first stable frame (supplementary; the
//                     authoritative cold-start row is logcat `Displayed`,
//                     see docs/PERF_HARNESS_RECIPE.md)
//   2. home_steady  — 10 s dwell on the unlocked home (missed-frame count)
//   3. send_screen  — push transition + 5 s dwell + pop (NAVIGATION ONLY:
//                     nothing is typed, prepared, or signed — no money moves)
//   4. thread_screen— contacts push → first conversation dwell + pop
//                     (decrypt-on-view read path, §0.4 untouched)
//
// The vault unlock is a founder-on-glass step: the test polls for the home
// surface while the founder authenticates (biometric system sheet — the
// harness never touches secret material, INV-1/2/3).
//
// Home carries ambient period animations (status-beacon pulse keyed to the
// wall clock), so this harness NEVER calls pumpAndSettle — real-time dwells
// under LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive let the engine
// render frames exactly as production would.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kaspaverse/main.dart' as app;

/// How long the harness waits for the founder to unlock the vault on glass.
const unlockWait = Duration(minutes: 3);

/// Polls [finder] with real-time waits until it matches or [limit] elapses.
Future<bool> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration limit = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

/// A real-time dwell that keeps the test pump alive without forcing frames —
/// under benchmarkLive the engine schedules its own vsync-driven frames.
Future<void> dwell(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.benchmarkLive;
  // Real touches normally die at the test binding. The founder must be able
  // to unlock on glass mid-run (passphrase — restored vaults have no Path-A
  // enrollment, a registered finding), so propagate device pointer events.
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('baseline: four-surface frame trace', (tester) async {
    // ── 1. startup: launch → first stable frame ──────────────────────────
    await binding.traceAction(() async {
      app.main();
      // First frames of the shell (splash → lock surface). Timed pumps, not
      // pumpAndSettle: the surface may animate indefinitely.
      await dwell(tester, const Duration(seconds: 3));
    }, reportKey: 'startup');

    // ── founder-on-glass: unlock (outside any trace) ─────────────────────
    final homeMarker = find.text('Send');
    final unlocked = await waitFor(tester, homeMarker, limit: unlockWait);
    expect(
      unlocked,
      isTrue,
      reason: 'vault was not unlocked within $unlockWait — '
          'the founder must authenticate on glass during this run',
    );
    // Let post-unlock work (wallet start, first sync paint) settle a moment
    // so the steady-state trace measures dwell, not the unlock transition.
    await dwell(tester, const Duration(seconds: 5));

    // ── 2. home steady-state: 10 s dwell ─────────────────────────────────
    await binding.traceAction(() async {
      await dwell(tester, const Duration(seconds: 10));
    }, reportKey: 'home_steady');

    // ── 3. send screen: push + dwell + pop (navigation only) ────────────
    await binding.traceAction(() async {
      await tester.tap(find.text('Send'));
      await dwell(tester, const Duration(seconds: 5));
    }, reportKey: 'send_screen');
    // Pop back to home (SendScreen is a pushed route; nothing was entered).
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    final backHome = await waitFor(tester, homeMarker);
    expect(backHome, isTrue, reason: 'did not return to home after send pop');

    // ── 4. thread screen: contacts → first conversation → dwell ─────────
    await binding.traceAction(() async {
      await tester.tap(find.text('Message'));
      await dwell(tester, const Duration(seconds: 3));
      // Open the first conversation if one exists (the standing Kasia
      // thread on the reference device). If none, the contacts dwell alone
      // still yields the surface's frame profile — recorded as such.
      final tile = find.byType(ListTile);
      if (tile.evaluate().isNotEmpty) {
        await tester.tap(tile.first);
        await dwell(tester, const Duration(seconds: 5));
      } else {
        await dwell(tester, const Duration(seconds: 5));
      }
    }, reportKey: 'thread_screen');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
