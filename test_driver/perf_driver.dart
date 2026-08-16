// Host-side driver for the V0 perf baseline harness.
//
// Receives the timelines that integration_test/perf_baseline_test.dart traced
// on-device and writes `<key>.timeline.json` + `<key>.timeline_summary.json`
// under build/perf_baseline/ — the machine-readable artifacts the baseline
// table in the internal performance budget cites.
//
// Run (the internal perf-harness recipe carries the full walk-through):
//   flutter drive --profile \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/perf_baseline_test.dart \
//     --keep-app-running \
//     -d <device>
//
// --keep-app-running IS MANDATORY, and it is not a convenience flag. Without it
// `flutter drive` tears the app down when the run ends, and that teardown is
// `stopApp` FOLLOWED BY `uninstallApp` — unconditional, whenever the application
// package is known, which it always is on Android (flutter_tools' drive service,
// verified against the pinned Flutter 3.41.5). Uninstalling wipes app data, and
// app data is the vault: an unrecoverable wallet unless the seed was written
// down. This harness runs against a real device with a real vault on it.
//
// The flag is spelled out here rather than cited, deliberately. It was cited
// once and the citation was later reworded away for pointing at a file that
// public clones do not have — which left this exact command, copy-pasteable and
// one flag short of destructive, with nothing left to explain the omission.
import 'package:flutter_driver/flutter_driver.dart' as driver;
import 'package:integration_test/integration_test_driver.dart';

const _traceKeys = ['startup', 'home_steady', 'send_screen', 'thread_screen'];

Future<void> main() {
  return integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;
      for (final key in _traceKeys) {
        final raw = data[key];
        if (raw == null) continue;
        final timeline = driver.Timeline.fromJson(raw as Map<String, dynamic>);
        final summary = driver.TimelineSummary.summarize(timeline);
        await summary.writeTimelineToFile(
          key,
          pretty: true,
          includeSummary: true,
          destinationDirectory: 'build/perf_baseline',
        );
      }
    },
  );
}
