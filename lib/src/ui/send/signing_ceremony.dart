import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/send.dart';
import '../../rust/api/wallet.dart' show ActivityDirection, MaturityState;
import '../../rust/api/transport.dart';
import '../error_text.dart';
import '../format.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_amount.dart';
import '../widgets/kv_check.dart';
import '../widgets/kv_burial_mark.dart';
import '../widgets/kv_fact_line.dart';
import '../widgets/kv_contact.dart';
import '../widgets/kv_fiat.dart';
import '../widgets/tx_status_chip.dart' show chipStateOfAcceptance;
import '../widgets/kv_cadence.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_explorer_exit.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_hold.dart';
import '../widgets/kv_sheet.dart';
import '../widgets/kv_status_chip.dart';
import '../widgets/kv_two_pane.dart';

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
/// Every amount here shows every significant decimal to a minimum of two —
/// **the same precision law every other surface takes** (D-267, withdrawing
/// D-210's carve-out for this one). The rationale the carve-out rested on
/// (*"a trimmed figure is a different string from the one that was signed"*)
/// is false: the trim removes only zeros, so `12.40000000` and `12.40` are the
/// same number and no digit that carries value can be dropped. What BG-6 needs
/// is that no digit be HIDDEN, and eight fixed places hid the end of a figure
/// behind five zeros the eye had to count past.
///
/// **A sheet while it is a question, a screen once it is an answer** (`S7` →
/// `S8`, UX-R2). The review floats over the Send screen the user built it on,
/// so Cancel visibly returns them to their own form; the moment something has
/// actually happened the surface becomes a full-page receipt, because a receipt
/// is a destination and not a modal.
///
/// D-221 §1 made this a full screen on the argument that *a ceremony which can
/// scroll its own primary action out of reach is not a ceremony* — BG-6's
/// restatement is taller than any viewport at 320 dp / 1.3×. **That objection
/// is answered rather than waived**: [KvSheet.foot] is laid out below the
/// scroll and outside it, so the hold is under the thumb at every text scale
/// and only the restatement above it moves. The half of the ruling that was
/// load-bearing is kept; the half that was a container is what the founder's
/// approved render decides (D-259).
///
/// Back always cancels safely — leaving without a completed hold calls
/// [abandon] and drops the unsigned plan stashed in Rust.
class SigningCeremony extends StatefulWidget {
  const SigningCeremony({
    super.key,
    required this.summary,
    required this.commit,
    required this.abandon,
    this.title,
    this.contextNote,
    this.acceptanceStatus,
    this.maturity,
    this.fiat,
    this.contacts,
    this.onLeftInFlight,
    this.explorerUrl,
    this.openUrl,
    this.onSendAnother,
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

  /// **The pin's maturity thresholds** (D-249) — required wherever
  /// [acceptanceStatus] is wired, because the Status row plots a rung and a
  /// rung needs a ceiling. Null draws no rung at all rather than assuming one:
  /// the two seams travel together, and a receipt that had the depth but not
  /// the threshold would be guessing at the only thing it is there to say.
  final KvMaturity? maturity;

  /// The `≈` price under the restatement (`S7`, founder 2026-09-04). Null ⇒
  /// no rate seam is wired and no line is drawn. It restates the KAS figure
  /// above it and is never a term in anything: **what is signed is the KAS
  /// amount**, and BG-5's safety half is what keeps a vendor's number from
  /// ever being that.
  final FiatScope? fiat;

  /// The address book, so the sheet and the receipt can say *who* (`S7`'s
  /// `To  Mara`, `S8`'s `To Mara`). Null ⇒ no name is shown and no contact can
  /// be saved — the address is rendered in full either way, which is the part
  /// that is not optional (BG-15).
  final ContactsScope? contacts;

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

  /// The explorer exit's two seams (UX-5). [explorerUrl] resolves a txid to the
  /// exact URL the user's chosen explorer would open — **built and validated in
  /// Rust**, never here — and [openUrl] hands it to the platform. Null hides
  /// the exit rather than showing a control that goes nowhere (BG-12), which is
  /// what the placeholder it replaced was doing under a knowingly-suspended law
  /// (D-223; this sub-phase was its named trigger).
  final Future<String> Function(String txid)? explorerUrl;

  final Future<bool> Function(String url)? openUrl;

  /// *Send another* on the receipt (`S8`). It pops the ceremony like **Done**
  /// does and then tells the caller not to leave — the send screen resets its
  /// own form instead of popping to home.
  ///
  /// Null hides the action, which is what every non-payment caller gets: there
  /// is no "another" of a merge or a handshake bond.
  final VoidCallback? onSendAnother;

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
  KvMaturity? maturity,
  VoidCallback? onLeftInFlight,
  Future<String> Function(String txid)? explorerUrl,
  Future<bool> Function(String url)? openUrl,
  VoidCallback? onSendAnother,
  FiatScope? fiat,
  ContactsScope? contacts,
}) {
  return Navigator.of(context).push(
    // **A sheet route, so the page underneath stays on screen** — scrimmed and
    // blurred at 6 dp, which is the only job the blur has (§1.8). The route
    // itself is transparent; the surface decides whether it is floating a sheet
    // or covering the window with a receipt.
    KvSheetRoute<SendOutcomeDto>(
      builder: (_) => SigningCeremony(
        summary: summary,
        commit: commit,
        abandon: abandon,
        title: title,
        contextNote: contextNote,
        acceptanceStatus: acceptanceStatus,
        maturity: maturity,
        onLeftInFlight: onLeftInFlight,
        explorerUrl: explorerUrl,
        openUrl: openUrl,
        onSendAnother: onSendAnother,
        fiat: fiat,
        contacts: contacts,
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
  final kas = '${_kas(s.amountSompi)} KAS';
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

/// Inline KAS figure for sentence copy, and for the label on the control that
/// signs.
///
/// **Trailing zeros trimmed, to a minimum of two** — the founder's precision
/// ruling of 2026-09-04, which withdrew the signing surface's exemption from
/// D-210. It reaches prose because BG-5 applies to every number on a signing
/// surface, prose included, and a hold pill reading *"Hold to send 12.40 KAS"*
/// beside a restatement reading `12.40` is one figure said twice rather than
/// two figures that need reconciling.
String _kas(BigInt sompi) {
  final parts = kasParts(sompi);
  return '${parts.integer}.${trimFraction(parts.fraction)}';
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

  /// **The beat between the ring completing and the wait appearing** (founder,
  /// on glass 2026-09-04: *"when the mark shows, it goes to the sent screen
  /// after like 200ms or something so user can have a feel of the fingerprint
  /// change"*).
  ///
  /// It is **purely visual, and the broadcast does not wait for it.**
  /// `_commit()` is already awaiting Rust while this runs; what the timer
  /// delays is only the foot swapping the hold pill for the staged wait, so
  /// the check the badge just drew is on screen long enough to be seen.
  /// Every safety property that keys off `_sending` — the closed exit, the
  /// in-flight signal, the sealed back gesture — flips at the instant the
  /// commit starts, exactly as before.
  ///
  /// **And the beat does not lead to the receipt.** The founder's phrasing
  /// describes what a fast send looks like from the outside; between the hold
  /// and an acceptance there is a real 1.3–3.8 s the wallet cannot skip, and
  /// a receipt shown at 200 ms would claim a network acceptance nobody has
  /// been told about. What follows the beat is the named wait, and the
  /// receipt follows the outcome.
  bool _showWait = false;
  Timer? _signedBeat;

  static const Duration _signedBeatFor = Duration(milliseconds: 200);

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

  /// **The DAG has actually taken it.** Set by the first poll that answers
  /// `accepted` or `confirmed`, and it is what releases the sheet.
  ///
  /// It also gates the `Displaced` reading: a tracker that says *displaced*
  /// before it ever said *accepted* is describing a transaction it cannot
  /// find, not one whose accepting block left the chain — and the founder saw
  /// exactly that flash by on a healthy send.
  bool _acceptSeen = false;

  /// The sheet has handed over to the receipt. One flag, set in one place.
  bool _settledNow = false;

  Timer? _acceptCeiling;

  /// **How long the sheet will wait for an acceptance before showing the
  /// receipt anyway.** Measured submit→accepted is 1.3–3.8 s, so this is
  /// comfortably past a healthy send and short enough that a dead link does
  /// not hold someone on a sheet — and the way out has been open since 6 s
  /// either way (`_reopenExitAfter`).
  static const Duration _acceptCeilingAfter = Duration(seconds: 15);

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
        if (!mounted) return;
        setState(() {
          _status = status;
          // **The first real acceptance is what releases the sheet.** Until
          // the DAG has taken it there is no depth to show, and a receipt
          // shown before that flashes `Seen —` for a second — which is what
          // the founder watched happen and asked to stop.
          if (status?.kind == TxStatusKind.accepted ||
              status?.kind == TxStatusKind.confirmed) {
            _acceptSeen = true;
          }
        });
        if (_acceptSeen) _settle();
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

  /// **A tap when the sheet has fully arrived** (founder, on glass
  /// 2026-09-04: *"add haptics when the signing sheet comes up… when the
  /// signing sheet is fully transitioned in, at that moment is when the
  /// haptics should land"*).
  ///
  /// Fired off the ROUTE's own animation rather than a timer, so it lands with
  /// the last frame of the transition however long the transition takes —
  /// including when the platform has animations scaled down, where a timed
  /// haptic would fire into a sheet that arrived long ago.
  ///
  /// `selection`, not an impact: the sheet asking a question is not the money
  /// moment. §6 keeps `mediumImpact` for the hold's threshold and
  /// `heavyImpact` for a broadcast that landed, and a heavier tap here would
  /// spend both before anything had happened.
  void _tapOnArrival(AnimationStatus status) {
    if (status != AnimationStatus.completed || _greeted) return;
    _greeted = true;
    KvHaptic.selection();
  }

  bool _greeted = false;
  Animation<double>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (identical(animation, _route)) return;
    _route?.removeStatusListener(_tapOnArrival);
    _route = animation;
    // **Attached unconditionally, and `_greeted` is what makes it once.**
    //
    // The obvious guard — skip if the animation already reads `completed` —
    // is wrong here and silently disabled the whole thing: before a route's
    // controller is attached, `ModalRoute.animation` is a `ProxyAnimation`
    // over `kAlwaysCompleteAnimation`, so at `didChangeDependencies` it
    // reports **completed**, and only then does it go `forward` → `completed`
    // for real (proved by driving a `KvSheetRoute`, not assumed).
    animation?.addStatusListener(_tapOnArrival);
  }

  @override
  void dispose() {
    _route?.removeStatusListener(_tapOnArrival);
    // Left without signing → release the stashed (unsigned) plan in Rust.
    if (!_committed) widget.abandon();
    _stageOne?.cancel();
    _stageTwo?.cancel();
    _exitTimer?.cancel();
    _signedBeat?.cancel();
    _acceptCeiling?.cancel();
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
    _signedBeat = Timer(_signedBeatFor, () {
      if (mounted) setState(() => _showWait = true);
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
      // **The exit timer is NOT cancelled here any more.** It is what gives
      // the way out back at 6 s, and the wait it guards now continues past
      // the commit.
      if (mounted) {
        // A failure, or a send the DAG will never be asked about (partial, or
        // no tracker wired), has nothing to wait for: the answer is already
        // the whole answer.
        if (_error != null ||
            !_isFullyBroadcast ||
            widget.acceptanceStatus == null) {
          _settle();
        } else {
          // Otherwise the staged wait stays up, on its last named stage —
          // *Waiting for a node to accept it* — which is now literally true
          // rather than a label the screen wore for a beat. A ceiling keeps
          // it from being a trap: past it the receipt shows whatever is
          // known, and the exit has been open since 6 s regardless.
          _acceptCeiling = Timer(_acceptCeilingAfter, () {
            if (mounted) _settle();
          });
        }
      }
    }
  }

  /// **Hand over to the receipt.** One place, so the sheet cannot be released
  /// by two paths that disagree about what it is waiting for.
  void _settle() {
    if (!mounted || _settledNow) return;
    _acceptCeiling?.cancel();
    _exitTimer?.cancel();
    setState(() {
      _settledNow = true;
      _sending = false;
    });
  }

  bool get _settled => _settledNow;

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
      // yet. Nothing is at risk before the hold completes, and after it the
      // screen owes the user its answer.
      // **Every door is the same door** (`wallet-security-auditor`, UX-R2).
      //
      // `canPop` used to be `!_sending || _mayLeave`, which let the system
      // back gesture pop the route itself — and a system pop carries no
      // result, so a *settled* receipt returned `null`. `null` is what a
      // dismissal-without-signing returns, so `_reviewWith` did not leave the
      // send screen, and the user landed back on step 2 holding the
      // destination and the amount of the send that had just gone out: one
      // tap and one hold from a duplicate. The same UX-4 hazard `onLeftInFlight`
      // exists for, arriving through the exit that bypassed it — and newly
      // self-contradictory here, because *Send another* deliberately clears
      // that form while back left it armed.
      //
      // So the route never pops itself. Back runs `_close()`, which is the
      // same call the sheet's Cancel and the receipt's Done make, and the
      // outcome reaches the caller whichever door was used.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_sending && !_mayLeave) return;
        _close();
      },
      // **A crossfade, because nothing appears without the motion that
      // accounts for it** (BG-24). The sheet does not cut to the receipt: the
      // page rises through it on the one curve, which is also what makes the
      // change of *kind* — a question becoming an answer — legible.
      child: AnimatedSwitcher(
        duration: KvMotion.enter,
        switchInCurve: KvMotion.curve,
        switchOutCurve: KvMotion.curve,
        child: KeyedSubtree(
          key: ValueKey<bool>(_settled),
          child: _settled ? _receipt(context) : _review(context, s),
        ),
      ),
    );
  }

  /// Name the destination from the receipt (`S8`). The same sheet Send step 1
  /// opens, so a name is bound to an address in exactly one place (BG-21).
  Future<void> _saveContact() async {
    final scope = widget.contacts;
    if (scope == null) return;
    final address = widget.summary.destination;
    final name = await showContactNameSheet(
      context,
      address: address,
      initial: scope.nameFor(address),
    );
    if (name == null || !mounted) return;
    try {
      await scope.save(address, name);
    } catch (e) {
      // **Said, not swallowed.** The send has already happened and a failed
      // save costs a label and nothing else — but a control that answers a tap
      // and silently does nothing is §8's one prohibition, and the same
      // operation on Send surfaces its error. One operation, one honesty
      // posture (`wallet-security-auditor`, UX-R2B).
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('The contact could not be saved. ${displayError(e)}'),
            duration: KvMotion.toast,
          ),
        );
      }
    }
  }

  /// **The one exit.** Cancel, Done, Send another and the system back gesture
  /// all arrive here, so the outcome reaches the caller whichever door was
  /// used and the in-flight signal fires exactly once from any of them — the
  /// "provably complete rather than probably" property the rail's chevron used
  /// to get from `canPop` and the system gesture never did.
  void _close() {
    if (_sending) widget.onLeftInFlight?.call();
    Navigator.of(context).pop(_outcome);
  }

  /// `S7` — the review, floating over the form it was built on.
  Widget _review(BuildContext context, SignableSummaryDto s) {
    // Null while the broadcast is in flight: nothing is left to cancel, and a
    // closed exit reads as closed rather than looking live and ignoring the
    // tap (BG-12).
    final exit = _sending && !_mayLeave ? null : _close;
    return KvSheet(
      title: widget.title ?? _defaultTitle(s.kind),
      onCancel: exit,
      onDismiss: exit,
      // **Red, by founder ruling on glass** (2026-09-04). This is the one
      // Cancel in the app that BG-7's risk hue actually describes: the way out
      // of a commitment that cannot be undone once it is made.
      cancelTone: KvColor.risk,
      foot: Padding(
        padding: const EdgeInsets.fromLTRB(KvSpace.l, KvSpace.m, KvSpace.l, 0),
        // The foot changes shape when the hold fires; `AnimatedSize` on the
        // one easing makes it read as the control handing over rather than
        // blinking out (BG-24).
        child: AnimatedSize(
          duration: KvMotion.calm,
          curve: KvMotion.curve,
          alignment: Alignment.topCenter,
          child: _sending && _showWait
              ? _StagedWait(stage: _stage, mayLeave: _mayLeave)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KvHold(
                      label: _holdLabel(s),
                      progress: _hold,
                      // Dead the moment it fires: the ring is full, the
                      // transaction is Rust's, and a second press has nothing
                      // to start.
                      enabled: !_fired,
                      signed: _fired,
                      onDown: _down,
                      onUp: _release,
                    ),
                  ],
                ),
        ),
      ),
      // `shrinkWrap`, so a short restatement makes a short sheet and a long one
      // scrolls inside the 90 % cap — the height is the content's, never the
      // window's.
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.l),
        children: _truthRows(context),
      ),
    );
  }

  /// `S8` — once something has happened, the surface is a receipt and a
  /// receipt is a place, not a modal.
  Widget _receipt(BuildContext context) {
    final o = _outcome;
    final v = _verdictFor(o, _error);
    final txid = o?.finalTxid;
    final s = widget.summary;
    final selfSend = s.kind == SignableKind.selfSendFrame;
    final consolidate = s.kind == SignableKind.consolidate;
    final returnsToSelf = selfSend || consolidate;
    final gutter = KvWindow.of(context).gutter;
    return Scaffold(
      // **A `Scaffold`, not a bare `ColoredBox`.** The receipt is a full page
      // on a transparent route, and everything a page assumes — a `Material`
      // for ink, a `ScaffoldMessenger` for the copy acknowledgement, and the
      // theme's own `DefaultTextStyle` instead of `WidgetsApp`'s underlined
      // fallback (§9's drawer defect, one layer down) — arrives with it.
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        // **One column, clamped at 560 and centred** (BG-33) — the same clamp
        // Send and Receive take. A receipt is a full page like any other, and
        // a 1132 dp `Done` pill at `expanded` was exactly the stretch the law
        // forbids (`ux-auditor`, measured off the 1180 frame).
        child: KvColumn(
          gutter: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.symmetric(horizontal: gutter),
                  children: [
                    const SizedBox(height: KvSpace.xl),
                    Center(
                      // **A tick for the good outcome, a lamp for the
                      // exceptions.** Green means confirmed (BG-7), so a green
                      // mark over an unconfirmed send would be an overclaim; the
                      // check says *this step completed* and claims nothing about
                      // depth. Only the exception is marked (founder, on glass,
                      // 2026-08-30).
                      child: v.tone == KvLampTone.ok
                          ? const KvCheck(
                              disc: KvCheck.receipt,
                              semanticLabel: 'Sent',
                            )
                          : KvLamp(v.tone),
                    ),
                    const SizedBox(height: KvSpace.l),
                    Text(
                      v.head,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 30,
                        height: 34 / 30,
                        letterSpacing: -0.75,
                        fontWeight: FontWeight.w800,
                        fontVariations: KvWeight.w800,
                        color: KvColor.ink,
                      ),
                    ),
                    const SizedBox(height: KvSpace.sm),
                    Text(
                      v.body,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 15,
                        height: 21 / 15,
                        color: KvColor.inkDim,
                      ),
                    ),
                    // Rust's own reason, then the Dart-caught one.
                    // `SendOutcomeDto.error` was once read as a BOOLEAN and
                    // rendered nowhere, so a vault that locked between prepare
                    // and commit and a node that rejected the transaction both
                    // came out as a bare "Send failed" — on the one surface where
                    // the user most needs to know which (run 1, F8).
                    for (final line in [o?.error, _error])
                      if (line != null && line.isNotEmpty) ...[
                        const SizedBox(height: KvSpace.sm),
                        Text(
                          line,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 13,
                            height: 19 / 13,
                            color: KvColor.inkDim,
                          ),
                        ),
                      ],
                    const SizedBox(height: KvSpace.l),
                    _ReceiptCard(
                      maturity: widget.maturity,
                      summary: s,
                      returnsToSelf: returnsToSelf,
                      acceptedAt: _acceptedAt,
                      txid: txid,
                      status: _status,
                      acceptSeen: _acceptSeen,
                      contacts: widget.contacts,
                      onSaveContact: _saveContact,
                    ),
                    if (v.landed && txid != null) ...[
                      const SizedBox(height: KvSpace.m),
                      _ReceiptActions(
                        txid: txid,
                        explorerUrl: widget.explorerUrl,
                        openUrl: widget.openUrl,
                      ),
                    ],
                    const SizedBox(height: KvSpace.l),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 0, gutter, KvSpace.m),
                child: Column(
                  children: [
                    KvAction(label: 'Done', primary: true, onTap: _close),
                    if (widget.onSendAnother != null && v.landed) ...[
                      const SizedBox(height: KvSpace.s),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          widget.onSendAnother!.call();
                          _close();
                        },
                        child: Semantics(
                          button: true,
                          // 52 dp (BG-12) — `s14` around an 18 dp line is 46.
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: KvSpace.s),
                            child: Text(
                              'Send another',
                              style: TextStyle(
                                fontFamily: KvFont.ui,
                                fontSize: 14,
                                height: 18 / 14,
                                fontWeight: FontWeight.w600,
                                fontVariations: KvWeight.w600,
                                color: KvColor.inkDim,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
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
      // The review is never the settled surface any more — `S8`'s receipt is
      // — so the label states the intent in the present tense and the past
      // tense lives on the receipt card.
      // **The headline is what LEAVES THE WALLET — amount plus fee — and it
      // is centred under the title** (founder, on glass 2026-09-04: *"i want
      // it that its the full amount that leaves the wallet… and not the input
      // amount"*, *"let it be centered under 'confirm send' & 'Cancel'"*).
      //
      // The `— SENDING` rule label is gone with it: the figure is the subject
      // of the sheet and needs nothing above it saying so, and the word it
      // carried now labels the row that states the amount.
      //
      // A self-send's value returns as change, so its honest cost is still the
      // fee alone (D-069) — the total would count money that never left.
      Center(
        child: KvAmount(
          returnsToSelf ? s.feeSompi : s.totalSompi,
          role: KvAmountRole.screen,
        ),
      ),
      // The `≈` price, centred under the figure it restates (`S7`, founder
      // 2026-09-04) — the same sompi, never a second arithmetic.
      const SizedBox(height: KvSpace.xs),
      KvFiatLine(
        fiat: widget.fiat,
        sompi: returnsToSelf ? s.feeSompi : s.totalSompi,
        alignment: MainAxisAlignment.center,
      ),

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
      const SizedBox(height: KvSpace.l),
      // **The truth card** (`S7`, §5): destination, fee and what leaves, in
      // one `chip` inner card. Every information-bearing sub-line inside it is
      // `inkDim` — `inkMeta` is 4.30 on `chip` and §1.4 forbids it there.
      _TruthCard(
        children: [
          // A self-send (message or merge) goes to our OWN address — showing
          // that raw address reads as "sending to a stranger". Drop it; the
          // thread (or the wallet itself) is the destination.
          if (!returnsToSelf) ...[
            // **`To` left, the name right** (`S7`, measured: every value on
            // this card ends on one right edge at 348.5 dp). The name is on
            // the line ABOVE the address and never in place of it — the 67
            // characters below are what the signature commits to, and they
            // are rendered in full whether or not the book knew this address
            // (BG-15).
            _ToHead(address: s.destination, contacts: widget.contacts),
            const SizedBox(height: KvSpace.s),
            // One mono run with the first and last groups weighted: an
            // address-poisoning attack buys a prefix and a suffix that LOOK
            // right, so the eye is put exactly where the attack has to
            // succeed (BG-15).
            KvAddress(
              s.destination,
              form: KvAddressForm.chunked,
              plated: false,
            ),
            const SizedBox(height: KvSpace.s),
            const _FactRule(),
          ],
          _FactRow(label: 'Network fee', sompi: s.feeSompi),
          const _FactRule(),
          // **What leaves, in `risk`, with its sign** (`S7`, §5, BG-7). The
          // label was `Total`, which names an arithmetic rather than a
          // consequence: the number a user must check before signing is what
          // will be gone from the wallet, and the hue, the word and the sign
          // all say the same thing so the meaning survives greyscale.
          // **`Sending` — what the RECIPIENT gets** (founder, on glass
          // 2026-09-04: *"where 'Leaves your wallet' was before, change it to
          // 'Sending'"*).
          //
          // It states the amount rather than the total, and that is a reading
          // rather than a transcription: the total moved up to the headline in
          // the same breath, so leaving this row on the total would print one
          // number twice and never print the other. With the amount here the
          // card is complete and its arithmetic closes — `Sending` plus
          // `Network fee` is the figure at the top — which is what BG-6 asks a
          // restatement to show. Say the word and it becomes the total.
          if (returnsToSelf)
            _FactRow(label: 'Returns to you', sompi: s.amountSompi)
          else
            _FactRow(
              label: 'Sending',
              sompi: s.amountSompi,
              direction: KvMoneyDirection.outgoing,
            ),
        ],
      ),

      const SizedBox(height: KvSpace.l),
      const KvStatusChip(
        tone: KvLampTone.warn,
        words: 'Once this is signed it cannot be reversed.',
        maxLines: null,
      ),
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

/// One exact cost line: label left, amount hard right (BG-5).
///
/// **Trailing zeros trimmed, on the signing surface too** (founder,
/// 2026-09-04). `12.40000000` reads `12.40` and `0.00010000` reads `0.0001`.
/// It is a safe change to make on the one surface D-210 used to exempt,
/// because the trim removes only zeros: no digit that carries value is lost,
/// nothing rounds, and what BG-6 needs from a restatement — that no digit be
/// hidden — is better served by a number whose end the eye can find.
class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.label,
    required this.sompi,
    this.direction = KvMoneyDirection.internal,
  });

  final String label;
  final BigInt sompi;

  /// BG-7: a figure with a direction takes that direction's hue, its sign and
  /// its weight. A fee has none — it is a cost, not a movement — and *what
  /// leaves* has all three.
  final KvMoneyDirection direction;

  /// What [KvAmount] will print, rebuilt here for [KvFactLine.valueText].
  /// Measurement only — see that field.
  String get _printed {
    final parts = kasParts(sompi);
    final sign = direction == KvMoneyDirection.outgoing ? '-' : '';
    return '$sign${parts.integer}.${trimFraction(parts.fraction)} KAS';
  }

  @override
  @override
  Widget build(BuildContext context) => KvFactLine(
    label: label,
    valueText: _printed,
    strongLabel: direction == KvMoneyDirection.outgoing,
    // No `FittedBox`. `KvAmount` fits its own figure given a bounded width
    // and keeps the unit OUT of that fit so its 11dp floor survives — an
    // outer one scales the whole thing again and puts the unit back under the
    // floor (measured at 6.01dp for a whole-supply fee row). Fitting a widget
    // that already fits itself is how a floor gets multiplied away.
    value: KvAmount(
      sompi,
      role: KvAmountRole.row,
      direction: direction,
      showUnit: true,
      // **A fact row states a COST, and a cost is read for its digits**
      // (BG-23, founder's call from the rendered comparison — D-230). The
      // role default cannot decide this: `row` is also the home ledger,
      // where a figure is a holding and the magnitude is the point. Here
      // the figure is a fee, always below 1, so the magnitude is `0` in
      // every case this surface will ever show and the weight belongs on
      // the digits that are the fee. `Leaves your wallet` takes the same flag
      // and is unaffected: above 1 every emphasis rule agrees, which is what
      // stops a fee out-shouting the total it is part of.
      emphasis: KvAmountEmphasis.significant,
    ),
  );
}

/// One dated fact: label left, wall-clock stamp right, on the same grid.
class _StampRow extends StatelessWidget {
  const _StampRow({required this.label, required this.at});

  final String label;
  final DateTime at;

  @override
  Widget build(BuildContext context) => KvFactLine(
    label: label,
    valueText: formatStamp(at),
    value: Text(
      formatStamp(at),
      textAlign: TextAlign.right,
      style: const TextStyle(
        fontFamily: KvFont.mono,
        fontSize: 13,
        height: 20 / 13,
        color: KvColor.ink,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );
}

/// `To` on the left, the contact's name on the right (`S7`).
class _ToHead extends StatelessWidget {
  const _ToHead({required this.address, required this.contacts});

  final String address;
  final ContactsScope? contacts;

  @override
  Widget build(BuildContext context) {
    final scope = contacts;
    if (scope == null) return const _CardLabel('To');
    return ValueListenableBuilder<List<ContactDto>>(
      valueListenable: scope.contacts,
      builder: (context, _, _) {
        final name = scope.nameFor(address);
        return Row(
          children: [
            const _CardLabel('To'),
            const SizedBox(width: KvSpace.m),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                // Absent, not "Unknown", when the book does not know it: the
                // seat is a name or nothing, and the offer to make one lives
                // where there is room for a control (`S6b`, `S8`).
                child: name == null
                    ? const SizedBox.shrink()
                    : KvContactName(name: name),
              ),
            ),
          ],
        );
      },
    );
  }
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

/// The `chip` inner card the restatement lives in (`S7`, §5).
///
/// **A card inside a sheet is `chip`, one step above the sheet's `plate`**
/// (§1.1) — and that one step is why every information-bearing line inside it
/// is `inkDim`: `inkMeta` measures 4.30 on `chip` and BG-14 does not bend.
class _TruthCard extends StatelessWidget {
  const _TruthCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    // **Tighter, all round** (founder, on glass 2026-09-04: *"reduce the gap
    // so the card is more rectangular in height to the currently three stuffs
    // in it"*). The rows carry their own 12 dp of vertical air, so the card's
    // own 14 was stacking a second gap on top of the first at the top and
    // bottom edges — the loose base he pointed at under `Leaves your wallet`.
    padding: const EdgeInsets.symmetric(
      horizontal: KvSpace.m,
      vertical: KvSpace.s,
    ),
    decoration: BoxDecoration(
      color: KvColor.chip,
      borderRadius: BorderRadius.circular(KvRadius.inner),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );
}

/// A label inside the truth card.
class _CardLabel extends StatelessWidget {
  const _CardLabel(this.text);

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

/// The receipt's card (`S8`): who it went to, what was sent, what it cost,
/// where it stands and when — on the same ruled grid the review used, so the
/// two read as one document rather than two designs of the same facts (BG-21).
///
/// **Every value ends on one right edge** (`S8`, measured: 347.5 dp for all
/// four rows, labels at 45.5). That is [KvFactLine]'s job and the founder's
/// note from the glass — *"let the details infront of them move to the other
/// edge of the screen"*.
///
/// **The status row is here now, and it carries no new number.** It was left
/// out at UX-R2 because `S8` draws `Settling · 1 of 10` — the retired
/// vocabulary and a threshold typed into the UI, which D-249 forbids until
/// both thresholds cross the FFI. What makes it buildable today is that
/// neither is needed: `TxStatusDto.blueDepth` is a node-read depth that
/// already crosses, and [KvBurialMark] already owns the ladder — `KvBurial`'s
/// ratified `Seen → Confirmed → final` and its `safe`/`settled` thresholds,
/// which live in one place and are read, never retyped. So the founder's
/// *"numbers streams from 1 - 100 and says confirmed after 100 confirmations"*
/// is exactly the shipped widget, pointed at this transaction. The vocabulary
/// migration he named next (*"eventually it will be Accepted and Settled"*)
/// is still D-248's and still R3's.
class _ReceiptCard extends StatelessWidget {
  const _ReceiptCard({
    required this.summary,
    required this.returnsToSelf,
    required this.acceptedAt,
    required this.txid,
    required this.status,
    required this.acceptSeen,
    required this.maturity,
    required this.contacts,
    required this.onSaveContact,
  });

  final SignableSummaryDto summary;
  final bool returnsToSelf;
  final DateTime? acceptedAt;
  final String? txid;

  /// The tracker's latest answer, or null while there is nothing to ask about.
  final TxStatusDto? status;

  /// The pin's thresholds. Null draws no rung — see [SigningCeremony.maturity].
  final KvMaturity? maturity;

  /// Whether an acceptance has ever been observed for this send. A `Displaced`
  /// answer before one is the tracker saying *I cannot find this*, not *its
  /// block left the chain*, and it must not be printed as the second.
  final bool acceptSeen;

  final ContactsScope? contacts;
  final VoidCallback onSaveContact;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.s20,
        vertical: KvSpace.s,
      ),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.plate),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!returnsToSelf) ...[
            const SizedBox(height: KvSpace.s),
            _ReceiptHead(
              address: s.destination,
              // **What LEFT, not the amount** — §5's own words for this slot,
              // and it removes a duplication `S8` does not have: the head, an
              // `Amount` row and a `Left your wallet` row were three printings
              // of two numbers, with the `risk` weight on the wrong one
              // (`ux-auditor`, UX-R2B). The head is now the total and the two
              // rows below explain it.
              sompi: returnsToSelf ? s.amountSompi : s.totalSompi,
              contacts: contacts,
              onSaveContact: onSaveContact,
            ),
            const SizedBox(height: KvSpace.s),
            const _FactRule(),
          ],
          _FactRow(label: 'Amount', sompi: s.amountSompi),
          const _FactRule(),
          _FactRow(label: 'Network fee', sompi: s.feeSompi),
          // **How deeply buried, streamed** — the ladder's own widget, so the
          // receipt and the ledger cannot disagree about one transaction
          // (BG-21). It appears once the tracker has answered at all; before
          // that there is nothing to say and it says nothing.
          if (status != null && maturity != null) ...[
            const _FactRule(),
            KvFactLine(
              label: 'Status',
              valueShare: 0.55,
              // **The tracker's own kind decides the reading — this surface
              // asserts nothing** (INV-9, BG-20).
              //
              // The first cut hardcoded `TxChipState.accepted` and consumed
              // only the depth, which made two of the DTO's five kinds
              // indistinguishable from a healthy send: `Stalled` (the tracker's
              // explicit *submitted, nothing accepted it past 60 s*) and
              // `Displaced` (the accepting block left the chain) both arrive
              // with `blue_depth: None`, and a null depth over `accepted` falls
              // to the `seen` rung — so both printed `Seen —`, in amber, on the
              // one surface a user consults to decide whether a payment needs
              // sending again. Caught independently by `wallet-security` and
              // `consensus` at UX-R2B; the mapper it should have used
              // (`chipStateOfAcceptance`) was already imported *beside* it,
              // which is L143 in one line.
              value: status!.kind == TxStatusKind.displaced && acceptSeen
                  // **Displaced is not a rung, so it does not borrow one.**
                  // The burial ladder measures how deep an accepted
                  // transaction is; a displaced one has no depth to be at, and
                  // dressing it as `Seen —` would say the chain still holds it.
                  // The sentence is the thread's own (BG-21) — the wallet says
                  // this in exactly one wording — and it is reversible by
                  // construction: the next poll lifts it if the network
                  // re-accepts.
                  ? const _StatusSentence('Displaced by the network')
                  : KvBurialMark(
                      state: chipStateOfAcceptance(status!.kind),
                      confirmations: status!.blueDepth?.toInt(),
                      // **The tracker's kind IS the maturity here**, and under
                      // D-248's vocabulary it needs no translation: `submitted`
                      // is a spend the DAG has not accepted, which is exactly
                      // `Pending`; anything else the tracker will answer has
                      // been accepted, and the rung then follows the depth.
                      //
                      // This replaces a hardcoded `MaturityState.pending`
                      // whose only job was to stop an unknown depth reading as
                      // the terminal word. The direction now carries that: a
                      // spend with no depth reads `Accepted —` by the
                      // arithmetic rather than by a fixed argument.
                      maturity: status!.kind == TxStatusKind.submitted
                          ? MaturityState.pending
                          : MaturityState.confirmed,
                      // A receipt is always our own spend, and a spend is never
                      // a coinbase.
                      direction: ActivityDirection.outgoing,
                      isCoinbase: false,
                      thresholds: maturity!,
                      fontSize: 13,
                    ),
            ),
          ],
          // **The accepting BLOCK's own timestamp** — `TxStatusDto
          // .acceptedUnixMs`, carried across the FFI for exactly this line.
          // Neither `DateTime.now()` nor the wallet's fold time will do: both
          // are this device's observation of an acceptance rather than the
          // acceptance, wrong by the poll latency on a live link and by hours
          // on a catch-up replay (`ffi-leak-auditor` caught the second of
          // those in this field's first cut).
          //
          // It appears only once there is an acceptance to stamp; a send still
          // waiting has no time to show and shows none.
          if (acceptedAt != null) ...[
            const _FactRule(),
            _StampRow(label: 'Accepted', at: acceptedAt!),
          ],
          // The id, under the acceptance (founder, 2026-09-04). **Truncated in
          // the middle, never at one end**: a txid is compared by both ends,
          // and *Copy ID* below copies every character of it.
          if (txid != null) ...[
            const _FactRule(),
            KvFactLine(
              label: 'Transaction ID',
              valueShare: 0.66,
              valueText: _shortId(txid!),
              value: Text(
                _shortId(txid!),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 13,
                  height: 20 / 13,
                  fontWeight: FontWeight.w500,
                  fontVariations: KvWeight.w500,
                  color: KvColor.ink,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
          const SizedBox(height: KvSpace.s),
        ],
      ),
    );
  }
}

