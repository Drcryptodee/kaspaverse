import 'dart:async';

import 'package:flutter/widgets.dart';

import '../rust/api/prefs.dart';

/// One price, with the two things that make it honest: when it was fetched,
/// and who said it.
///
/// A price is the single claim in this app that consensus cannot re-verify
/// (INV-8's carve-out, D-191), so it never travels without its provenance.
@immutable
class KvRateQuote {
  const KvRateQuote({
    required this.usdPerKas,
    required this.fetchedAt,
    required this.source,
  });

  final double usdPerKas;
  final DateTime fetchedAt;

  /// The endpoint it came from — what the disclosure names.
  final String source;

  /// USD value of `sompi`, or null when the multiplication cannot be trusted.
  ///
  /// **Render-layer arithmetic on a display-only number.** `double` is right
  /// here and wrong two lines away: this figure is a convenience beside the
  /// balance and never a term in a settlement (BG-5), while the balance itself
  /// stays `BigInt` sompi from Rust to paint.
  double? usdFor(BigInt sompi) {
    if (sompi < BigInt.zero) return null;
    final kas = sompi / BigInt.from(100000000);
    final value = kas * usdPerKas;
    return value.isFinite ? value : null;
  }
}

/// The fiat rate — the app's one unverifiable claim, kept switchable.
///
/// **Why a service at all, when the row could call the bridge directly.** The
/// price is read by the money plate and written by the node surface, and those
/// two must never disagree about whether the rate is on (the C7 rule). One
/// writer, notifiers out.
///
/// **Ref-counted, not app-lifetime** (L5). The timer runs only while a surface
/// that renders a price is mounted, so a locked wallet fetches nothing: BG-13
/// discards the money screen at 0ms, [detach] stops the clock with it, and the
/// app stops talking to a price vendor the moment nobody is looking at a price.
class RateService with WidgetsBindingObserver {
  RateService._();

  static final RateService instance = RateService._();

  /// How often a mounted surface re-asks. Slow on purpose: a wallet balance
  /// restated in dollars is context, not a ticker, and a price that moves
  /// under the user's eyes invites watching it instead of reading it.
  static const Duration refreshEvery = Duration(minutes: 5);

  /// When a price starts being able to mislead, and therefore starts showing
  /// its age (D-189: *"source lives where the source is chosen, age appears
  /// when age matters"*). Two missed refreshes — at which point something is
  /// wrong rather than merely quiet.
  static const Duration staleAfter = Duration(minutes: 10);

  /// Bridge seams, one static per call (`messaging_service`'s shape), so a
  /// widget test never needs the native library.
  @visibleForTesting
  static Future<RateConfigDto> Function() readConfigFn = prefsRateConfig;
  @visibleForTesting
  static Future<void> Function(bool enabled, String endpoint) writeConfigFn =
      (enabled, endpoint) =>
          prefsSetRateConfig(enabled: enabled, endpoint: endpoint);
  @visibleForTesting
  static Future<RateQuoteDto?> Function() fetchQuoteFn = prefsRateQuote;

  /// Test seam for "now", matching `HomeScreen.clock`.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// The latest usable price, or null — which is what `—` on the glass means.
  /// **Never a fabricated number**: a failed fetch keeps the last good quote
  /// (with its age) or leaves this null, and invents nothing.
  final ValueNotifier<KvRateQuote?> quote = ValueNotifier(null);

  /// Whether the user has the rate switched on — **`null` until the stored
  /// posture has actually been read**.
  ///
  /// It was `true` initially, on the reasoning that the default is on. That
  /// made the initialiser a claim rather than a default: a user who had
  /// switched fiat off got `≈ —` on their money plate for as long as the read
  /// took, on every launch (`wallet-security-auditor`). Unknown is a third
  /// state and the glass renders it as nothing at all.
  final ValueNotifier<bool?> enabled = ValueNotifier(null);

  /// The price source, as chosen. Named on the row where it is chosen (D-193).
  final ValueNotifier<String> endpoint = ValueNotifier('');

  /// What "reset to the shipped source" would restore.
  final ValueNotifier<String> defaultEndpoint = ValueNotifier('');

  /// Why the last fetch produced nothing, in the bridge's own words. Null when
  /// nothing has gone wrong. Rendered where the source is chosen — never as a
  /// toast, and never on the money plate, which says `—` and stops there.
  final ValueNotifier<String?> error = ValueNotifier(null);

  Timer? _timer;
  int _attached = 0;
  bool _fetching = false;

