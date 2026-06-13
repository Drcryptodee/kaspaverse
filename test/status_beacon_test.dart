import 'package:flutter_test/flutter_test.dart';
import 'package:kaspaverse/src/ui/theme/tokens.dart';
import 'package:kaspaverse/src/ui/widgets/status_beacon.dart';

void main() {
  group('evaluateBeacon — the DS-1 stale-dimming logic', () {
    test('an error outranks every other state', () {
      expect(
        evaluateBeacon(connected: true, age: Duration.zero, error: 'x'),
        BeaconState.error,
      );
      expect(
        evaluateBeacon(connected: false, age: null, error: 'x'),
        BeaconState.error,
      );
    });

    test('no fresh data yet (age null) is connecting', () {
      expect(
        evaluateBeacon(connected: false, age: null, error: null),
        BeaconState.connecting,
      );
      // Connected to a node but no tip yet still reads connecting.
      expect(
        evaluateBeacon(connected: true, age: null, error: null),
        BeaconState.connecting,
      );
    });

    test('connected + fresh is connected', () {
      expect(
        evaluateBeacon(
          connected: true,
          age: const Duration(seconds: 1),
          error: null,
        ),
        BeaconState.connected,
      );
    });

    test('silence past the threshold is stale even while connected', () {
      expect(
        evaluateBeacon(
          connected: true,
          age: const Duration(seconds: 30),
          error: null,
        ),
        BeaconState.stale,
      );
    });

    test('a dropped link is stale even with recent data (DS-1)', () {
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 1),
          error: null,
        ),
        BeaconState.stale,
      );
    });

    test('the boundary (exactly staleAfter) is stale', () {
      expect(
        evaluateBeacon(
          connected: true,
          age: KvFreshness.staleAfter,
          error: null,
        ),
        BeaconState.stale,
      );
    });
  });

  group('formatAge — floors, never overstates freshness', () {
    test(
      'seconds',
      () => expect(formatAge(const Duration(seconds: 12)), '12 s'),
    );
    test(
      'minutes floor',
      () => expect(formatAge(const Duration(seconds: 125)), '2 m'),
    );
    test(
      'hours floor',
      () => expect(formatAge(const Duration(minutes: 130)), '2 h'),
    );
  });
}