/// A status the burial ladder has no rung for, said in words with a `warn`
/// lamp — the same dot-and-words shape `KvBurialMark` wears, so the row reads
/// as one channel rather than two (BG-21).
class _StatusSentence extends StatelessWidget {
  const _StatusSentence(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: KvColor.warn,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: KvSpace.xs),
      Flexible(
        child: Text(
          words,
          maxLines: 2,
          textAlign: TextAlign.right,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            height: 18 / 13,
            fontWeight: FontWeight.w500,
            fontVariations: KvWeight.w500,
            // The dot carries the hue; the words do not (§1.5).
            color: KvColor.inkDim,
          ),
        ),
      ),
    ],
  );
}

/// A 64-character txid, shortened for a row that has to hold something else
/// too: eight from each end, which is what a user compares against a block
/// explorer. The whole string is one tap away on *Copy ID*.
String _shortId(String txid) => txid.length <= 20
    ? txid
    : '${txid.substring(0, 8)}\u2026'
          '${txid.substring(txid.length - 8)}';

/// The receipt card's head (`S8`): the disc, *To Mara* over the compact
/// address, and what left on the right.
///
/// **When the book does not know the address, the name's seat becomes the
/// offer to fill it** (founder, 2026-09-04: *"if not, it shouldn't say
/// unknown, i change my mind, just put 'save as contact' where it says 'To
/// Mara'"*). It is the best moment in the app to ask: the user has just chosen
/// to send here, so the address has earned a name — and the row still shows
/// the address either way, because a name is never what a funds surface is
/// checked against (BG-15).
class _ReceiptHead extends StatelessWidget {
  const _ReceiptHead({
    required this.address,
    required this.sompi,
    required this.contacts,
    required this.onSaveContact,
  });

