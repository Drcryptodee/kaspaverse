import '../theme/tokens.dart';

/// The honest states of a chain link (BG-8, design_system §8). Colour is
/// never the only signal — every state pairs a dot colour with a text label
/// (§11). [offline] is C7's addition (D-089 ruling 6): when the OS says the
/// phone has no network, the glass names the phone instead of blaming a node.
enum BeaconState { connected, connecting, stale, error, offline }

/// Pure state derivation — the testable heart of the P0.3 stale-dimming
/// retrofit, widened at C7 (D-091 ruling 1) to the three truths the engine
/// actually knows.
///
/// Priority, and why:
/// 1. **Churn hold** — a link that drops with fresh data in hand keeps reading
///    live for [churnGrace]. Sub-2 s transitions are Wi-Fi re-association
///    noise, not information (register item 16's ruling on the render side; the
///    engine's twin is `MIN_STRIKE_RUN_SECS`). It can never hold a stale
///    reading live, because [churnGrace] < [staleAfter].
/// 2. **Phone offline** — the OS's own `onLost`, and only while the socket is
///    also down: a live socket is proof of a network whatever a flapping
///    callback claims. Ranked above [error] deliberately — with no network,
///    every downstream error is a *consequence*, and "connection error" would
///    blame the nodes for the user's Wi-Fi.
/// 3. **Error** — an explicit failure we were handed.
/// 4. **Finding a node** — [searching]: a race is hunting. This is the fix for
///    the 2026-07-30 field observation (a 14–28 s weak-link hunt rendered as
///    *"as of 20 s ago"*, which reads as *connected, data slightly stale* —
///    the exact opposite of the truth). That quote is the PRE-C7 glass, kept as
///    history; the stale label has since shortened to *"20 s ago"* so the age
///    survives a narrow header (2026-08-24 — see rule 6's arm below).
/// 5. No data ever ([age] null) is also *finding a node* — honest in the
///    instant between mount and the first race flag.
/// 6. A dropped link or silence past [staleAfter] is `stale`.
/// 7. Otherwise `connected`.
///
/// **Invariant this ordering buys (C7's acceptance bar):** a staleness phrase
/// can never render before the first `wss_connected` of a process. Reaching
/// rule 6 while disconnected requires `age != null`, and only a connected
/// snapshot bearing real chain data ever sets that clock.
///
/// [age] is the time since the last *fresh* snapshot (null ⇒ none ever);
/// [sinceDrop] the time since the link last went down (null ⇒ up, or never up).
BeaconState evaluateBeacon({
  required bool connected,
  required Duration? age,
  required String? error,
  bool searching = false,
  bool osOffline = false,
  Duration? sinceDrop,
  Duration staleAfter = KvFreshness.staleAfter,
  Duration churnGrace = KvFreshness.linkChurnGrace,
}) {
  if (error == null &&
      !connected &&
      sinceDrop != null &&
      sinceDrop < churnGrace &&
      age != null &&
      age < staleAfter) {
    return BeaconState.connected;
  }
  if (!connected && osOffline) return BeaconState.offline;
  if (error != null) return BeaconState.error;
  if (!connected && searching) return BeaconState.connecting;
  if (age == null) return BeaconState.connecting;
  if (!connected || age >= staleAfter) return BeaconState.stale;
  return BeaconState.connected;
}

/// Human age for the stale line: "12 s", "3 m", "2 h". Floors — never
/// overstates freshness.
String formatAge(Duration age) {
  if (age.inSeconds < 60) return '${age.inSeconds} s';
  if (age.inMinutes < 60) return '${age.inMinutes} m';
  return '${age.inHours} h';
}

// **The `StatusBeacon` widget was retired at UX-2** (register item 2). It
// rendered a healthy link in `success` GREEN with a green glow, which BG-7
// narrowed away from: green is money **arriving**, things **confirmed**, and
// a control the **user switched on** — never "healthy", because a link
// changes without the user. Its replacements are shipped and composed on the
// money plate: `KvStatusChip` carries the words and the lamp, and `KvCadence`
// carries liveness. **The network chip carries no lamp at all** — green is
// forbidden here by the same law, and an amber one would duplicate the trust
// line directly beneath it, so health is carried by the trust line staying
// silent (D-192).
//
// What survives is this file's pure derivation — [BeaconState],
// [evaluateBeacon] and [formatAge] — which the money plate, the network
// sheet, the node surface and the history sheet all read. The scar the
// ordering encodes is worth more than the chip that used to draw it.
