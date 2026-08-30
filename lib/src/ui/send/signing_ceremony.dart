import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../error_text.dart';
import '../format.dart';
import '../theme/kv_page_route.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_amount.dart';
import '../widgets/kv_cadence.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_status_chip.dart';
import '../widgets/kv_surface.dart';

/// THE signing ceremony (consensus B7, BG-6) — **one surface for every mode**:
/// paying, accepting, staking, merging, emptying, messaging.
///
/// Everything here renders the [SignableSummaryDto] Rust decoded from the
/// ACTUAL transactions it will sign — never the form's echo of what was typed.
/// That includes the MODE: every per-kind branch on this screen switches on
/// the summary's Rust-set [SignableKind], **never on which screen opened it**
/// (D-185 / `wallet-security-auditor`). Keyed off the surface, the first real
/// wager would inherit whatever the messaging lane is allowed to do; keyed off
/// the enum, it cannot.
///
/// Every amount here is exact to all eight decimals — the one place D-210's
/// trailing-zero trim does **not** apply, because a trimmed figure is a
/// different string from the one that was signed.
///
/// **It is a screen, not a sheet** (UX-4, promoting the device-proven
/// prototype). A ceremony that scrolls its own primary action out of reach is
/// not a ceremony: the hold is pinned below the scroll, so the control that
/// signs is always under the thumb whatever the text scale. Back always
/// cancels safely — leaving without a completed hold calls [abandon] and drops
/// the unsigned plan stashed in Rust.
class SigningCeremony extends StatefulWidget {
  const SigningCeremony({
    super.key,
    required this.summary,
    required this.commit,
    required this.abandon,
    this.title,
    this.contextNote,
    this.acceptanceStatus,
    this.onLeftInFlight,
  });

  final SignableSummaryDto summary;
  final Future<SendOutcomeDto> Function(BigInt nonce) commit;
  final Future<void> Function() abandon;

  /// Heading override. Defaults by the summary's kind ("Confirm send",
  /// "Confirm contact request", …); thread flows rename the ceremony honestly
  /// ("Confirm challenge") without touching the B7 numbers or the hold.
  final String? title;

  /// One optional plain-English line under the destination — what this send
  /// carries beyond value (e.g. the bond-refund rule). Never a number the
  /// summary doesn't back (B7: the DTO stays the only source of figures).
  final String? contextNote;

  /// The tracker's live answer for one txid, polled once a second while the
  /// receipt is on screen so the depth STREAMS.
  ///
  /// It is node-read (`AcceptanceTracker::status` computes the depth at read
  /// from the live sink blue score — INV-9), and it is injected so the widget
  /// tests run without the native library. **Null, or a null answer, renders
  /// nothing at all**: unwatched, pruned or tracker-unavailable are all states
  /// where the honest output is silence, never a zero.
  final Future<TxStatusDto?> Function(String txid)? acceptanceStatus;

  /// Fired when the user leaves **after the hold completed and before the
  /// outcome landed** — the overrun exit.
  ///
  /// It exists because that exit pops `null`, and `null` is the same value a
  /// dismissal-without-signing returns, which every caller reads as *nothing
  /// was sent*. On the send screen that restores a form still holding the
  /// amount and the address: the most re-send-ready state the app can present,
  /// one tap from a duplicate, immediately after telling the user to go and
  /// check whether it landed (`wallet-security-auditor`, UX-4). A caller that
  /// can take them somewhere better says so here.
  final VoidCallback? onLeftInFlight;

  @override
  State<SigningCeremony> createState() => _SigningCeremonyState();
}

/// Open the ceremony over the current route and return its outcome (`null` =
/// dismissed without signing; the ceremony's own dispose already abandoned the
/// stash).
///
/// **One entry point, so a caller cannot open the ceremony a second way.**
/// Every send-like flow in the app — the send screen, the merge row in
/// Settings, and the three messaging lanes through `runConfirmSend` — pushes
/// this and nothing else.
Future<SendOutcomeDto?> showSigningCeremony(
  BuildContext context, {
  required SignableSummaryDto summary,
  required Future<SendOutcomeDto> Function(BigInt nonce) commit,
  required Future<void> Function() abandon,
  String? title,
  String? contextNote,
  Future<TxStatusDto?> Function(String txid)? acceptanceStatus,
  VoidCallback? onLeftInFlight,
}) {
  return Navigator.of(context).push(
    KvPageRoute<SendOutcomeDto>(
      builder: (_) => SigningCeremony(
        summary: summary,
        commit: commit,
        abandon: abandon,
        title: title,
        contextNote: contextNote,
        acceptanceStatus: acceptanceStatus,
        onLeftInFlight: onLeftInFlight,
      ),
    ),
  );
}

/// Kind-derived ceremony heading — the one place flow modes name themselves.
///
/// Exhaustive on purpose: there is no `_` arm, so a ninth [SignableKind] is a
/// compile error here rather than a mode that quietly inherits "Confirm send".
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

/// The label on the control that signs. Names the action **and its object**
/// (BG-11) — never "Confirm".
///
/// Exhaustive for the same reason as [_defaultTitle], and it is the more
/// important of the two: this is the last string a user reads before an
/// irreversible transaction, and a new kind inheriting "Hold to send N KAS"
/// could describe the wrong operation entirely.
String _holdLabel(SignableSummaryDto s) {
  final amount = kasParts(s.amountSompi);
  final kas = '${amount.integer}.${amount.fraction} KAS';
  return switch (s.kind) {
    SignableKind.payment => 'Hold to send $kas',
    SignableKind.bond => 'Hold to send $kas',
    SignableKind.bondRefund => 'Hold to send $kas',
    SignableKind.selfSendFrame => 'Hold to send message',
    SignableKind.stake => 'Hold to stake $kas',
    SignableKind.bcast => 'Hold to broadcast $kas',
    SignableKind.sweep => 'Hold to send $kas',
    SignableKind.consolidate => 'Hold to merge ${s.utxoCount} coins',
  };
}

