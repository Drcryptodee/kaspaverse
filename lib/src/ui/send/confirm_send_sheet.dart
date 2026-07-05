import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/amount_text.dart';
import '../widgets/haptics.dart';

/// The anti-blind-signing confirm (consensus B7 — the heart of P1.6). Everything
/// here renders the [SendSummaryDto] Rust decoded from the ACTUAL transactions it
/// will sign — never the form's echo of the user's intent. The hold-to-sign
/// ceremony (DS-3) is decelerate-only with no double-tap path to broadcast, and
/// every amount on this surface is exact to all 8 decimals (DS-2: the full
/// truth at the moment of commitment).
///
/// Dismissing before the hold completes calls [abandon] (drops the Rust stash);
/// a completed send pops with its [SendOutcomeDto].
class ConfirmSendSheet extends StatefulWidget {
  const ConfirmSendSheet({
    super.key,
    required this.summary,
    required this.commit,
    required this.abandon,
    this.title = 'Confirm send',
    this.contextNote,
    this.selfSend = false,
  });

  final SendSummaryDto summary;
  final Future<SendOutcomeDto> Function(BigInt nonce) commit;
  final Future<void> Function() abandon;

  /// Sheet heading — transport sends (P2.3) rename the ceremony honestly
  /// ("Confirm contact request", "Confirm message") without touching the
  /// B7 numbers or the hold-to-sign discipline.
  final String title;

  /// One optional plain-English line under the destination — what this send
  /// carries beyond value (e.g. the bond-refund rule). Never a number the
  /// summary doesn't back (B7: the DTO stays the only source of figures).
  final String? contextNote;

  /// A **self-send** (D-069): the payment output returns to the sender's own
  /// address as change, so the message value never leaves the wallet and the
  /// real cost is the network fee alone. The sheet then leads with the FEE (not
  /// the amount), drops the raw self "To" address, and states the returning
  /// value plainly — never showing a self-send as if 0.1 KAS were spent.
  final bool selfSend;

  @override
  State<ConfirmSendSheet> createState() => _ConfirmSendSheetState();
}

class _ConfirmSendSheetState extends State<ConfirmSendSheet> {
  bool _committed = false;
  bool _sending = false;
  SendOutcomeDto? _outcome;
  String? _error;

  @override
  void dispose() {
    // Dismissed without sending → release the stashed (unsigned) plan in Rust.
    if (!_committed) widget.abandon();
    super.dispose();
  }

  Future<void> _commit() async {
    setState(() {
      _committed = true;
      _sending = true;
      _error = null;
    });
    try {
      final outcome = await widget.commit(widget.summary.nonce);
      // Broadcast accepted — the §7 money moment (fires only for real
      // acceptance, full or partial; a zero-submitted failure stays silent).
      if (outcome.submitted > 0) KvHaptic.moneyMoment();
      if (mounted) setState(() => _outcome = outcome);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          0,
          KvSpace.gutter,
          KvSpace.l,
        ),
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_sending) {
      return const Padding(
        padding: EdgeInsets.all(KvSpace.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_outcome != null || _error != null) {
      return _ResultView(
        outcome: _outcome,
        error: _error,
        onDone: () => Navigator.of(context).pop(_outcome),
      );
    }
    return _confirm(context);
  }

  Widget _confirm(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.summary;
    final amount = kasParts(s.amountSompi);
    final selfSend = widget.selfSend;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: Text(widget.title, style: theme.textTheme.titleMedium)),
        const SizedBox(height: KvSpace.l),
        // The headline is the honest COST. For a payment that is the amount
        // leaving; for a self-send message the value returns as change, so the
        // cost is the network fee — never the returning value (D-069).
        Center(
          child: Text(
            selfSend ? 'Costs you' : 'Sending',
            style: theme.textTheme.labelSmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: KvSpace.xs),
        Center(
          child: AmountText(
            selfSend ? s.feeSompi : s.amountSompi,
            role: AmountRole.screen,
          ),
        ),
        const SizedBox(height: KvSpace.l),
        // A self-send goes to our OWN address — showing that raw address reads
        // as "sending to a stranger". Drop it; the thread is the destination.
        if (!selfSend)
          _Field(
            label: 'To',
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(KvSpace.sm),
              decoration: BoxDecoration(
                color: KvColor.surfaceAlt,
                borderRadius: BorderRadius.circular(KvRadius.data),
              ),
              child: Text(
                chunkAddress(s.destination),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: KvFont.mono,
                ),
              ),
            ),
          ),
        if (widget.contextNote != null) ...[
          if (!selfSend) const SizedBox(height: KvSpace.s),
          Text(
            widget.contextNote!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: KvSpace.m),
        // The exact costs — never "≈ free" (KIP-9 storage mass can be
        // non-trivial); all 8 decimals on a signing surface (DS-2). For a
        // self-send the "Total" is replaced by the returning value, stated as
        // a return, not a cost.
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: KvSpace.m,
            vertical: KvSpace.xs,
          ),
          decoration: BoxDecoration(
            border: Border.all(color: KvColor.border),
            borderRadius: BorderRadius.circular(KvRadius.data),
          ),
          child: Column(
            children: [
              _CostRow(label: 'Network fee', sompi: s.feeSompi),
              const Divider(),
              if (selfSend)
                _CostRow(label: 'Returns to you', sompi: s.amountSompi)
              else
                _CostRow(label: 'Total', sompi: s.totalSompi),
            ],
          ),
        ),
        if (selfSend) ...[
          const SizedBox(height: KvSpace.s),
          Text(
            'Your message rides the Kaspa L1 to your contact; the value above '
            'returns to you as change, so you only pay the network fee.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textTertiary,
            ),
          ),
        ],
        if (s.txCount > 1) ...[
          const SizedBox(height: KvSpace.m),
          Text(
            'Sent as ${s.txCount} transactions (your amount exceeds one '
            "transaction's size limit).",
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textTertiary,
            ),
          ),
        ],
        const SizedBox(height: KvSpace.xl),
        _HoldToSign(
          label: selfSend
              ? 'Hold to send message'
              : 'Hold to send ${amount.integer}.${amount.fraction} KAS',
          onComplete: _commit,
        ),
        const SizedBox(height: KvSpace.s),
        Text(
          // Irreversibility, said once, plainly, at signing (§12).
          'Kaspa transactions confirm in about a second and cannot be reversed.',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: KvColor.textTertiary,
          ),
        ),
      ],
    );
  }
}

