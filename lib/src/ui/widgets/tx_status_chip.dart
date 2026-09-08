import 'dart:async';

import 'package:flutter/material.dart';

import '../../rust/api/transport.dart';
import '../theme/tokens.dart';

/// The V2 chip states a transaction row can wear. `none` is the terminal
/// quiet: a settled row carries no label (Rams #5 — only the exception is
/// marked; founder-nodded 2026-07-09).
enum TxChipState { accepted, stalled, none }

// `chipStateOf`, `gateByDepth` and `chipCounterCeiling` lived here until
// UX-R3's second beat. The burial ladder (`KvBurial.rungFor`) reads a plain
// `stalled` bool now, and the ceiling — `100`, the last maturity threshold
// typed into `lib/` — gated nothing on any remaining path (D-249).

/// Chip state for a thread message from its tracker status.
///
/// **There is no `Pending`, by founder ruling** (2026-09-08: *"remove pending
/// entirely (we never use 'pending')"*), and removing the word removed the
/// state rather than renaming it — a chip that says nothing while a
/// transaction is in flight claims nothing, which is the honest posture for a
/// second or two of network. `submitted` and `displaced` therefore both render
/// quiet; a displaced row already says *Displaced by the network* on its own
/// line, which is the fact that matters.
///
/// `confirmed` and `null` (unwatched or horizon-pruned) are the quiet terminal
/// too — by then the delivered mark inside the bubble carries it. Pure; tested.
TxChipState chipStateOfAcceptance(TxStatusKind? kind) {
  return switch (kind) {
    null => TxChipState.none,
    TxStatusKind.confirmed => TxChipState.none,
    TxStatusKind.accepted => TxChipState.accepted,
    TxStatusKind.submitted => TxChipState.none,
    TxStatusKind.displaced => TxChipState.none,
    TxStatusKind.stalled => TxChipState.stalled,
  };
}

/// **Has this message reached the chain?** — the delivered double-check
/// (founder ruling, 2026-09-08).
///
/// True once a block has accepted the transaction, and it stays true: on a
/// public ledger *accepted* is the moment the message becomes retrievable by
/// its recipient, which is exactly what "delivered" claims and the most this
/// app can honestly claim. It is deliberately NOT *read* — nothing in this
/// protocol tells us that, and the mark lighting up for a read receipt is a
/// logged future idea with a privacy question in front of it
/// (IDEAS_BACKLOG 2026-09-08b).
///
/// A displaced row is not delivered: the chain took its block back.
bool deliveredOfAcceptance(TxStatusKind? kind) => switch (kind) {
  TxStatusKind.accepted || TxStatusKind.confirmed => true,
  null ||
  TxStatusKind.submitted ||
  TxStatusKind.displaced ||
  TxStatusKind.stalled => false,
};

/// The three-state transaction status chip (V2, founder-nodded design):
/// dot + label, never color alone (design_system §11).
///
/// - **accepted** — `success` (the chain accepted it; on Kaspa this IS the
///   user-meaningful confirmation, BG-6). **Transient**: it says *this just
///   happened*, holds for [acceptedDwell], and dissolves, because a permanent
///   label on every settled message is noise and the delivered mark inside the
///   bubble is what carries the fact afterwards (founder ruling, 2026-09-08).
/// - **stalled** — `warning`, steady: degraded is not "in progress". Amber is
///   re-rationed here from the old Pending label (semantic scarcity, §3).
/// - **none** — the chip dissolves; a settled row stays quiet.
///
/// State changes crossfade at `fast`; the dissolve to quiet takes `normal`.
/// Vault register throughout: decelerate-only, no celebration (BG-9).
class TxStatusChip extends StatefulWidget {
  const TxStatusChip({super.key, required this.state, this.confirmations});

  /// How long `Accepted` stays on screen before it dissolves.
  ///
  /// Founder ruling, 2026-09-08: *"accepted will only show for say; 2 seconds
  /// and it dissapears"* — **raised to 10 the same day**, after he watched it.
  /// Two seconds is long enough to notice a label and not long enough to read
  /// one while looking at the message it belongs to.
  ///
  /// It is an ARRIVAL, not a status — the message reaching the chain is a
  /// moment, and a moment is announced and then over. What remains afterwards
  /// is the delivered mark in the bubble, which is a fact rather than an event.
  ///
  /// `stalled` is untouched by this: *Not accepted yet* is a standing
  /// condition and stays until it stops being true.
  static const Duration acceptedDwell = Duration(seconds: 10);

  final TxChipState state;

  /// Live depth for the counting states (founder request, V2 sitting): when
  /// set, the label streams "N confirmations" instead of the static word —
  /// green while an accepted send deepens, quiet grey while a deposit
  /// matures — and the dissolve still marks "deep enough". Node-read
  /// (tracker blue-depth for sends; DAA distance for deposits); tabular
  /// digits so the count never jiggles (§4).
  final int? confirmations;