/// Inline KAS figure for sentence copy — full 8 decimals (BG-5 applies to
/// every number on a signing surface, prose included).
String _kas(BigInt sompi) {
  final parts = kasParts(sompi);
  return '${parts.integer}.${parts.fraction}';
}

class _SigningCeremonyState extends State<SigningCeremony>
    with SingleTickerProviderStateMixin {
  bool _committed = false;
  bool _sending = false;
  SendOutcomeDto? _outcome;
  String? _error;

  /// Which named stage the wait is showing. See [_StagedWait].
  int _stage = 0;
  Timer? _stageOne;
  Timer? _stageTwo;

  /// Whether the screen has held the user past the wait's expected shape and
  /// should give the exit back.
  ///
  /// The commit await is bounded by the pinned client's own request timeout,
  /// not by anything here, and a chained send is that bound **per leg** — so a
  /// sealed screen can hold someone for minutes with a dead chevron, which is
  /// the kind of dead end a user answers by force-killing the app mid-broadcast
  /// (`wallet-security-auditor`, UX-4). Nothing is lost by leaving: the
  /// transaction is already Rust's, and its result arrives in activity from the
  /// chain either way.
  bool _mayLeave = false;
  Timer? _exitTimer;

  /// The tracker's latest answer for this send's txid, or null while there is
  /// nothing to ask about and whenever the answer itself is null.
  TxStatusDto? _status;
  Timer? _depthPoll;

  /// One second, which is what makes the count STREAM rather than step. The
  /// depth is recomputed at read from the live sink blue score, so each poll
  /// is a fresh node-read rather than a cached number ticking on a clock.
  static const Duration _depthEvery = Duration(seconds: 1);

  /// Start streaming the depth once there is a txid to ask about. Every answer
  /// is rendered as it comes and a null one clears the mark — the receipt
  /// shows the chain's number or nothing, never a remembered one.
  /// True only when `finalTxid` names the **payment** transaction.
  ///
  /// `PreparedSend::commit` reassigns `final_txid` after *every* successful
  /// submit (`rust/chain/src/send.rs`), so on a partial broadcast it holds the
  /// last leg that happened to land — a compounding leg, not the payment. That
  /// leg is watched like any other, is accepted within about a second, and
  /// would print `Accepted` directly under `Total`: a chain-stamped acceptance
  /// sitting beside an amount that never went out. The verdict below would say
  /// `Partly sent`, and the stamp would have already contradicted it.
  ///
  /// The four conditions MIRROR Rust's own [`fully_broadcast`]
  /// (`rust/bridge/src/api/send.rs`), which is the D-041 change-cursor gate:
  /// the question "is this send complete enough to name a payment id" has one
  /// answer in this codebase, not two that can drift apart.
  bool get _isFullyBroadcast {
    final o = _outcome;
    return o != null &&
        !o.partial &&
        o.error == null &&
        o.total > 0 &&
        o.submitted == o.total;
  }

  void _watchDepth() {
    final probe = widget.acceptanceStatus;
    final txid = _outcome?.finalTxid;
    if (probe == null || txid == null || _depthPoll != null) return;
    // A partial send has no payment id to ask about, so it asks nothing: the
    // poll is gated at its ONE entry point rather than at the render, so there
    // is no second site to keep in step and no 1 Hz poll running against a
    // txid whose answer must never be shown.
    if (!_isFullyBroadcast) return;
    Future<void> tick() async {
      try {
        final status = await probe(txid);
        if (mounted) setState(() => _status = status);
      } catch (_) {
        // A failed read is not a depth. Leave the last honest answer alone
        // rather than blanking a number the chain did give us.
      }
    }

    unawaited(tick());
    _depthPoll = Timer.periodic(_depthEvery, (_) => tick());
  }

  /// Comfortably past the measured 1.3–3.8 s submit→accepted range, so a
  /// normal send never sees the line at all.
  static const Duration _reopenExitAfter = Duration(seconds: 6);

  /// **800 ms, a constant with no configuration surface** (BG-6).
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: KvMotion.deliberate,
    // The fall is FAST — a released hold is not a failure and should not take
    // the same 800ms to admit it (D-189/D-190). The friction is the forward
    // direction only, and `reverseDuration` cannot shorten it.
    reverseDuration: KvMotion.calm,
    // NOT the default `AnimationBehavior.normal`: Flutter scales that to 5%
    // (40 ms) whenever the platform reports reduced animations, which would
    // turn the hold into a tap on the one control that broadcasts an
    // irreversible transaction. Friction is safety here, not decoration, so it
    // is preserved even when every other animation in the app collapses.
    animationBehavior: AnimationBehavior.preserve,
  )..addStatusListener(_onHoldStatus);
  bool _fired = false;

  @override
  void dispose() {
    // Left without signing → release the stashed (unsigned) plan in Rust.
    if (!_committed) widget.abandon();
    _stageOne?.cancel();
    _stageTwo?.cancel();
    _exitTimer?.cancel();
    _depthPoll?.cancel();
    _hold.dispose();
    super.dispose();
  }

  void _onHoldStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_fired) {
      _fired = true;
      KvHaptic.holdThreshold();
      _commit();
    }
  }

  void _down(TapDownDetails _) {
    if (_fired) return;
    _hold.forward();
  }

  /// Releasing early always cancels. The ring falls back on the one easing —
  /// decelerating, no overshoot (BG-9) — because an early release is not a
  /// failure and must not feel like one.
  void _release([Object? _]) {
    if (_fired) return;
    _hold.reverse();
  }

  Future<void> _commit() async {
    setState(() {
      _committed = true;
      _sending = true;
      _error = null;
      _stage = 0;
    });
    // The named wait (D-189). It runs against the clock because the wallet has
    // no finer signal to run against — see [_StagedWait], which is where that
    // limit is written down rather than papered over.
    _stageOne = Timer(_StagedWait.toBroadcasting, () {
      if (mounted) setState(() => _stage = 1);
    });
    _stageTwo = Timer(_StagedWait.toAwaiting, () {
      if (mounted) setState(() => _stage = 2);
    });
    _exitTimer = Timer(_reopenExitAfter, () {
      if (mounted) setState(() => _mayLeave = true);
    });
    try {
      final outcome = await widget.commit(widget.summary.nonce);
      // Broadcast accepted — the §6 money moment (fires only for real
      // acceptance, full or partial; a zero-submitted failure stays silent).
      if (outcome.submitted > 0) KvHaptic.moneyMoment();
      if (mounted) {
        setState(() => _outcome = outcome);
        _watchDepth();
      }
    } catch (e) {
      // `e.toString()` on an AppError renders "Instance of 'AppError'" — the
      // type name, printed into the body of a failed SEND (run 1, F8).
      if (mounted) setState(() => _error = displayError(e));
    } finally {
      _stageOne?.cancel();
      _stageTwo?.cancel();
      _exitTimer?.cancel();
      if (mounted) setState(() => _sending = false);
    }
  }

  bool get _settled => _outcome != null || _error != null;

  /// When the chain accepted this send, or null while there is no acceptance
  /// to stamp. Never the device's clock.
  DateTime? get _acceptedAt {
    final ms = _status?.acceptedUnixMs;
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms.toInt());
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    return PopScope(
      // Back always cancels SAFELY (BG-6) — and while the broadcast is in
      // flight there is nothing left to cancel, so the exit closes instead of
      // dropping the user out of a money operation whose result has not landed
      // yet. The same reasoning as the preparing card's non-dismissible
      // barrier, one beat later: nothing is at risk before the hold completes,
      // and after it the screen owes the user its answer.
      canPop: !_sending || _mayLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _sending) widget.onLeftInFlight?.call();
      },
      child: Scaffold(
        backgroundColor: KvColor.abyss,
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: KvSpace.statusBarReserve),
              KvRail(
                // **Once it is settled the rail says what HAPPENED**, not what
                // the screen was for. Leaving it at *"Confirm send"* over a
                // completed send is the whole screen still reading as a
                // confirm form with a note stuck to the bottom — founder, on
                // glass, 2026-08-30.
                title: _settled
                    ? _verdictFor(_outcome, _error).head
                    : (widget.title ?? _defaultTitle(s.kind)),
                // Null while the broadcast is in flight: nothing is left to
                // cancel, and the chevron reads as closed rather than looking
                // live and ignoring the tap (BG-12).
                // No `onLeftInFlight` call here — `PopScope` above already
                // makes it, for BOTH exits. `Navigator.pop` is not a silent
                // exit: it reaches `onPopInvokedWithResult` synchronously in
                // the same call, so calling it here as well fired the callback
                // TWICE on the rail and once on the system back — two exits
                // disagreeing about how many times an event happened
                // (`wallet-security-auditor`, UX-4, measured).
                //
                // The collapse is provably complete rather than probably:
                // `onBack` is non-null exactly when `!(_sending && !_mayLeave)`,
                // which is the same expression as `canPop`, so whenever this
                // target is tappable the pop is permitted and the `PopScope`
                // arm always runs.
                onBack: _sending && !_mayLeave
                    ? null
                    : () => Navigator.of(context).pop(_outcome),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: KvSpace.gutter,
                  ),
                  children: [
                    const SizedBox(height: KvSpace.m),
                    ..._truthRows(context),
                    if (_sending) ...[
                      const SizedBox(height: KvSpace.l),
                      _StagedWait(stage: _stage, mayLeave: _mayLeave),
                    ],
                    // **The verdict sits BELOW the figures, not above them**
                    // (founder, on glass 2026-08-30 — he tried it at the top
                    // and preferred it where it was). What the rebuild keeps
                    // is everything else: the rail speaks the outcome, the
                    // verb block is past tense, the caution is gone, and the
                    // reference number closes the receipt.
                    if (_settled) ...[
                      const SizedBox(height: KvSpace.l),
                      _OutcomeHead(outcome: _outcome, error: _error),
                    ],
                    if (_settled && _outcome?.finalTxid != null)
                      _Receipt(txid: _outcome!.finalTxid!),
                    const SizedBox(height: KvSpace.l),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  KvSpace.gutter,
                  0,
                  KvSpace.gutter,
                  KvSpace.m,
                ),
                child: _settled
                    ? KvAction(
                        label: 'Done',
                        primary: true,
                        onTap: () => Navigator.of(context).pop(_outcome),
                      )
                    : _HoldToSign(
                        // While the broadcast is in flight the control is
                        // inert, so it stops asking for a hold: a lit control
                        // commanding an action that no longer applies is the
                        // same defect as a disabled one that will not say why
                        // (BG-12). "Sending" is the one word true of every
                        // stage the wait can be on.
                        label: _sending ? 'Sending…' : _holdLabel(s),
                        progress: _hold,
                        enabled: !_sending,
                        onDown: _down,
                        onUp: _release,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The restatement: what the wallet BUILT, in the order a reader checks it.
  List<Widget> _truthRows(BuildContext context) {
    final s = widget.summary;
    // The mode is Rust's decode (SignableKind on the summary), never a caller
    // flag — the last un-Rust-vouched fact left this surface at V5.
    final selfSend = s.kind == SignableKind.selfSendFrame;
    final sweep = s.kind == SignableKind.sweep;
    final consolidate = s.kind == SignableKind.consolidate;
    // Flows whose value returns to our own wallet: the honest headline cost is
    // the fee, and our own address is not rendered as a "destination"
    // (D-069's rule, which a merge shares).
    final returnsToSelf = selfSend || consolidate;

    return [
      // The headline is the honest COST. For a payment that is the amount
      // leaving; for a self-send message the value returns as change, so the
      // cost is the network fee — never the returning value (D-069).
      //
      // **Past tense once something actually landed**, so the receipt does not
      // still say *"Sending"* over a completed send (founder, on glass,
      // 2026-08-30). It flips on `landed` — something was submitted — and NOT
      // on "settled": a `Not confirmed` outcome keeps the present tense,
      // because the wallet does not know whether it went and a past-tense
      // label there would claim it did not. Same reasoning that deleted the
      // funds-safe sentence.
      KvRuledLabel(
        _verdictFor(_outcome, _error).landed
            ? (returnsToSelf ? 'Cost you' : 'Sent')
            : (returnsToSelf ? 'Costs you' : 'Sending'),
      ),
      const SizedBox(height: KvSpace.xs),
      KvAmount(
        returnsToSelf ? s.feeSompi : s.amountSompi,
        role: KvAmountRole.screen,
      ),

      // A self-send (message or merge) goes to our OWN address — showing that
      // raw address reads as "sending to a stranger". Drop it; the thread (or
      // the wallet itself) is the destination.
      if (!returnsToSelf) ...[
        const SizedBox(height: KvSpace.l),
        const KvRuledLabel('To'),
        const SizedBox(height: KvSpace.xs),
        // Groups of four with the first and last weighted: an address-poisoning
        // attack buys a prefix and a suffix that LOOK right, so the eye is put
        // exactly where the attack has to succeed (BG-15).
        KvAddress(s.destination, form: KvAddressForm.chunked),
      ],

      // Kind-derived plain-English lines, each citing only the DTO's own
      // built-tx numbers (B7: the summary stays the single source).
      if (sweep) ...[
        const SizedBox(height: KvSpace.sm),
        _Note(
          'This empties your wallet: all ${s.utxoCount} spendable '
          '${s.utxoCount == 1 ? 'coin moves' : 'coins move'} to this address, '
          'and the fee comes out of the total.',
        ),
      ],
      if (consolidate) ...[
        const SizedBox(height: KvSpace.sm),
        _Note(
          // A merge too big for one transaction runs in bounded passes and
          // leaves one coin PER PASS (D-170), so the promise names the number
          // it will actually leave — and says a second tap goes further,
          // because the action is idempotent.
          //
          // The switch is `resultingCoins`, Rust's own read off the built
          // chain, NEVER `txCount`: the native compound arm also chains past
          // one transaction and still ends in exactly one coin, so a
          // transaction count would state a false coin count on the commoner
          // path (ux audit, 2026-08-23).
          s.resultingCoins > 1
              ? 'Merges ${s.utxoCount} coins into ${s.resultingCoins} at your '
                    'own address — as far as one merge goes. The value stays '
                    'yours, and merging again takes it further.'
              : 'Merges ${s.utxoCount} coins into one at your own address — '
                    'the value stays yours, so future sends need fewer coins '
                    'and cost less.',
        ),
        if (s.typicalNowFeeSompi != null && s.typicalAfterFeeSompi != null) ...[
          const SizedBox(height: KvSpace.s),
          _Note(
            'A typical send today costs ${_kas(s.typicalNowFeeSompi!)} KAS in '
            'fees — after this, ${_kas(s.typicalAfterFeeSompi!)} KAS.',
          ),
        ],
      ],
      if (widget.contextNote != null) ...[
        const SizedBox(height: KvSpace.sm),
        _Note(widget.contextNote!),
      ],
      // B7: the payload facts are the SCREEN's rendering of the summary's
      // built-tx decode — present exactly when the flow carries a payload
      // (payment mode never sees these fields), never a caller string.
      if (s.payloadKind != null) ...[
        const SizedBox(height: KvSpace.sm),
        _Note(
          'Carries: ${s.payloadKind} payload, ${s.payloadLen} bytes '
          '(decoded from the built transaction).',
        ),
      ],

      const SizedBox(height: KvSpace.l),
      // The exact costs — never "≈ free" (the relay floor prices compute +
      // transient bytes; a payload is never free, and KIP-9 storage gates what
      // BUILDS). For a self-send the "Total" is replaced by the returning
      // value, stated as a return, not a cost.
      const _FactRule(),
      _FactRow(label: 'Network fee', sompi: s.feeSompi),
      const _FactRule(),
      if (returnsToSelf)
        _FactRow(label: 'Returns to you', sompi: s.amountSompi)
      else
        _FactRow(label: 'Total', sompi: s.totalSompi),
      const _FactRule(),

      // **The accepting BLOCK's own timestamp** — `TxStatusDto.acceptedUnixMs`,
      // carried across the FFI for exactly this line. Neither `DateTime.now()`
      // nor the wallet's fold time will do: both are this device's observation
      // of an acceptance rather than the acceptance, wrong by the poll latency
      // on a live link and by hours on a catch-up replay (`ffi-leak-auditor`
      // caught the second of those in this field's first cut).
      //
      // It appears only once there is an acceptance to stamp; a send still
      // waiting has no time to show and shows none.
      if (_acceptedAt != null) ...[
        _StampRow(label: 'Accepted', at: _acceptedAt!),
        const _FactRule(),
      ],

      if (selfSend) ...[
        const SizedBox(height: KvSpace.sm),
        _Note(
          'Your message rides the Kaspa L1 to your contact; the value above '
          'returns to you as change, so you only pay the network fee.',
        ),
      ],
      if (s.txCount > 1) ...[
        const SizedBox(height: KvSpace.sm),
        _Note(
          // A merge splits on COIN COUNT, never on amount — the payment
          // sentence would name the wrong cause on this surface.
          consolidate
              ? 'Sent as ${s.txCount} transactions — more coins than one '
                    'transaction can hold.'
              : 'Sent as ${s.txCount} transactions (your amount exceeds one '
                    "transaction's size limit).",
        ),
      ],

      // Irreversibility, said once, plainly, **before** signing (BG-11).
      //
      // **AMBER, not red** (founder call, on glass 2026-08-30 — D-222). BG-7
      // gives red to money *leaving or at risk*; at the moment this line is
      // read nothing has been signed and nothing is at risk, so it is a
      // caution about what will become true — *"needs checking"*, which is
      // amber's own definition. Red here spent the strongest hue in the system
      // on a warning, one line above a control the user has not pressed.
      //
      // **And it disappears the moment the send settles**, because by then it
      // is both redundant — the verdict plate says what happened — and wrong
      // in tense: *"Once this is signed"* over an already-signed transaction.
      if (!_settled) ...[
        const SizedBox(height: KvSpace.l),
        const KvStatusChip(
          tone: KvLampTone.warn,
          words: 'Once this is signed it cannot be reversed.',
          maxLines: null,
        ),
      ],
    ];
  }
}

