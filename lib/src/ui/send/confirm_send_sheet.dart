import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../format.dart';
import '../error_text.dart';
import '../theme/tokens.dart';
import '../widgets/amount_text.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_loader.dart';

/// The anti-blind-signing confirm (consensus B7 — the heart of P1.6; ONE
/// signing surface for every send-like flow since V5). Everything here
/// renders the [SignableSummaryDto] Rust decoded from the ACTUAL transactions
/// it will sign — never the form's echo of the user's intent. That includes
/// the MODE: the self-send rendering (D-069) derives from the summary's
/// Rust-set [SignableKind], never a caller flag, and the payload facts line
/// renders the DTO's own built-tx decode. The hold-to-sign ceremony (BG-6) is
/// decelerate-only with no double-tap path to broadcast, and every amount on
/// this surface is exact to all 8 decimals (BG-5: the full truth at the
/// moment of commitment).
///
/// Dismissing before the hold completes calls [abandon] (drops the Rust
/// stash); a completed send pops with its [SendOutcomeDto].
class ConfirmSendSheet extends StatefulWidget {
  const ConfirmSendSheet({
    super.key,
    required this.summary,
    required this.commit,
    required this.abandon,
    this.title,
    this.contextNote,
  });

  final SignableSummaryDto summary;
  final Future<SendOutcomeDto> Function(BigInt nonce) commit;
  final Future<void> Function() abandon;

  /// Sheet heading override. Defaults by the summary's kind ("Confirm send",
  /// "Confirm contact request", …); thread flows rename the ceremony honestly
  /// ("Confirm challenge") without touching the B7 numbers or the
  /// hold-to-sign discipline.
  final String? title;

  /// One optional plain-English line under the destination — what this send
  /// carries beyond value (e.g. the bond-refund rule). Never a number the
  /// summary doesn't back (B7: the DTO stays the only source of figures).
  final String? contextNote;

  @override
  State<ConfirmSendSheet> createState() => _ConfirmSendSheetState();
}

/// Kind-derived ceremony heading — the one place flow modes name themselves.
String _defaultTitle(SignableKind kind) => switch (kind) {
  SignableKind.payment => 'Confirm send',
  SignableKind.bond => 'Confirm contact request',
  SignableKind.bondRefund => 'Confirm accept',
  SignableKind.selfSendFrame => 'Confirm message',
  SignableKind.stake => 'Confirm stake',
  SignableKind.bcast => 'Confirm broadcast',
  SignableKind.sweep => 'Confirm send all',
  SignableKind.consolidate => 'Confirm merge',
};

