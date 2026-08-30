import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/error.dart';
import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../error_text.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_amount.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_keypad.dart';
import '../widgets/kv_status_chip.dart';
import '../widgets/kv_surface.dart';
import 'signing_ceremony.dart';

/// Send — amount and destination. **NOTHING signs here.**
///
/// Entry is cheap and reversible, so the screen stays light: no ceremony, no
/// warnings, no friction proportional to a risk that has not been taken yet
/// (D-189). Every blocked state says why **in amber with the exact number** —
/// *"you are 0.00001994 KAS short"*, never *"too small"*. Red would claim
/// money is at risk when none is (BG-7), and a disabled control always says
/// why (BG-12).
///
/// The amount pad is [KvKeypad] in its plain skin — the same primitive that
/// takes a passphrase. One muscle memory, one codepath to audit, and the
/// amount inherits the no-system-keyboard guarantee for free.
///
/// "Review" builds the transaction(s) in Rust and opens the anti-blind-signing
/// [SigningCeremony] — the amount and fee the user approves are Rust's decode
/// of the actual transactions, never this form's echo (B7).
///
/// A pure consumer (injected fns + the live mature balance) so widget tests run
/// without the native library; `main.dart` wires it to `WalletService`.
class SendScreen extends StatefulWidget {
  const SendScreen({
    super.key,
    required this.mature,
    required this.prepare,
    required this.commit,
    required this.abandon,
    this.balanceStale,
    this.feePreview,
    this.acceptanceStatus,
    this.minimumSendable,
    this.prepareSweep,
  });

  /// Spendable (mature) balance, for the informational "available" line and
  /// the shortfall arithmetic. The authoritative check (incl. the KIP-9 fee)
  /// is Rust's `prepare`.
  final ValueListenable<BigInt?> mature;

  /// Whether [mature] is a **last-known** figure rather than a live one — the
  /// money plate's own `_dimmed` bit, handed down rather than re-derived
  /// (BG-8: every chain-derived value wires live · stale · unknown).
  ///
  /// It does two things, and the second matters more. The reading dims, and
  /// the screen **stops quoting the balance back as a fact**: a shortfall
  /// sentence built on a figure the wallet cannot currently vouch for is a
  /// confident claim about someone's money, which is the P0.3 scar with a
  /// number attached.
  ///
  /// Null means no freshness signal was wired, and the figure is then rendered
  /// as given. BG-8's third state — `—` for unknown — rides [mature] being
  /// null and is independent of this.
  final ValueListenable<bool>? balanceStale;

  final Future<SignableSummaryDto> Function(
    String destination,
    BigInt amountSompi,
  )
  prepare;
  final Future<SendOutcomeDto> Function(BigInt nonce) commit;
  final Future<void> Function() abandon;

  /// Send max — the sweep builder (Rust solves the amount: it depends on the
  /// fee of the transaction spending it, so the field's number can never be
  /// right). Null hides the affordance (tests that only exercise payments).
  final Future<SignableSummaryDto> Function(String destination)? prepareSweep;

  /// **The fee this exact payment would cost, priced by the Generator now.**
  ///
  /// Called as the amount is typed so the cost is on the glass BEFORE Review,
  /// not after it. Signerless and stash-free; `None` whenever no transaction
  /// can be built, and the screen then shows no fee at all — never a guess,
  /// and never a stale figure left standing beside a changed amount.
  final Future<BigInt?> Function(String destination, BigInt amountSompi)?
  feePreview;

  /// The tracker's live answer for a txid, handed to the ceremony so the
  /// receipt can stream its depth. Null ⇒ the receipt shows no depth mark.
  final Future<TxStatusDto?> Function(String txid)? acceptanceStatus;

  /// The smallest currently-sendable amount (sompi), probed from the pinned
  /// Generator over the live coin shape (D-054). A null provider or a null
  /// result means no floor is known, and then nothing is ever blocked by one —
  /// the Generator on `prepare` stays the single authority either way.
  final Future<BigInt?> Function()? minimumSendable;

  /// The amount field. Named because the screen now has two text fields and a
  /// test must be able to say which one it means.
  static const Key amountTarget = Key('send-amount-target');

  /// The destination field, for the same reason.
  static const Key addressTarget = Key('send-address-target');

  /// The screen's own scroll. Named because the amount is a text field now and
  /// carries a `Scrollable` of its own, so "the first Scrollable" stopped
  /// meaning "the list".
  static const Key scrollTarget = Key('send-scroll');

  @override
  State<SendScreen> createState() => _SendScreenState();
}