/// A quiet explanatory line. Sentences WRAP; only numbers refuse to (L131),
/// and every string on this screen is a sentence.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 13,
      height: 19 / 13,
      color: KvColor.inkDim,
    ),
  );
}

/// The hairline between two facts. A ruled row is what turns a pair of numbers
/// into a ledger you read down.
class _FactRule extends StatelessWidget {
  const _FactRule();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: KvColor.hairline);
}

/// One exact cost line: label left, all-8-decimals amount right (BG-5).
///
/// **A `Wrap`, not a `Row` of two equal `Flexible`s.** Equal flex hands the
/// figure exactly half the width whatever the label needs, so the fee and the
/// total on the signing surface fell under the 11dp floor from about
/// 10,000 KAS upward at 320dp/1.3× — 6.70dp at whole supply — while the row
/// still had space the label was not using. Wrapped, each child may take the
/// whole width and the amount drops to its own run when it needs to: the
/// widest figure the network can express then renders at 17.1dp.
///
/// It is the cure `_AvailableLine` took one screen over, for the same reason:
/// **the cure is width, not scale** (`ux-auditor`, UX-4).
class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.sompi});

  final String label;
  final BigInt sompi;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.sm),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: KvSpace.m,
        runSpacing: KvSpace.xs,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkDim,
            ),
          ),
          // No `FittedBox`. `KvAmount` fits its own figure given a bounded
          // width and keeps the unit OUT of that fit so its 11dp floor
          // survives — an outer one scales the whole thing again and puts the
          // unit back under the floor (measured at 6.01dp for a whole-supply
          // fee row). Fitting a widget that already fits itself is how a floor
          // gets multiplied away.
          KvAmount(
            sompi,
            role: KvAmountRole.row,
            fractionDigits: 8,
            showUnit: true,
            // **A fact row states a COST, and a cost is read for its digits**
            // (BG-23, founder's call from the rendered comparison — D-230). The
            // role default cannot decide this: `row` is also the home ledger,
            // where a figure is a holding and the magnitude is the point. Here
            // the figure is a fee, always below 1, so the magnitude is `0` in
            // every case this surface will ever show and the weight belongs on
            // the digits that are the fee. `Total` takes the same flag and is
            // unaffected: above 1 every emphasis rule agrees, which is what
            // stops a fee out-shouting the total it is part of.
            emphasis: KvAmountEmphasis.significant,
          ),
        ],
      ),
    );
  }
}