  final String address;
  final BigInt sompi;
  final ContactsScope? contacts;
  final VoidCallback onSaveContact;

  @override
  Widget build(BuildContext context) {
    final scope = contacts;
    if (scope == null) return _row(null);
    return ValueListenableBuilder<List<ContactDto>>(
      valueListenable: scope.contacts,
      builder: (context, _, _) => _row(scope.nameFor(address)),
    );
  }

  Widget _row(String? name) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final avatar = KvContactAvatar(name: name);
        final who = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (name == null)
              KvContactAction(
                label: 'Save as contact',
                tone: KvColor.primaryMuted,
                onTap: onSaveContact,
              )
            else
              Text(
                'To $name',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  fontVariations: KvWeight.w600,
                  color: KvColor.ink,
                ),
              ),
            KvAddress(address, fontSize: 12),
          ],
        );
        // `S8`, measured: `amountReceipt`'s 18, in `risk` with its sign — what
        // left, at a glance, before any row is read.
        final figure = KvAmount(
          sompi,
          role: KvAmountRole.row,
          size: 18,
          direction: KvMoneyDirection.outgoing,
          showUnit: false,
        );

        // **Does the address still fit beside the figure?** Measured, because
        // guessing here produced two defects in one sitting: unbounded, the
        // address scaled to 7.5 dp at the floor; given a floor and no room, it
        // wrapped INSIDE a row that had none and collided with the amount
        // (both found in the 320 dp / 1.3× frame, not argued).
        //
        // So the row asks the question rather than assuming an answer, and
        // when the answer is no it puts the figure on its own line — the same
        // fallback `KvFactLine` takes, and it keeps the right edge.
        final scaler = MediaQuery.textScalerOf(context);
        double widthOf(String text, double size) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: TextStyle(fontFamily: KvFont.mono, fontSize: size),
            ),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          )..layout();
          final w = painter.width;
          painter.dispose();
          return w;
        }

        final needed = widthOf(truncateAddressPayload(address), 12);
        // **The figure is measured, not reserved.** A flat 150 dp guess was
        // wider than `-12.403154` actually paints, so the head stacked at the
        // 393 reference where `S8` draws it inline — the reserve, not the
        // content, was deciding the layout.
        final parts = kasParts(sompi);
        final figureWidth = widthOf(
          '-${parts.integer}.${trimFraction(parts.fraction)}',
          18,
        );
        // What the column would get: the row less the disc, the gaps, and the
        // figure beside it.
        final room =
            constraints.maxWidth -
            KvSpace.rowDisc -
            KvSpace.sm -
            KvSpace.s -
            figureWidth;

        if (needed <= room) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              avatar,
              const SizedBox(width: KvSpace.sm),
              Expanded(child: who),
              const SizedBox(width: KvSpace.s),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: figureWidth),
                child: figure,
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                avatar,
                const SizedBox(width: KvSpace.sm),
                Expanded(child: who),
              ],
            ),
            const SizedBox(height: KvSpace.s),
            Align(alignment: Alignment.centerRight, child: figure),
          ],
        );
      },
    );
  }
}