/// Inline KAS figure for sentence copy — full 8 decimals (BG-5 applies to
/// every number on a signing surface, prose included).
String _kas(BigInt sompi) {
  final parts = kasParts(sompi);
  return '${parts.integer}.${parts.fraction}';
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
      // `e.toString()` on an AppError renders "Instance of 'AppError'" — the
      // type name, printed into the body of a failed SEND (run 1, F8).
      if (mounted) setState(() => _error = displayError(e));
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
        child: Center(child: KvLoader()),
      );
    }
    if (_outcome != null || _error != null) {
      // Scrolls for the same reason the confirm branch does, and more so since
      // this wave: the result can now carry Rust's reason AND the Dart-caught
      // one on top of the txid block. Content is never clipped on a signing
      // surface — the comment below used to be true of only one branch.
      return SingleChildScrollView(
        child: _ResultView(
          outcome: _outcome,
          error: _error,
          onDone: () => Navigator.of(context).pop(_outcome),
        ),
      );
    }
    // Scrolls only when the viewport can't fit the whole ceremony (small
    // screens / large text scale): every fact stays reachable — content is
    // never clipped on a signing surface (BG-5 spirit).
    return SingleChildScrollView(child: _confirm(context));
  }

  Widget _confirm(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.summary;
    final amount = kasParts(s.amountSompi);
    // The mode is Rust's decode (SignableKind on the summary), never a
    // caller flag — the last un-Rust-vouched fact left this surface at V5.
    final selfSend = s.kind == SignableKind.selfSendFrame;
    final sweep = s.kind == SignableKind.sweep;
    final consolidate = s.kind == SignableKind.consolidate;
    // Flows whose value returns to our own wallet: the honest headline cost
    // is the fee, and our own address is not rendered as a "destination"
    // (D-069's rule, which a merge shares).
    final returnsToSelf = selfSend || consolidate;
    final title = widget.title ?? _defaultTitle(s.kind);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: Text(title, style: theme.textTheme.titleMedium)),
        const SizedBox(height: KvSpace.l),
        // The headline is the honest COST. For a payment that is the amount
        // leaving; for a self-send message the value returns as change, so the
        // cost is the network fee — never the returning value (D-069).
        Center(
          child: Text(
            returnsToSelf ? 'Costs you' : 'Sending',
            style: theme.textTheme.labelSmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: KvSpace.xs),
        Center(
          child: AmountText(
            returnsToSelf ? s.feeSompi : s.amountSompi,
            role: AmountRole.screen,
          ),
        ),
        const SizedBox(height: KvSpace.l),
        // A self-send (message or merge) goes to our OWN address — showing
        // that raw address reads as "sending to a stranger". Drop it; the
        // thread (or the wallet itself) is the destination.
        if (!returnsToSelf)
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
        // Kind-derived plain-English lines, each citing only the DTO's own
        // built-tx numbers (B7: the summary stays the single source).
        if (sweep) ...[
          const SizedBox(height: KvSpace.s),
          Text(
            'This empties your wallet: all ${s.utxoCount} spendable '
            '${s.utxoCount == 1 ? 'coin moves' : 'coins move'} to this '
            'address, and the fee comes out of the total.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
        ],
        if (consolidate) ...[
          Text(
            // A merge too big for one transaction runs in bounded passes and
            // leaves one coin PER PASS (D-170), so the promise names the number
            // it will actually leave — and says a second tap goes further,
            // because the action is idempotent.
            //
            // The switch is `resultingCoins`, Rust's own read off the built
            // chain, NEVER `txCount`: the native compound arm also chains past
            // one transaction and still ends in exactly one coin, so a
            // transaction count would state a false coin count on the commoner
            // path (ux audit, this sitting).
            s.resultingCoins > 1
                ? 'Merges ${s.utxoCount} coins into ${s.resultingCoins} at your '
                      'own address — as far as one merge goes. The value stays '
                      'yours, and merging again takes it further.'
                : 'Merges ${s.utxoCount} coins into one at your own address — '
                      'the value stays yours, so future sends need fewer coins '
                      'and cost less.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
          if (s.typicalNowFeeSompi != null &&
              s.typicalAfterFeeSompi != null) ...[
            const SizedBox(height: KvSpace.s),
            Text(
              'A typical send today costs ${_kas(s.typicalNowFeeSompi!)} KAS '
              'in fees — after this, ${_kas(s.typicalAfterFeeSompi!)} KAS.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
          ],
        ],
        if (widget.contextNote != null) ...[
          if (!returnsToSelf || consolidate) const SizedBox(height: KvSpace.s),
          Text(
            widget.contextNote!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
        ],
        // B7: the payload facts are the SHEET's rendering of the summary's
        // built-tx decode — present exactly when the flow carries a payload
        // (payment mode never sees these fields), never a caller string.
        if (s.payloadKind != null) ...[
          if (!selfSend || widget.contextNote != null)
            const SizedBox(height: KvSpace.s),
          Text(
            'Carries: ${s.payloadKind} payload, ${s.payloadLen} bytes '
            '(decoded from the built transaction).',
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: KvSpace.m),
        // The exact costs — never "≈ free" (the relay floor prices compute +
        // transient bytes; a payload is never free, and KIP-9 storage gates
        // what BUILDS); all 8 decimals on a signing surface (BG-5). For a
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
              if (returnsToSelf)
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
            // A merge splits on COIN COUNT, never on amount — the payment
            // sentence would name the wrong cause on this surface.
            consolidate
                ? 'Sent as ${s.txCount} transactions — more coins than one '
                      'transaction can hold.'
                : 'Sent as ${s.txCount} transactions (your amount exceeds one '
                      "transaction's size limit).",
            style: theme.textTheme.bodySmall?.copyWith(
              color: KvColor.textTertiary,
            ),
          ),
        ],
        const SizedBox(height: KvSpace.xl),
        _HoldToSign(
          label: switch (s.kind) {
            SignableKind.selfSendFrame => 'Hold to send message',
            SignableKind.consolidate => 'Hold to merge ${s.utxoCount} coins',
            _ => 'Hold to send ${amount.integer}.${amount.fraction} KAS',
          },
          onComplete: _commit,
        ),
        const SizedBox(height: KvSpace.s),
        Text(
          // Irreversibility, said once, plainly, at signing (BG-11). The old
          // "about a second" was optimistic by 1.3-3.8x against the measured
          // submit->accepted range; UX-4 adds the staged wait behind it.
          'Once this is signed it cannot be reversed.',
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

/// One exact cost line: label left, all-8-decimals amount right (BG-5).
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
        // Rust's own reason, then the Dart-caught one. `SendOutcomeDto.error`
        // was read as a BOOLEAN and rendered nowhere, so a vault that locked
        // between prepare and commit and a node that rejected the transaction
        // both came out as a bare "Send failed" — on the one surface where the
        // user most needs to know which (run 1, F8).
        for (final line in [outcome?.error, error])
          if (line != null && line.isNotEmpty) ...[
            const SizedBox(height: KvSpace.m),
            Text(
              line,
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

/// BG-6 hold-to-sign: press and hold; a decelerate-only fill advances over
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
    // NOT `normal`: that is Flutter's default and it scales the duration to
    // 5% (40ms) whenever the platform reports reduced animations, which would
    // turn the hold into a tap on the one control that broadcasts an
    // irreversible transaction. Friction is safety here, not decoration, so it
    // is preserved even when every other animation in the app collapses.
    animationBehavior: AnimationBehavior.preserve,
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
    return Semantics(
      // DESCRIPTIVE ONLY — no `onTap`, and that omission is the design.
      //
      // This node reported `isButton=false` with no hint, so a screen-reader
      // user met an unlabelled control that says nothing about what it needs
      // and does nothing when activated (ux-auditor + wallet-security-auditor,
      // 2026-08-24 fix wave). `button: true` plus a hint naming the gesture at
      // least makes the control state its requirement.
      //
      // What is deliberately NOT done here: wiring `SemanticsAction.tap` or
      // `longPress` to `_commit`. A semantics activation is ONE discrete
      // action, so it would collapse the 800 ms hold to an instant — the exact
      // F1 defect this same sitting fixed, wearing an accessibility badge. The
      // control therefore remains unsignable via TalkBack, which is a real and
      // recorded defect (D-178) awaiting an accessible ceremony that KEEPS the
      // friction, not a shortcut past it.
      button: true,
      hint:
          'Press and hold for ${KvMotion.deliberate.inMilliseconds} '
          'milliseconds to sign',
      child: GestureDetector(
        onTapDown: _down,
        onTapUp: _release,
        onTapCancel: _release,
        // No bloom here. BG-2: emission is never elevation, and §1.5 permits
        // exactly one bloom shape — a 6dp lamp under an 8dp blur with no
        // spread. A 24dp/spread-2 halo behind a 56dp control is elevation
        // wearing the light's clothes.
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
                // Decelerate-only fill (BG-9 vault register; never
                // overshoot). Under reduced motion the progress renders as an
                // opacity ramp over the whole button instead of a width sweep
                // (§6/§11) — the 800ms hold itself is safety friction and
                // never shortens. That second half is not free: it holds only
                // because the controller above is built with
                // `AnimationBehavior.preserve`. Guarded by 'a hold under reduced
                // animations still takes the full deliberate duration' in
                // test/send_flow_test.dart.
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      final progress = KvMotion.out.transform(
                        _controller.value,
                      );
                      if (MediaQuery.of(context).disableAnimations) {
                        return Opacity(
                          opacity: progress,
                          child: Container(color: KvColor.primary),
                        );
                      }
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: progress,
                          child: Container(color: KvColor.primary),
                        ),
                      );
                    },
                  ),
                ),
                // Scale the full-precision label down rather than ever clip or
                // ellipsize an amount (BG-5), incl. at large text scale.
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
                          // The `button` role (§2), never `labelLarge` —
                          // that slot is `sectionTitle` at 11dp, and this is
                          // the most safety-critical string in the app.
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: KvColor.abyss,
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