  @override
  State<TxStatusChip> createState() => _TxStatusChipState();
}

class _TxStatusChipState extends State<TxStatusChip> {
  /// The `Accepted` dwell has elapsed for the state currently held.
  bool _spent = false;

  /// This row has already announced its arrival once — see [didUpdateWidget].
  bool _seenAccepted = false;
  Timer? _dwell;

  @override
  void initState() {
    super.initState();
    _seenAccepted = widget.state == TxChipState.accepted;
    _armDwell();
  }

  @override
  void didUpdateWidget(TxStatusChip old) {
    super.didUpdateWidget(old);
    if (old.state == widget.state) return;
    // **A chip that has already said `Accepted` never says it again.**
    //
    // The founder saw it flash: *"it comes and go within millisecond and
    // stablizes to say accepted"*. The cause is that a thread pull can hand
    // this widget `none` for a frame — a delta whose statuses have not landed
    // yet, or an acceptance that momentarily reads back as unwatched — and the
    // old rule re-armed on ANY change, so the label tore out and back in with
    // a full `AnimatedSwitcher` crossfade each way.
    //
    // Latching the arrival makes the transition one-way: once accepted, this
    // chip's only remaining move is to spend its dwell and dissolve. A real
    // regression to `stalled` still shows, because that is a different state
    // and a standing condition rather than a moment.
    if (_seenAccepted && widget.state != TxChipState.stalled) return;
    if (widget.state == TxChipState.accepted) _seenAccepted = true;
    _spent = false;
    _armDwell();
  }

  void _armDwell() {
    _dwell?.cancel();
    if (widget.state != TxChipState.accepted) return;
    _dwell = Timer(TxStatusChip.acceptedDwell, () {
      if (mounted) setState(() => _spent = true);
    });
  }

  @override
  void dispose() {
    _dwell?.cancel();
    super.dispose();
  }

  /// What is actually drawn — the widget's state until its dwell is spent.
  TxChipState get _shown {
    if (_spent && _seenAccepted && widget.state != TxChipState.stalled) {
      return TxChipState.none;
    }
    // A momentary `none` from a half-landed pull does not blank a chip that is
    // mid-dwell — it holds `Accepted` until the dwell says otherwise.
    if (_seenAccepted && widget.state == TxChipState.none) {
      return TxChipState.accepted;
    }
    return widget.state;
  }

  @override
  Widget build(BuildContext context) {
    final state = _shown;
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
      child: KeyedSubtree(key: ValueKey(state), child: _body(context, state)),
    );
  }

  Widget _body(BuildContext context, TxChipState state) {
    var (color, label) = switch (state) {
      TxChipState.accepted => (KvColor.success, 'Accepted'),
      TxChipState.stalled => (KvColor.warning, 'Not accepted yet'),
      TxChipState.none => (null, null),
    };
    if (color == null || label == null) return const SizedBox.shrink();
    // The counting states stream their depth; stalled never counts (it has
    // no depth to count) and a null depth falls back to the static word.
    final n = widget.confirmations;
    if (n != null && state != TxChipState.stalled) {
      label = '$n confirmation${n == 1 ? '' : 's'}';
    }

    // A 6dp dot with **no bloom**, and the absence is the point: §1.5 defines
    // a lamp as a dot under an 8dp blur, so this is a coloured mark rather
    // than one of BG-2's three emitting kinds. That is why a feed of pending
    // rows does not spend the screen's emission budget one row at a time.
    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // **Nothing breathes any more.** The breath belonged to `Pending`, and
        // the two states left are both settled facts rather than waits — one
        // an arrival that dissolves, one a standing condition.
        dot,
        const SizedBox(width: KvSpace.xs),
        // Bounded, so the longest label in the set — `Not accepted yet` —
        // cannot push a ledger row past its own width at 320dp / 1.3x. Every
        // caller places this inside a bounded box (the money screen's `Wrap`,
        // the thread's `Align`), so the flex always has something to divide.
        //
        // Ellipsis rather than wrap, and only here: this chip is the row's
        // FOURTH signal, behind the word, the sign and the colour, so a
        // squeeze that shortens it costs no meaning. BG-5's never-ellipsize
        // law is about amounts, and the amount is a different widget.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              // **The dot carries the hue; the words do not.** §1.5 is
              // explicit that a fault reads as an indicator coming on rather
              // than as coloured text, and `KvStatusChip` holds its words at
              // `inkDim` for exactly that reason — this chip was the last
              // place in the system where a status tinted its own sentence
              // (`ux-auditor`, UX-2). Contrast was never the problem (`ok`
              // 11.72, `warn` 10.61 on `abyss`); the voice was.
              color: KvColor.inkDim,
              // The count ticks ~10×/s on Kaspa — digits must not jiggle
              // (§4).
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
