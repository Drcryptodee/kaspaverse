import 'dart:async';

import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../theme/tokens.dart';
import '../widgets/kv_loader.dart';
import 'confirm_send_sheet.dart';

/// How long a prepare may take before the wait is worth showing. Under this a
/// card would flash and vanish, which reads as a glitch rather than progress.
const Duration _showProgressAfter = Duration(milliseconds: 250);

/// How long the card waits before naming the reason. Any prepare slow enough to
/// reach here is waiting on coins to reach the send's own source address — see
/// `await_spendable_at`, which every transport caller runs once — but the
/// sentence is hedged because a slow link can also get here, and the wallet
/// should not assert what it has not checked.
///
/// **Measured against the path D-150 made the common one** (device sitting,
/// 2026-08-15). This timer starts when the CARD is pushed, not when the prepare
/// starts, so the reason lands at `_showProgressAfter + _explainAfter` of
/// prepare. At the old 1200 ms that was 1450 ms — and a healthy maturity wait
/// measured **1203 ms** on glass, putting the whole prepare at roughly 1500 ms.
/// The reason therefore fired ~50 ms before the sheet replaced the card: it
/// reproduced, one level down, exactly the flash-and-vanish that
/// [_showProgressAfter] exists to prevent, and the founder saw only bare
/// spinners across a ten-send sitting. Sized above the measured normal so it
/// speaks only when the prepare is genuinely dragging.
///
/// **This moves the window, it does not close it.** A prepare that resolves
/// between roughly `_showProgressAfter + _explainAfter` and ~200 ms past it
/// still shows a half-faded line and tears it down; the tuning takes the
/// typical case out of that window rather than removing it. Closing it properly
/// means the card explaining when Rust TELLS it a maturity wait is running
/// instead of when a clock guesses — a bridge change, logged in IDEAS_BACKLOG.
///
/// The falsifier, if this is ever re-tuned: a wait that resolves normally must
/// NOT reach this beat — compare against `_showProgressAfter + _explainAfter`,
/// which is where the line actually lands, not against this constant alone.
/// **Only half of that sum is instrumented today**: `transport-send: waited …
/// ms` bounds the wait, nothing bounds the build that follows it, so the
/// ~1500 ms figure above is one measured wait plus an estimate. Instrumenting
/// the build leg is in IDEAS_BACKLOG; do that before trusting a re-tune.
const Duration _explainAfter = Duration(milliseconds: 2000);

/// How long before the card stops saying "a few seconds" and says it will end
/// by itself. Past this the first line has become false, and the barrier the
/// user cannot dismiss has been silent long enough to read as a hang.
const Duration _reassureAfter = Duration(seconds: 7);

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
  // REQUIRED, with no default on purpose. Every default that could be written
  // here is documented two doc-comments down as never correct on any shipped
  // path — this card precedes a message, a contact request, an acceptance or a
  // backup, never a plain payment — and a default that is always wrong is a
  // wrong-copy trap for whoever adds the next caller.
  required String preparingObject,
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
  if (slow && context.mounted) {
    dismissProgress = _showPreparing(context, preparingObject);
  }

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
/// one is about to show them. That defence is only as good as the bound it
/// covers, so the bound is kept to ONE `MATURITY_WAIT`: every transport caller
/// runs `await_spendable_at` once and hands the coins it waited for down to
/// `prepare_transport_send` rather than letting it wait again.
///
/// **The wait itself makes no network call**, so an unresponsive node cannot
/// stretch it: each poll reads the pinned `UtxoContext`'s in-memory mature set
/// (`get_utxos` filters `context().mature` — no RPC, no `await` in its body),
/// which leaves the deadline as the only clock. Every RPC under the BUILD that
/// follows carries its own timeout.
///
/// **No cancel, deliberately** (ux ruling, this session). Nothing is signed,
/// broadcast or at risk during the wait, so DS-3's friction-tracks-
/// irreversibility rule does not demand an exit. The proposed cancel would set
/// a flag and call `transport_abandon()` when the prepare resolved — and that
/// call is NOT nonce-guarded, so cancelling one send could clear a LATER send's
/// valid stashed plan. That trades an inconvenience for a correctness defect.
VoidCallback _showPreparing(BuildContext context, String object) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: KvColor.abyss.withValues(alpha: 0.72),
    builder: (_) =>
        PopScope(canPop: false, child: _PreparingCard(object: object)),
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
  const _PreparingCard({required this.object});

  /// What is being prepared, as the user would name it. Caller-supplied for
  /// the same reason [runConfirmSend]'s `title` is: this card never precedes a
  /// plain payment — `send_screen` builds the sheet directly behind its own
  /// `_building` state — so a hardcoded "transaction" would disagree with the
  /// "Confirm message" / "Confirm backup" sheet two beats later.
  final String object;

  @override
  State<_PreparingCard> createState() => _PreparingCardState();
}

class _PreparingCardState extends State<_PreparingCard> {
  Timer? _timer;
  Timer? _reassureTimer;
  bool _explain = false;
  bool _reassure = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_explainAfter, () {
      if (mounted) setState(() => _explain = true);
    });
    _reassureTimer = Timer(_reassureAfter, () {
      if (mounted) setState(() => _reassure = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _reassureTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // A live region: this text enters the tree only when the beat fires, on a
    // barrier with no exit, so without an announcement a screen-reader user
    // hears "loading… Preparing your transaction" and then silence through
    // both escalations — the same defect as a beat that never lands, one sense
    // over.
    final reason = Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: KvSpace.s),
        child: Text(
          // Says only what is KNOWN. The earlier line named the cause — "waiting
          // for your last transaction to settle" — which this surface never
          // checked and which is simply false on a first backup or a first
          // handshake, where nothing has been sent yet.
          //
          // The late line is the §12 half: on a barrier with no exit, the one
          // thing the user needs and cannot infer is that it ENDS. That much is
          // provable here — the Rust wait is deadline-bounded and a prepare error
          // propagates to the caller's own surface — where naming the cause still
          // is not, so it stays unnamed (L92).
          // §12: the funds-safe fact is stated because it is provably true —
          // nothing is signed or broadcast until a completed hold inside
          // `ConfirmSendSheet`, which this card is still in front of. Scoped to
          // "this" on purpose: "nothing has been sent" would be false to a user
          // whose PREVIOUS send is the very thing being waited on. And the
          // second clause says "the wait", never "it": with a transaction
          // named one clause earlier, "it stops on its own" reads as the send
          // aborting itself — the opposite of the reassurance intended.
          _reassure
              ? "Still working. This hasn't been sent yet, and the wait ends "
                    'on its own either way.'
              : 'This can take a few seconds.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: KvColor.textSecondary,
          ),
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
              // Names its object (§12) — this line is now the ENTIRE copy for
              // the whole typical wait, since the reason beat deliberately no
              // longer fires there. Matches `create_screen.dart`'s
              // "Preparing your recovery words…".
              Text(
                'Preparing your ${widget.object}',
                style: theme.textTheme.titleMedium,
              ),
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