/// One dated fact: label left, wall-clock stamp right, on the same ruled grid
/// the money rows use.
class _StampRow extends StatelessWidget {
  const _StampRow({required this.label, required this.at});

  final String label;
  final DateTime at;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: KvSpace.sm),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: KvSpace.m,
      runSpacing: KvSpace.xs,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            height: 19 / 13,
            color: KvColor.inkDim,
          ),
        ),
        Text(
          formatStamp(at),
          style: const TextStyle(
            fontFamily: KvFont.mono,
            fontSize: 13,
            height: 20 / 13,
            color: KvColor.ink,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

/// The named post-signature wait (D-189): signing → broadcasting → waiting for
/// acceptance. A single spinner for two and a half seconds tells the user
/// nothing about which half of the operation could still fail.
///
/// **No step is ever marked complete, and that is the design — not an omission.**
/// `send_commit` is ONE await across the FFI: it signs, broadcasts and collects
/// the node's answer inside a single call, and the only two events Dart can
/// actually observe are *the call started* and *the call returned*. The stage
/// the clock is showing is therefore **where the wallet has got to in the
/// expected order**, which is true, and never **what has finished**, which
/// would not be. The case that settles it is the refusal: paint a green tick
/// beside *Broadcast to the network* and the outcome plate two beats later
/// says *"Your funds are safe — nothing left your wallet"*, and the screen
/// contradicts itself on the one surface that must never be wrong.
///
/// The copy is present-continuous for the same reason. Each label states what
/// the wallet is doing, and the cadence marks which one is now.
///
/// The last stage is open-ended: it holds until the real outcome lands,
/// however long the node takes. D-189's third figure (800 ms) was the nominal
/// length of that stage, and the real signal supersedes it — a wait that ran
/// out of stages would be back to telling the user nothing.
///
/// Splitting these into observed facts means a progress signal crossing the
/// FFI from `commit_and_advance`'s per-txid submit hook, which is a bridge
/// surface change (T3) and is recorded in the phase register, not faked here.
class _StagedWait extends StatelessWidget {
  const _StagedWait({required this.stage, this.mayLeave = false});

  /// 0 signing · 1 broadcasting · 2 waiting for acceptance.
  final int stage;

  /// The wait has outlived its expected shape and the exit is open again.
  final bool mayLeave;

  /// The measured submit→accepted range is 1.3–3.8 s; these are D-189's beats
  /// inside it, as offsets from the completed hold.
  static const Duration toBroadcasting = Duration(milliseconds: 700);
  static const Duration toAwaiting = Duration(milliseconds: 1600);

  static const List<String> steps = [
    'Signing on this device',
    'Broadcasting to the network',
    'Waiting for a node to accept it',
  ];

  /// **The disclosure that makes the emphasis honest.** The highlighted row is
  /// where the send is EXPECTED to be by the clock, not somewhere the wallet
  /// has watched it arrive — one await covers all three — and a failure at the
  /// first step still lets the second light up. Saying so once turns the list
  /// from three claims into an ordered plan with a position marker on it
  /// (`consensus-auditor`, UX-4).
  static const String framing =
      'These run in order, and the wallet hears back only at the end.';

  /// Shown once the wait has outlived its expected shape, with the exit open
  /// again. It says the two things a held user needs and cannot infer: that
  /// they may leave, and that leaving costs them nothing.
  ///
  /// It claims nothing about where the transaction has GOT to — *"already out
  /// of the wallet"* is overwhelmingly likely at six seconds and not
  /// observable from here, which is the reasoning that deleted the funds-safe
  /// sentence one plate over. What it says instead is provable: leaving
  /// cancels nothing, because nothing here can cancel a commit that is already
  /// running in Rust.
  static const String overrun =
      'Taking longer than usual. You can leave — leaving cancels nothing, and '
      'the result lands in your activity either way.';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: KvSpace.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      steps[i],
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 13,
                        height: 19 / 13,
                        // Weight and tone carry "now", and nothing carries
                        // "done" — a passed step and a coming step read alike
                        // because the wallet knows the same amount about both.
                        fontWeight: i == stage
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: i == stage ? KvColor.ink : KvColor.inkMeta,
                      ),
                    ),
                  ),
                  if (i == stage) ...[
                    const SizedBox(width: KvSpace.s),
                    const KvCadence(running: true),
                  ],
                ],
              ),
            ),
          const SizedBox(height: KvSpace.xs),
          Text(
            mayLeave ? overrun : framing,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 12,
              height: 17 / 12,
              color: KvColor.inkMeta,
            ),
          ),
        ],
      ),
    );
  }
}

