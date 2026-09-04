import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/error.dart';
import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../error_text.dart';
import '../format.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_amount.dart';
import '../widgets/kv_check.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_contact.dart';
import '../widgets/kv_fiat.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_two_pane.dart';
import '../widgets/kv_keypad.dart';
import '../widgets/kv_status_chip.dart';
import 'signing_ceremony.dart';

/// Send — **two steps, and nothing signs on either** (`S6a` · `S6b` · `S6`).
///
/// Step 1 is who; step 2 is how much; the ceremony is step 3 and it is the only
/// place a signature happens. The split is the founder-approved render's, and
/// it earns itself twice over: the address is the half a user must *check*, and
/// giving it a screen of its own means the check is not competing with a keypad
/// for the same glance — and the amount step can then restate the destination
/// as a settled fact above the figure rather than as a field still being edited.
///
/// Entry is cheap and reversible, so the screen stays light: no ceremony, no
/// warnings, no friction proportional to a risk that has not been taken yet
/// (D-189). Every blocked state says why **in amber with the exact number** —
/// *"you are 0.00001994 KAS short"*, never *"too small"*. Red would claim money
/// is at risk when none is (BG-7), and a disabled control always says why
/// (BG-12).
///
/// The amount pad is [KvKeypad] in its plain skin — the same primitive that
/// takes a passphrase. One muscle memory, one codepath to audit, and the amount
/// inherits the no-system-keyboard guarantee for free.
///
/// "Review" builds the transaction(s) in Rust and opens the anti-blind-signing
/// [SigningCeremony] — the amount and fee the user approves are Rust's decode of
/// the actual transactions, never this form's echo (B7).
///
/// ## What this screen does NOT draw, and why
///
///  * **No scan button.** `S6a` seats one on the field. The founder ruled the
///    scanner into its own sitting (2026-09-04) because a camera is a new
///    dependency and a new permission; §8 forbids a control that answers a tap
///    and does nothing, so the seat stays empty until it works.
///  * **No `RECENT` tab on the contacts card, and no "you last sent here"
///    date.** `S6a` heads the card `RECENT` with a `Contacts` link opposite and
///    `S6b` dates the match. Both need a counterparty on `ActivityRecord`
///    (§9.15/§9.31/§9.32), which does not exist — and a date is exactly the
///    corroborating detail that must not be invented on a surface a user is
///    about to trust with money. The card itself, *Save as contact* and the
///    match line all ship (D-268).
///  * **No fee tier.** `S6` draws `Network fee · Standard ›` with a chevron.
///    The bridge prices one fee — the Generator's — and there is no tier to
///    pick, so the row is a **reading** and not a control: no chevron, no tap.
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
    this.explorerUrl,
    this.openUrl,
    this.fiat,
    this.contacts,
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

  /// The receipt's explorer exit (UX-5), forwarded to the ceremony. Resolved in
  /// **Rust** — the template is validated there and no URL is built on this
  /// side — and opened by the platform channel the app already owns. Null hides
  /// the exit, which is what replaced D-223's knowingly-suspended placeholder.
  final Future<String> Function(String txid)? explorerUrl;

  final Future<bool> Function(String url)? openUrl;

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

  /// The `≈` restatement under the figure being typed (`S6`), and under the
  /// ceremony's restatement of it (`S7`).
  ///
  /// **Fiat on a spend surface is a founder ruling** (2026-09-04) that
  /// withdrew BG-5's *"never on a spend"* clause. The clause existed because a
  /// second figure beside the one that matters can only compete with it; what
  /// answers that is subordination, which `KvFiatLine` carries on every seat
  /// — half the scale, `inkMeta`, and its age the moment it could mislead.
  /// The safety half of BG-5 is untouched: fiat never prices a fee, never
  /// sizes a spend, and is never what a signature commits to.
  ///
  /// Null ⇒ no rate seam is wired and no line is drawn.
  final FiatScope? fiat;

  /// The address book (`S6a` · `S6b`). Null ⇒ no contacts card, no name on the
  /// recipient row, and no *Save as contact* — every one of which is an
  /// addition to the screen, so its absence costs nothing that was there.
  final ContactsScope? contacts;

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
  /// Which step is on screen. **Two, and the ceremony is the third** — the
  /// counter in the bar counts all three, because a user who has been through
  /// the flow once should be able to tell from the bar how far they are from
  /// the thing that signs.
  int _step = 0;

  /// The typed amount, canonical and ungrouped — exactly what [sompiFromKas]
  /// parses. Never a formatted string.
  String get _amount => _amountField.text;
  set _amount(String v) => _amountField.text = v;

  /// The amount as an editable field, so the DEVICE keyboard can take over when
  /// the figure is tapped (founder, 2026-08-30).
  ///
  /// **This narrows D-189 rather than reversing it.** The on-screen pad stays
  /// the default and stays the same primitive the passphrase keyboard uses —
  /// the muscle memory and the one-codepath audit both survive. What changes is
  /// that an amount may ALSO be typed on the system keyboard, which costs
  /// nothing that mattered: the no-system-IME law is INV-3's, and it protects
  /// SECRETS. An amount is not one.
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
  /// nothing buildable to price **or while a fresh probe is in flight**.
  BigInt? _fee;

  /// **The last fee the Generator actually quoted**, held across a re-price so
  /// the row can keep showing a figure while the next one is being priced.
  ///
  /// The row used to clear to `—` on every keystroke and fill in 250 ms later,
  /// which is what the founder saw and objected to twice: *"it disappears and
  /// comes back withing tiny milliseconds."* No animation could fix that,
  /// because the figure genuinely left.
  ///
  /// **It is not shown as if it were current.** While `_fee` is null and this
  /// is not, the row dims the figure — the value drops to the tone of its own
  /// label — so what is on screen is visibly *not the answer to what you just
  /// typed*. When the answer lands the figure brightens and its digits roll
  /// to the new ones, which is the arrival the founder asked for and also the
  /// only moment the row claims to be current.
  ///
  /// It is cleared the instant there is nothing to price, so an emptied field
  /// shows the dash rather than the fee of an amount that no longer exists.
  BigInt? _lastFee;
  Timer? _feeDebounce;

  /// Guards against an out-of-order answer overwriting a newer one: every
  /// request carries a token and only the latest may land. Without it a slow
  /// probe for `1` can return after a fast probe for `12` and leave the screen
  /// showing the fee for an amount the user has already moved past — a true
  /// number against the wrong figure, which is worse than none.
  int _feeToken = 0;

  /// Long enough that a run of keystrokes makes ONE probe, short enough that
  /// the figure feels live. The probe builds a real transaction chain, so it is
  /// not free.
  static const Duration _feeDebounceFor = Duration(milliseconds: 250);

  /// Re-price what is typed now. Clears the fee first, because a fee that
  /// lingers beside a changed amount is a lie for as long as it lingers.
  void _repriceFee() {
    final probe = widget.feePreview;
    _feeDebounce?.cancel();
    final token = ++_feeToken;
    if (_fee != null) setState(() => _fee = null);
    final amount = _amountSompi;
    if (probe == null || amount == null || amount <= BigInt.zero) {
      // Nothing to price at all: the row goes back to BG-8's dash rather than
      // holding a figure for an amount that no longer exists.
      if (_lastFee != null) setState(() => _lastFee = null);
      return;
    }
    if (!_addressLooksValid) {
      if (_lastFee != null) setState(() => _lastFee = null);
      return;
    }
    final destination = _destination;
    _feeDebounce = Timer(_feeDebounceFor, () async {
      try {
        final fee = await probe(destination, amount);
        if (mounted && token == _feeToken) {
          setState(() {
            _fee = fee;
            _lastFee = fee;
          });
        }
      } catch (_) {
        // No fee is a real answer; a failed probe is not a number.
      }
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(widget.contacts?.refresh() ?? Future<void>.value());
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
    // freshness bit nobody updates.
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

  /// Any edit rebuilds and clears a prior error. The destination is half of
  /// what the fee is priced on, so it re-prices too.
  void _onChanged() {
    setState(() => _error = null);
    _repriceFee();
  }

  BigInt? get _amountSompi => sompiFromKas(_amount);

  String get _destination => _address.text.trim();

  /// Shape only — see [mainnetAddressLengths].
  bool get _addressLooksValid =>
      _destination.startsWith('kaspa:') &&
      mainnetAddressLengths.contains(_destination.length) &&
      !hasInnerWhitespace(_destination);

  /// One handler for BOTH input paths — the pad writes through the controller
  /// exactly as the keyboard does, so there is one place the amount changes.
  void _onAmountChanged() {
    setState(() => _error = null);
    _repriceFee();
  }

  void _key(String ch) => _amount = amountKeyPress(_amount, ch);

  void _backspace() => _amount = amountBackspace(_amount);

  /// Fill the field with a share of the spendable balance. **An entry aid, not
  /// an authority**: `prepare` still decides whether what it produced can be
  /// built, and the fee comes out of it rather than off it — which is why 100 %
  /// is not one of these and is [_reviewSweep] instead.
  void _fraction(BigInt mature, int percent) {
    final part = mature * BigInt.from(percent) ~/ BigInt.from(100);
    // **`kasCanonical`, never `kasParts().integer`** — the latter is grouped
    // for the eye and `sompiFromKas` rejects a comma, so a grouped write froze
    // the field at any balance over 1,000 KAS (`consensus-auditor`, UX-R2).
    // Truncating division floors, so a fraction can never exceed the balance.
    _amount = kasCanonical(part);
  }

  /// **Step 1's block** — what is wrong with the destination, in the order a
  /// user would fix it.
  ///
  /// An invisible character is the worst possible refusal to read: the address
  /// LOOKS right, and a generic *"that doesn't look valid"* sends the user
  /// hunting through 67 correct characters (founder, on glass 2026-08-30).
  _Block? _addressBlock() {
    if (_destination.isEmpty) {
      return (reason: 'Enter an address to continue', notice: null);
    }
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
    if (!mainnetAddressLengths.contains(_destination.length)) {
      return (
        reason: 'Check the destination address',
        notice:
            'That is ${_destination.length} characters. A mainnet address is '
            '67 — or 69 for the rarer ECDSA form.',
      );
    }
    return null;
  }

  /// **Step 2's block**, and the deliberate split between what refuses and what
  /// only warns.
  ///
  ///  * *Structural* — no amount: the form cannot be submitted, so it is not.
  ///  * *Arithmetic against a number the wallet itself holds* — an amount above
  ///    the mature balance. That is not a Generator judgement; the wallet's own
  ///    spendable figure is the authority for "you do not have this much", and
  ///    a null **or stale** balance blocks nothing (BG-8): refusing a send, and
  ///    quoting a figure back as a fact, on a number the wallet cannot vouch
  ///    for would be a fabricated certainty about someone's money.
  ///  * *The probed KIP-9 floor* — **warns and never blocks.** The floor is a
  ///    Generator judgement and the Generator on `prepare` is the single
  ///    authority for what can be built (D-054). A probe gone stale HIGH would
  ///    otherwise refuse a send Rust would have made, with no way past — a
  ///    capability taken from exactly the dust-trapped user the floor exists to
  ///    help. So the sentence appears with both figures and the control stays
  ///    live.
  _Block? _amountBlock(BigInt? mature, {required bool stale}) {
    final amount = _amountSompi;
    final hasAmount = amount != null && amount > BigInt.zero;
    if (!hasAmount) return (reason: 'Enter an amount', notice: null);

    // The floor WARNS and never blocks — but it must not fall out of the
    // function either. It is CARRIED, and whatever blocks below keeps its own
    // reason: an advisory branch that returns early is an advisory branch that
    // has quietly become an exit for the blocking ones (`consensus-auditor`,
    // UX-4).
    final min = _minSompi;
    final floorNotice = min != null && amount < min
        ? 'The network will not relay less than ${_trimmed(min)} KAS. You are '
              '${_trimmed(min - amount)} KAS short.'
        : null;

    if (!stale && mature != null && amount > mature) {
      return (
        reason: 'More than you can spend',
        notice:
            'You have ${_trimmed(mature)} KAS spendable. You are '
            '${_trimmed(amount - mature)} KAS short.',
      );
    }
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

  /// Step 1 → step 2. The address is settled from here on and is restated at
  /// the head of step 2 as a fact rather than a field; **Edit** comes back.
  void _continue() {
    if (_addressBlock() != null) return;
    _addressFocus.unfocus();
    setState(() => _step = 1);
    _repriceFee();
  }

  void _back() {
    if (_step == 0) {
      Navigator.of(context).pop();
    } else {
      _amountFocus.unfocus();
      setState(() => _step = 0);
    }
  }

  /// Fill the field from the address book (`S6a`).
  ///
  /// It **fills the field rather than skipping to step 2**, deliberately. The
  /// contact row is a shortcut for typing 67 characters, not a shortcut past
  /// checking them: the address lands in the field, the checked line and its
  /// mark appear over it exactly as they do for a paste, and Continue is still
  /// a deliberate tap. A tap that jumped straight to the keypad would make a
  /// stale or poisoned book the last word on where money goes.
  void _pickContact(String address) {
    _address.text = address;
    _addressFocus.unfocus();
  }

  /// Name the address currently in the field (`S6b`'s *Save as contact*), or
  /// rename one that already has a name.
  Future<void> _saveContact() async {
    final scope = widget.contacts;
    if (scope == null) return;
    final address = _destination;
    final name = await showContactNameSheet(
      context,
      address: address,
      initial: scope.nameFor(address),
    );
    if (name == null || !mounted) return;
    try {
      await scope.save(address, name);
    } catch (e) {
      // A failed save is a failed save — it is not a send, and it must not
      // read like one. The screen's own error slot says so and the address in
      // the field is untouched.
      if (mounted) setState(() => _error = displayError(e));
    }
  }

  Future<void> _review() async {
    final amountSompi = _amountSompi;
    if (amountSompi == null || amountSompi <= BigInt.zero) return;
    await _reviewWith(() => widget.prepare(_destination, amountSompi));
  }

  /// "Max": the sweep flow — same address, same ceremony, **no amount** (Rust
  /// solves it, because the amount depends on the fee of the transaction
  /// spending it and the field's number can never be right).
  ///
  /// **The chip stays tappable even before an address is entered**, and answers
  /// with words instead of a silently greyed door. The dust-trapped user it
  /// exists for must never meet a control that will not say what it needs.
  Future<void> _reviewSweep() async {
    final prepareSweep = widget.prepareSweep;
    // The chip is never greyed — see above — so the busy guard lives here
    // rather than on `onTap`.
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
      var another = false;
      final outcome = await showSigningCeremony(
        context,
        summary: summary,
        commit: widget.commit,
        abandon: widget.abandon,
        acceptanceStatus: widget.acceptanceStatus,
        onLeftInFlight: () => leftInFlight = true,
        explorerUrl: widget.explorerUrl,
        openUrl: widget.openUrl,
        // The ceremony draws the same price and the same name this screen
        // does — one scope, forwarded, so the two surfaces cannot disagree
        // about who the recipient is or what the amount is worth.
        fiat: widget.fiat,
        contacts: widget.contacts,
        onSendAnother: () {
          another = true;
          _sendAnother();
        },
      );
      if (!mounted) return;
      // **Send another resets the form rather than leaving it standing.** The
      // receipt's own action already popped the ceremony; what must not happen
      // is the pop below, which would take the user home one tap after they
      // asked to stay — and what must not happen either is a form still
      // holding the address and amount of a send that just went out, which is
      // one tap from a duplicate (`wallet-security-auditor`, UX-4).
      if (another) return;
      // A fully-broadcast send returns to home; the new balance + outgoing row
      // arrive via the live sync (no manual refresh).
      //
      // **So does a send the user walked away from mid-broadcast.** That exit
      // returns `null` like a dismissal does, and leaving them here would
      // restore a form still holding the amount and the address — one tap from
      // a duplicate, right after the ceremony told them to go and check whether
      // it landed. Home is where that activity is.
      if (leftInFlight ||
          (outcome != null && !outcome.partial && outcome.error == null)) {
        Navigator.of(context).pop();
      }
    } on AppError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      // `displayError`, never `e.toString()`: on an `AppError` that prints
      // *"Instance of 'AppError'"* — the type name, in the body of a failed
      // send (run 1, F8).
      if (mounted) setState(() => _error = displayError(e));
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  /// Back to an empty step 1, with nothing carried over from the send that
  /// just landed.
  void _sendAnother() {
    _address.clear();
    _amountField.clear();
    setState(() {
      _step = 0;
      _fee = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The shortfall sentence is derived from the live balance, so the screen
    // has to be a LISTENER of it and not a reader — a block computed once at
    // build time would go on saying "you are 3 KAS short" after the coins that
    // covered it settled (L132).
    return ValueListenableBuilder<BigInt?>(
      valueListenable: widget.mature,
      builder: (context, mature, _) => ValueListenableBuilder<bool>(
        valueListenable: _stale,
        builder: (context, stale, _) => PopScope(
          // System back walks the steps before it leaves the screen.
          canPop: _step == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _step > 0) _back();
          },
          child: Scaffold(
            backgroundColor: KvColor.abyss,
            // **The system inset, and nothing more** (§9.22, D-262).
            body: SafeArea(
              child: Column(
                children: [
                  KvTopBar(
                    title: 'Send',
                    onBack: _back,
                    // `S6` seats the step counter at the right of the bar. It
                    // is drawn on both steps, not only the second: a counter
                    // that appears halfway through reads as a defect, and one
                    // fact has one face (BG-21).
                    trailing: Text(
                      '${_step + 1}/3',
                      style: const TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 13,
                        height: 18 / 13,
                        fontWeight: FontWeight.w500,
                        fontVariations: KvWeight.w500,
                        color: KvColor.inkMeta,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  // **One column, clamped at 560 and centred** (BG-33): a
                  // wider window gains columns with jobs, never a wider
                  // keypad. The gutter is the class's, not the constant.
                  Expanded(
                    child: KvColumn(
                      gutter: false,
                      // **Nothing appears or vanishes without the motion that
                      // accounts for it** (BG-24). The step slides the way it
                      // is going — forward from the right, back from the left
                      // — on the one curve, so *Continue* and *Edit* read as
                      // the same journey in two directions rather than as two
                      // screens swapping places.
                      child: AnimatedSwitcher(
                        duration: KvMotion.enter,
                        switchInCurve: KvMotion.curve,
                        switchOutCurve: KvMotion.curve,
                        transitionBuilder: (child, animation) {
                          final forward =
                              (child.key as ValueKey<int>).value == _step;
                          final from = (forward == (_step == 1)) ? 0.06 : -0.06;
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: Offset(from, 0),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            for (final old in previous)
                              Positioned.fill(child: old),
                            ?current,
                          ],
                        ),
                        child: KeyedSubtree(
                          key: ValueKey<int>(_step),
                          child: _step == 0
                              ? _recipientStep()
                              : _amountStep(mature, stale: stale),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Step 1 · who ────────────────────────────────────────────────────────

  Widget _recipientStep() {
    final block = _addressBlock();
    final valid = _addressLooksValid;
    final gutter = KvWindow.of(context).gutter;
    return Column(
      children: [
        Expanded(
          child: ListView(
            key: SendScreen.scrollTarget,
            padding: EdgeInsets.symmetric(horizontal: gutter),
            children: [
              const SizedBox(height: KvSpace.m),
              const _Caps('TO'),
              const SizedBox(height: KvSpace.s10),
              _AddressField(
                controller: _address,
                focusNode: _addressFocus,
                valid: valid,
                onPaste: _paste,
                onClear: () {
                  _address.clear();
                  _addressFocus.unfocus();
                },
              ),
              const SizedBox(height: KvSpace.sm),
              if (valid)
                _CheckedLine(
                  address: _destination,
                  contacts: widget.contacts,
                  onSave: _saveContact,
                )
              else
                const Text(
                  // The render promises that a `kaspa:` link with an amount
                  // fills both steps. No such link format exists in this
                  // project's evidence base — no KCC defines one — so the
                  // sentence says only what the app actually does. The link
                  // lands with the scanner, whose sitting decides the format
                  // (founder, 2026-09-04).
                  'Paste reads your clipboard once, when you tap. Check the '
                  'first and last characters against where you got it.',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 14,
                    height: 20 / 14,
                    color: KvColor.inkMeta,
                  ),
                ),
              // Amber, never red: a destination that will not parse puts no
              // money at risk, and red would say it did (BG-7).
              if (block?.notice != null) ...[
                const SizedBox(height: KvSpace.sm),
                KvStatusChip(
                  tone: KvLampTone.warn,
                  words: block!.notice!,
                  plated: true,
                  maxLines: null,
                ),
              ],
              // **The address book** (`S6a`). Hidden while an address is being
              // checked: the card is a way of FILLING the field, and a list of
              // other people to send to, sitting under an address the user is
              // in the middle of verifying, is an invitation to tap the wrong
              // one.
              // **This screen's error slot, on the step that can produce one.**
              // `_saveContact` writes `_error` and only `_amountStep` rendered
              // it, so a failed *Save as contact* on step 1 was a control that
              // answered a tap and did nothing — §8's one outright prohibition
              // (`ux-auditor`, UX-R2B).
              if (_error != null) ...[
                const SizedBox(height: KvSpace.sm),
                KvStatusChip(
                  tone: KvLampTone.warn,
                  words: _error!,
                  plated: true,
                  maxLines: null,
                ),
              ],
              // It arrives and leaves on the one easing (BG-24): a 240 dp card
              // cutting in when the read answers, or out on the first
              // keystroke, is exactly the change this rule exists to account
              // for.
              AnimatedSize(
                duration: KvMotion.calm,
                curve: KvMotion.curve,
                alignment: Alignment.topCenter,
                child: !valid && _address.text.trim().isEmpty
                    ? _ContactsCard(
                        contacts: widget.contacts,
                        onPick: _pickContact,
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: KvSpace.l),
            ],
          ),
        ),
        _Foot(
          gutter: gutter,
          child: KvAction(
            label: 'Continue to amount',
            primary: true,
            // The reason rides INSIDE the pill (`S6a`): a screen whose only
            // control is this one has nowhere quieter to put it, and the
            // footprint stays constant as the address is fixed.
            inlineReason: true,
            disabledReason: block?.reason,
            onTap: _continue,
          ),
        ),
      ],
    );
  }

  // ── Step 2 · how much ───────────────────────────────────────────────────

  Widget _amountStep(BigInt? mature, {required bool stale}) {
    final block = _amountBlock(mature, stale: stale);
    final gutter = KvWindow.of(context).gutter;
    // **Keyed off the KEYBOARD, not off focus**: Back dismisses the IME without
    // dropping focus, so a `hasFocus` predicate left the pad hidden with the
    // keyboard already gone — a dead void where the digits should be (found on
    // glass). `viewInsetsOf` also rebuilds as the IME animates, so the pad
    // yields the moment it starts rising rather than after it has arrived.
    final imeUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Column(
      children: [
        Expanded(
          child: ListView(
            key: SendScreen.scrollTarget,
            padding: EdgeInsets.symmetric(horizontal: gutter),
            children: [
              const SizedBox(height: KvSpace.s),
              _RecipientRow(
                address: _destination,
                contacts: widget.contacts,
                onEdit: _back,
              ),
              // **The block sits higher, so the amber notice has room above
              // the pad** (founder, on glass 2026-09-04: *"shift the input
              // amount up a tiny little bit alongside things below it… so
              // that when the amber notice pops up, some parts of it below
              // doesnt go below the keypad"*). 32 → 20 here, and the gaps
              // under the figure tighten with it: the section is the same
              // content in less height, which is the only way the notice
              // gains room without the pad moving.
              const SizedBox(height: KvSpace.s20),
              // **The figure is the subject of this screen**, and it is being
              // typed: mono 56 (`S6`, measured — cap 41.0 dp against the
              // keypad's 22 dp calibration), which is a step above the balance
              // hero because a balance is read and this is written.
              _TypedAmount(controller: _amountField, focusNode: _amountFocus),
              const SizedBox(height: KvSpace.s),
              // The `≈` price, under the figure it restates (`S6`, founder
              // 2026-09-04). It reads the typed amount, so the two can never
              // disagree, and it renders nothing at all when no rate is wired
              // or the user has switched fiat off.
              KvFiatLine(
                fiat: widget.fiat,
                sompi: _amountSompi,
                alignment: MainAxisAlignment.center,
              ),
              const SizedBox(height: KvSpace.s14),
              _Shares(
                mature: widget.mature,
                stale: _stale,
                onFraction: (pc) {
                  final m = mature;
                  if (m != null && m > BigInt.zero) _fraction(m, pc);
                },
                onMax: widget.prepareSweep == null ? null : _reviewSweep,
              ),
              // **The cost section keeps its seat whether or not there is a
              // cost yet** (founder, on glass 2026-09-04: *"let network fee
              // card have its own section"*).
              //
              // It used to appear only once a fee had been priced, which put a
              // 52 dp row in and out of the layout as the user typed — and
              // because the keypad sat in the same scroll, every appearance
              // shoved the digits down and every disappearance pulled them
              // back. The keys moved under the thumb. Two changes fix it and
              // both are structural: the row is always here, and the pad now
              // lives outside the scroll entirely.
              const SizedBox(height: KvSpace.s14),
              _FeeRow(sompi: _fee ?? _lastFee, pending: _fee == null),
              if (block?.notice != null) ...[
                const SizedBox(height: KvSpace.s),
                KvStatusChip(
                  tone: KvLampTone.warn,
                  words: block!.notice!,
                  plated: true,
                  maxLines: null,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: KvSpace.s),
                KvStatusChip(
                  tone: KvLampTone.warn,
                  words: _error!,
                  plated: true,
                  maxLines: null,
                ),
              ],
              const SizedBox(height: KvSpace.sm),
            ],
          ),
        ),
        // **The pad is furniture, not content** (`S6`, and the founder's own
        // complaint about it moving). Below the scroll, so nothing that
        // appears above it — a fee, an amber notice, an error — can shift a
        // key out from under the thumb it is already travelling to.
        //
        // **The pad steps aside for the system keyboard and comes back when it
        // closes** (founder, 2026-08-30). Two keyboards at once is not a
        // layout.
        AnimatedSize(
          duration: KvMotion.calm,
          curve: KvMotion.curve,
          alignment: Alignment.bottomCenter,
          child: imeUp
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: EdgeInsets.fromLTRB(gutter, KvSpace.s, gutter, 0),
                  child: KvKeypad.amount(onChar: _key, onBackspace: _backspace),
                ),
        ),
        _Foot(
          gutter: gutter,
          child: KvAction(
            // Names the action and its object (BG-11). The figure is the
            // user's own string, and D-210's trim governs it — as it now
            // governs the surface that restates what was BUILT too (D-267),
            // so the label here and the restatement there print one form.
            // **The trimmed form, not the raw field text.** Typing `12.4`
            // used to give `Review 12.4 KAS` over a ceremony restating `12.40`
            // and a pill reading `Hold to send 12.40 KAS` — one amount in two
            // printed forms, one tap apart (`ux-auditor`, UX-R2B).
            label: _amountSompi == null
                ? 'Review this send'
                : 'Review ${_trimmed(_amountSompi!)} KAS',
            primary: !_building,
            inlineReason: true,
            disabledReason: _building
                ? 'Building your transaction\u2026'
                : block?.reason,
            onTap: _review,
          ),
        ),
      ],
    );
  }
}

/// The screen's fixed foot. Everything above it scrolls; this never does.
class _Foot extends StatelessWidget {
  const _Foot({required this.child, required this.gutter});

  final Widget child;
  final double gutter;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(gutter, KvSpace.s, gutter, KvSpace.l),
    child: child,
  );
}

/// §2 `caps` — a section label, and the only place this screen shouts.
class _Caps extends StatelessWidget {
  const _Caps(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 11,
      height: 16 / 11,
      letterSpacing: 1.1,
      fontWeight: FontWeight.w600,
      fontVariations: KvWeight.w600,
      color: KvColor.inkMeta,
    ),
  );
}

/// The verdict under a destination that parses (`S6b`): the app's one check,
/// and the network it is for.
///
/// **`ok`, not teal** — teal is never a status (BG-2/BG-7) — and the words
/// carry the meaning so the state survives greyscale (BG-25).
class _ValidLine extends StatelessWidget {
  const _ValidLine();

  @override
  Widget build(BuildContext context) => const Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      KvCheck(semanticLabel: 'Valid'),
      SizedBox(width: KvSpace.s10),
      // **It wraps; the mark never shrinks.** At 320 dp / 1.3× the sentence
      // does not fit beside a 28 dp mark, and a `Row` of two natural-size
      // children overflows rather than reflowing (measured: 5.9 dp over).
      Expanded(
        child: Text(
          'Valid Kaspa address · Mainnet',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 14,
            height: 20 / 14,
            fontWeight: FontWeight.w500,
            fontVariations: KvWeight.w500,
            color: KvColor.ok,
          ),
        ),
      ),
    ],
  );
}

/// The checked address, and what the wallet knows about it (`S6b`).
///
/// The mark and its sentence are [_ValidLine]; this adds the two things that
/// depend on the address book — the offer to name a stranger, and the
/// statement that this one is not a stranger.
///
/// **Both halves matter and they are not symmetric.** *Save as contact* is a
/// convenience. The match card is a **safety** signal: a user who pasted an
/// address they have used before is told so, and one who expected a match and
/// does not get it has just learned something worth stopping for — which is
/// the honest half of what a contacts feature buys on a spend screen.
class _CheckedLine extends StatelessWidget {
  const _CheckedLine({
    required this.address,
    required this.contacts,
    required this.onSave,
  });

  final String address;
  final ContactsScope? contacts;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scope = contacts;
    if (scope == null) return const _ValidLine();
    return ValueListenableBuilder<List<ContactDto>>(
      valueListenable: scope.contacts,
      builder: (context, _, _) {
        final name = scope.nameFor(address);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(child: _ValidLine()),
                if (name == null)
                  KvContactAction(label: 'Save as contact', onTap: onSave),
              ],
            ),
            if (name != null) ...[
              const SizedBox(height: KvSpace.s),
              _MatchCard(name: name),
            ],
          ],
        );
      },
    );
  }
}

/// *This matches **Mara** in your contacts.* (`S6b`)
///
/// **`S6b` also says "You last sent here 12 Aug" and this does not.**
/// `ActivityRecord` carries no counterparty (§9.15), so the wallet cannot say
/// when it last sent anywhere in particular — and a date is exactly the kind
/// of corroborating detail that must not be invented on a surface a user is
/// about to trust with money. **Trigger:** the counterparty field crossing the
/// FFI.
class _MatchCard extends StatelessWidget {
  const _MatchCard({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.sm,
      ),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.notice),
      ),
      child: Row(
        children: [
          KvContactAvatar(name: name, size: 36),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'This matches '),
                  TextSpan(
                    text: name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontVariations: KvWeight.w700,
                      color: KvColor.ink,
                    ),
                  ),
                  const TextSpan(text: ' in your contacts.'),
                ],
              ),
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 14,
                height: 20 / 14,
                color: KvColor.inkDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The address book, on the screen that routes money (`S6a`).
///
/// **`S6a` heads the card `RECENT` with a `Contacts` tab opposite, and this
/// ships only the contacts half.** "Recent" means the addresses you last sent
/// to, and `ActivityRecord` carries no counterparty (§9.15) — so the wallet
/// cannot build that list, and a tab that switches to nothing is §8's
/// prohibition with a second name. One heading, no toggle, until the field
/// exists. **Trigger:** the counterparty field crossing the FFI.
///
/// Renders nothing at all when the book is empty: an empty card headed
/// CONTACTS teaches a first-time user that the feature is broken rather than
/// unused, and there is nowhere on this screen to add one from scratch — the
/// door is *Save as contact*, one address later.
class _ContactsCard extends StatelessWidget {
  const _ContactsCard({required this.contacts, required this.onPick});

  final ContactsScope? contacts;
  final void Function(String address) onPick;

  @override
  Widget build(BuildContext context) {
    final scope = contacts;
    if (scope == null) return const SizedBox.shrink();
    return ValueListenableBuilder<List<ContactDto>>(
      valueListenable: scope.contacts,
      builder: (context, list, _) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: KvSpace.l),
          // **`KvRowContainer`, not a hand-rolled plate.** The first cut
          // painted `plate` + `KvRadius.plate` + a caps header + a hairline
          // between rows — which is that widget, spelled out, differing only
          // in its gutter. Two implementations of one container is L143 with
          // a different name (`ux-auditor`, UX-R2B).
          child: KvRowContainer(
            header: const Padding(
              padding: EdgeInsets.only(top: KvSpace.s10, bottom: KvSpace.xs),
              child: _Caps('CONTACTS'),
            ),
            children: [
              for (final c in list)
                KvContactRow(
                  name: c.name,
                  address: c.address,
                  onTap: () => onPick(c.address),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The destination, restated at the head of step 2 as a settled fact (`S6`).
///
/// **The name never replaces the address** (BG-15). `S6` draws `M · Mara ·
/// kaspa:qr7m…gfx9t · Edit`, and the compact address is the half that carries
/// the safety: a contact name is exactly what an address-poisoning attack
/// wants to be trusted, so the row shows who the wallet *thinks* this is and
/// the characters that decide it, side by side.
///
/// An address with no name keeps §4's *stranger* disc — `chip` with an
/// `inkMeta` glyph — which claims nothing about who it belongs to.
class _RecipientRow extends StatelessWidget {
  const _RecipientRow({
    required this.address,
    required this.contacts,
    required this.onEdit,
  });

  final String address;
  final ContactsScope? contacts;
  final VoidCallback onEdit;

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
    return Container(
      constraints: const BoxConstraints(minHeight: KvSpace.control),
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.s,
        vertical: KvSpace.s,
      ),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.control),
      ),
      child: Row(
        children: [
          KvContactAvatar(name: name),
          const SizedBox(width: KvSpace.s14),
          Expanded(
            child: name == null
                ? KvAddress(address)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KvContactName(name: name, size: 15),
                      const SizedBox(height: 1),
                      KvAddress(address, fontSize: 12),
                    ],
                  ),
          ),
          const SizedBox(width: KvSpace.s),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onEdit,
            child: Semantics(
              button: true,
              label: 'Edit the destination',
              child: const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: KvSpace.sm,
                  // 52 dp: `s14` around an 18 dp line measures 46, and BG-12's
                  // floor does not bend because a control is quiet.
                  vertical: KvSpace.s,
                ),
                child: Text(
                  'Edit',
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
      ),
    );
  }
}

/// 25 % · 50 % · Max (`S6`).
///
/// The first two fill the field; **Max is the sweep** and goes straight to the
/// ceremony, because the amount depends on the fee of the transaction spending
/// it and no number this screen could type would be right (D-190). Its figure
/// is the spendable balance — *"`available` is the number Send max means"* —
/// and what actually leaves is restated by Rust on the surface that signs.
class _Shares extends StatelessWidget {
  const _Shares({
    required this.mature,
    required this.stale,
    required this.onFraction,
    required this.onMax,
  });

  final ValueListenable<BigInt?> mature;
  final ValueListenable<bool> stale;
  final void Function(int percent) onFraction;
  final VoidCallback? onMax;

  /// `S6`, measured: 32 tall, 8 dp apart.
  static const double height = 32;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BigInt?>(
      valueListenable: mature,
      builder: (context, value, _) => ValueListenableBuilder<bool>(
        valueListenable: stale,
        builder: (context, isStale, _) {
          // **A stale balance is not a number to type into a spend.**
          // `_amountBlock` yields when the reading is last-known — *"a
          // fabricated certainty about someone's money"* — and the Max chip
          // says `· last known` on its figure. A quarter of an unvouched
          // figure, typed silently, is the same claim one function up refuses
          // to make (`consensus-auditor`, UX-R2). Max stays live either way:
          // Rust solves the sweep, so no figure of ours is being asserted.
          final known = value != null && value > BigInt.zero && !isStale;
          return Wrap(
            alignment: WrapAlignment.center,
            spacing: KvSpace.s,
            runSpacing: KvSpace.s,
            children: [
              _Share(label: '25%', onTap: known ? () => onFraction(25) : null),
              _Share(label: '50%', onTap: known ? () => onFraction(50) : null),
              if (onMax != null)
                _Share(
                  label: 'Max',
                  // BG-8's three states, on the figure and not on the word:
                  // `—` while the balance is unknown, dimmed while it is
                  // last-known. **A stale figure never blocks the control** —
                  // the sweep is Rust's arithmetic, not this figure's.
                  figure: value == null ? '—' : _trimmed(value),
                  stale: isStale,
                  lit: true,
                  onTap: onMax,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Share extends StatelessWidget {
  const _Share({
    required this.label,
    this.figure,
    this.lit = false,
    this.stale = false,
    required this.onTap,
  });

  final String label;
  final String? figure;

  /// A ghost text action in `primary` — BG-2 names *Paste · Max · All* as
  /// permitted emissions, and this screen spends one of its three here.
  final bool lit;
  final bool stale;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tone = onTap == null
        ? KvColor.etch
        : (lit ? KvColor.primary : KvColor.inkDim);
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // A 32 dp chip in a 52 dp target (BG-12): the visual may be smaller
        // than the target, and the target never shrinks. **Padding, not a
        // sized box** — a `SizedBox` with a `Center` inside a `Wrap` has
        // unbounded width and takes the whole run, which stacked three chips
        // that fit side by side (caught in the 393 frame).
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: (KvSpace.touchTarget - _Shares.height) / 2,
          ),
          child: Container(
            height: _Shares.height,
            padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
            decoration: BoxDecoration(
              color: KvColor.plate,
              borderRadius: BorderRadius.circular(KvRadius.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // BG-30: the word speaks, the figure counts, and they are
                // never set in the same face.
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 13,
                    height: 18 / 13,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: tone,
                  ),
                ),
                if (figure != null) ...[
                  Text(
                    ' · ',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 13,
                      color: tone,
                    ),
                  ),
                  // The 45 % dim is a LARGE-TEXT device (BG-8 as narrowed,
                  // D-257) and 13 dp is not large text — so a stale figure
                  // here says so by its word, not by fading under AA. (The
                  // `Opacity(1)` that used to wrap this was a no-op left
                  // behind by that narrowing.)
                  Text(
                    figure!,
                    style: TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 13,
                      height: 18 / 13,
                      fontWeight: FontWeight.w500,
                      fontVariations: KvWeight.w500,
                      color: tone,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  // **The qualifier is a WORD, so it is Jakarta** (BG-30):
                  // mono carries figures and never a sentence, and
                  // `last known` was riding the figure's own run.
                  if (stale)
                    Text(
                      ' · last known',
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 13,
                        height: 18 / 13,
                        fontWeight: FontWeight.w500,
                        fontVariations: KvWeight.w500,
                        color: tone,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The fee, as a **reading** (`S6`) — and a seat that is always occupied.
///
/// `S6` draws it as a row with a chevron — a fee-tier picker. The bridge prices
/// one fee, the Generator's, so there is no tier to pick and the chevron is not
/// drawn: a control that answers a tap and does nothing is §8's one outright
/// prohibition. **Trigger:** a fee-estimate surface on the bridge.
///
/// ## Why the row is here before there is a fee
///
/// The founder's complaint, on glass: the row appearing and vanishing as an
/// amount was typed *"messes with the UX of the placement of the keypad"*. It
/// did — the pad shared this scroll, so a 52 dp row entering the layout pushed
/// every key down and leaving pulled them back, under a thumb already moving.
/// The pad has since left the scroll, and this keeps its seat regardless, so
/// the section above the pad has one shape.
///
/// ## What the empty seat says, and what it must not
///
/// **A dash, not `0.00000000`.** The founder asked for the zeros
/// (*"i want the network fee to appear as 0.000.. ish"*) and the reason —
/// layout stability — is fully answered by the constant seat above. The zeros
/// are not, because they state a *fee of zero* on the one screen where a user
/// decides what a send costs: type an amount, let the node be slow, and
/// `0.00000000 KAS` is a wallet claiming this transaction is free. BG-8 gives
/// an unknown value the dash precisely so it cannot be read as an answer, and
/// a fee is the value on this screen most worth not guessing. The dash costs
/// one character of the look and keeps the row unable to mislead.
///
/// ## The arrival
///
/// **Crossfaded, never counted up.** The founder asked for the figure to
/// *"stream in a ease in, ease change way"*, and the entrance is eased — but
/// `KvStreamingCount`'s fourth law is that **money never streams**: a counter
/// tweening 0 → 0.0001 renders fee values the Generator never quoted, on a
/// funds surface, which is the one thing that primitive asserts against. So
/// the row eases the figure *in*, and every frame of it shows either a number
/// Rust priced or no number at all.
class _FeeRow extends StatelessWidget {
  const _FeeRow({required this.sompi, this.pending = false});

  /// The figure to show: the current quote, or the last one while a fresh
  /// probe is in flight. Null only when there is nothing to price at all.
  final BigInt? sompi;

  /// A probe is running and [sompi] is the PREVIOUS quote — so the figure is
  /// dimmed to say it is not the answer to what was just typed.
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final fee = sompi;
    return Container(
      constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.s20,
        vertical: KvSpace.sm,
      ),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.control),
      ),
      child: Row(
        children: [
          const Text(
            'Network fee',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 14,
              height: 20 / 14,
              color: KvColor.inkMeta,
            ),
          ),
          const Spacer(),
          // **A `KvAmount`, not a formatted string** (D-230), so BG-23's
          // emphasis rule reaches the screen the number is first read on and
          // not only the ceremony. Trimmed rather than padded to eight —
          // which is now every surface's rule, not this one's exception
          // (founder, 2026-09-04).
          //
          // `trailingMax` in spirit: the figure is the non-flex child under a
          // stated cap, so a large fee cannot starve the label and cannot
          // paint past the gutter (L131).
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: fee == null
                ? const Text(
                    // BG-8's dash for a datum nobody has yet.
                    '\u2014',
                    key: ValueKey<String>('fee-unknown'),
                    style: TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 13,
                      height: 20 / 13,
                      fontWeight: FontWeight.w500,
                      fontVariations: KvWeight.w500,
                      color: KvColor.inkMeta,
                    ),
                  )
                // **The digits change in place** (founder, on glass
                // 2026-09-04): *"its the increment or decrement that user sees
                // changing… not like the number and KAS is going out and
                // coming in."* The first cut crossfaded the whole figure,
                // which reads as a swap. Only the character slots that
                // actually changed move now, and exactly two glyphs — the old
                // one and the new one, both quoted by the Generator — exist
                // in a slot while it does. Nothing is interpolated, so
                // `KvStreamingCount`'s "money never streams" is untouched.
                : AnimatedOpacity(
                    duration: KvMotion.fast,
                    curve: KvMotion.curve,
                    // Down to its own label's weight while it is not the
                    // answer; back to full when it is. `ink` at 60 % on
                    // `plate` measures ~10:1, so this stays well clear of AA
                    // — D-257 narrowed the 45 % dim because `inkMeta` fell
                    // under the floor, and that is a different tone.
                    opacity: pending ? 0.6 : 1,
                    child: KvAmount(
                      fee,
                      role: KvAmountRole.row,
                      size: 13,
                      showUnit: true,
                      emphasis: KvAmountEmphasis.significant,
                      rolling: true,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A KAS figure for this screen's copy.
///
/// **Every significant digit and no trailing zeros** (D-210, and since D-267
/// the rule on every surface including the one that signs — there is no longer
/// a second form to be consistent with). The padding is noise a user has to
/// read past to find where the number ends.
///
/// A shortfall keeps every digit that carries value either way, because
/// [trimFraction] only ever removes zeros: *"you are 0.00001994 KAS short"*
/// survives verbatim (D-189), and *"2.40000000"* becomes *"2.40"*.
String _trimmed(BigInt sompi) {
  final p = kasParts(sompi);
  return '${p.integer}.${trimFraction(p.fraction)}';
}

/// The destination field (`S6a` · `S6b`).
///
/// **Two faces, one field.** Empty or being edited, it is a text field with the
/// Paste ghost inside it. Holding an address of the right shape, it renders
/// that address through [KvAddress] — one continuous mono run with the first
/// and last groups weighted — because the moment the field stops being edited
/// it becomes something to *check*, and a checkable address is what BG-15
/// specifies. Tapping it puts the caret back; ✕ empties it.
///
/// The validated border is `ok` at 45 % (`S6b`, measured). §1.6 forbids a
/// tinted edge on a **plate carrying a status**; a field is not that — it is
/// the object the state belongs to, and the mark and the words beneath it carry
/// the same meaning, so the colour is never alone (BG-25).
class _AddressField extends StatefulWidget {
  const _AddressField({
    required this.controller,
    required this.focusNode,
    required this.valid,
    required this.onPaste,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool valid;
  final VoidCallback onPaste;
  final VoidCallback onClear;

  /// `S6a`, measured: the empty field is 60 tall and grows with the address.
  static const double minHeight = 60;

  @override
  State<_AddressField> createState() => _AddressFieldState();
}

class _AddressFieldState extends State<_AddressField> {
  /// **Editing is a state this widget owns, not one derived from focus.**
  ///
  /// The first cut derived it — *rendered when valid and unfocused* — and the
  /// derivation could not be undone: while the rendering is up the `TextField`
  /// is unmounted, so its `FocusNode` is detached, so `requestFocus()` on it
  /// does nothing at all. Tapping the address to correct it was a control that
  /// answered a tap and did nothing (§8), and only the ✕ could get out of it.
  /// Owning the flag makes the field come back first and take focus after.
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  /// Leaving the field settles it back to the checkable rendering.
  void _onFocus() {
    if (!widget.focusNode.hasFocus && _editing) {
      setState(() => _editing = false);
    }
  }

  void _edit() {
    setState(() => _editing = true);
    // After the frame that mounts the field: a `FocusNode` cannot take focus
    // before the widget it belongs to exists.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.focusNode.requestFocus(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final text = value.text.trim();
        final rendered = widget.valid && !_editing;
        return Container(
          constraints: const BoxConstraints(minHeight: _AddressField.minHeight),
          padding: const EdgeInsets.fromLTRB(
            KvSpace.s20,
            KvSpace.s,
            KvSpace.s,
            KvSpace.s,
          ),
          decoration: BoxDecoration(
            color: KvColor.plate,
            borderRadius: BorderRadius.circular(KvRadius.plate),
            border: widget.valid
                ? Border.all(color: KvColor.ok.withValues(alpha: 0.45))
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: rendered
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _edit,
                        child: Semantics(
                          button: true,
                          label: 'Edit the destination address',
                          child: KvAddress(
                            text,
                            form: KvAddressForm.chunked,
                            plated: false,
                          ),
                        ),
                      )
                    : TextField(
                        key: SendScreen.addressTarget,
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        maxLines: null,
                        autocorrect: false,
                        enableSuggestions: false,
                        cursorColor: KvColor.primary,
                        style: const TextStyle(
                          fontFamily: KvFont.mono,
                          fontSize: 13,
                          height: 19 / 13,
                          fontWeight: FontWeight.w500,
                          fontVariations: KvWeight.w500,
                          color: KvColor.ink,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 6),
                          // A placeholder is not information (§1.3), so it is
                          // `etch` — and it is a sentence, so it is Jakarta
                          // while the address it will hold is mono (BG-30).
                          hintText: 'Kaspa address',
                          hintStyle: TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 15,
                            height: 20 / 15,
                            color: KvColor.etch,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: KvSpace.s),
              if (text.isEmpty)
                _PasteChip(onTap: widget.onPaste)
              else
                _ClearButton(
                  onTap: () {
                    setState(() => _editing = false);
                    widget.onClear();
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The Paste ghost (`S6a`).
///
/// **`primary`, not `primaryMuted`.** §1.5 lists "the Paste chip's glyph and
/// label" under the ambient teal and BG-2 lists *Paste* among the ghost text
/// actions that emit — two laws on one object, and `S6a` settles it: the render
/// paints both glyph and word at `#49eacb`. It is a ghost action that happens
/// to sit in a chip, and it spends one of this screen's three emissions.
class _PasteChip extends StatelessWidget {
  const _PasteChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Paste the address from your clipboard',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // A 40 dp chip in a 52 dp target (BG-12): the visual may be smaller
        // than the target, and the target never shrinks.
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: (KvSpace.touchTarget - KvSpace.rowDisc) / 2,
          ),
          child: Container(
            height: KvSpace.rowDisc,
            padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
            decoration: BoxDecoration(
              color: KvColor.chip,
              borderRadius: BorderRadius.circular(KvRadius.control),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KvGlyphIcon(KvGlyph.paste, size: 16, tone: KvColor.primary),
                SizedBox(width: KvSpace.s),
                Text(
                  'Paste',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.primary,
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

/// Clear the field (`S6b`). One of §2a's five marks that may stand alone.
class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Clear the address',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const SizedBox(
        width: KvSpace.touchTarget,
        height: KvSpace.touchTarget,
        child: Center(
          child: KvGlyphIcon(KvGlyph.close, size: 20, tone: KvColor.inkDim),
        ),
      ),
    ),
  );
}

/// The amount, as an editable field that looks like the figure it is.
///
/// **Two input paths, one source of truth.** Tapping it raises the DEVICE's
/// number keyboard and the on-screen pad steps aside; dismissing the keyboard
/// brings the pad back. Both write the same [TextEditingController], so they
/// cannot disagree about what has been typed, and the pad remains the default —
/// this narrows D-189, it does not reverse it.
///
/// **The grammar is enforced on both.** [_AmountGrammar] refuses anything
/// [sompiFromKas] would refuse, so a system keyboard cannot type a second
/// decimal point, a ninth decimal, or a figure past the `u64` sompi ceiling
/// that the pad already refuses at the keystroke. One law, two doors.
///
/// It scales down rather than wrapping or clipping (BG-5) — a figure is the one
/// thing on a screen that may not reflow (L131/BG-14) — and the unit sits
/// OUTSIDE that fit so its 11 dp floor survives the scale.
class _TypedAmount extends StatelessWidget {
  const _TypedAmount({required this.controller, required this.focusNode});

  final TextEditingController controller;
  final FocusNode focusNode;

  /// `S6`, measured: cap 41.0 dp ÷ JetBrains Mono's 0.739 cap ratio.
  static const double size = 56;

  @override
  Widget build(BuildContext context) {
    const figure = TextStyle(
      fontFamily: KvFont.mono,
      fontSize: size,
      height: 60 / size,
      fontWeight: FontWeight.w700,
      fontVariations: KvWeight.w700,
      color: KvColor.ink,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerEnd,
            child: IntrinsicWidth(
              child: TextField(
                key: SendScreen.amountTarget,
                controller: controller,
                focusNode: focusNode,
                textAlign: TextAlign.end,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: const [_AmountGrammar()],
                maxLines: 1,
                cursorColor: KvColor.primary,
                cursorWidth: 2,
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  // A placeholder `0`, not a fabricated `0.00000000`: nothing
                  // has been entered, and eight zeros would look like an
                  // amount.
                  hintText: '0',
                  hintStyle: figure.copyWith(color: KvColor.etch),
                ),
                style: figure,
              ),
            ),
          ),
        ),
        const SizedBox(width: KvSpace.s10),
        const Padding(
          padding: EdgeInsets.only(bottom: KvSpace.s10),
          child: Text(
            // **Teal, by founder ruling on glass** (D-262). `S6` sets the unit
            // in the meta grey; the same unit beside the balance was ruled
            // `primaryMuted` the same day, and one fact has one face (BG-21).
            // Ambient teal on structure — not an emission, so it costs nothing
            // against BG-2's cap (§1.5). A unit is a word, so it is Jakarta.
            'KAS',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 16,
              height: 20 / 16,
              fontWeight: FontWeight.w600,
              fontVariations: KvWeight.w600,
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
/// this refuses the same things at the field, so a device keyboard cannot type a
/// second decimal point, a ninth decimal, or a figure past the `u64` sompi
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