/// A labelled confirm row: small caption over the (Rust-decoded) value.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: KvColor.textSecondary,
          ),
        ),
        const SizedBox(height: KvSpace.xs),
        child,
      ],
    );
  }
}

/// One exact cost line: label left, all-8-decimals amount right (DS-2).
class _CostRow extends StatelessWidget {
  const _CostRow({required this.label, required this.sompi});

  final String label;
  final BigInt sompi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
          const Spacer(),
          AmountText(sompi, role: AmountRole.row, exact: true),
        ],
      ),
    );
  }
}

/// The post-broadcast result: the txid (copyable, for an explorer cross-check),
/// or an honest partial/failure (B6 — never a silent "it failed").
class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.outcome,
    required this.error,
    required this.onDone,
  });

  final SendOutcomeDto? outcome;
  final String? error;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = outcome;
    final failedOutright = o == null || (o.submitted == 0 && o.error != null);
    final partial = o != null && o.partial;

    final (IconData icon, Color color, String title) = failedOutright
        ? (Icons.error_outline, KvColor.error, 'Send failed')
        : partial
        ? (Icons.warning_amber, KvColor.warning, 'Partly sent')
        : (Icons.check_circle_outline, KvColor.success, 'Sent');

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: KvSpace.m),
        Center(
          child: Container(
            width: KvSpace.control + KvSpace.s,
            height: KvSpace.control + KvSpace.s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.14),
            ),
            child: Icon(icon, color: color, size: KvSpace.xl),
          ),
        ),
        const SizedBox(height: KvSpace.sm),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        if (partial) ...[
          const SizedBox(height: KvSpace.s),
          Text(
            'Broadcast ${o.submitted} of ${o.total} transactions; the rest did '
            'not send. Your activity will reflect what landed.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textSecondary,
              fontFamily: KvFont.ui,
            ),
          ),
        ],
        if (o?.finalTxid != null) ...[
          const SizedBox(height: KvSpace.l),
          Text(
            'Transaction id',
            style: theme.textTheme.labelSmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
          const SizedBox(height: KvSpace.xs),
          Container(
            padding: const EdgeInsets.all(KvSpace.sm),
            decoration: BoxDecoration(
              color: KvColor.surfaceAlt,
              borderRadius: BorderRadius.circular(KvRadius.data),
            ),
            child: SelectableText(
              o!.finalTxid!,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: KvFont.mono,
              ),
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: KvSpace.m),
          Text(
            error!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.error,
              fontFamily: KvFont.ui,
            ),
          ),
        ],
        const SizedBox(height: KvSpace.xl),
        FilledButton(onPressed: onDone, child: const Text('Done')),
      ],
    );
  }
}

/// DS-3 hold-to-sign: press and hold; a decelerate-only fill advances over
/// [KvMotion.deliberate]; only completing the hold fires [onComplete] (no
/// double-tap path to broadcast). Releasing early reverses — nothing happens.
/// The threshold lands with `mediumImpact` (§7).
class _HoldToSign extends StatefulWidget {
  const _HoldToSign({required this.label, required this.onComplete});

  final String label;
  final VoidCallback onComplete;

  @override
  State<_HoldToSign> createState() => _HoldToSignState();
}

class _HoldToSignState extends State<_HoldToSign>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: KvMotion.deliberate,
  )..addStatusListener(_onStatus);
  bool _fired = false;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_fired) {
      _fired = true;
      KvHaptic.holdThreshold();
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _down(_) {
    if (_fired) return;
    _controller.forward();
  }

  void _release([_]) {
    if (_fired) return;
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTapDown: _down,
      onTapUp: _release,
      onTapCancel: _release,
      child: Container(
        // Glow is rationed to primary actions (§3) — this is THE primary
        // action; the shadow sits outside the clip so it can breathe.
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(KvRadius.button),
          boxShadow: const [
            BoxShadow(color: KvColor.glow, blurRadius: 24, spreadRadius: 2),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(KvRadius.button),
          child: Container(
            height: KvSpace.control,
            // Dual teal (token semantics): muted = ambient base, primary = the
            // "activated" charge sweeping over it. Dark text reads on both.
            color: KvColor.primaryMuted,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Decelerate-only fill (DS-5 vault register; never overshoot).
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: KvMotion.out.transform(_controller.value),
                        child: Container(color: KvColor.primary),
                      ),
                    ),
                  ),
                ),
                // Scale the full-precision label down rather than ever clip or
                // ellipsize an amount (DS-2), incl. at large text scale.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.lock_outline,
                          size: 18,
                          color: KvColor.abyss,
                        ),
                        const SizedBox(width: KvSpace.s),
                        Text(
                          widget.label,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: KvColor.abyss,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
