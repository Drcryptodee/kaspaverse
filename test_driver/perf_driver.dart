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
//     -d <device>
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
        final timeline = driver.Timeline.fromJson(
          raw as Map<String, dynamic>,
        );
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