/// The mainnet address lengths, derived from the pinned crate rather than
/// remembered: `Version::public_key_len` is 32 bytes for `PubKey` and
/// `ScriptHash` and 33 for `PubKeyECDSA` (`crypto/addresses/src/lib.rs:164` at
/// `cfafeb4`); a version byte joins the payload, the whole is base32 at 5 bits
/// a character, and an 8-character checksum follows — 53 + 8 and 55 + 8
/// payload characters, plus `kaspa:`.
///
/// **This is a SHAPE check and never a checksum.** Dart validates nothing about
/// an address's contents: `send_prepare` calls `validate_mainnet_address`,
/// which is the pinned crate's own parse, and that verdict is the one that
/// decides (INV-9 — consensus logic is never re-implemented here).
const Set<int> _mainnetAddressLengths = {67, 69};

/// What is wrong with the form right now: the sentence under Review when the
/// control is disabled, and the amber notice when there is a number to give.
///
/// **One record, so the disable switch and the sentence can never disagree** —
/// BG-12's "a disabled control always says why" holds by construction rather
/// than by two fields being kept in step. A null [reason] with a notice is a
/// WARNED state, not a blocked one; see [_SendScreenState._blockFor] for which
/// is which and why.
typedef _Block = ({String? reason, String? notice});

class _SendScreenState extends State<SendScreen> {
  /// The typed amount, canonical and ungrouped — exactly what
  /// [sompiFromKas] parses. Never a formatted string.
  String get _amount => _amountField.text;
  set _amount(String v) => _amountField.text = v;

  /// The amount as an editable field, so the DEVICE keyboard can take over
  /// when the figure is tapped (founder, 2026-08-30).
  ///
  /// **This narrows D-189 rather than reversing it.** The on-screen pad stays
  /// the default and stays the same primitive the passphrase keyboard uses —
  /// the muscle memory and the one-codepath audit both survive. What changes
  /// is that an amount may ALSO be typed on the system keyboard, which costs
  /// nothing that mattered: the no-system-IME law is INV-3's, and it protects
  /// SECRETS. An amount is not one. The passphrase surfaces are untouched and
  /// have no such handover.
  ///
  /// The controller is the single source of truth for both input paths, so the
  /// pad and the keyboard can never disagree about what has been typed.
  final _amountField = TextEditingController();
  final _amountFocus = FocusNode();

  /// Never re-derived — see [SendScreen.balanceStale]. The fallback is a
  /// constant `false`, not a second folding of the link state.
  late final ValueListenable<bool> _stale =
      widget.balanceStale ?? ValueNotifier<bool>(false);
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  bool _building = false;
  String? _error;
  BigInt? _minSompi;

  /// The Generator's fee for what is currently typed, or null when there is
  /// nothing buildable to price.
  BigInt? _fee;
  Timer? _feeDebounce;

  /// Guards against an out-of-order answer overwriting a newer one: every
  /// request carries a token and only the latest may land. Without it a slow
  /// probe for `1` can return after a fast probe for `12` and leave the screen
  /// showing the fee for an amount the user has already moved past — a true
  /// number against the wrong figure, which is worse than none.
  int _feeToken = 0;

  /// Long enough that a run of keystrokes makes ONE probe, short enough that
  /// the figure feels live. The probe builds a real transaction chain, so it
  /// is not free.
  static const Duration _feeDebounceFor = Duration(milliseconds: 250);

