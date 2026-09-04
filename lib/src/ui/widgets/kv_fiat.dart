import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/rate_service.dart' show KvRateQuote, RateService;
import 'status_beacon.dart' show formatAge;
import '../theme/tokens.dart';

/// The fiat wiring a surface consumes — same law as `ChainScope`.
///
/// It lived inside `home_screen.dart` while the money plate was the only
/// surface that restated a balance in dollars. Since 2026-09-04 three surfaces
/// do (the plate, the amount being typed on Send, and the signing sheet), so
/// the scope and its one renderer moved to where a widget may reach them
/// without importing a screen.
class FiatScope {
  const FiatScope({
    required this.enabled,
    required this.quote,
    this.attach,
    this.detach,
  });

  /// `null` until the stored posture has been read — rendered as nothing,
  /// never as an optimistic `≈ —` (`wallet-security-auditor`).
  final ValueListenable<bool?> enabled;
  final ValueListenable<KvRateQuote?> quote;

  final VoidCallback? attach;
  final VoidCallback? detach;
}

/// The `≈` restatement, in mono at `inkMeta`, one step under the figure it
/// belongs to (BG-5 as amended).
///
/// **Three surfaces, one implementation** (BG-21/L83). It began as the money
/// plate's private line; the founder then put a price under the amount being
/// typed on Send and under the KAS figure on the signing sheet (2026-09-04:
/// *"let the price show under the amount just like the screenshot has it …
/// its ok to have it here and as well as the signing sheet"*), which is
/// `S6`'s and `S7`'s own `≈ $0.34`. Three copies of a figure that can be
/// stale is three places for the staleness rule to be corrected in one.
///
/// **BG-5's carve-out travels with it.** Fiat is a convenience beside the unit
/// of account and never instead of it (D-191): subordinate in scale and tone
/// on every seat, never a term in a fee, never what sizes a spend. What the
/// founder's ruling withdrew is the *"never on a spend"* clause — see the
/// design system's BG-5 for the amended wording and why the safety half of
/// that law is untouched.
class KvFiatLine extends StatefulWidget {
  const KvFiatLine({
    super.key,
    required this.fiat,
    required this.sompi,
    this.now,
    this.alignment = MainAxisAlignment.start,
  });

  /// Null ⇒ the rate seam is not wired at all (a widget test, a build without
  /// it): the line renders nothing, exactly as if the user had switched it off.
  final FiatScope? fiat;

  /// What to restate — the owning surface's own number, so the two can never
  /// disagree. Null is that surface's `—`, and it restates as `≈ —` rather
  /// than as `$0.00`: an unknown amount has an unknown value, and a confident
  /// zero beside a dash is the kind of true-looking lie BG-8 exists to stop.
  final BigInt? sompi;

  /// A freshness clock the surface already runs. Null runs one here — see
  /// [_KvFiatLineState._now].
  final ValueListenable<DateTime>? now;

  /// Centred under a typed amount (`S6`/`S7`), leading under the plate (`S1`).
  final MainAxisAlignment alignment;

  @override
  State<KvFiatLine> createState() => _KvFiatLineState();
}

class _KvFiatLineState extends State<KvFiatLine> {
  /// **The screen's freshness clock, not a `clock()` call** (BG-8).
  ///
  /// The age below is the one branch that must appear WITHOUT a new value
  /// arriving — a vendor that goes down stops delivering quotes, which is
  /// exactly when the figure starts being able to mislead. Computed from a
  /// bare `clock()` it was unreachable in practice: the only thing that
  /// rebuilt this line was a fresh quote, and a fresh quote resets the age to
  /// zero. So a dead source rendered a confident `≈ \$36.79`, ageless, forever
  /// (`consensus-auditor`, UX-3 — `L126` in its purest form).
  ///
  /// A surface that already ticks (the money plate) passes its own through
  /// [KvFiatLine.now]; one that does not gets this, so the staleness branch is
  /// reachable on **every** seat rather than only the one that happened to
  /// own a timer. A stale rate matters more on a spend, not less.
  ValueNotifier<DateTime>? _owned;
  Timer? _tick;