/// The outcome, in the three beats §7 requires: **what happened → what it
/// means for the funds → what to do.**
///
/// **This surface cannot say *"your funds are safe"*, and the reason is worth
/// keeping.** §7 licenses the sentence only where it is provably true. It
/// looked provable when `submitted == 0`, and it is not: `PreparedSend::commit`
/// signs first and then awaits `try_submit`, and **any** error on that await
/// returns `submitted: 0` — including a request timeout and a socket dropped
/// after the bytes went out. A node can have accepted and relayed the
/// transaction while the acknowledgement never came back. Telling that user
/// their funds are safe, with the balance snapping back to corroborate it, is
/// how they send it a second time (`wallet-security-auditor`, UX-4).
///
/// So the copy names the OUTCOME, `o.error` names the cause, and the third
/// beat is the action that actually protects them: look in activity before
/// sending again. **Making the sentence sayable again is a Rust change** — a
/// discriminator on `SendOutcomeDto` separating *refused before any submit was
/// attempted* from *submit attempted, answer unknown* — recorded in the phase
/// register, not inferred here.
///
/// A thrown call gets the same treatment for the same reason: an exception
/// says the call did not return a result, not how far it got, and this is not
/// a surface for a comforting inference.
/// What happened, as one value — so the RAIL, the labels and the plate all
/// read from the same verdict instead of each deciding for itself.
typedef _Verdict = ({KvLampTone tone, String head, String body, bool landed});