  /// Re-price what is typed now. Clears the fee first, because a fee that
  /// lingers beside a changed amount is a lie for as long as it lingers.
  void _repriceFee() {
    final probe = widget.feePreview;
    _feeDebounce?.cancel();
    final token = ++_feeToken;
    if (_fee != null) setState(() => _fee = null);
    final amount = _amountSompi;
    if (probe == null || amount == null || amount <= BigInt.zero) return;
    if (!_addressLooksValid) return;
    final destination = _destination;
    _feeDebounce = Timer(_feeDebounceFor, () async {
      try {
        final fee = await probe(destination, amount);
        if (mounted && token == _feeToken) setState(() => _fee = fee);
      } catch (_) {
        // No fee is a real answer; a failed probe is not a number.
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _address.addListener(_onChanged);
    _addressFocus.addListener(_onChanged);
    _amountFocus.addListener(() => setState(() {}));
    // The system keyboard writes straight into the controller, so the fee and
    // the block ladder have to hear about it the same way a pad press does.
    _amountField.addListener(_onAmountChanged);
    // Fetch the live floor once per screen-open. Advisory: a failure (engine
    // not ready, probe error) simply means no floor is known, and a null floor
    // blocks nothing.
    final probe = widget.minimumSendable;
    if (probe != null) {
      probe()
          .then((min) {
            if (mounted) setState(() => _minSompi = min);
          })
          .catchError((Object _) {
            /* no floor — prepare stays authoritative */
          });
    }
  }

  @override
  void didUpdateWidget(SendScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `_stale` is captured once at mount, so silently swapping the seam would
    // leave this screen wired to the old notifier and quietly reading a
    // freshness bit nobody updates. The same hazard `home_screen.dart` asserts
    // for its own scopes, and the same fix: make it loud in debug rather than
    // subtle in release.
    assert(
      identical(oldWidget.balanceStale, widget.balanceStale) &&
          identical(oldWidget.mature, widget.mature),
      'SendScreen: a balance seam was swapped after mount — the screen is '
      'still listening to the old one (V4 seam law).',
    );
  }

  @override
  void dispose() {
    _address.dispose();
    _addressFocus.dispose();
    _amountField.dispose();
    _amountFocus.dispose();
    _feeDebounce?.cancel();
    super.dispose();
  }

  /// Any edit rebuilds (Review enablement) and clears a prior error. The
  /// destination is half of what the fee is priced on, so it re-prices too.
  void _onChanged() {
    setState(() => _error = null);
    _repriceFee();
  }

  BigInt? get _amountSompi => sompiFromKas(_amount);

  String get _destination => _address.text.trim();

  /// Shape only — see [_mainnetAddressLengths].
  bool get _addressLooksValid =>
      _destination.startsWith('kaspa:') &&
      _mainnetAddressLengths.contains(_destination.length);

  /// One handler for BOTH input paths — the pad writes through the controller
  /// exactly as the keyboard does, so there is one place the amount changes.
  void _onAmountChanged() {
    setState(() => _error = null);
    _repriceFee();
  }

  void _key(String ch) => _amount = amountKeyPress(_amount, ch);

  void _backspace() => _amount = amountBackspace(_amount);

  /// The one place a blocked or warned state is decided, in the order the user
  /// would fix it: what is missing, then what the amount cannot be, then the
  /// destination.
  ///
  /// **Every notice carries the exact figure**, because a number is something
  /// the user can act on and "too small" is a shrug. Amber throughout: a
  /// refusal to BUILD puts no money at risk, and red on this screen would say
  /// it did (BG-7).
  ///
  /// **What DISABLES Review, and what only warns, is a deliberate split.**
  ///
  ///  * *Structural* — no amount, no destination, an address that is not the
  ///    shape of a mainnet address: the form cannot be submitted, so it is not.
  ///  * *Arithmetic against a number the wallet itself holds* — an amount above
  ///    the mature balance. That is not a Generator judgement; the wallet's own
  ///    spendable figure is the authority for "you do not have this much", and
  ///    a null balance blocks nothing (BG-8).
  ///  * *The probed KIP-9 floor* — **warns and never blocks.** The floor is a
  ///    Generator judgement, and the Generator on `prepare` is the single
  ///    authority for what can be built (D-054, pinned since the floor
  ///    shipped). A probe that has gone stale HIGH while the screen was open
  ///    would otherwise refuse a send Rust would have made, with no way past —
  ///    a capability taken from exactly the dust-trapped user the floor exists
  ///    to help. So the sentence appears with both figures and the control
  ///    stays live.
  _Block? _blockFor(BigInt? mature, {required bool stale}) {
    final amount = _amountSompi;
    final hasAmount = amount != null && amount > BigInt.zero;
    final hasAddress = _destination.isNotEmpty;

    if (!hasAmount && !hasAddress) {
      return (reason: 'Enter an amount and a destination', notice: null);
    }
    if (!hasAmount) return (reason: 'Enter an amount', notice: null);

    // The floor WARNS and never blocks — but it must not fall out of the
    // function either. Returning here with a null reason handed a live Review
    // to a form with no address at all, because every structural check below
    // was skipped: an advisory branch had quietly become an early exit for the
    // blocking ones (`consensus-auditor`, UX-4). It is CARRIED instead, and
    // whatever blocks below keeps its own reason.
    final min = _minSompi;
    final floorNotice = min != null && amount < min
        ? 'The network will not relay less than ${_trimmed(min)} KAS. You are '
              '${_trimmed(min - amount)} KAS short.'
        : null;

    // BG-8: an unknown balance is never a block, and neither is a STALE one.
    // `mature` is null until the first sync lands, and it is last-known while
    // the link is down — refusing a send, and quoting a figure back as a fact,
    // on a number the wallet cannot currently vouch for would be a fabricated
    // certainty about someone's money.
    if (!stale && mature != null && amount > mature) {
      return (
        reason: 'More than you can spend',
        notice:
            'You have ${_trimmed(mature)} KAS spendable. You are '
            '${_trimmed(amount - mature)} KAS short.',
      );
    }

    if (!hasAddress) {
      return (reason: 'Enter a destination address', notice: floorNotice);
    }
    // An invisible character is the worst possible refusal to read: the
    // address LOOKS right, and the wallet's generic *"that doesn't look like a
    // valid Kaspa address"* sends the user hunting through 67 correct
    // characters (founder, on glass 2026-08-30). Leading and trailing space is
    // trimmed long before here; this is the one in the middle.
    if (hasInnerWhitespace(_destination)) {
      return (
        reason: 'Check the destination address',
        notice:
            'There is a space in that address. A Kaspa address has none — '
            'delete it and the rest is fine.',
      );
    }
    if (!_destination.startsWith('kaspa:')) {
      return (
        reason: 'Check the destination address',
        notice: 'A mainnet Kaspa address starts with "kaspa:".',
      );
    }
    if (!_mainnetAddressLengths.contains(_destination.length)) {
      return (
        reason: 'Check the destination address',
        notice:
            'That is ${_destination.length} characters. A mainnet address is '
            '67 — or 69 for the rarer ECDSA form.',
      );
    }
    // Nothing blocks. The floor's sentence still stands if it fired.
    return floorNotice == null ? null : (reason: null, notice: floorNotice);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      _address.text = text;
      _addressFocus.unfocus();
    }
  }

  Future<void> _review() async {
    final amountSompi = _amountSompi;
    if (amountSompi == null || amountSompi <= BigInt.zero) return;
    await _reviewWith(() => widget.prepare(_destination, amountSompi));
  }

  /// "Send max": the sweep flow — same address field, same ceremony, no amount
  /// (Rust solves it).
  ///
  /// **The chip stays TAPPABLE even before an address is entered**, and
  /// answers with words instead of a silently greyed door. The dust-trapped
  /// user it exists for must never meet a control that will not say what it
  /// needs. That rule moved here with the affordance when D-190 put it beside
  /// `available` — it belongs to the control, not to the corner it used to sit
  /// in.
  Future<void> _reviewSweep() async {
    final prepareSweep = widget.prepareSweep;
    // The chip is never greyed — see the doc above — so the busy guard lives
    // here rather than on `onTap`. A control that looks pressable and is not
    // is the thing BG-12 forbids, and this is the one control on the screen
    // whose whole point is that it answers.
    if (prepareSweep == null || _building) return;
    if (!_addressLooksValid) {
      setState(
        () => _error =
            'Enter the destination address first — no amount is needed to '
            'send everything.',
      );
      return;
    }
    await _reviewWith(() => prepareSweep(_destination));
  }

  Future<void> _reviewWith(
    Future<SignableSummaryDto> Function() prepare,
  ) async {
    setState(() {
      _building = true;
      _error = null;
    });
    try {
      final summary = await prepare();
      if (!mounted) return;
      // The ceremony renders Rust's decode (summary), not the form (B7).
      var leftInFlight = false;
      final outcome = await showSigningCeremony(
        context,
        summary: summary,
        commit: widget.commit,
        abandon: widget.abandon,
        acceptanceStatus: widget.acceptanceStatus,
        onLeftInFlight: () => leftInFlight = true,
      );
      if (!mounted) return;
      // A fully-broadcast send returns to home; the new balance + outgoing row
      // arrive via the live sync (no manual refresh).
      //
      // **So does a send the user walked away from mid-broadcast.** That exit
      // returns `null` like a dismissal does, and leaving them here would
      // restore a form still holding the amount and the address — one tap from
      // a duplicate, right after the ceremony told them to go and check
      // whether it landed. Home is where that activity is
      // (`wallet-security-auditor`, UX-4).
      if (leftInFlight ||
          (outcome != null && !outcome.partial && outcome.error == null)) {
        Navigator.of(context).pop();
      }
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      // `displayError`, never `e.toString()`: on an `AppError` that prints
      // *"Instance of 'AppError'"* — the type name, in the body of a failed
      // send (run 1, F8). The ceremony has always routed through it; this
      // sibling had not.
      if (mounted) setState(() => _error = displayError(e));
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The shortfall sentence is derived from the live balance, so the screen
    // has to be a LISTENER of it and not a reader — a block computed once at
    // build time would go on saying "you are 3 KAS short" after the coins that
    // covered it settled (L132: a derived state whose producer nothing
    // watches).
    return ValueListenableBuilder<BigInt?>(
      valueListenable: widget.mature,
      builder: (context, mature, _) => ValueListenableBuilder<bool>(
        valueListenable: _stale,
        builder: (context, stale, _) =>
            _body(context, _blockFor(mature, stale: stale)),
      ),
    );
  }

  Widget _body(BuildContext context, _Block? block) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            KvRail(title: 'Send', onBack: () => Navigator.of(context).pop()),
            // **The amount block is FIXED and everything else scrolls.**
            // The figure is the subject of this screen and it is being typed:
            // a readout that scrolls out from under the hand typing it is
            // worse than no readout, and at 320dp/1.3× the content is always
            // taller than the viewport. Fixing it here also makes the layout
            // overflow-proof — the scroll absorbs whatever is left, so no
            // geometry can produce a RenderFlex that does not fit (measured:
            // an earlier cut with the PAD pinned overflowed by 133dp at the
            // floor).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                KvSpace.gutter,
                KvSpace.m,
                KvSpace.gutter,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const KvRuledLabel('Amount'),
                  const SizedBox(height: KvSpace.xs),
                  // Tapping the figure takes focus back off the address field
                  // and brings the pad back. Without it the pad is reachable
                  // exactly once: the address field takes focus, our keypad
                  // steps aside for the system IME, and nothing on the screen
                  // gives it back — a control that disappears with no way to
                  // recall it (BG-12's neighbour).
                  _TypedAmount(
                    controller: _amountField,
                    focusNode: _amountFocus,
                    onTapWhileAddressFocused: _addressFocus.unfocus,
                  ),
                  const SizedBox(height: KvSpace.sm),
                  // The datum under a number being typed, with no end stops:
                  // end stops turn a line into a SCALE, and an amount being
                  // entered is not being measured against anything (D-190).
                  Container(height: 1, color: KvColor.datum),
                  const SizedBox(height: KvSpace.s),
                  // **A `Wrap`, not a `Row`.** `available` and `Send max`
                  // belong together — `available` is the number Send max
                  // means (D-190) — but an `Expanded` makes that pairing cost
                  // the figure its width, and a figure is the one thing that
                  // may not reflow (BG-5) or shrink under the 11dp floor
                  // (BG-14). At 320dp/1.3× the chip leaves 157dp against a
                  // seven-figure balance needing 262dp, which a `FittedBox`
                  // "solves" by rendering a 6.7dp reading. Wrapped, the chip
                  // drops to its own run and the figure keeps the gutter.
                  // `spaceBetween` puts `Send max` on the RIGHT EDGE against
                  // `available` on the left (founder, 2026-08-30) — and it is
                  // still a `Wrap`, so the chip drops to its own run rather
                  // than starving the figure at the floor geometry.
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: KvSpace.s,
                    runSpacing: KvSpace.s,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _AvailableLine(mature: widget.mature, stale: _stale),
                      if (widget.prepareSweep != null)
                        _MaxChip(onTap: _reviewSweep),
                    ],
                  ),
                  // **The fee, priced by the Generator over the real coins**,
                  // as the amount is typed. It appears only when there is a
                  // transaction to price and vanishes the instant the amount
                  // changes, so the figure on screen is never one built for a
                  // different amount.
                  //
                  // No `≈`, and that is earned rather than asserted: the probe
                  // runs the SAME two-shape build and the same `shipped_shape`
                  // decision `prepare_send` runs, so the ceremony prints this
                  // number. The first cut priced one shape and claimed the
                  // same thing, and was wrong by up to 0.001118 KAS on the
                  // founder's own wallet (`consensus-auditor`, UX-4B).
                ],
              ),
            ),
            Expanded(
              child: ListView(
                key: SendScreen.scrollTarget,
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
                children: [
                  const SizedBox(height: KvSpace.l),
                  const KvRuledLabel('To'),
                  const SizedBox(height: KvSpace.xs),
                  _AddressField(
                    controller: _address,
                    focusNode: _addressFocus,
                    onPaste: _paste,
                    onClear: () {
                      _address.clear();
                      _addressFocus.unfocus();
                    },
                  ),
                  if (_destination.isNotEmpty && _addressLooksValid) ...[
                    const SizedBox(height: KvSpace.s),
                    // The full-form review (BG-15): the user reads it back
                    // against the source before anything is built.
                    KvAddress(_destination, form: KvAddressForm.chunked),
                  ],

                  // **The notices live in the scroll, never in the pinned
                  // footer.** A notice is a sentence of unbounded length at a
                  // user's chosen text scale, and a pinned footer that can
                  // grow without bound turns the layout into one that
                  // overflows at some geometry — measured at 3dp over at
                  // 320dp/1.3× before this moved. Everything pinned on this
                  // screen is now deterministic in height; everything that is
                  // not is inside the scroll that absorbs it.
                  //
                  // Nothing is lost by it: the disabled control states its own
                  // reason (BG-12) whether or not the notice has been scrolled
                  // to, and the notice sits directly under the field that
                  // caused it.
                  //
                  // Amber throughout, including the build refusal: a send that
                  // could not be BUILT put nothing at risk, and red made a
                  // neutral sentence read as blame (§13).
                  // **The fee sits with the destination it prices** (founder,
                  // on glass 2026-08-30, chosen from the rendered comparison —
                  // D-231). It used to sit in the pinned amount block, above
                  // `To`, which read as a property of the AMOUNT. It is not:
                  // `_probeFee` refuses without both an amount and a valid
                  // address, so the fee is the cost of THIS SEND and belongs
                  // beside the address that makes it one. The third candidate
                  // — last in the scroll, against the Review control — was
                  // rendered and rejected on sight: below the keypad it falls
                  // under the fold, so the number nobody scrolls to is a number
                  // nobody reads.
                  if (_fee != null) ...[
                    const SizedBox(height: KvSpace.sm),
                    _FeeLine(sompi: _fee!),
                  ],
                  if (block?.notice != null) ...[
                    const SizedBox(height: KvSpace.sm),
                    KvStatusChip(
                      tone: KvLampTone.warn,
                      words: block!.notice!,
                      plated: true,
                      maxLines: null,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: KvSpace.sm),
                    KvStatusChip(
                      tone: KvLampTone.warn,
                      words: _error!,
                      plated: true,
                      maxLines: null,
                    ),
                  ],
                  // **The pad steps aside for EITHER system keyboard, and
                  // comes back when it closes** — the address field's, and now
                  // the amount's own (founder, 2026-08-30). Two keyboards at
                  // once is not a layout, and a pad that stayed put under a
                  // rising IME is the clunkiness he asked me to avoid.
                  //
                  // **Keyed off the KEYBOARD, not off focus**, and the
                  // difference is the whole second half of the request. Back
                  // dismisses the IME without dropping focus, so a
                  // `hasFocus` predicate left the pad hidden with the keyboard
                  // already gone: a dead void where the digits should be. The
                  // comment above said "comes back when it closes" while the
                  // code could not do it — found on glass, 2026-08-30.
                  // `viewInsetsOf` also rebuilds as the IME animates, so the
                  // pad yields the moment it starts rising rather than after
                  // it has arrived.
                  //
                  // `AnimatedSize` on the one easing so the swap reads as the
                  // pad making room rather than blinking out; the IME's own
                  // rise runs over the top of it.
                  AnimatedSize(
                    duration: KvMotion.calm,
                    curve: KvMotion.out,
                    alignment: Alignment.topCenter,
                    child: MediaQuery.viewInsetsOf(context).bottom > 0
                        ? const SizedBox(width: double.infinity)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: KvSpace.l),
                              KvKeypad.amount(
                                onChar: _key,
                                onBackspace: _backspace,
                              ),
                            ],
                          ),
                  ),
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
              child: Column(
                children: [
                  KvAction(
                    label: 'Review this send',
                    primary: !_building,
                    disabledReason: _building
                        ? 'Building your transaction…'
                        : block?.reason,
                    onTap: _review,
                  ),
                  if (block?.reason == null && !_building) ...[
                    const SizedBox(height: KvSpace.s),
                    const Text(
                      'Nothing is signed until you hold to send.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 11,
                        height: 15 / 11,
                        color: KvColor.inkMetaLow,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A KAS figure for this screen's copy.
///
/// **Every significant digit and no trailing zeros** (D-210). BG-6's fixed
/// eight belong to a signing surface, and this screen signs nothing — its own
/// header says so — while the padding is noise a user has to read past to
/// find where the number ends, and it is what made `available` too wide to
/// render at a readable size.
///
/// A shortfall keeps every digit that carries value either way, because
/// [trimFraction] only ever removes zeros: *"you are 0.00001994 KAS short"*
/// survives verbatim (D-189), and *"2.40000000"* becomes *"2.40"*.
String _trimmed(BigInt sompi) {
  final p = kasParts(sompi);
  return '${p.integer}.${trimFraction(p.fraction)}';
}

/// The live fee, in the same face the ceremony prints it in.
///
/// **A `KvAmount`, not a formatted string** (D-230). It used to be
/// `Text('network fee 0.003154')` in mono, which meant BG-23's emphasis rule
/// reached the ceremony and not the screen the number is first read on — the
/// same figure wearing two faces, which is BG-21. Trimmed rather than padded to
/// eight: this is a live datum under the precision law (D-210), not BG-6's
/// restatement of what was built.
class _FeeLine extends StatelessWidget {
  const _FeeLine({required this.sompi});

  final BigInt sompi;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        const Text(
          'network fee ',
          maxLines: 1,
          style: TextStyle(
            fontFamily: KvFont.mono,
            fontSize: 12,
            height: 16 / 12,
            color: KvColor.inkMetaLow,
          ),
        ),
        KvAmount(
          sompi,
          role: KvAmountRole.row,
          size: 12,
          emphasis: KvAmountEmphasis.significant,
        ),
      ],
    );
  }
}

/// The amount, as an editable field that looks like the figure it is.
///
/// **Two input paths, one source of truth.** Tapping it raises the DEVICE's
/// number keyboard and the on-screen pad steps aside; dismissing the keyboard
/// brings the pad back. Both write the same [TextEditingController], so they
/// cannot disagree about what has been typed, and the pad remains the default
/// — this narrows D-189, it does not reverse it (see [SendScreen]'s field).
///
/// **The grammar is enforced on both.** The formatter below refuses anything
/// [sompiFromKas] would refuse, so a system keyboard cannot type a second
/// decimal point, a ninth decimal, or a figure past the `u64` sompi ceiling
/// that the pad already refuses at the keystroke. One law, two doors.
///
/// It scales down rather than wrapping or clipping (BG-5) — a figure is the
/// one thing on a screen that may not reflow (L131/BG-14) — and the unit sits
/// OUTSIDE that fit so its 11dp floor survives the scale.
class _TypedAmount extends StatelessWidget {
  const _TypedAmount({
    required this.controller,
    required this.focusNode,
    required this.onTapWhileAddressFocused,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onTapWhileAddressFocused;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: IntrinsicWidth(
                child: TextField(
                  key: SendScreen.amountTarget,
                  controller: controller,
                  focusNode: focusNode,
                  onTap: onTapWhileAddressFocused,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: const [_AmountGrammar()],
                  maxLines: 1,
                  cursorColor: KvColor.primary,
                  // A placeholder `0`, not a fabricated `0.00000000`: nothing
                  // has been entered, and eight zeros would look like an
                  // amount.
                  decoration: const InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: '0',
                    hintStyle: TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 32,
                      height: 38 / 32,
                      fontWeight: FontWeight.w500,
                      color: KvColor.inkMeta,
                    ),
                  ),
                  style: const TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 32,
                    height: 38 / 32,
                    fontWeight: FontWeight.w500,
                    color: KvColor.ink,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: KvSpace.s),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'KAS',
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: KvAmount.readableFloor,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.6,
              color: KvColor.primaryMuted,
            ),
          ),
        ),
      ],
    );
  }
}