  static const Duration _every = Duration(seconds: 30);

  ValueListenable<DateTime> get _now =>
      widget.now ?? (_owned ??= ValueNotifier(DateTime.now()));

  @override
  void initState() {
    super.initState();
    // **This seat holds the rate open while it is on screen** (L5).
    //
    // `RateService` is ref-counted so the timer runs only while something that
    // draws a price is mounted — and until UX-R2B only the money plate called
    // it. Send and the ceremony worked anyway, because both are *pushed over*
    // Home and Home's attach was still live: a correctness property resting on
    // a routing accident (`consensus-auditor`). Attaching here makes every seat
    // hold its own reference, so the two funds surfaces keep a fresh price
    // whatever route reaches them, and a locked wallet still fetches nothing.
    widget.fiat?.attach?.call();
    if (widget.now == null) {
      _tick = Timer.periodic(_every, (_) {
        if (mounted) _owned?.value = DateTime.now();
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _owned?.dispose();
    widget.fiat?.detach?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.fiat;
    if (scope == null) return const SizedBox.shrink();
    return ValueListenableBuilder<bool?>(
      valueListenable: scope.enabled,
      builder: (context, on, _) {
        // Off, or not yet known: both render nothing. A line that appears one
        // frame after launch is better than one that appears and then leaves.
        if (on != true) return const SizedBox.shrink();
        return ValueListenableBuilder<KvRateQuote?>(
          valueListenable: scope.quote,
          builder: (context, quote, _) => ValueListenableBuilder<DateTime>(
            valueListenable: _now,
            builder: (context, at, _) {
              final sompi = widget.sompi;
              final value = sompi == null ? null : quote?.usdFor(sompi);
              final figure = value == null
                  ? '≈ —'
                  : '≈ \$${value.toStringAsFixed(2)}';
              // Silence is the healthy state (D-189/D-192): a fresh rate says
              // nothing about its age, and the age appears at the point where
              // it could start to mislead.
              final since = quote == null
                  ? null
                  : at.difference(quote.fetchedAt);
              final age = since == null
                  ? 'no rate yet'
                  : since >= RateService.staleAfter
                  ? '${formatAge(since)} old'
                  : null;
              return Semantics(
                label: value == null
                    ? 'Value in dollars: no exchange rate yet'
                    : 'Approximately ${value.toStringAsFixed(2)} US dollars',
                excludeSemantics: true,
                child: Row(
                  mainAxisAlignment: widget.alignment,
                  mainAxisSize: widget.alignment == MainAxisAlignment.start
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      figure,
                      // 15, not `fact`'s 13 (render `S1`, measured, D-261;
                      // `S7` measured the same size under the ceremony's
                      // 32 dp restatement).
                      style: const TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 15,
                        height: 20 / 15,
                        fontWeight: FontWeight.w500,
                        fontVariations: KvWeight.w500,
                        // Subordinate by scale AND tone (BG-5): KAS is the
                        // unit of account and this sits beside it, never
                        // instead.
                        color: KvColor.inkMeta,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (age != null) ...[
                      const SizedBox(width: KvSpace.s),
                      Flexible(
                        child: Text(
                          age,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // **Mono for the age, Jakarta for the sentence**
                          // (BG-30). `12 m old` is an elapsed time and takes
                          // `metaMono`, the same face as the ledger's own row
                          // times; `no rate yet` is a *sentence*, and mono
                          // never carries one — which the first cut got wrong
                          // by setting the whole slot in mono because the
                          // common branch is a figure.
                          style: TextStyle(
                            fontFamily: quote == null ? KvFont.ui : KvFont.mono,
                            fontSize: 11,
                            height: 16 / 11,
                            fontWeight: FontWeight.w500,
                            fontVariations: KvWeight.w500,
                            color: KvColor.inkMeta,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
