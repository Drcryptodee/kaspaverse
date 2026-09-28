/// **The chain's average pace, kept while the app is connected** — the `BPS`
/// row's right side (the founder, 2026-09-28, D-342: *"on the right side, let
/// it show an avg … kaspa.stream shows '1h avg: 10.1' … lets have a different
/// avg"*). Pure, so the arithmetic is provable without a socket.
///
/// **What it measures:** the virtual DAA score's climb between the oldest
/// sample kept and the newest, over the time between them — blocks a second
/// over up to the last hour. The score climbs by one per block merged inside
/// the DAA window (the pin's formula, verified at LINK-UX1 — see
/// `NodeScope.tickPulse`), so this is the chain's own pace; it needs no
/// watching in between, because the score counts every block whether or not
/// the app saw it arrive — a background spell or a reconnect inside the window
/// changes nothing.
///
/// **Why "up to an hour", and not a fixed window:** the app only knows what it
/// has been connected to see, so the span is the honest one — `12 mins avg:`
/// until an hour exists, then `1 hour avg:` rolling. Nothing is fetched: one
/// sample every [spacing] rides the stream the app already holds (≤ 361
/// entries).
///
/// **Its precision is earned by its span.** The endpoints are timed on the
/// phone's clock a coalesced snapshot after the score moved (≤ ~0.3 s), so
/// over [minSpan] (two minutes) the error is under 0.25 % — the one decimal it
/// prints. Under that it says nothing.
class KvPaceLog {
  final List<(DateTime, int)> _kept = <(DateTime, int)>[];
  (DateTime, int)? _latest;

  /// One kept sample at most this often.
  static const Duration spacing = Duration(seconds: 10);

  /// The longest span the average covers.
  static const Duration span = Duration(hours: 1);

  /// The shortest span it reports — see the class doc.
  static const Duration minSpan = Duration(minutes: 2);

  /// **A score that falls by more than this is another count, not a pace**
  /// (a minute of chain). Nodes differ by a few blocks at any moment, so a
  /// swap to one slightly behind keeps the window; anything larger starts
  /// again rather than printing an average across two unrelated counts. The
  /// connect race binds only synced nodes, so a node far behind is not
  /// expected — this is the guard for when one is.
  static const int skewTolerance = 600;

  /// Forget everything — `ChainService.reset`, or a test.
  void reset() {
    _kept.clear();
    _latest = null;
  }

  /// A connected snapshot's score, seen [at].
  void record(DateTime at, int score) {
    final latest = _latest;
    // A clock that did not advance adds nothing to a rate.
    if (latest != null && !at.isAfter(latest.$1)) return;
    if (latest != null && score < latest.$2 - skewTolerance) _kept.clear();
    // **A gap longer than the span starts the window again** (`ux-auditor`,
    // LINK-UX1): after hours in the background the sample from before the
    // gap would anchor the average for a whole hour more — `1 hour avg:` printed
    // over nine. The chain's pace across the gap is still true, but it is not
    // the last hour's, and the label says the last hour.
    if (_kept.isNotEmpty && at.difference(_kept.last.$1) > span) {
      _kept.clear();
    }
    _latest = (at, score);
    if (_kept.isEmpty || at.difference(_kept.last.$1) >= spacing) {
      _kept.add((at, score));
    }
    // Keep exactly one sample at or past the span's edge, and every newer
    // one: the average is then the last hour, never the whole session.
    while (_kept.length > 2 && at.difference(_kept[1].$1) >= span) {
      _kept.removeAt(0);
    }
    // **And never one older than the span by more than a sample's spacing**
    // (`ux-auditor`): across a gap shorter than the hour, the sample from
    // before it stayed the anchor while the first one after it aged in, and
    // `1 hour avg:` covered up to nearly two. Dropped, the window is the shorter
    // span actually covered, and its label says so (`35 mins avg:`).
    while (_kept.length > 1 && at.difference(_kept.first.$1) > span + spacing) {
      _kept.removeAt(0);
    }
  }

  /// The average pace over the span kept, in blocks a second, and that span
  /// — or null until [minSpan] has been seen.
  ({double bps, Duration span})? average() {
    final latest = _latest;
    if (latest == null || _kept.isEmpty) return null;
    final (from, fromScore) = _kept.first;
    final covered = latest.$1.difference(from);
    if (covered < minSpan) return null;
    final bps = (latest.$2 - fromScore) / (covered.inMicroseconds / 1e6);
    // Within a sample's spacing of the hour IS the hour: the anchor's age
    // steps by the snapshot cadence's jitter, and without this the label
    // flickered `1 h avg` ↔ `59 m avg` (the first cut's words) ~1.7 times a
    // minute (`ux-auditor`).
    return (bps: bps, span: covered >= span - spacing ? span : covered);
  }
}