/// The money-entry grammar, enforced on the SYSTEM keyboard.
///
/// The on-screen pad refuses an illegal keystroke at the key ([amountKeyPress]);
/// this refuses the same things at the field, so a device keyboard cannot type
/// a second decimal point, a ninth decimal, or a figure past the `u64` sompi
/// ceiling. Rejecting means keeping the previous value — the character simply
/// does not appear, which is what the pad does too.
class _AmountGrammar extends TextInputFormatter {
  const _AmountGrammar();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    // Empty and a lone trailing point are legal *intermediate* states that
    // `sompiFromKas` rejects as final values — the user is mid-way through
    // typing `0.` and has not said anything wrong yet.
    if (text.isEmpty || text == '0.' || text == '.') return newValue;
    return sompiFromKas(text) == null ? oldValue : newValue;
  }
}

/// "available N" — the spendable (mature) balance, informational only. It sits
/// with Send max because that is the number Send max means (D-190).
///
/// **All three of BG-8's states.** `—` when unknown, dimmed with the reason in
/// words when the figure is last-known, full brightness only when the link is
/// up. The AGE that BG-8 pairs with a dimmed reading is deliberately absent
/// and recorded as a divergence in `design_system.md` §9 rather than argued
/// away here: an age belongs to the line that vouches for the number, and this
/// screen carries no trust line.
///
/// **It never clips and never shrinks under the readable floor.** It sat in a
/// `Row` with `Send max`, which at 320dp/1.3× left 157dp against a figure
/// needing 262dp — first as a silent clip that showed a *smaller, different*
/// number (BG-5, L131 exactly), then as a `FittedBox` rendering the balance at
/// 6.7dp. Both found by `ux-auditor`; both invisible to the `TextPainter`
/// guard, the first because it measured a layout without `Send max` and the
/// second because a `Text` inside a `FittedBox` never exceeds its lines. The
/// cure is width, not scale: the figure keeps the gutter and the chip wraps.
class _AvailableLine extends StatelessWidget {
  const _AvailableLine({required this.mature, required this.stale});