/// The verdict, derived from Rust's outcome alone.
_Verdict _verdictFor(SendOutcomeDto? outcome, String? error) {
  final o = outcome;
  final partial = o != null && o.partial;
  final refused = o != null && o.submitted == 0;
  final threw = o == null;

  final (KvLampTone tone, String head, String body) = switch ((
    threw,
    refused,
    partial,
  )) {
    // Same headline as the arm below, for the same reason: *"the send did
    // not complete"* is *"it did not go through"* in another tense, and the
    // third beat two lines later says *"if it did land"* — the copy would
    // contradict itself. On the Rust side a throw does prove nothing left
    // (`send_commit` returns `Err` only from `take_stashed`, before any
    // signing), but that is one caller's guarantee and not this widget's,
    // and the two arms stay distinguishable in the BODY where the claim is
    // hedged (`wallet-security-auditor`, UX-4).
    (true, _, _) => (
      KvLampTone.warn,
      'Not confirmed',
      'The wallet could not finish the send. Check your activity before '
          'sending again — if it did land, it will appear there.',
    ),
    // **`submitted == 0` is the ABSENCE of an answer, not a failure**, and
    // the headline may not upgrade it into one. `chain::send` returns it for
    // a local `try_sign` failure — before any node is contacted — and
    // equally for a `try_submit` error, which covers a request timeout and a
    // socket dropped after the bytes went out; a node can have accepted and
    // relayed the transaction while the acknowledgement never came back.
    // *"It did not go through"* invites the re-send that becomes a double
    // spend just as surely as the funds-safe sentence this sitting deleted
    // (`ux-auditor` / `wallet-security-auditor`, UX-4). The headline names
    // what is known — nothing came back — `o.error` names the cause, and the
    // third beat is the check that actually protects them.
    (_, true, _) => (
      KvLampTone.warn,
      'Not confirmed',
      'The wallet never got an answer about this send. Check your activity '
          'before sending again — if it did land, it will appear there.',
    ),
    (_, _, true) => (
      KvLampTone.risk,
      'Partly sent',
      'Broadcast ${o!.submitted} of ${o.total} transactions; the rest did '
          'not send. Your activity will reflect what landed.',
    ),
    _ => (
      KvLampTone.ok,
      'Sent',
      // **No waiting language.** It read *"settles over the next few
      // minutes"*, which is slower than Kaspa is and slower than it feels:
      // the network accepts in about a second and the hundred-confirmation
      // safety mark lands in roughly ten. Telling a user to expect minutes on
      // a chain built for seconds is a false impression assembled out of true
      // words (founder, 2026-08-30).
      'The network accepted it.',
    ),
  };
  // `landed` is the one bit the rest of the screen may act on: something was
  // submitted. It is NOT "it succeeded" — a partial landed too — and it is
  // never inferred from the absence of an error.
  return (tone: tone, head: head, body: body, landed: (o?.submitted ?? 0) > 0);
}

/// The verdict — what happened, in the three beats §7 requires, under the
/// figures it concludes.
class _OutcomeHead extends StatelessWidget {
  const _OutcomeHead({required this.outcome, required this.error});

  final SendOutcomeDto? outcome;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final o = outcome;
    final v = _verdictFor(outcome, error);
    final tone = v.tone;
    final head = v.head;
    final body = v.body;