/// `Copy ID` · `Explorer` (`S8`) — the two quiet things worth doing with a
/// transaction that has landed, **side by side**.
///
/// The founder's note: *"Make view on explorer be a but beside the Copy ID,
/// let it just say `<icon> Explorer` … let it be like the screenshot
/// example."* It was a full-width card under the copy action; the render draws
/// a pair of text buttons, centred, and that is what this is.
///
/// **The disclosure moved rather than vanished.** D-192 is why the exit ever
/// named its destination — a departure you cannot name is not one you
/// consented to — and the founder took the printed line off this seat on
/// 2026-09-04. The naming now lives where the destination is *chosen*
/// (Settings) and where the exit renders in its full register (the
/// transaction detail); the spoken label here still carries it in full. One
/// widget, two registers (BG-21).
class _ReceiptActions extends StatelessWidget {
  const _ReceiptActions({
    required this.txid,
    required this.explorerUrl,
    required this.openUrl,
  });

  final String txid;
  final Future<String> Function(String txid)? explorerUrl;
  final Future<bool> Function(String url)? openUrl;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Semantics(
            button: true,
            label: 'Copy the transaction id',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () async {
                // The tap copies ALL of it — a truncated txid is as useless as
                // a truncated address — and says so, because a copy with no
                // acknowledgement leaves the user tapping twice.
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
              child: const Padding(
                // 52 dp (BG-12) — `s14` around an 18 dp line is 46.
                padding: EdgeInsets.symmetric(
                  horizontal: KvSpace.sm,
                  vertical: KvSpace.s,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KvGlyphIcon(KvGlyph.copy, size: 18, tone: KvColor.inkDim),
                    SizedBox(width: KvSpace.s),
                    Text(
                      'Copy ID',
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 14,
                        height: 18 / 14,
                        fontWeight: FontWeight.w600,
                        fontVariations: KvWeight.w600,
                        color: KvColor.inkDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // It disappears entirely when the seams are absent, which is what a
        // control with nowhere to go should do (BG-12).
        if (explorerUrl != null) ...[
          const SizedBox(width: KvSpace.m),
          Flexible(
            child: KvExplorerExit(
              subject: txid,
              resolve: explorerUrl!,
              open: openUrl ?? (_) async => false,
              compact: true,
            ),
          ),
        ],
      ],
    );
  }
}
