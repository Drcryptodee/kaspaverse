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

  // ── C7 (D-091 ruling 1): the three honest truths, and the field case ─────
  //
  // The regression these lock down was lived, not imagined: on 2026-07-30 a
  // weak-link cold open hunted 13.84 s (the founder saw ~28 s) while the glass
  // read "as of 20+ seconds ago" — which parses as *connected, data slightly
  // stale*, the exact opposite of the truth. He said "I'm not sure what it was
  // doing." Evidence: CONNECTIVITY_R1_FIELD_EVIDENCE.md.
  group('evaluateBeacon — honest link states (C7)', () {
    test('a pre-connect hunt says finding a node, never a staleness phrase', () {
      // Cold process: no data has ever arrived.
      expect(
        evaluateBeacon(
          connected: false,
          age: null,
          error: null,
          searching: true,
        ),
        BeaconState.connecting,
      );
      // THE field case: a warm process whose socket is gone (resume after a
      // grace-drop). Data exists and is 20 s old, so the pre-C7 rules read
      // `stale` → "as of 20 s ago". A hunt is running: it must read as a hunt.
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 20),
          error: null,
          searching: true,
        ),
        BeaconState.connecting,
        reason: 'the 2026-07-30 observation-A misread — never regress this',
      );
    });

    test('a long hunt stays one state — 1 s to 30 s reads identically', () {
      // The weak-link hunt spans rounds (probe fan-out → 3 s pause → round 2).
      // Rust holds `race_running` across the whole loop, so the glass must not
      // change its mind at any point inside it — not to connected, not to
      // offline, and above all not to a staleness phrase.
      for (final secs in [1, 4, 8, 14, 20, 28, 30]) {
        expect(
          evaluateBeacon(
            connected: false,
            age: Duration(seconds: secs),
            error: null,
            searching: true,
          ),
          BeaconState.connecting,
          reason: 'a $secs s hunt must still read as a hunt',
        );
      }
    });

    test('the OS says offline: the phone is named, not the nodes', () {
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 20),
          error: null,
          osOffline: true,
          searching: true,
        ),
        BeaconState.offline,
        reason: 'offline outranks the hunt — the cause, not the symptom',
      );
      // It outranks an error too: with no network, "connection error" would
      // blame a node for the user's dead Wi-Fi.
      expect(
        evaluateBeacon(
          connected: false,
          age: null,
          error: 'websocket closed',
          osOffline: true,
        ),
        BeaconState.offline,
      );
    });

    test('a live socket outranks a stale OS claim of offline', () {
      // Android's default-network callback can flap (a Wi-Fi↔cell handoff
      // fires onAvailable(new) and onLost(old) in either order). A working
      // socket is proof of a network, whatever the callback says.
      expect(
        evaluateBeacon(
          connected: true,
          age: const Duration(seconds: 1),
          error: null,
          osOffline: true,
        ),
        BeaconState.connected,
      );
    });

    test('a ≤2 s blip never flips the glass (item 16 churn smoothing)', () {
      // Dropped 1 s ago with fresh data in hand: Wi-Fi re-association noise.
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 1),
          error: null,
          searching: true,
          sinceDrop: const Duration(seconds: 1),
        ),
        BeaconState.connected,
      );
      // Past the hold, the honest state takes over.
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 3),
          error: null,
          searching: true,
          sinceDrop: const Duration(seconds: 3),
        ),
        BeaconState.connecting,
      );
      // The hold can never present STALE data as live — it is strictly
      // shorter than the stale threshold, so a hold with old data cannot
      // happen; assert the ordering that guarantees it.
      expect(
        KvFreshness.linkChurnGrace < KvFreshness.staleAfter,
        isTrue,
        reason: 'a longer hold would paint stale data at full brightness',
      );
      // An explicit error is information, not churn — it is never held back.
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 1),
          error: 'boom',
          sinceDrop: const Duration(milliseconds: 500),
        ),
        BeaconState.error,
      );
    });

    test(
      'connected-but-quiet still reads stale — the phrase keeps its job',
      () {
        // DS-1's staleness convention is correct exactly here: the socket is up
        // and the data is old (the midnight DAA stall). C7 narrows where the
        // phrase may appear; it does not remove it.
        expect(
          evaluateBeacon(
            connected: true,
            age: const Duration(seconds: 30),
            error: null,
          ),
          BeaconState.stale,
        );
      },
    );

    test('no staleness phrase is reachable before the first connect', () {
      // The invariant, exhaustively over the flags: with no prior fresh
      // snapshot (age == null) the state can never be `stale`, whatever the
      // engine bits say.
      for (final searching in [true, false]) {
        for (final osOffline in [true, false]) {
          for (final connected in [true, false]) {
            expect(
              evaluateBeacon(
                connected: connected,
                age: null,
                error: null,
                searching: searching,
                osOffline: osOffline,
              ),
              isNot(BeaconState.stale),
              reason:
                  'connected=$connected searching=$searching '
                  'osOffline=$osOffline leaked a staleness reading',
            );
          }
        }
      }
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
