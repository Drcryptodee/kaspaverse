import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/tokens.dart';

/// Size role for [AmountText]: the [hero] balance headline vs an amount in a
/// list [row] (mapped onto the theme's `displayMedium` / `bodyLarge` slots,
/// both already mono + tabular — DS-4).
enum AmountRole { hero, row }

/// DS-2 money anatomy: the integer part at full role size in `text-primary`,
/// the fraction + `" KAS"` at ~70% in `text-secondary`, sharing the baseline.
/// Mono + tabular figures (from the theme) so digits never jiggle as a value
/// ticks.
///
/// - `null` sompi renders the DS-1 **unknown** `—` (never a fake `0`).
/// - A real value — including `0` — renders `0.00000000 KAS` (a synced empty
///   wallet is a live zero, never unknown).
/// - **Floors toward zero** (via [kasParts]) — never rounds a balance up.
/// - `stale` dims to `opacity-stale` (DS-1; the freshness age lives on the
///   beacon, as with the shipped scores).
class AmountText extends StatelessWidget {
  const AmountText(
    this.sompi, {
    super.key,
    this.role = AmountRole.hero,
    this.stale = false,
  });

  /// Non-negative balance in sompi (`BigInt`, L3). `null` = not yet known.
  final BigInt? sompi;
  final AmountRole role;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = (role == AmountRole.hero
        ? theme.textTheme.displayMedium
        : theme.textTheme.bodyLarge)!;
    final integerStyle = base.copyWith(color: KvColor.textPrimary);
    final fractionStyle = base.copyWith(
      color: KvColor.textSecondary,
      fontSize: (base.fontSize ?? 16) * 0.7,
    );

    final Widget content;
    if (sompi == null) {
      // DS-1 unknown — never a fabricated zero.
      content = Text(
        '—',
        maxLines: 1,
        semanticsLabel: 'amount unknown',
        style: base.copyWith(color: KvColor.textSecondary),
      );
    } else {
      final parts = kasParts(sompi!);
      content = Text.rich(
        TextSpan(
          children: [
            TextSpan(text: parts.integer, style: integerStyle),
            TextSpan(text: '.${parts.fraction} KAS', style: fractionStyle),
          ],
        ),
        maxLines: 1,
        // §11: a screen reader speaks the amount, not grouped digit-soup.
        semanticsLabel: '${parts.integer}.${parts.fraction} KAS',
      );
    }

    // The hero never wraps or ellipsizes — it scales down to fit (DS-2; the
    // shipped score-tile pattern). Rows stay at their fixed size.
    final laidOut = role == AmountRole.hero
        ? FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: content,
          )
        : content;

    return AnimatedOpacity(
      opacity: stale ? KvFreshness.opacityStale : 1.0,
      duration: KvMotion.instant,
      curve: KvMotion.out,
      child: laidOut,
    );
  }
}
