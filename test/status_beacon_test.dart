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

  // ── LINK-Q1 (D-331(b)): the lamp holds on a bound socket; the data does not ─
  //
  // CONN-F1 measured it: on the founder's weak Starlink hop every stall on a
  // live socket recovered in 5.25–7.50 s, and a five-second lamp turned amber
  // for each one. The ruling moves the LAMP to fifteen seconds on a bound
  // socket and leaves the DATA's clock — the balance's dim — at five.
  group('evaluateBeacon — the lamp\'s hold (LINK-Q1)', () {
    const hold = KvFreshness.liveHoldBound;

    test('a bound socket\'s lamp stays live through a short stall', () {
      for (final secs in [5, 6, 7, 10, 14]) {
        expect(
          evaluateBeacon(
            connected: true,
            age: Duration(seconds: secs),
            error: null,
            liveHold: hold,
          ),
          BeaconState.connected,
          reason: 'a $secs s stall on a bound socket is not amber',
        );
      }
      expect(
        evaluateBeacon(connected: true, age: hold, error: null, liveHold: hold),
        BeaconState.stale,
        reason: 'past the hold it is — the boundary is stale, as it always was',
      );
    });

    test('the hold is for a BOUND socket — a real drop is not held', () {
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 3),
          error: null,
          liveHold: hold,
          sinceDrop: const Duration(seconds: 3),
        ),
        BeaconState.stale,
        reason: 'past the churn grace a dropped link is stale at any age',
      );
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 3),
          error: null,
          searching: true,
          liveHold: hold,
        ),
        BeaconState.connecting,
      );
    });

    test('the churn hold holds against the caller\'s clock', () {
      // A silence swap's sub-second cut-over, eleven seconds into a silence:
      // the lamp still calls the data live, so the drop must not flash amber.
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 11),
          error: null,
          liveHold: hold,
          sinceDrop: const Duration(milliseconds: 600),
        ),
        BeaconState.connected,
      );
      // The data's own clock never held that — and still does not.
      expect(
        evaluateBeacon(
          connected: false,
          age: const Duration(seconds: 11),
          error: null,
          sinceDrop: const Duration(milliseconds: 600),
        ),
        BeaconState.stale,
      );
      expect(
        KvFreshness.linkChurnGrace < KvFreshness.liveHoldBound,
        isTrue,
        reason: 'the churn hold can never outlast the lamp it holds',
      );
    });

    test('a new socket that has not spoken, after a long quiet, is still '
        'finding the chain — not an age the user is about to leave', () {
      expect(
        evaluateBeacon(
          connected: true,
          age: const Duration(minutes: 30),
          error: null,
          liveHold: hold,
          awaitingScore: true,
        ),
        BeaconState.connecting,
      );
      // Once it speaks, the clock is fresh and the lamp is live; a socket that
      // spoke and then went quiet past the hold IS stale.
      expect(
        evaluateBeacon(
          connected: true,
          age: const Duration(seconds: 20),
          error: null,
          liveHold: hold,
        ),
        BeaconState.stale,
      );
    });

    test('without a hold the function is exactly what it was — the balance\'s '
        'clock did not move', () {
      // Exhaustive over the inputs the old function read, at every second
      // across both lines: omitting `liveHold` must equal the pre-LINK-Q1 rule.
      BeaconState old({
        required bool connected,
        required Duration? age,
        required String? error,
        required bool searching,
        required bool osOffline,
        required Duration? sinceDrop,
      }) {
        if (error == null &&
            !connected &&
            sinceDrop != null &&
            sinceDrop < KvFreshness.linkChurnGrace &&
            age != null &&
            age < KvFreshness.staleAfter) {
          return BeaconState.connected;
        }
        if (!connected && osOffline) return BeaconState.offline;
        if (error != null) return BeaconState.error;
        if (!connected && searching) return BeaconState.connecting;
        if (age == null) return BeaconState.connecting;
        if (!connected || age >= KvFreshness.staleAfter) {
          return BeaconState.stale;
        }
        return BeaconState.connected;
      }

      final ages = <Duration?>[
        null,
        for (var s = 0; s <= 20; s++) Duration(seconds: s),
      ];
      final drops = <Duration?>[
        null,
        const Duration(milliseconds: 500),
        const Duration(seconds: 3),
      ];
      for (final connected in [true, false]) {
        for (final age in ages) {
          for (final error in [null, 'x']) {
            for (final searching in [true, false]) {
              for (final osOffline in [true, false]) {
                for (final sinceDrop in drops) {
                  expect(
                    evaluateBeacon(
                      connected: connected,
                      age: age,
                      error: error,
                      searching: searching,
                      osOffline: osOffline,
                      sinceDrop: sinceDrop,
                    ),
                    old(
                      connected: connected,
                      age: age,
                      error: error,
                      searching: searching,
                      osOffline: osOffline,
                      sinceDrop: sinceDrop,
                    ),
                    reason:
                        'connected=$connected age=$age error=$error '
                        'searching=$searching offline=$osOffline drop=$sinceDrop',
                  );
                }
              }
            }
          }
        }
      }
    });
  });

  group('formatAge — floors, never overstates freshness', () {
    test(
      'seconds',
      () => expect(formatAge(const Duration(seconds: 12)), '12\u00A0s'),
    );
    test(
      'minutes floor',
      () => expect(formatAge(const Duration(seconds: 125)), '2\u00A0m'),
    );
    test(
      'hours floor',
      () => expect(formatAge(const Duration(minutes: 130)), '2\u00A0h'),
    );
  });
}