    return KvSurface(
      width: double.infinity,
      padding: const EdgeInsets.all(KvSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // **A tick for the good outcome, a lamp for the exceptions.**
              // Green means confirmed (BG-7), so a green lamp on `Sent` while
              // the chain had confirmed nothing was an overclaim; a tick says
              // *this step completed* and claims nothing about depth. The
              // exceptions keep the lamp, because only the exception is marked
              // (founder, on glass 2026-08-30).
              if (tone == KvLampTone.ok)
                const KvGlyphIcon(KvMark.check, size: 18, tone: KvColor.ok)
              else
                KvLamp(tone),
              const SizedBox(width: KvSpace.s),
              Expanded(
                child: Text(
                  head,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 17,
                    height: 22 / 17,
                    fontWeight: FontWeight.w600,
                    color: KvColor.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: KvSpace.s),
          _Note(body),
          // Rust's own reason, then the Dart-caught one. `SendOutcomeDto.error`
          // was once read as a BOOLEAN and rendered nowhere, so a vault that
          // locked between prepare and commit and a node that rejected the
          // transaction both came out as a bare "Send failed" — on the one
          // surface where the user most needs to know which (run 1, F8).
          for (final line in [o?.error, error])
            if (line != null && line.isNotEmpty) ...[
              const SizedBox(height: KvSpace.sm),
              Text(
                line,
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 19 / 13,
                  color: KvColor.inkDim,
                ),
              ),
            ],
          // **The explorer exit's card — placement now, destination in UX-5.**
          //
          // It is a control that does nothing, which BG-12 forbids outright.
          // The founder allowed the exception in terms — *"even if its a
          // placeholder that is breaking a law. i alllow it"* — so it is a law
          // knowingly suspended and ledgered (D-223), not one quietly bent.
          // **UX-5 is the trigger**: that sub-phase owns `ExplorerConfig`'s
          // two URL builders and the disclosure of what the exit hands over.
          if (v.landed) ...[
            const SizedBox(height: KvSpace.m),
            const _ExplorerCard(),
          ],
        ],
      ),
    );
  }
}

/// The explorer exit, drawn where it will live and not yet wired.
///
/// **It says what it is.** A card that looked live and did nothing when tapped
/// would teach the user that controls on this screen are unreliable, on the
/// one surface where that lesson is most expensive — so the placeholder wears
/// its state instead of hiding it, which is the least the suspended law can
/// ask for.
class _ExplorerCard extends StatelessWidget {
  const _ExplorerCard();

  @override
  Widget build(BuildContext context) => KvSurface(
    tone: KvSurfaceTone.chip,
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      horizontal: KvSpace.m,
      vertical: KvSpace.sm,
    ),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'View in explorer',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkMeta,
            ),
          ),
        ),
        Text(
          'coming next',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 11,
            height: 15 / 11,
            fontWeight: FontWeight.w500,
            color: KvColor.inkMetaLow,
            letterSpacing: 0.4,
          ),
        ),
      ],
    ),
  );
}

/// The receipt's reference number, at the FOOT of the receipt where a
/// reference number goes — not stacked on top of the amount it refers to.
class _Receipt extends StatelessWidget {
  const _Receipt({required this.txid});

