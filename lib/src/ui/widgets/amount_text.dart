import 'package:flutter/material.dart';

import '../format.dart';
import '../theme/tokens.dart';

/// Size role for [AmountText], mapped onto the §4 type ramp: the [hero] home
/// balance (`displayMedium`), a [screen]-level amount such as the confirm
/// sheet's headline (`displaySmall`), or an amount in a list [row]
/// (`bodyLarge`). All three slots are mono + tabular already.
enum AmountRole { hero, screen, row }

/// DS-2 money anatomy: the integer part at full role size in `text-primary`,
/// the fraction + `" KAS"` at ~70% in `text-secondary`, sharing the baseline.
/// Mono + tabular figures (from the theme) so digits never jiggle as a value
/// ticks.
///
/// - `null` sompi renders the DS-1 **unknown** `—` (never a fake `0`).
/// - A real value — including `0` — renders a live zero (a synced empty
///   wallet is `0.00…`, never unknown).
/// - **Precision** (§5): rows trim trailing zeros to ≥2 decimals (feeds rule);
///   hero/screen show all 8. `exact: true` forces the full 8 anywhere — every
///   signing surface uses it (DS-2: the full truth at commitment).
/// - **Floors toward zero** (via [kasParts]) — never rounds a balance up.
/// - [prefix] renders a direction sign (`+`/`−`) inside the amount so the
///   semantics label speaks it too; direction is never colour-only (§11).
/// - `stale` dims to `opacity-stale` (DS-1; the freshness age lives on the
///   beacon, as with the shipped scores).
class AmountText extends StatelessWidget {
  const AmountText(
    this.sompi, {
    super.key,
    this.role = AmountRole.hero,
    this.stale = false,
    this.prefix,
    bool? exact,
  }) : _exact = exact;

  /// Non-negative balance in sompi (`BigInt`, L3). `null` = not yet known.
  final BigInt? sompi;
  final AmountRole role;
  final bool stale;

  /// Optional direction sign rendered before the integer part.
  final String? prefix;

  final bool? _exact;

  /// Full 8 decimals unless this is a plain list row (§5).
  bool get _showExact => _exact ?? (role != AmountRole.row);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = switch (role) {
      AmountRole.hero => theme.textTheme.displayMedium,
      AmountRole.screen => theme.textTheme.displaySmall,
      AmountRole.row => theme.textTheme.bodyLarge,
    }!;
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
      final fraction = _showExact
          ? parts.fraction
          : trimFraction(parts.fraction);
      final sign = prefix ?? '';
      content = Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$sign${parts.integer}', style: integerStyle),
            TextSpan(text: '.$fraction KAS', style: fractionStyle),
          ],
        ),
        maxLines: 1,
        // §11: a screen reader speaks the amount, not grouped digit-soup.
        semanticsLabel: '$sign${parts.integer}.$fraction KAS',
      );
    }

    // Hero/screen amounts never wrap or ellipsize — they scale down to fit
    // (DS-2; the shipped score-tile pattern). Rows stay at their fixed size.
    final laidOut = role == AmountRole.row
        ? content
        : FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: content,
          );

    return AnimatedOpacity(
      opacity: stale ? KvFreshness.opacityStale : 1.0,
      duration: KvMotion.instant,
      curve: KvMotion.out,
      child: laidOut,
    );
  }
}
