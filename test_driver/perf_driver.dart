// Host-side driver for the V0 perf baseline harness.
//
// Receives the timelines that integration_test/perf_baseline_test.dart traced
// on-device and writes `<key>.timeline.json` + `<key>.timeline_summary.json`
// under build/perf_baseline/ — the machine-readable artifacts the baseline
// table in the internal performance budget cites.
//
// Run it only through the script, never with `flutter drive` typed by hand:
//   tools/perf/frame_traces.sh <device-serial>
//
// Two of drive's own paths uninstall an app, and an uninstall wipes its data,
// which is the vault: an unrecoverable wallet unless the seed was written down.
// Without --keep-app-running, drive's teardown runs `stopApp` and then
// `uninstallApp` when the run ends, pass or fail. And when an install fails,
// Flutter's installer uninstalls the package it was given; drive retries a
// failed launch with the package it resolved before building (the APK left on
// disk by the last build, else the Gradle namespace), which can be the funded
// one even when the build itself is the `.dev` package. The script builds the
// `.dev` APK, refuses unless the APK's own package is org.kaspaverse.app.dev,
// and hands drive that APK with --keep-app-running, so every attempt and the
// teardown name the `.dev` package (verified against the pinned Flutter
// 3.41.5).
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
