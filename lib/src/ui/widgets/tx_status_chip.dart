import 'package:flutter/material.dart';

import '../../rust/api/transport.dart';
import '../../rust/api/wallet.dart';
import '../theme/tokens.dart';

/// The V2 chip states a transaction row can wear. `none` is the terminal
/// quiet: a settled row carries no label (Rams #5 — only the exception is
/// marked; founder-nodded 2026-07-09).
enum TxChipState { pending, accepted, stalled, none }

/// Chip state for a wallet activity row: the V1 acceptance overlay
/// (`maturity`) plus the V2 stall flag. Pure; tested.
TxChipState chipStateOf(MaturityState maturity, {required bool stalled}) {
  return switch (maturity) {
    MaturityState.confirmed => TxChipState.none,
    MaturityState.accepted => TxChipState.accepted,
    MaturityState.pending when stalled => TxChipState.stalled,
    MaturityState.pending => TxChipState.pending,
  };
}

/// Chip state for a thread message from its tracker status. `null` (unwatched
/// or horizon-pruned) and `confirmed` are both the quiet terminal; `displaced`
/// honestly re-pends (the accepting block left the chain). Pure; tested.
TxChipState chipStateOfAcceptance(TxStatusKind? kind) {
  return switch (kind) {
    null => TxChipState.none,
    TxStatusKind.confirmed => TxChipState.none,
    TxStatusKind.accepted => TxChipState.accepted,
    TxStatusKind.submitted => TxChipState.pending,
    TxStatusKind.displaced => TxChipState.pending,
    TxStatusKind.stalled => TxChipState.stalled,
  };
}

/// The three-state transaction status chip (V2, founder-nodded design):
/// dot + label, never color alone (design_system §11).
///
/// - **pending** — quiet `textTertiary`, dot breathing on [pulsePhase] (the
///   StatusBeacon contract: parent supplies the tick; the breath stops the
///   instant the state resolves — DS-1-honest attention guidance).
/// - **accepted** — `success` (the chain accepted it; on Kaspa this IS the
///   user-meaningful confirmation, DS-3).
/// - **stalled** — `warning`, steady: degraded is not "in progress". Amber is
///   re-rationed here from the old Pending label (semantic scarcity, §3).
/// - **none** — the chip dissolves; a settled row stays quiet.
///
/// State changes crossfade at `fast`; the dissolve to quiet takes `normal`.
/// Vault register throughout: decelerate-only, no celebration (DS-5).
class TxStatusChip extends StatelessWidget {
  const TxStatusChip({
    super.key,
    required this.state,
    this.pulsePhase = false,
    this.confirmations,
  });

  final TxChipState state;

  /// Parent-driven breath tick (e.g. `now.second.isEven`) — only the pending
  /// state consumes it.
  final bool pulsePhase;

  /// Live depth for the counting states (founder request, V2 sitting): when
  /// set, the label streams "N confirmations" instead of the static word —
  /// green while an accepted send deepens, quiet grey while a deposit
  /// matures — and the dissolve still marks "deep enough". Node-read
  /// (tracker blue-depth for sends; DAA distance for deposits); tabular
  /// digits so the count never jiggles (§4).
  final int? confirmations;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedSwitcher(
      duration: state == TxChipState.none ? KvMotion.normal : KvMotion.fast,
      switchInCurve: KvMotion.out,
      switchOutCurve: KvMotion.out,
      // The dissolve releases its space smoothly (no end-of-fade layout
      // snap); reduced motion degrades to opacity-only (§6).
      transitionBuilder: (child, animation) {
        final fade = FadeTransition(opacity: animation, child: child);
        if (reduced) return fade;
        return SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1.0,
          child: fade,
        );
      },
      child: KeyedSubtree(key: ValueKey(state), child: _body(context, reduced)),
    );
  }

  Widget _body(BuildContext context, bool reduced) {
    var (color, label) = switch (state) {
      TxChipState.pending => (KvColor.textTertiary, 'Pending'),
      TxChipState.accepted => (KvColor.success, 'Accepted'),
      TxChipState.stalled => (KvColor.warning, 'Not accepted yet'),
      TxChipState.none => (null, null),
    };
    if (color == null || label == null) return const SizedBox.shrink();
    // The counting states stream their depth; stalled never counts (it has
    // no depth to count) and a null depth falls back to the static word.
    final n = confirmations;
    if (n != null && state != TxChipState.stalled) {
      label = '$n confirmation${n == 1 ? '' : 's'}';
    }

    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The breath rides the dot only (the label stays legible) and
        // freezes to a static full-opacity dot under reduced motion — the
        // StatusBeacon contract, exactly (§6/§11).
        if (state == TxChipState.pending && !reduced)
          AnimatedOpacity(
            opacity: pulsePhase ? 1.0 : KvFreshness.opacityStale,
            duration: KvMotion.normal,
            curve: KvMotion.out,
            child: dot,
          )
        else
          dot,
        const SizedBox(width: KvSpace.xs),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: color,
            // The count ticks ~10×/s on Kaspa — digits must not jiggle (§4).
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