  final ValueListenable<BigInt?> mature;
  final ValueListenable<bool> stale;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BigInt?>(
      valueListenable: mature,
      builder: (context, value, _) => ValueListenableBuilder<bool>(
        valueListenable: stale,
        builder: (context, isStale, _) {
          const style = TextStyle(
            fontFamily: KvFont.mono,
            fontSize: 12,
            height: 16 / 12,
            color: KvColor.inkMetaLow,
            fontFeatures: [FontFeature.tabularFigures()],
          );
          // BG-8: `—` while it is unknown, never a fabricated zero. D-210:
          // every significant digit and no trailing zeros — this screen signs
          // nothing, so the fixed eight are not its exception to claim, and
          // the padding is what made the figure too wide to read.
          final figure = value == null
              ? 'available —'
              : 'available ${_trimmed(value)}';
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedOpacity(
                opacity: value != null && isStale
                    ? KvFreshness.opacityStale
                    : 1,
                duration: KvMotion.instant,
                curve: KvMotion.out,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    figure,
                    maxLines: 1,
                    softWrap: false,
                    style: style,
                  ),
                ),
              ),
              // The freshness clause is a SENTENCE and gets its own line, so
              // it never eats the figure's width: BG-14 forbids a number from
              // reflowing, not a clause. Words as well as opacity, so the
              // state survives greyscale and a screen reader.
              if (value != null && isStale)
                Text(
                  'not live — last known',
                  style: style.copyWith(fontFamily: KvFont.ui),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Send max. A chip rather than a button because it fills a field — it commits
/// nothing.
class _MaxChip extends StatelessWidget {
  const _MaxChip({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Send the maximum, leaving only the fee',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KvRadius.control),
        // **No `height`, no `alignment` — and that is the whole fix.**
        // `KvSurface` is a `Container`, and a `Container` given an `alignment`
        // EXPANDS to its incoming constraints. In the old `Row` the chip sat
        // beside an `Expanded` and got only the leftover; in the `Wrap` that
        // cured the figure's shrink it is handed the whole gutter, so it
        // rendered as a full-width button — a second primary action competing
        // with the one teal control, which inverts D-190's reason for putting
        // it here (found on glass, device sitting 2026-08-30).
        //
        // Symmetric vertical padding reaches the 48dp target without a fixed
        // height: a 16dp line box plus 2 × 16 is exactly `touchTarget`, and it
        // grows with the text scale instead of clipping.
        child: KvSurface.control(
          // **A teal edge, by founder request (D-223).** BG-2 rations teal to
          // three emitting objects and gives a FILL only to the one primary
          // action; an edge is neither a fill nor a lit lamp, and `Send max`
          // is the one control on this screen that fills the field the user is
          // about to commit. Recorded because a teal outline on a secondary
          // control is the kind of thing an auditor should find decided rather
          // than drifted.
          edge: KvColor.primaryMuted,
          padding: const EdgeInsets.symmetric(
            horizontal: KvSpace.m,
            vertical: KvSpace.m,
          ),
          child: const Text(
            'Send max',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 12,
              height: 16 / 12,
              fontWeight: FontWeight.w600,
              color: KvColor.inkBright,
            ),
          ),
        ),
      ),
    );
  }
}

/// The destination field: paste on the left, the address, clear on the right.
///
/// **It stays typable, and the system keyboard is the right one for it.** The
/// no-system-IME law protects SECRETS (§0.7/INV-3) and the amount pad exists
/// for muscle memory (D-189); an address is public data, and a field that
/// could only be pasted into would cost a user reading one off paper the
/// ability to send at all — a sovereignty control must never remove a
/// capability (BG-17's rule, applied one surface over).
///
/// **There is no scan affordance**, and its absence is deliberate: no QR
/// scanner is built, and a control that looks pressable and does nothing is
/// exactly what BG-12 forbids. The prototype drew one; drawing it here would
/// have been a promise the app cannot keep.
class _AddressField extends StatelessWidget {
  const _AddressField({
    required this.controller,
    required this.focusNode,
    required this.onPaste,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onPaste;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return KvSurface.control(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s),
      child: Row(
        children: [
          const SizedBox(width: KvSpace.s),
          Expanded(
            child: TextField(
              key: SendScreen.addressTarget,
              controller: controller,
              focusNode: focusNode,
              minLines: 1,
              maxLines: 2,
              style: const TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 13,
                height: 20 / 13,
                color: KvColor.ink,
              ),
              // The field IS the container; a second painted fill and outline
              // inside its own pill is the defect UX-3 found on the explorer
              // rows (theme `applyDefaults` reaching into a styled field).
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: KvSpace.sm),
                hintText: 'Paste a Kaspa address',
                hintStyle: TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 13,
                  height: 20 / 13,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            Semantics(
              button: true,
              label: 'Clear the destination address',
              child: InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(KvRadius.control),
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: KvSpace.touchTarget,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: KvSpace.s),
                  alignment: Alignment.center,
                  child: const Text(
                    'Clear',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: KvColor.primaryMuted,
                    ),
                  ),
                ),
              ),
            ),
          // **Paste sits on the RIGHT** and the hint gets the left edge
          // (founder, 2026-08-30). It is the field's one action, and an action
          // reads as an action at the end of the thing it acts on; on the left
          // it competed with the placeholder for the eye.
          _FieldAction(
            mark: KvMark.paste,
            label: 'Paste an address',
            onTap: onPaste,
          ),
        ],
      ),
    );
  }
}

/// A glyph inside the address field: **20 dp of glyph in a 48×48 target.**
class _FieldAction extends StatelessWidget {
  const _FieldAction({
    required this.mark,
    required this.label,
    required this.onTap,
  });

  final KvMark mark;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KvRadius.chip),
        child: SizedBox(
          width: KvSpace.touchTarget,
          height: KvSpace.touchTarget,
          child: Center(
            child: KvGlyphIcon(mark, size: 20, tone: KvColor.inkMeta),
          ),
        ),
      ),
    );
  }
}