  /// A surface that renders a price appeared. First attach loads the config,
  /// fetches once, and starts the clock.
  void attach() {
    _attached++;
    if (_attached > 1) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load(thenFetch: true));
    _startTimer();
  }

  /// A surface that renders a price went away. Last detach stops the clock.
  ///
  /// The quote is deliberately **kept**: a re-attach paints the last known
  /// price immediately, with its age, rather than flashing `—` at a user who
  /// just came back — dimmed cached truth beats an empty frame (BG-8).
  void detach() {
    if (_attached == 0) return;
    _attached--;
    if (_attached > 0) return;
    WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
  }

  /// **The clock follows the app, not only the widget** (`ChainService`'s own
  /// background posture, D-053 — *no invisible always-on stream*).
  ///
  /// Mounted is not the same as visible: with any auto-lock grace above zero,
  /// a backgrounded wallet keeps this screen alive for up to fifteen minutes,
  /// and the timer would have gone on asking a price vendor for a figure
  /// nobody could see — one to three unattended requests from a phone in a
  /// pocket (`wallet-security-auditor`). At grace 0 the lock discards the
  /// screen and `detach` already handled it; this covers every other grace.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_attached == 0) return;
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      // Coming back is exactly when a stale price is worth replacing.
      unawaited(refresh());
    } else {
      _stopTimer();
    }
  }

  void _startTimer() {
    _timer ??= Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Re-read the stored posture without fetching — for a surface that only
  /// shows the setting (the node screen opening cold).
  Future<void> loadConfig() => _load(thenFetch: false);

  Future<void> _load({required bool thenFetch}) async {
    try {
      final config = await readConfigFn();
      enabled.value = config.enabled;
      endpoint.value = config.endpoint;
      defaultEndpoint.value = config.defaultEndpoint;
    } catch (_) {
      // A platform gap (host tests, a missing channel) leaves the last known
      // posture standing rather than claiming the rate is on.
      return;
    }
    if (thenFetch && (enabled.value ?? false)) await refresh();
  }

  /// Change the posture. Writes through Rust — which validates the endpoint —
  /// then re-reads, so what the glass shows is what was stored and never what
  /// was asked for. Throws the bridge's message on a refusal.
  Future<void> setConfig({
    required bool enabled,
    required String endpoint,
  }) async {
    final wasFrom = this.endpoint.value;
    await writeConfigFn(enabled, endpoint);
    error.value = null;
    // **Off, or from somewhere else, both clear the figure.** Off is obvious:
    // a switch that leaves the old number sitting there has not visibly done
    // anything. A changed SOURCE is the subtler half — a price from a vendor
    // the user just replaced is a different claim, not cached truth, and
    // leaving it under a row that now names the new source makes the reading
    // and its disclosure name different things (`consensus-auditor`).
    if (!enabled || endpoint.trim() != wasFrom) quote.value = null;
    await _load(thenFetch: enabled);
  }

  /// Fetch one price now. Safe to call repeatedly — a fetch already in flight
  /// swallows the second call rather than doubling the egress.
  Future<void> refresh() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final fetched = await fetchQuoteFn();
      if (fetched == null) {
        // Rust refused because the rate is off. The switch is enforced at the
        // egress, so this is the authoritative answer even if our own
        // `enabled` notifier were stale.
        enabled.value = false;
        quote.value = null;
        return;
      }
      // A result from a source that is no longer the chosen one is dropped,
      // not shown. It is reachable without any failure: the in-flight swallow
      // below means a refresh started against the old endpoint can land after
      // the user has replaced it.
      if (endpoint.value.isNotEmpty && fetched.source != endpoint.value) {
        return;
      }
      quote.value = KvRateQuote(
        usdPerKas: fetched.usdPerKas,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(
          fetched.fetchedAtUnixMs.toInt(),
        ),
        source: fetched.source,
      );
      error.value = null;
    } catch (e) {
      // The last good price survives with its age; a failure never invents one
      // and never clears one that was true when it was fetched.
      error.value = e.toString();
    } finally {
      _fetching = false;
    }
  }

  /// Whether [quote] is old enough that its age must be shown (BG-8/D-189).
  bool get quoteIsStale {
    final current = quote.value;
    if (current == null) return false;
    return clock().difference(current.fetchedAt) >= staleAfter;
  }

  @visibleForTesting
  void reset() {
    if (_attached > 0) WidgetsBinding.instance.removeObserver(this);
    _stopTimer();
    _attached = 0;
    _fetching = false;
    quote.value = null;
    enabled.value = null;
    endpoint.value = '';
    defaultEndpoint.value = '';
    error.value = null;
  }
}
