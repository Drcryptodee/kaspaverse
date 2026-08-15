import 'dart:async';

import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../theme/tokens.dart';
import '../widgets/kv_loader.dart';
import 'confirm_send_sheet.dart';

/// How long a prepare may take before the wait is worth showing. Under this a
/// card would flash and vanish, which reads as a glitch rather than progress.
const Duration _showProgressAfter = Duration(milliseconds: 250);

/// How long the card waits before naming the reason. Any prepare slow enough
/// to reach here is waiting on our own change to mature — see
/// `prepare_transport_send` — but the sentence is hedged because a slow link
/// can also get here, and the wallet should not assert what it has not checked.
const Duration _explainAfter = Duration(milliseconds: 1200);

/// THE one confirm-send ceremony (V5): prepare in Rust → open the shared
/// hold-to-sign sheet over the Rust-decoded [SignableSummaryDto] (B7) →
/// return the outcome (null = dismissed without signing; the sheet's own
/// dispose already abandoned the stash).
///
/// Deliberately owns ONLY the shared shape. Prepare errors PROPAGATE — each
/// caller keeps its own surface (send screen: inline error; messaging
/// surfaces: snackbar) — and each caller runs its own refresh after the
/// sheet closes. Never auto-broadcasts: broadcast fires only inside a
/// completed hold ([ConfirmSendSheet]).
///
/// A prepare in the messages lane can now BLOCK for up to twenty-odd seconds
/// waiting for the previous send's change to mature, instead of failing the
/// way it used to. Twenty seconds of an unresponsive screen is its own bug, so
/// a slow prepare gets a card that says what is happening.
Future<SendOutcomeDto?> runConfirmSend(
  BuildContext context, {
  required Future<SignableSummaryDto> Function() prepare,
  required Future<SendOutcomeDto> Function(BigInt nonce) commit,
  required Future<void> Function() abandon,
  String? title,
  String? contextNote,
}) async {
  final pending = prepare();
  // Race the prepare against the delay so a fast one costs nothing extra.
  //
  // A CANCELLABLE timer, not `Future.any` over a `Future.delayed`: that leaves
  // the losing timer armed, which outlives the ceremony and fails any widget
  // test that tears the tree down first. Errors are swallowed HERE only to
  // settle the race — `pending` is awaited below and rethrows there, which is
  // what keeps the propagate-to-caller contract above.
  final gate = Completer<bool>();
  void settle(bool slow) {
    if (!gate.isCompleted) gate.complete(slow);
  }

  final timer = Timer(_showProgressAfter, () => settle(true));
  unawaited(pending.then((_) => settle(false), onError: (_) => settle(false)));
  final slow = await gate.future;
  timer.cancel();

  VoidCallback? dismissProgress;
  if (slow && context.mounted) dismissProgress = _showPreparing(context);

  final SignableSummaryDto summary;
  try {
    summary = await pending;
  } finally {
    dismissProgress?.call();
  }

  if (!context.mounted) {
    // The surface died between prepare and the sheet: nobody can ever commit
    // this plan — release the Rust stash instead of leaving an unsigned,
    // nonce-guarded orphan until the next prepare overwrites it (V5
    // wallet-security note, closed).
    await abandon();
    return null;
  }
  return showModalBottomSheet<SendOutcomeDto>(
    context: context,
    backgroundColor: KvColor.surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ConfirmSendSheet(
      summary: summary,
      commit: commit,
      abandon: abandon,
      title: title,
      contextNote: contextNote,
    ),
  );
}

/// Put the preparing card up and return the one call that takes it down.
///
/// **Holds the ROUTE, never a `BuildContext` captured in the builder.** The
/// builder does not run until the next frame, while `await pending` resumes on
/// a microtask — so a prepare that finishes inside that gap used to run the
/// dismiss against a still-null context, do nothing, and leave a barrier the
/// user cannot dismiss (`barrierDismissible: false`, `PopScope(canPop: false)`,
/// no cancel) sitting over the whole app until a force-quit. `route.isActive`
/// is true from the moment of push, so an early dismiss cannot be lost, and
/// `removeRoute` takes down THIS route rather than whatever is on top.
///
/// The barrier stays non-dismissible on purpose: a build is running in Rust and
/// there is exactly one `PENDING_TRANSPORT` slot, so letting the user reach the
/// surface underneath would let a second prepare overwrite the plan the first
/// one is about to show them. The wait it covers is bounded in Rust
/// (`MATURITY_WAIT`) and every RPC under it carries its own timeout.
VoidCallback _showPreparing(BuildContext context) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: KvColor.abyss.withValues(alpha: 0.72),
    builder: (_) => const PopScope(canPop: false, child: _PreparingCard()),
  );
  navigator.push(route);
  return () {
    if (route.isActive) navigator.removeRoute(route);
  };
}

/// Spinner, then — if the wait keeps going — a note that it is expected.
///
/// **Wrapped in a `Material`.** `DialogRoute.buildPage` inserts none, so a bare
/// `Container` inherits `MaterialApp`'s `_errorTextStyle` — the "you forgot a
/// Material" fallback: monospace, weight 900, under a yellow double underline.
/// Verified by printing the effective `TextSpan` style, not by inspection. Both
/// text styles now come from the theme ramp for the same reason: a raw
/// `fontSize` is not a step in the type scale.
class _PreparingCard extends StatefulWidget {
  const _PreparingCard();

  @override
  State<_PreparingCard> createState() => _PreparingCardState();
}

class _PreparingCardState extends State<_PreparingCard> {
  Timer? _timer;
  bool _explain = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_explainAfter, () {
      if (mounted) setState(() => _explain = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final reason = Padding(
      padding: const EdgeInsets.only(top: KvSpace.s),
      child: Text(
        // Says only what is KNOWN. The earlier line named the cause — "waiting
        // for your last transaction to settle" — which this surface never
        // checked and which is simply false on a first backup or a first
        // handshake, where nothing has been sent yet.
        'This can take a few seconds.',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: KvColor.textSecondary,
        ),
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: KvSpace.xl),
          padding: const EdgeInsets.all(KvSpace.l),
          decoration: BoxDecoration(
            color: KvColor.surface,
            borderRadius: BorderRadius.circular(KvRadius.card),
            border: Border.all(color: KvColor.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const KvLoader(),
              const SizedBox(height: KvSpace.m),
              Text('Preparing', style: theme.textTheme.titleMedium),
              // Held back rather than shown at once: naming a delay before
              // there is one invents a problem the user did not have. Under
              // reduced motion it simply appears (§6).
              if (reduced)
                if (_explain) reason else const SizedBox(width: double.infinity)
              else
                AnimatedSize(
                  duration: KvMotion.fast,
                  curve: KvMotion.out,
                  child: AnimatedOpacity(
                    opacity: _explain ? 1 : 0,
                    duration: KvMotion.fast,
                    curve: KvMotion.out,
                    child: _explain
                        ? reason
                        : const SizedBox(width: double.infinity),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