  final String txid;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: KvSpace.l),
      const KvRuledLabel('Transaction id'),
      const SizedBox(height: KvSpace.xs),
      // **Tap to copy** (founder, 2026-08-30). A `SelectableText` made the
      // whole 64 characters reachable only through a long-press-and-drag,
      // which is the wrong gesture for the one string on this screen a user
      // wants to take somewhere else. The tap copies ALL of it — a truncated
      // txid is as useless as a truncated address — and says so, because a
      // copy with no acknowledgement leaves the user tapping twice.
      Semantics(
        button: true,
        label: 'Copy the transaction id',
        child: InkWell(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: txid));
            KvHaptic.selection();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Transaction id copied'),
                  duration: KvMotion.toast,
                ),
              );
            }
          },
          borderRadius: BorderRadius.circular(KvRadius.plate),
          child: KvSurface(
            tone: KvSurfaceTone.well,
            width: double.infinity,
            padding: const EdgeInsets.all(KvSpace.sm),
            child: Text(
              txid,
              style: const TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 13,
                height: 20 / 13,
                color: KvColor.ink,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// BG-6 hold-to-sign: press and hold; the ring fills over [KvMotion.deliberate]
/// on the one decelerating easing; **only completing the hold signs**, and
/// there is no tap path to broadcast. Releasing early reverses — nothing
/// happens. The threshold lands with `mediumImpact` (§6).
class _HoldToSign extends StatelessWidget {
  const _HoldToSign({
    required this.label,
    required this.progress,
    required this.enabled,
    required this.onDown,
    required this.onUp,
  });

  final String label;
  final Animation<double> progress;
  final bool enabled;
  final void Function(TapDownDetails) onDown;
  final void Function([Object?]) onUp;

  /// The ring, inset one grid step inside the control on each side.
  static const double _ringSize = KvSpace.control - KvSpace.s * 2;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // DESCRIPTIVE ONLY — no `onTap`, and that omission is the design.
      //
      // This node once reported `isButton=false` with no hint, so a
      // screen-reader user met an unlabelled control that says nothing about
      // what it needs and does nothing when activated (ux-auditor +
      // wallet-security-auditor, 2026-08-24 fix wave). `button: true` plus a
      // hint naming the gesture at least makes the control state its
      // requirement.
      //
      // What is deliberately NOT done here: wiring `SemanticsAction.tap` or
      // `longPress` to the commit. A semantics activation is ONE discrete
      // action, so it would collapse the 800 ms hold to an instant — the exact
      // F1 defect that same sitting fixed, wearing an accessibility badge. The
      // control therefore remains unsignable via TalkBack, which is a real and
      // recorded defect (D-178) awaiting an accessible ceremony that KEEPS the
      // friction, not a shortcut past it.
      button: true,
      hint:
          'Press and hold for ${KvMotion.deliberate.inMilliseconds} '
          'milliseconds to sign',
      child: GestureDetector(
        onTapDown: enabled ? onDown : null,
        onTapUp: enabled ? onUp : null,
        onTapCancel: enabled ? () => onUp() : null,
        child: AnimatedBuilder(
          animation: progress,
          builder: (context, _) {
            // **LINEAR IN BOTH DIRECTIONS** — the gauge is a reading, and
            // BG-22 exempts a reading from BG-9's curve (D-229).
            //
            // Forward, the reasoning is old: on `Cubic(0.2, 0, 0, 1)` the ring
            // reads 61% closed at 200ms and 93% at 480ms, so the last 320ms of
            // safety friction — 40% of it — renders as the final 7% of the arc,
            // indistinguishable from done.
            //
            // **The fall used to take the curve**, on the argument that it is
            // motion rather than a reading. That argument is wrong and
            // `ux-auditor` found why: the controller does not reset on release,
            // so a re-press RESUMES from wherever the fall reached. The value
            // is live the whole way down, the arc is still reporting how much
            // hold is banked, and the eased version overstated it by 1.76x at
            // the midpoint — then dropped 38 points in one frame the instant a
            // thumb came back. A gauge that is resumable is a reading in both
            // directions.
            //
            // The forgiveness an early release needs lives in
            // `reverseDuration` (240ms against the 800ms climb), which is
            // untouched: the fall is still fast, it is simply honest while it
            // falls.
            final t = progress.value;
            return Container(
              // The §3 control height, and the same one `KvAction` takes — so
              // the footer does not change size when the ceremony settles and
              // the hold is replaced by *Done*. A MINIMUM rather than a fixed
              // height, because the label below is allowed a second line at
              // the floor geometry and a fixed box would clip it.
              constraints: const BoxConstraints(minHeight: KvSpace.control),
              decoration: BoxDecoration(
                // No teal fill. §1.5 permits exactly three emitting things,
                // and on this screen the emission is spent on the ring — the
                // one that is literally the sign ring BG-2 names. A filled
                // teal pill behind it would be a second.
                color: KvColor.control,
                borderRadius: BorderRadius.circular(KvRadius.control),
                border: Border.all(
                  color: t > 0 ? KvColor.primaryMuted : KvColor.edgeHi,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    // DERIVED from the control it sits in, not chosen: one
                    // step of the grid inset on each side. A number picked by
                    // eye is a number nobody can re-check (L121).
                    width: _ringSize,
                    height: _ringSize,
                    child: CustomPaint(painter: _RingPainter(t)),
                  ),
                  const SizedBox(width: KvSpace.sm),
                  // **It WRAPS; it does not shrink.** The label is a sentence
                  // carrying an amount, and BG-14 forbids only the NUMBER from
                  // reflowing — the wrap falls at a space, so the figure and
                  // its unit stay together on one line whatever happens.
                  // Fitted instead, a whole-supply amount put the last string
                  // a user reads before an irreversible transaction at 9.6dp
                  // against an 11dp law (`ux-auditor`, UX-4). It never
                  // ellipsizes and never clips: the control grows instead.
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 15,
                          height: 20 / 15,
                          fontWeight: FontWeight.w600,
                          color: enabled ? KvColor.ink : KvColor.inkMeta,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: KvSpace.sm),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The sign ring: a track, the arrow of the thing this control does, and the
/// filling arc.
///
/// **The arc sweeps under reduced animations too, and that is BG-9's
/// carve-out** (D-229). BG-9 and §3 both read *"reduced motion collapses
/// everything to opacity, **except the hold**"*, and this painter used to
/// collapse it anyway: it drew a COMPLETE circle for the whole 800 ms with only
/// its opacity carrying `t`. At 100 ms of the hold the gauge read *closed* in
/// the strongest channel it has — **BG-22's Lie Factor of 8, rising without
/// bound as t approaches 0** — on the control that broadcasts an irreversible
/// transaction, for exactly the users least able to compensate for it.
///
/// The exception had been half-discharged: D-177 fixed the *duration* half
/// (`AnimationBehavior.preserve`, so 800 ms never becomes 40 ms) and nobody
/// went back for the *extent* half. Both halves now hold.
///
/// **And a filling arc is not what reduced motion is for.** It translates
/// nothing and parallaxes nothing; it is the direct reading of a control the
/// user's own thumb is holding down. The opacity ramp it replaced was itself
/// motion — a fade — so the old branch traded a readable channel for an
/// unreadable one and bought nothing. There is now one rendering, which is also
/// why BG-19 gets no second encoding to complain about.
class _RingPainter extends CustomPainter {
  const _RingPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 3;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = KvColor.edgeHi,
    );

    // The arrow of the thing this control does, sitting inside the ring it
    // fills. Teal, because the sign ring is one of exactly three things in the
    // app that emit (BG-2) — and this is that same emission, not a second one.
    // Smaller than the ring it sits in: the ring is the mechanism, the arrow
    // is only its label.
    final k = (size.width * 0.56) / KvGlyph.grid;
    canvas.save();
    canvas.translate(size.width * 0.22, size.height * 0.22);
    final arrow = Paint()
      ..color = KvColor.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = KvGlyph.stroke * k
      ..strokeCap = KvGlyph.cap
      ..strokeJoin = StrokeJoin.miter;
    canvas.drawPath(
      Path()
        ..moveTo(12 * k, 17 * k)
        ..lineTo(12 * k, 7 * k)
        ..moveTo(8 * k, 11 * k)
        ..lineTo(12 * k, 7 * k)
        ..lineTo(16 * k, 11 * k),
      arrow,
    );
    canvas.restore();

    if (t <= 0) return;
    // Fat enough to read as a gauge closing rather than a hairline creeping —
    // this is the last thing that happens before money leaves, and it should
    // feel like a mechanism seating.
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      // **BUTT, not round or square — and this is BG-22, not taste**
      // (`ux-auditor`, D-229). A round or square cap paints half a stroke width
      // PAST each end of the arc: 2 x 2.25dp on a 106.81dp circumference is
      // **4.21% of the ring added to every reading**, so the gauge showed 16.7%
      // at a true 12.5% — Lie Factor 1.34 at 100ms, and unbounded as t
      // approaches 0. The house cap is square (`KvGlyph.cap`) because a glyph
      // is a mark; a gauge is a measurement, and a measurement may not overhang
      // its own value.
      ..strokeCap = StrokeCap.butt
      ..color = KvColor.primary;
    // BG-22: the swept angle IS the reading, so it is `t` and nothing else —
    // no easing in either direction (see the caller), no substitute channel
    // under reduced motion, and no cap painting past the end.
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * t,
      false,
      fill,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t;
}
