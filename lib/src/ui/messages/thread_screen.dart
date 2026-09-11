import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/error.dart';
import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import 'contacts_screen.dart'
    show confirmBlockContact, signingToggleSub, signingToggleTitle;
import '../send/confirm_send_flow.dart';
import '../error_text.dart';
import '../format.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_address.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_contact.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_icon_button.dart';
import '../widgets/kv_loader.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_toggle.dart';
import '../widgets/kv_sheet.dart';
import '../widgets/kv_two_pane.dart';
import '../widgets/tx_status_chip.dart';

/// One conversation thread (P2.3 plain view + P2.4 `kv:1:` game frames +
/// V2 incremental pulls, status chips and the reorg ghost).
///
/// Decrypt-on-view (§0.4): every render PULLS the thread from Rust — sealed
/// rows open there while the vault is unlocked; the decrypted text lives in
/// this widget's ephemeral state exactly as long as the screen shows it, and
/// is dropped on dispose. Nothing is cached in a service; vault locked ⇒ the
/// pull errs and the locked state renders instead of content.
///
/// V2: pulls are INCREMENTAL (`transport_thread_since` decrypts only the new
/// tail past the last rendered txid); every pull also carries the live status
/// of EVERY row, so tombstone flips and acceptance transitions of rows behind
/// the cursor land without re-decrypting the conversation. Rows are
/// txid-keyed in an [AnimatedList]; arrivals glide in and never yank a reader
/// who has scrolled up.
///
/// **No game surface in a chat** (founder ruling 2026-09-11, D-322): a
/// recognised `kv:1:` frame that arrives renders as its readable line, a plain
/// bubble — no card, no accept, no stake, no taunt. The P2.4 challenge card and
/// its composer were removed outright; the wire parser in `core::frames` is
/// untouched and the frames are still decoded, they are just not a surface.
/// How PvP works is decided globally first, and not through chats.
///
/// FLAG_SECURE (§17) decided consciously: message content is user
/// conversation, NOT seed material — screenshots stay the user's choice
/// (parity with the receive screen's QR; the secret surfaces keep their own
/// guard). Recorded in the P2.3 session notes.
class ThreadScreen extends StatefulWidget {
  const ThreadScreen({
    super.key,
    required this.conversationId,
    required this.contactLabel,
    this.contactAddress = '',
    this.messaging,
  });

  final String conversationId;
  final String contactLabel;

  /// The counterparty's address, for the bar's second line. Empty on a row
  /// whose sender the node has not resolved yet — the bar then names the
  /// person and claims no key, which is the honest half of the pair.
  final String contactAddress;

  /// Test seam; defaults to the singleton.
  final MessagingService? messaging;

  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  MessagingService get _messaging =>
      widget.messaging ?? MessagingService.instance;

  final _compose = TextEditingController();
  final _scroll = ScrollController();
  final _listKey = GlobalKey<AnimatedListState>();

  /// Append-only within a view (the store never reorders or removes rows in
  /// a live conversation); txid-keyed via [_seen] so a full re-pull after a
  /// degraded cursor can never duplicate (V2 cursor law).
  final List<ThreadMessageDto> _messages = [];
  final Set<String> _seen = {};

  /// Live per-txid status (tombstone + acceptance) — refreshed WHOLE on every
  /// pull, so rows behind the cursor keep telling the truth.
  Map<String, MessageStatusDto> _statuses = const {};

  /// Where each saved attachment landed, by txid — the destination the user
  /// chose, kept so "Open" can point at it without a second copy existing.
  final Map<String, SavedFile> _saved = {};

  /// One byte-fetch per rendered image, kept so a rebuild does not re-cross
  /// the bridge. Bounded in practice by what fits in a transaction (~70 KB).
  final Map<String, Future<Uint8List>> _imageCache = {};

  String? _lockedMessage;
  bool _loading = true;

  /// First paint lands at the bottom instantly; later arrivals glide.
  bool _settled = false;

  /// The draft, mirrored so the send control can arm on it (BG-27). A
  /// `TextEditingController` is a `Listenable`; nothing here reads its text
  /// except to decide whether there is anything to commit.
  String _draft = '';

  // ── The live fee (founder, 2026-09-08), on the send screen's pattern ──────
  //
  // Not a second mechanism: `send_screen.dart` already prices a transaction as
  // it is typed, and every part of that shape is load-bearing rather than
  // stylistic, so all of it is carried over — the 250 ms debounce, the token
  // that stops a slow answer overwriting a newer one, and holding the last
  // quote (dimmed) while a fresh probe runs so the figure never tweens through
  // numbers the Generator did not quote.

  /// The quote to draw: the current one, or the previous one while a probe is
  /// in flight. Null when there is nothing to price at all.
  BigInt? _fee;

  /// **The exact text [_fee] was quoted for.**
  ///
  /// The figure deliberately survives a keystroke, so the row never blinks and
  /// never tweens through numbers the Generator did not quote. That
  /// is right for a DISPLAY and wrong for a decision: the whole safety
  /// argument for turning the confirm sheet off is that the price was on the
  /// glass first, and a quote for an earlier draft is not that price
  /// (`consensus-auditor`, this sitting). The unceremonious send arm requires
  /// this to equal what it is about to send.
  String? _feeFor;

  /// A probe is running, so [_fee] is the PREVIOUS answer.
  bool _feePending = false;

  /// **A send is in flight.** The one re-entry guard on a funds surface whose
  /// confirm sheet may be turned off — see [_send].
  bool _sending = false;

  /// The composer's focus, so the emoji key can take the system keyboard down
  /// and put it back.
  final FocusNode _composeFocus = FocusNode();

  /// The in-app emoji panel is open, which is also when the trailing key wears
  /// the keyboard mark instead of the smile.
  bool _emojiUp = false;

  /// **The system keyboard's own height, remembered from the last time it was
  /// up** — and the height our panel takes.
  ///
  /// Founder, 2026-09-08: *"I want it to be the same height and lenght with the
  /// systems keyboard height. cos when i toggle back to keyboard, there is this
  /// bad UX jump of the keyboard which is taller than the emoji thingy."* A
  /// fixed 260 was always going to be wrong for somebody: keyboard height is
  /// the IME's decision, it differs per keyboard, per language, per device, and
  /// it changes when a suggestion strip appears.
  ///
  /// So it is measured rather than chosen. `viewInsets.bottom` IS the keyboard
  /// while the keyboard is up; we latch the last non-zero reading and hand our
  /// panel the same number, so the swap is a content change under a lid that
  /// never moves. [_panelFallback] covers the one case with no reading yet — a
  /// user whose first action in a thread is the emoji key.
  double _keyboardHeight = 0;

  /// How much of the thread's viewport was taken from the bottom last frame —
  /// the system keyboard, or our emoji panel standing in for it.
  ///
  /// **This is what makes the thread move up with the keyboard.** `Scaffold`
  /// resizes for the inset, so the composer stays visible — but the list keeps
  /// its scroll offset, and a shorter viewport at the same offset means the
  /// bottom of the conversation slides below the fold. The founder had to
  /// scroll down to see what he had just been reading: *"the keyboard just
  /// comes up to cover the text … let it be like whatsapp or standard, where
  /// it pushes the last chat or wherever they are on the thread screen up."*
  ///
  /// So every time that space GROWS, the list is nudged by exactly the same
  /// amount: the reader keeps looking at what they were looking at, and the
  /// content appears to be pushed up rather than covered.
  double _bottomSpace = 0;

  /// The keyboard has been asked for and has not arrived yet, so our panel
  /// stays up underneath it.
  ///
  /// **This is what actually removes the jump.** Collapsing our panel the
  /// instant the tap lands drops the composer to the bottom of the screen for
  /// the two or three frames before the IME's own animation reaches it, and
  /// that dip is the thing that reads as a jolt — matching the heights alone
  /// does not fix it. Holding the panel until `viewInsets` goes non-zero means
  /// the lid never moves: our panel is replaced by the keyboard behind it.
  bool _awaitingKeyboard = false;

  /// Until the keyboard has been seen once. Deliberately close to a common
  /// Android keyboard so a first-tap panel is not wildly off; it is replaced
  /// by the real number the first time the keyboard opens.
  static const double _panelFallback = 260;

  /// **Swap the system keyboard for the emoji panel, and back.**
  ///
  /// Android has no public API to open the IME's own emoji page — that is a
  /// keyboard's private surface, and Gboard's emoji key is Gboard's. So the
  /// panel is ours: it works on every keyboard the user might have, it cannot
  /// be taken away by an IME update, and it costs no dependency (which at this
  /// tier would need a `dependency-steward` verdict of its own). The behaviour
  /// he described is unchanged — a smile that becomes a keyboard, and back.
  void _toggleEmoji() {
    KvHaptic.selection();
    if (_emojiUp) {
      // Ask for the keyboard and KEEP our panel up until it is actually
      // there — see [_awaitingKeyboard].
      setState(() => _awaitingKeyboard = true);
      _composeFocus.requestFocus();
      return;
    }
    // Take the system keyboard down FIRST, then open ours, or the two fight
    // for the same space for a frame.
    _composeFocus.unfocus();
    setState(() => _emojiUp = true);
  }

  /// **Delete the character before the cursor**, the way a keyboard's own
  /// backspace does — and grapheme-wise, so one tap removes one emoji rather
  /// than half of a surrogate pair or a lone skin-tone modifier.
  void _backspace() {
    final value = _compose.value;
    final sel = value.selection;
    final text = value.text;
    if (text.isEmpty) return;
    // A selection is replaced by nothing; a caret eats what is behind it.
    if (sel.isValid && !sel.isCollapsed) {
      _compose.value = value.copyWith(
        text: text.replaceRange(sel.start, sel.end, ''),
        selection: TextSelection.collapsed(offset: sel.start),
        composing: TextRange.empty,
      );
      return;
    }
    final at = sel.isValid ? sel.start : text.length;
    if (at == 0) return;
    // `characters` counts what a reader calls a character: an emoji built of a
    // base, a zero-width joiner and a modifier goes in one tap, which is the
    // whole point on this panel.
    final before = text.substring(0, at);
    final kept = before.characters.skipLast(1).toString();
    _compose.value = value.copyWith(
      text: kept + text.substring(at),
      selection: TextSelection.collapsed(offset: kept.length),
      composing: TextRange.empty,
    );
  }

  /// Insert an emoji at the cursor, or at the end when the field has never
  /// been focused. The selection lands after it, so a run of taps types a run.
  void _insertEmoji(String emoji) {
    final value = _compose.value;
    final sel = value.selection;
    if (!sel.isValid) {
      _compose.text = value.text + emoji;
      _compose.selection = TextSelection.collapsed(
        offset: _compose.text.length,
      );
      return;
    }
    final text = value.text.replaceRange(sel.start, sel.end, emoji);
    _compose.value = value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: sel.start + emoji.length),
      composing: TextRange.empty,
    );
  }

  /// **Why the last send did not go**, said at the composer.
  ///
  /// It exists because the signing toggle can remove the sheet, and the sheet
  /// is where every refusal used to be read. Cleared on the next keystroke, so
  /// it never outlives the draft it was about.
  String? _sendRefusal;

  Timer? _feeDebounce;

  /// Only the newest probe may land. Without it a slow answer for `hi` can
  /// return after a fast one for `hi there` and leave a true number against
  /// the wrong text — worse than no number.
  int _feeToken = 0;

  /// Long enough that a run of keystrokes makes ONE probe, short enough that
  /// the figure feels live. The probe builds a real transaction, so it is not
  /// free. Same number as the send screen's, deliberately.
  static const Duration _feeDebounceFor = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _messaging.lastPing.addListener(_onPing);
    _compose.addListener(_onDraft);
    _composeFocus.addListener(_onComposeFocus);
    _pull();
  }

  void _onComposeFocus() {
    // Focus means the system keyboard is coming up, so ours goes down. This
    // covers the tap-into-the-field case without the field having to know the
    // panel exists.
    // Focus alone is not the keyboard: `_toggleEmoji` requests focus and then
    // waits for the INSET, so this must not pull the panel out from under it.
    if (_composeFocus.hasFocus && _emojiUp && !_awaitingKeyboard) {
      setState(() => _emojiUp = false);
    }
  }

  void _onDraft() {
    final draft = _compose.text;
    _repriceFee();
    if (_sendRefusal != null) setState(() => _sendRefusal = null);
    // Only when the ANSWER changes — a rebuild per keystroke over a thread
    // list is what BG-18's own rule warns about.
    if (draft.trim().isEmpty != _draft.trim().isEmpty) {
      setState(() => _draft = draft);
    } else {
      _draft = draft;
    }
  }

  /// Re-price what is typed now.
  ///
  /// An emptied field clears the figure outright rather than leaving the fee
  /// of a message that no longer exists; anything else keeps the standing
  /// quote on screen and asks Rust, which prices **the exact wire this send
  /// would build** — the namespace, the alias head and the sealed envelope
  /// included. [_feeFor] is what stops a held quote being acted on.
  void _repriceFee() {
    _feeDebounce?.cancel();
    final token = ++_feeToken;
    final text = _compose.text.trim();
    if (text.isEmpty) {
      if (_fee != null || _feePending) {
        setState(() {
          _fee = null;
          _feeFor = null;
          _feePending = false;
        });
      }
      return;
    }
    if (!_feePending) setState(() => _feePending = true);
    _feeDebounce = Timer(_feeDebounceFor, () async {
      try {
        final fee = await _messaging.commFeePreview(
          widget.conversationId,
          text,
        );
        if (!mounted || token != _feeToken) return;
        // Both in ONE `setState`, so no frame ever holds a figure beside the
        // wrong text — which is the whole point of keeping the pair.
        setState(() {
          _fee = fee;
          _feeFor = fee == null ? null : text;
          _feePending = false;
        });
      } catch (_) {
        // No fee is a real answer and a failed probe is not a number. The
        // send still works: with no figure the tap routes through the confirm
        // sheet, which states Rust's own reason.
        if (!mounted || token != _feeToken) return;
        setState(() {
          _fee = null;
          _feeFor = null;
          _feePending = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _messaging.lastPing.removeListener(_onPing);
    _compose.removeListener(_onDraft);
    _feeDebounce?.cancel();
    _composeFocus.removeListener(_onComposeFocus);
    _composeFocus.dispose();
    _compose.dispose();
    _scroll.dispose();
    // The decrypted rows die with this state object (§0.4 — view-scoped) — and
    // so must the decoded IMAGES. Flutter's imageCache is global and keyed on
    // the provider, so a rendered attachment would otherwise outlive the thread
    // that decrypted it, holding message content in memory for a screen the
    // user has closed. Both keys go: the card decodes through `ResizeImage`,
    // the viewer through the bare `MemoryImage`.
    for (final pending in _imageCache.values) {
      pending
          .then((bytes) {
            final raw = MemoryImage(bytes);
            PaintingBinding.instance.imageCache.evict(raw);
            PaintingBinding.instance.imageCache.evict(
              ResizeImage(raw, width: _thumbnailWidth),
            );
          })
          .catchError((_) {});
    }
    _imageCache.clear();
    _messages.clear();
    super.dispose();
  }

  void _onPing() {
    if (_messaging.lastPing.value == widget.conversationId) _pull();
  }

  /// Move this conversation's read mark to its newest inbound row.
  ///
  /// Fire-and-forget by design: the count is a courtesy, and a device that
  /// cannot write the mark must still render the thread. Rust pings the list
  /// itself when the mark actually moves, which is the moment a badge goes.
  Future<void> _markRead() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    try {
      await _messaging.markRead(widget.conversationId);
    } catch (_) {
      // A watermark that could not be written costs a badge, never a message.
    }
  }

  /// Chip state for a row: outbound comm rows ride the tracker's answer;
  /// everything else stays quiet.
  TxChipState _chipFor(ThreadMessageDto m) {
    if (!m.outbound || m.kind != 'comm') return TxChipState.none;
    return chipStateOfAcceptance(_statuses[m.txid]?.acceptance?.kind);
  }

  /// **Delivered** — the double check inside an outbound bubble.
  ///
  /// Outbound comm rows only. A handshake is not something anyone said, and a
  /// message they sent US needs no delivery report from us.
  bool _deliveredFor(ThreadMessageDto m) {
    if (!m.outbound || m.kind != 'comm') return false;
    return deliveredOfAcceptance(_statuses[m.txid]?.acceptance?.kind);
  }

  /// Ghost truth: the live status map wins over the decrypt-time flag.
  bool _ghostFor(ThreadMessageDto m) =>
      _statuses[m.txid]?.tombstoned ?? m.tombstoned;

  /// Merge one delta into the view: append unseen rows (txid-keyed — a full
  /// answer merges idempotently) and replace the status map whole.
  void _merge(ThreadDeltaDto delta) {
    setState(() {
      for (final m in delta.messages) {
        if (_seen.add(m.txid)) {
          _messages.add(m);
          // Null until the list first builds — initialItemCount covers it.
          _listKey.currentState?.insertItem(
            _messages.length - 1,
            duration: KvMotion.calm,
          );
        }
      }
      _statuses = {for (final s in delta.statuses) s.txid: s};
      _lockedMessage = null;
      _loading = false;
    });
  }

  Future<void> _pull() async {
    try {
      var delta = await _messaging.threadSince(
        widget.conversationId,
        _messages.isEmpty ? null : _messages.last.txid,
      );
      if (!mounted) return;
      // Read the reader's position BEFORE inserts move the extent.
      final wasAtBottom =
          !_scroll.hasClients ||
          (_scroll.position.maxScrollExtent - _scroll.position.pixels) < 96;
      _merge(delta);
      // Stranding heal (consensus-audit V2 finding 1): statuses cover EVERY
      // row, so a txid we have never rendered means a row sorted BEHIND the
      // cursor (sender-claimed handshake timestamp / same-ms tie-break).
      // One full re-pull materializes it; the merge cannot duplicate, and a
      // full answer's statuses ⊇ all rows, so this converges in one step.
      if (delta.statuses.any((s) => !_seen.contains(s.txid))) {
        delta = await _messaging.threadSince(widget.conversationId, null);
        if (!mounted) return;
        _merge(delta);
      }
      // **The rows are now on screen, so they have been read.**
      //
      // Here and nowhere else: this runs on the thread's first frame with rows
      // and on every delta while the thread is the visible route — which is
      // exactly the founder's condition, that the user could actually see
      // them. A ping alone is not enough (`lastPing` is a `ValueNotifier` and
      // skips an equal value, L48), so the mark rides the PULL the ping
      // caused rather than the ping.
      //
      // Backgrounding the app with the thread open does not mark what arrives
      // meanwhile: the route is no longer being looked at, and Rust's own
      // forward-only rule means a later mark simply catches up.
      unawaited(_markRead());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final bottom = _scroll.position.maxScrollExtent;
        final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        if (!_settled) {
          _scroll.jumpTo(bottom);
          _settled = true;
        } else if (wasAtBottom) {
          // An arrival glides down; a reader scrolled up is never yanked;
          // reduced motion lands instantly (§6).
          if (reduced) {
            _scroll.jumpTo(bottom);
          } else {
            _scroll.animateTo(
              bottom,
              duration: KvMotion.calm,
              curve: KvMotion.curve,
            );
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.clear();
        _seen.clear();
        _statuses = const {};
        _lockedMessage = displayError(e);
        _loading = false;
        _settled = false;
      });
    }
  }

  /// The ONE spend path for every comm-carried kind, over the shared
  /// [runConfirmSend] ceremony (V5): the summary — self-send mode and payload
  /// facts included — is Rust's decode (B7); this surface keeps only its own
  /// error style (snackbar), the thread re-pull, and the submitted signal.
  /// Never auto-broadcasts (broadcast fires only inside a completed hold).
  Future<bool> _confirmSend({
    required Future<SignableSummaryDto> Function() prepare,
    required String title,
    Widget? footer,
  }) async {
    try {
      final outcome = await runConfirmSend(
        context,
        prepare: prepare,
        commit: _messaging.commit,
        abandon: _messaging.abandon,
        title: title,
        // The founder's toggle, on the one sheet it governs — supplied by the
        // plain-message caller, never by this shared funnel.
        footer: footer,
        // Every send this funnel makes lands in the thread as a message.
        preparingObject: 'message',
      );
      await _pull();
      return outcome != null && outcome.submitted > 0;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
      return false;
    }
  }

  /// **The send, and the one place the founder's toggle changes anything.**
  ///
  /// Four doors, and only one of them skips the sheet:
  ///
  ///  - **signing on** (the default) ⇒ the confirm ceremony, unchanged;
  ///  - **signing off, and a fee on the glass** ⇒ straight to Rust's
  ///    unceremonious door, which re-checks the preference, the comm-class
  ///    scope, the built transaction's own destination and the fee ceiling
  ///    before anything is broadcast;
  ///  - **signing off, no fee quoted** ⇒ **the ceremony anyway.** The live
  ///    figure is the only price disclosure once the sheet is gone, so a send
  ///    with no figure has had none — and the sheet is also what turns "no
  ///    quote" into Rust's own sentence about why;
  ///  - **the ceiling tripped** ⇒ Rust refuses with the figure in words, and
  ///    the tap falls back to the sheet, which shows it in full.
  ///
  /// The preference is read HERE rather than held in state: it can be changed
  /// on the sending sheet itself and in message settings, and a cached copy is
  /// how those two disagree.
  Future<void> _send() async {
    final text = _compose.text.trim();
    // **The re-entry guard.** With the ceremony on, the modal sheet absorbed a
    // second tap; turning it off removed that without anything replacing it,
    // and a double tap would then either broadcast twice — two messages, two
    // fees, nothing confirmed — or overwrite the single `PENDING_TRANSPORT`
    // slot and fail the first commit on a stale nonce
    // (`wallet-security-auditor`, this sitting). A sheet is also a lock.
    if (text.isEmpty || _sending) return;
    KvHaptic.selection();
    setState(() => _sending = true);
    try {
      await _sendInner(text);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendInner(String text) async {
    var ceremony = true;
    try {
      ceremony = await _messaging.messageSigning();
    } catch (_) {
      // An unreadable preference is the ceremony. The safe state is the one
      // that asks (`MessagePrefs::load`'s own posture, restated).
    }
    if (!mounted) return;

    // **The quote must be for THIS text, and settled.**
    //
    // `_fee` is deliberately held across a keystroke so the figure does not
    // blink. That is right for a display and wrong for a decision: sending
    // inside the debounce would
    // broadcast, with no sheet, a message whose fee the user has never seen,
    // and the price on the glass is the entire safety argument for turning the
    // sheet off (`consensus-auditor`, this sitting). Anything else falls
    // through to the ceremony, which prices it in front of them.
    if (!ceremony && _fee != null && !_feePending && _feeFor == text) {
      try {
        final outcome = await _messaging.sendCommNow(
          widget.conversationId,
          text,
        );
        if (!mounted) return;
        if (outcome.submitted > 0) {
          _compose.clear();
          await _pull();
          return;
        }
      } on AppError catch (e) {
        if (!mounted) return;
        // **A refusal from the ceremony-free door OPENS the ceremony.**
        //
        // Every post-build refusal — an unexpected kind, a destination that is
        // not this conversation's own, a fee over the ceiling — is a case
        // worth a second look, and the sheet IS the second look. Showing the
        // sentence and stopping would leave the user tapping into the same
        // refusal with the control that could resolve it turned off
        // (`wallet-security-auditor`, this sitting).
        //
        // The sentence still rides the composer, because it says WHY the sheet
        // appeared when the user had turned it off — the fee refusal names the
        // figure, which is the whole reason that arm exists.
        setState(() => _sendRefusal = e.message);
      }
      // Fell through: refused after the build, or submitted nothing and threw
      // nothing. Either way the ceremony is the honest next step rather than a
      // report of a send that did not happen.
      if (!mounted) return;
    }

    final sent = await _confirmSend(
      prepare: () => _messaging.prepareComm(widget.conversationId, text),
      title: 'Confirm message',
      // **The toggle rides the PLAIN MESSAGE ceremony only** — a switch on a
      // sheet it does not change is a control that lies
      // (`wallet-security-auditor`, MSG-M1). The funnel is shared with the
      // attachment send, which the preference governs no more than it did the
      // arcade frames it used to share it with.
      footer: _SigningToggle(messaging: _messaging),
    );
    if (sent) _compose.clear();
  }

  /// Save a file attachment to the device.
  ///
  /// The bytes are fetched only now, never with the thread pull: rendering a
  /// card needs the description, and shipping every attachment's bytes across
  /// the bridge to draw one would be waste for the common case and unbounded
  /// for the hostile one.
  Future<void> _saveAttachment(String txid) async {
    KvHaptic.selection();
    try {
      final saved = await _messaging.saveAttachment(
        widget.conversationId,
        txid,
      );
      // A cancel returns null and says nothing — backing out of the picker is
      // a decision, not something to report back at the user.
      if (!mounted || saved == null) return;
      // Remember WHERE it went. That is what lets "Open" hand the phone the
      // user's own file instead of making a second decrypted copy to point at.
      setState(() => _saved[txid] = saved);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved ${saved.name}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
  }

  /// Open a saved file with whatever the phone has for it.
  Future<void> _openSaved(String txid, String mime) async {
    final saved = _saved[txid];
    if (saved == null) return;
    KvHaptic.selection();
    try {
      final opened = await _messaging.openSavedFile(saved.uri, mime);
      if (!mounted || opened) return;
      // Nothing installed can open this type. That is a fact about the phone,
      // not a failure of ours, and it is said plainly.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No app on this phone can open that file type.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
  }

  /// Decoded bytes for images we render in place, one fetch per message.
  Future<Uint8List> _imageBytes(String txid) => _imageCache.putIfAbsent(
    txid,
    () => _messaging.attachmentBytes(widget.conversationId, txid),
  );

  @override
  Widget build(BuildContext context) {
    // **Latch the keyboard's height while it is up — from the ROOT view.**
    //
    // `MediaQuery.viewInsetsOf(context)` is the wrong reader here and it is
    // wrong silently: `Scaffold` with `resizeToAvoidBottomInset` (the default)
    // strips the bottom view inset from its body's `MediaQuery` precisely
    // because it has already resized for it — so a read from inside the body
    // is always 0, the latch never fires, and the panel falls back to a
    // guessed height. That is the *"not tall enough"* the founder saw.
    //
    // `View.of(context)` is the window itself, below every widget that
    // consumes insets, and its `viewInsets` are physical pixels — hence the
    // divide by `devicePixelRatio`.
    final view = View.of(context);
    final inset = view.viewInsets.bottom / view.devicePixelRatio;
    if (inset > 0 && inset != _keyboardHeight) _keyboardHeight = inset;
    // **Keep the reader where they were as the bottom space changes.** Our
    // panel and the keyboard are the same kind of event to the list, so both
    // are measured here and neither needs to know about the other.
    final taken = inset > 0
        ? inset
        : (_emojiUp
              ? (_keyboardHeight > 0 ? _keyboardHeight : _panelFallback)
              : 0.0);
    if (taken != _bottomSpace) {
      final delta = taken - _bottomSpace;
      _bottomSpace = taken;
      if (delta > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final target = (_scroll.position.pixels + delta).clamp(
            0.0,
            _scroll.position.maxScrollExtent,
          );
          // Jump, never animate: this rides the keyboard's OWN animation, and
          // a second easing on top of it is the wobble every chat app that
          // gets this wrong has.
          _scroll.jumpTo(target);
        });
      }
    }
    // The keyboard has arrived — our panel can go now, and only now.
    if (_awaitingKeyboard && inset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_awaitingKeyboard) return;
        setState(() {
          _awaitingKeyboard = false;
          _emojiUp = false;
        });
      });
    }
    final theme = Theme.of(context);
    final address = widget.contactAddress;
    final initial = _nameOf(widget.contactLabel);
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            // `M4`'s bar: the way back, then the person — their disc, their
            // name, and the key the name stands for (see [KvTopBar.avatar]).
            KvTopBar(
              title: widget.contactLabel,
              onBack: () => Navigator.of(context).maybePop(),
              // [KvContactAvatar] — §4's contact face, the same object the
              // Send screen's address book draws (BG-21). `null` is the
              // stranger, which is what an unnamed counterparty is.
              avatar: KvContactAvatar(name: initial, size: KvRowDisc.person),
              subtitle: address.isEmpty
                  ? null
                  : KvAddress(
                      address,
                      form: KvAddressForm.compact,
                      fontSize: 12,
                    ),
              trailing: KvIconButton(
                mark: KvGlyph.kebab,
                label: 'Thread actions',
                tone: KvColor.inkDim,
                onTap: _threadActions,
              ),
            ),
            Expanded(child: KvColumn(gutter: false, child: _body(theme))),
            // **A refusal belongs where the send was attempted.** With the
            // confirm sheet turned off there is no other surface to carry
            // one, and a SnackBar over a composer is gone before a thumb has
            // moved.
            //
            // **And it EASES**, rather than appearing between two frames and
            // shoving the composer down — the comment claimed motion this had
            // to grow (BG-24, `ux-auditor`). `AnimatedSize` over an empty box
            // is the house's own way of saying *nothing appears without the
            // motion that accounts for it*, and reduced motion collapses it.
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : KvMotion.calm,
              curve: KvMotion.curve,
              alignment: Alignment.bottomCenter,
              child: _sendRefusal == null
                  ? const SizedBox(width: double.infinity)
                  : KvColumn(
                      child: Padding(
                        padding: const EdgeInsets.only(top: KvSpace.s),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 2),
                              child: KvGlyphIcon(
                                KvGlyph.info,
                                size: 16,
                                tone: KvColor.warn,
                              ),
                            ),
                            const SizedBox(width: KvSpace.s),
                            Expanded(
                              child: Text(
                                _sendRefusal ?? '',
                                style: const TextStyle(
                                  fontFamily: KvFont.ui,
                                  fontSize: 13,
                                  height: 18 / 13,
                                  fontWeight: FontWeight.w400,
                                  fontVariations: KvWeight.w400,
                                  color: KvColor.warnInk,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            // **A revived thread has no composer until a handshake goes
            // out** (D-307): their message minted this row after a wipe took
            // the alias they know us by, and a reply sent under a fresh one
            // would be built, signed, paid for and read by nobody — the
            // D-162 sink. Rust refuses that send; this is the honest face of
            // the refusal, with the one repair the protocol has. It watches
            // the list, so the composer returns on the pull that records our
            // new alias.
            ValueListenableBuilder<List<ConversationDto>>(
              valueListenable: _messaging.conversations,
              builder: (context, rows, _) {
                final row = rows
                    .where((c) => c.conversationId == widget.conversationId)
                    .firstOrNull;
                final revived = row != null && row.replyNeedsHandshake;
                // **The swap eases** (BG-24): the composer returns on the
                // pull after the handshake commits, on a settled screen, and
                // a field appearing between two frames where a plate stood
                // is a cut. Zero under reduced motion, like every ease here.
                // And the SEAT eases with it: a switcher alone crossfades
                // the faces while the height steps in one frame, shoving the
                // thread above it by the difference between a one-line field
                // and the plate (`ux-auditor`, MSG-BLOCK — the `KvSearchField`
                // class). The old face is pinned to the new bounds so it
                // never floats mid-plate during the fade.
                return AnimatedSize(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : KvMotion.calm,
                  curve: KvMotion.curve,
                  alignment: Alignment.bottomCenter,
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : KvMotion.calm,
                    switchInCurve: KvMotion.curve,
                    switchOutCurve: KvMotion.curve,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        for (final old in previous) Positioned.fill(child: old),
                        ?current,
                      ],
                    ),
                    child: revived
                        ? _ReplyNeedsHandshake(
                            key: const ValueKey('reply-needs-handshake'),
                            bond: _messaging.handshakeBondSompi,
                            onSend: _sendHandshake,
                          )
                        : KeyedSubtree(
                            key: const ValueKey('composer'),
                            child: KvColumn(
                              child: Padding(
                                padding: const EdgeInsets.only(
                                  top: KvSpace.s,
                                  bottom: KvSpace.sm,
                                ),
                                // **ONE container: the words above, the controls in its
                                // bottom-right corner** (founder, 2026-09-08: *"the send
                                // button, the input, the emoji and all is in one container and
                                // the send button and emoji always stay at the bottom right
                                // corner of the chat input container, while the texts are
                                // above and clearly seen and aligned even if the texts are
                                // much"*).
                                //
                                // The shape before this was a pill with the controls INSIDE it
                                // on one line, which is WhatsApp's for a single line and comes
                                // apart the moment a message is long: the marks ride the last
                                // line, so they drift down the box as it grows and the text
                                // has to flow around them. Claude's and Gemini's composers
                                // solve it the same way this now does — the text owns its own
                                // full width at the top, and the controls own a fixed row
                                // under it. Nothing reflows as the message grows; the box just
                                // gets taller.
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    10,
                                    8,
                                    6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: KvColor.plate,
                                    borderRadius: BorderRadius.circular(
                                      KvRadius.bubble,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextField(
                                        controller: _compose,
                                        focusNode: _composeFocus,
                                        minLines: 1,
                                        // Taller than the old four: the container no longer
                                        // has to share its line with anything, so a long
                                        // message can actually be read before it is sent.
                                        maxLines: 6,
                                        keyboardType: TextInputType.multiline,
                                        textInputAction:
                                            TextInputAction.newline,
                                        cursorColor: KvColor.primary,
                                        style: const TextStyle(
                                          fontFamily: KvFont.ui,
                                          fontSize: 15,
                                          height: 20 / 15,
                                          fontWeight: FontWeight.w400,
                                          fontVariations: KvWeight.w400,
                                          color: KvColor.ink,
                                        ),
                                        decoration: const InputDecoration(
                                          isDense: true,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding: EdgeInsets.zero,
                                          hintText: 'Message',
                                          hintStyle: TextStyle(
                                            fontFamily: KvFont.ui,
                                            fontSize: 15,
                                            height: 20 / 15,
                                            fontWeight: FontWeight.w400,
                                            fontVariations: KvWeight.w400,
                                            color: KvColor.inkMeta,
                                          ),
                                        ),
                                      ),
                                      // **A tiny gap, not a breath** (founder, 2026-09-08:
                                      // *"reduce the padding between the message input and the
                                      // emoji/send icon … just a tiny gap"*). The row below
                                      // belongs to the box the words are in; separating them
                                      // made it read as a second object.
                                      const SizedBox(height: 2),
                                      // **The controls' own row, pinned to the bottom.** The
                                      // fee sits at its left because that is the one piece of
                                      // empty space in the box and it puts the price
                                      // immediately beside the control that spends it — still
                                      // tiny, still by the send mark, and no longer a floating
                                      // line above a container it does not belong to.
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Expanded(
                                            child: _ComposerFee(sompi: _fee),
                                          ),
                                          _EmojiKey(
                                            showingEmoji: _emojiUp,
                                            onTap: _toggleEmoji,
                                          ),
                                          // The two marks are one control group, so they sit
                                          // together rather than evenly spread across the row.
                                          _SendMark(
                                            armed:
                                                _draft.trim().isNotEmpty &&
                                                !_sending,
                                            // A disabled control says WHY, and the two reasons
                                            // it can be disabled are different facts (BG-12).
                                            reason: _sending
                                                ? 'Sending…'
                                                : 'Write a message first',
                                            onTap: _send,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                );
              },
            ),
            // **Our emoji panel takes the keyboard's place, never the
            // thread's.** It opens where the system keyboard was, so the
            // messages above do not move when you switch between them —
            // which is the whole reason the keyboard goes down first.
            AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : KvMotion.enter,
              curve: KvMotion.curve,
              alignment: Alignment.topCenter,
              child: _emojiUp
                  ? _EmojiPanel(
                      // The keyboard's own height, so the swap moves nothing.
                      height: _keyboardHeight > 0
                          ? _keyboardHeight
                          : _panelFallback,
                      onPick: _insertEmoji,
                      onBackspace: _backspace,
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  /// The thread's own overflow — Block, and whatever a thread grows next.
  /// (The arcade composer that once lived here went with the challenge
  /// surface, D-322.)
  Future<void> _threadActions() async {
    KvHaptic.selection();
    final action = await Navigator.of(context).push<String>(
      KvSheetRoute<String>(
        builder: (_) => _ThreadActionsSheet(
          // A block is keyed on the address (D-308); a thread whose
          // counterparty the node has not named yet cannot carry it.
          canBlock: widget.contactAddress.isNotEmpty,
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'block') await _blockContact();
  }

  /// **Block, from inside the thread** (D-308) — the same question the list
  /// asks, in the same words. The thread closes on success: the row it drew
  /// no longer exists, and a screen over a conversation that has been reset
  /// to strangers would be a view of nothing.
  Future<void> _blockContact() async {
    final confirmed = await confirmBlockContact(
      context,
      label: widget.contactLabel,
      address: widget.contactAddress,
      isInvitation: false,
    );
    if (!confirmed || !mounted) return;
    try {
      await _messaging.block(widget.conversationId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
      return;
    }
    if (!mounted) return;
    // The messenger is the app's, so the line survives the pop below.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Blocked. Only a new request from them reaches you.'),
      ),
    );
    Navigator.of(context).pop();
  }

  /// **The one repair a revived thread has** (D-307): a fresh handshake to an
  /// address we already know, announcing the alias this phone no longer had.
  /// Rust reuses the revived row for it (`transport_prepare_handshake`), so
  /// the thread keeps its id and its messages; the commit records our alias
  /// and the composer comes back on the next pull.
  Future<void> _sendHandshake() async {
    try {
      await runConfirmSend(
        context,
        prepare: () => _messaging.prepareHandshake(widget.contactAddress),
        commit: _messaging.commit,
        abandon: _messaging.abandon,
        title: 'Confirm handshake',
        preparingObject: 'handshake',
        contextNote:
            'Carries a ${kasCanonical(_messaging.handshakeBondSompi)} KAS '
            'bond, the network norm. Their app already has you, so it takes '
            'the new alias silently and keeps the bond.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
    await _messaging.refresh();
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      return const Center(child: KvLoader());
    }
    if (_lockedMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const KvGlyphIcon(
                KvGlyph.lock,
                tone: KvColor.inkDim,
                size: KvSpace.xl,
              ),
              const SizedBox(height: KvSpace.m),
              Text(
                _lockedMessage!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: KvColor.inkDim,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet.',
          style: theme.textTheme.bodyMedium?.copyWith(color: KvColor.inkDim),
        ),
      );
    }
    return AnimatedList(
      key: _listKey,
      controller: _scroll,
      padding: const EdgeInsets.all(KvSpace.m),
      initialItemCount: _messages.length,
      itemBuilder: (context, index, animation) {
        final m = _messages[index];
        // The archive marker is a BOUNDARY, not a per-message tag. It fires on
        // the last archive-sourced row of a run — i.e. exactly where our own
        // node's view of the thread begins — so a restored history carries one
        // honest line instead of one per bubble.
        final next = index + 1 < _messages.length ? _messages[index + 1] : null;
        final prev = index > 0 ? _messages[index - 1] : null;
        // Grouping: a message CLOSES a run when the next one comes from the
        // other side, lands on another day, or arrives more than a few minutes
        // later. Only the closing message carries a time and the bubble tail —
        // stamping every line makes a fast exchange unreadable, and a run of
        // tails turns a conversation into a column of arrows.
        final closesRun =
            next == null ||
            next.outbound != m.outbound ||
            !_sameDay(next.unixMs, m.unixMs) ||
            _gap(m.unixMs, next.unixMs) > _runGap;
        // Continues the run above ⇒ tighter spacing, so a burst reads as one
        // utterance rather than three unrelated ones.
        final continues =
            prev != null &&
            prev.outbound == m.outbound &&
            _sameDay(prev.unixMs, m.unixMs) &&
            _gap(prev.unixMs, m.unixMs) <= _runGap;
        final showDay = prev == null || !_sameDay(prev.unixMs, m.unixMs);
        final archiveBoundary =
            m.provenance == 'archive' &&
            (next == null || next.provenance != 'archive');
        // Is EVERYTHING above this line restored? The fill runs at every open
        // and lands rows in block-time order, so archive rows interleave with
        // our own sent messages and node-scanned ones. A mid-thread run must
        // not claim the user's own messages were restored.
        final allAboveRestored =
            archiveBoundary &&
            !_messages
                .take(index)
                .any((older) => older.provenance != 'archive');
        // The DS entrance for inserted rows: a fixed 24dp rise + fade
        // (§6 — never row-height-relative, so a tall challenge card rises
        // exactly as far as a one-liner), decelerate-only; reduced motion
        // degrades to the fade alone; initial rows build with a completed
        // animation (no replay).
        final curved = CurvedAnimation(
          parent: animation,
          curve: KvMotion.curve,
        );
        final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        Widget row = _MessageRow(
          key: ValueKey(m.txid),
          message: m,
          showTime: closesRun,
          tail: closesRun,
          continuesRun: continues,
          archiveBoundary: archiveBoundary,
          allAboveRestored: allAboveRestored,
          chip: _chipFor(m),
          delivered: _deliveredFor(m),
          acceptedUnixMs: _statuses[m.txid]?.acceptance?.acceptedUnixMs,
          ghost: _ghostFor(m),
          onSaveFile: _saveAttachment,
          onOpenFile: _openSaved,
          savedFile: _saved[m.txid] != null,
          imageBytes: _imageBytes,
        );
        // The day separator belongs to the item, not between items: an
        // AnimatedList indexes its own children, so a separator inserted as a
        // sibling would desynchronise every insert animation from its row.
        if (showDay) {
          row = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DaySeparator(unixMs: m.unixMs),
              row,
            ],
          );
        }
        if (!reduced) {
          row = AnimatedBuilder(
            animation: curved,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, (1 - curved.value) * KvMotion.entranceOffset),
              child: child,
            ),
            child: row,
          );
        }
        return FadeTransition(opacity: curved, child: row);
      },
    );
  }
}

/// Human title (emoji + name) for a game slug — the card's identity, mapped
/// from the same slug the Rust line-generator uses (`core::frames::game_label`).
/// How far apart two messages from the same side may be and still read as one
/// utterance. Beyond it the run breaks, the later message gets its own time,
/// and the bubble above closes with a tail.
const Duration _runGap = Duration(minutes: 5);

/// The card thumbnail's decode width. Named because `dispose` must evict the
/// exact `ResizeImage` key the decode created — a literal in two places is a
/// leak the day one of them changes.
const int _thumbnailWidth = 600;

DateTime _at(BigInt unixMs) =>
    DateTime.fromMillisecondsSinceEpoch(unixMs.toInt());

bool _sameDay(BigInt a, BigInt b) {
  final x = _at(a);
  final y = _at(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// Absolute gap — message times come from the chain (or, for an archive row,
/// from an indexer that can stamp anything, D-074), so they are not guaranteed
/// monotonic and a negative difference must not silently read as "adjacent".
Duration _gap(BigInt a, BigInt b) => _at(a).difference(_at(b)).abs();

/// The clock face for one message. Uses the platform's own formatter so a
/// phone set to 12-hour time gets 12-hour time — the wallet does not get to
/// pick the user's clock.
String _clock(BuildContext context, BigInt unixMs) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(_at(unixMs)),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// **"Turn off signing for messages"**, on the message sending sheet — the
/// founder's ruling of 2026-09-08, in his own words: *"users who prefer not
/// signing everytime they want to send a message can absolutely do so (dont
/// argue this. i want it)."*
///
/// ## What it turns off, said plainly because the word matters
///
/// **The ceremony, never the signature.** Every transaction this wallet
/// broadcasts is signed in Rust behind the vault, and no preference reaches
/// that (INV-2). What this removes is the confirm step — the sheet you are
/// reading it on. With it off, a message sends on the tap, for the fee already
/// shown above the send button.
///
/// ## The bounds, all of which live in Rust
///
/// `transport_send_comm_now` is the only unceremonious door in the bridge, and
/// it refuses anything that is not a plain message: a handshake, an acceptance
/// (which refunds a counterparty's bond), a stash and a payment are not
/// expressible through it. It re-reads this preference, re-checks the BUILT
/// transaction's kind and destination against the conversation's own bound
/// address, and refuses a fee above the ceiling — which is what keeps the
/// toggle honest on a lane whose payload can be a large attachment.
///
/// **Default on**, mirrored in message settings so it can be turned back on
/// without first sending something, and read fresh on every send so the two
/// surfaces cannot disagree.
class _SigningToggle extends StatefulWidget {
  const _SigningToggle({required this.messaging});

  final MessagingService messaging;

  @override
  State<_SigningToggle> createState() => _SigningToggleState();
}

class _SigningToggleState extends State<_SigningToggle> {
  /// Null until the preference has been read. The row does not render at all
  /// until then: a switch that flicks from a guess to the truth on the second
  /// frame is a control lying about the state it governs (BG-24).
  bool? _signing;

  /// Why the last flip did not stick, said under the row.
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final signing = await widget.messaging.messageSigning();
      if (mounted) setState(() => _signing = signing);
    } catch (_) {
      // Unreadable ⇒ the ceremony, which is the state you are already in.
      if (mounted) setState(() => _signing = true);
    }
  }

  Future<void> _set(bool signing) async {
    KvHaptic.selection();
    setState(() {
      _signing = signing;
      _error = null;
    });
    try {
      await widget.messaging.setMessageSigning(signing);
    } catch (e) {
      // The write failed, so the row goes back to what is actually stored
      // rather than showing a choice the device did not keep — and it says so
      // where it happened. §4: this language has no toasts, and a reason that
      // vanishes on a timer is not a reason (`ux-auditor`, 2026-09-08).
      if (!mounted) return;
      setState(() {
        _signing = !signing;
        _error = displayError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final signing = _signing;
    // **It eases in** (BG-24). The preference is read asynchronously, so
    // without this a ~70 dp control appears between two frames and grows the
    // sheet immediately before the hold that commits money — the same defect
    // the composer's refusal line was wrapped for in this sitting
    // (`ux-auditor`, 2026-09-08).
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : KvMotion.calm,
      curve: KvMotion.curve,
      alignment: Alignment.topCenter,
      child: signing == null
          ? const SizedBox(width: double.infinity)
          : _row(signing),
    );
  }

  Widget _row(bool signing) {
    return KvToggle(
      bare: true,
      // The ceremony's body sits on `plate`, so `inkMeta` is legal here —
      // stated rather than defaulted, because the same control on `chip` in
      // message settings is not (BG-14, §1.4).
      ground: KvColor.plate,
      // **The switch is ON when signing is OFF**, because the founder's label
      // names the ACT ("turn off signing"), not the state. A toggle whose
      // label and position disagree is the classic settings defect, so the
      // sub-line below says what each position means outright.
      on: !signing,
      // One fact, one string — shared with `M5`'s mirror (BG-21).
      title: signingToggleTitle,
      // A failed write speaks here, in the seat the sub-line already owns —
      // the switch has already sprung back, and this says why.
      sub: _error ?? signingToggleSub(signing),
      onChanged: (off) => _set(!off),
    );
  }
}

/// **What this message will cost, streaming as it is typed** — tiny, above the
/// send mark (founder, 2026-09-08: *"the fee must be tiny above the send
/// button"*).
///
/// It is the send screen's `_FeeRow` at composer scale and under the same two
/// laws, which is why it is a sibling and not a copy of the idea:
///
///  - **money never streams.** The figure is crossfaded, never counted up: a
///    counter tweening toward a fee renders values the Generator never quoted,
///    on a surface that commits money.
///  - **an unknown fee is nothing, never zero.** No quote yet, a locked
///    vault, a bound address with no mature coins — the slot is empty and the
///    send falls through to the confirm sheet, which states Rust's own reason.
///    `0.0000` here would be a wallet claiming this message is free.
///
/// **The slot holds its height whether or not there is a figure** (BG-24), so
/// nothing below it moves on the first keystroke. Opacity is the only thing
/// that changes, and it changes between 0 and 1 — never to a dim.
class _ComposerFee extends StatelessWidget {
  const _ComposerFee({required this.sompi});

  /// The current quote, or the last one while a fresh probe is in flight.
  ///
  /// **It is never marked as stale on the glass**, and it does not need to be:
  /// a held quote reads as the last thing the Generator said, which is true,
  /// and the send arm refuses to act on one that is not for the text in the
  /// field. Marking it cost 1.93:1 at this size, which is what removed it.
  final BigInt? sompi;

  /// Measured off the composer, not chosen: the mark below is 44 dp of visual
  /// control, and this line is the smallest the Bible allows a figure with a
  /// unit to be set at — 11 dp, which clears BG-14's floor.
  static const double _size = 11;

  @override
  Widget build(BuildContext context) {
    final fee = sompi;
    return SizedBox(
      // **In the composer's own bottom row, at its left.**
      //
      // It has moved twice and both moves were the same lesson. Beside the
      // send mark in a non-flex column it SIZED the field next to it
      // (measured off the frames: 299 → 271 dp at 393 on the first
      // keystroke); on its own line above the box it held its size but
      // floated over a container it did not belong to. Inside the box, on the
      // row the controls own, it takes the one piece of empty space there is
      // and costs the words nothing — that row's height is already set by the
      // marks beside it.
      //
      // **The height takes the scaler.** Measured with a `TextPainter`: this
      // line box is 14.0 / 16.0 / 18.0 dp at 1.0 / 1.15 / 1.3, so a fixed 14
      // clips from 1.15 upward and the digits survive 1.0 by 0.35 dp
      // (`ux-auditor`, measured). This is the figure BG-6's new exception
      // rests on; it may not be the thing that clips.
      height: MediaQuery.textScalerOf(context).scale(14),
      child: AnimatedOpacity(
        duration: KvMotion.fast,
        curve: KvMotion.curve,
        // **Full strength or nothing.** It used to dim to 45% while a probe
        // ran, which at 11 dp `inkMeta` on `abyss` is 1.93:1 — the row §1.4
        // records as failing, held for the whole debounce on every keystroke
        // run (`ux-auditor` BLOCK). The pending state costs nothing to say
        // this way: the send arm already refuses to act on a quote that is not
        // for the text in the field, so a figure on screen is never the thing
        // a decision rests on unless it is current.
        opacity: fee == null ? 0 : 1,
        // **The figure is mono, the unit is Jakarta** (BG-30) — the same two
        // faces `M5`'s bond row sets, one class over. The figure is trimmed by
        // [kasCanonical], which is the send screen's own rule, so one payment
        // and one message never print a fee two ways.
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: fee == null ? '' : kasCanonical(fee),
                  style: const TextStyle(
                    fontFamily: KvFont.mono,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                TextSpan(
                  text: fee == null ? '' : ' KAS',
                  style: const TextStyle(fontFamily: KvFont.ui),
                ),
              ],
            ),
            maxLines: 1,
            textAlign: TextAlign.start,
            // §2 sets `metaMono` at 500. (The face itself declares wght
            // 100–800 with a 400 default — read from the variable font's
            // `fvar`, not remembered; an earlier comment here claimed the
            // range started at 500.)
            style: const TextStyle(
              fontSize: _size,
              height: 14 / _size,
              fontWeight: FontWeight.w500,
              fontVariations: KvWeight.w500,
              color: KvColor.inkMeta,
            ),
          ),
        ),
      ),
    );
  }
}

/// **The send control: a mark on the ground, and nothing else** (founder,
/// 2026-09-08: *"does it need to be in a teal or grey circle? why not make it
/// simply the send icon only, that lights up teal to send. so that we can even
/// widen the text input more"*).
///
/// The disc went for the reason he gives: it was 44 dp of painted circle whose
/// only job was to carry a 20 dp mark, and the ring around that mark came out
/// of the field beside it. **The target did not go** — it is still
/// [KvSpace.touchTarget] wide of tappable area (BG-12); what is drawn inside it
/// is now just the glyph.
///
/// **BG-27 still decides the ink, which is the whole signal.** `primary` when
/// there is something to commit, `etch` when there is not — the same rule the
/// disc carried, now said in one channel instead of two. That is also why this
/// is no longer [KvIconButton]: that part IS a 44 dp disc by its own
/// definition, and borrowing it to draw no disc would make its geometry a lie.
class _SendMark extends StatelessWidget {
  const _SendMark({
    required this.armed,
    required this.reason,
    required this.onTap,
  });

  final bool armed;

  /// Why it cannot be pressed, when it cannot. Two different facts — an empty
  /// draft, and a send already in flight — and a screen reader is told which.
  final String reason;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: armed,
      label: 'Send',
      hint: armed ? null : reason,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: armed ? onTap : null,
          child: SizedBox(
            // Square-ish, and still BG-12's floor of tappable width — the
            // box's own padding gives the rest of the target.
            width: KvSpace.touchTarget,
            height: 36,
            child: Center(
              child: AnimatedSwitcher(
                duration: KvMotion.fast,
                child: KvGlyphIcon(
                  KvGlyph.send,
                  key: ValueKey(armed),
                  size: 24,
                  tone: armed ? KvColor.primary : KvColor.etch,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The line between one day's messages and the next.
///
/// "Today"/"Yesterday" for the two days a reader holds in their head, then the
/// §5 UI date form (`June 30, 2026`) — never the ISO form, which §5 reserves
/// for technical surfaces.
class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.unixMs});

  final BigInt unixMs;

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String _label() {
    final at = _at(unixMs);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(at.year, at.month, at.day);
    final days = today.difference(that).inDays;
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    return '${_months[at.month - 1]} ${at.day}, ${at.year}';
  }

  @override
  Widget build(BuildContext context) {
    // `M4` draws the day as bare caps on the ground — no chip, no rule. The
    // chip was a container around a label, which BG-4 calls a boundary saying
    // nothing: a date is not an object, it is where the thread changes day.
    // The `caps` role (§2), measured off `M4` at cap 8.25 ÷ 0.773.
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.l, bottom: KvSpace.sm),
      child: Center(
        child: Container(
          // **In a pill, not bare on the ground** (founder, 2026-09-08).
          //
          // UX-R5 took the chip OFF this label on the reasoning that a
          // boundary around a label is a boundary around nothing. That was
          // right for a divider and wrong for this: a day separator floats
          // over a scrolling column of bubbles, and a bare caps line reads as
          // a message that lost its bubble. The pill says *this is chrome, not
          // something anyone said* — which is exactly what a boundary is for.
          decoration: BoxDecoration(
            color: KvColor.chip,
            borderRadius: BorderRadius.circular(KvRadius.control),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: KvSpace.sm,
            vertical: KvSpace.xs,
          ),
          child: Text(
            _label().toUpperCase(),
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 16 / 11,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w600,
              fontVariations: KvWeight.w600,
              // `inkDim` on `chip`, never `inkMeta` — 4.30 against 7.36, and
              // §1.4 forbids the first on this ground (BG-14).
              color: KvColor.inkDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// Long-press a message to copy it.
///
/// **Why this is allowed, next to code this strict about plaintext.** §0.4 is
/// the plaintext DISCIPLINE — ciphertext at rest, decrypt-on-view, nothing
/// decrypted held in a state manager — and it governs how long the APP keeps
/// your words, not what you may do with them. The user's half was settled
/// twice already, both times the same way: saving an attachment writes
/// decrypted bytes to storage, and FLAG_SECURE is deliberately NOT applied to
/// threads because "message content is user conversation, NOT seed material —
/// screenshots stay the user's choice". A screenshot leaks strictly more than
/// a clipboard entry.
///
/// The clipboard law that DOES bind is BG-10, and it forbids exactly one thing:
/// seed material to the clipboard. Untouched — this copies a message, and only
/// a readable one, because an unreadable row is a txid and no words.
Future<void> _copyMessage(BuildContext context, String text) async {
  KvHaptic.selection();
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Message copied'), duration: KvMotion.pulse),
  );
}

/// The one decoration a message bubble wears, so the text bubble and the
/// attachment card can never drift apart.
///
/// Direction is carried THREE ways — side, hue, and the tail corner — because
/// any one of them alone fails somewhere: alignment collapses on a narrow
/// screen, hue is invisible to a colour-blind reader, and the tail only
/// appears on the last bubble of a run.
/// **A bubble has no edge** (`M4` measured: the ground steps straight to
/// `#121717` at x 25.00 with no intermediate tone, and to `#0F2E28` on the
/// outgoing side). BG-4 says a plate on the ground has none, and the bubble is
/// exactly that — a tone step is the whole boundary. It used to draw
/// `Border.all` on both sides, which is the boundary said twice.
BoxDecoration _bubbleDecoration({required bool outbound, required bool tail}) =>
    BoxDecoration(
      color: outbound ? KvColor.tealTint : KvColor.plate,
      borderRadius: _bubbleRadius(outbound: outbound, tail: tail),
    );

/// The bubble's corner set. Every corner takes the card radius except the one
/// nearest the speaker on the run's LAST bubble, which tightens to the data
/// radius — the tail. Direction is then legible without relying on alignment
/// alone, and a run of messages reads as one block with one tail.
BorderRadius _bubbleRadius({required bool outbound, required bool tail}) {
  // `KvRadius.bubble`, which exists for this and was not being used: the
  // corner was `card` (28) and `M4` solves to ~24 off three points on the
  // curve. 22 is the token within 2 dp; 28 is visibly rounder than the render.
  const big = Radius.circular(KvRadius.bubble);
  const small = Radius.circular(KvRadius.bubbleTail);
  return BorderRadius.only(
    topLeft: big,
    topRight: big,
    bottomLeft: tail && !outbound ? small : big,
    bottomRight: tail && outbound ? small : big,
  );
}

/// **A bubble caps off the COLUMN it is in, never off the window** (U2-1 /
/// U2-2, the defect this sub-phase exists to close).
///
/// Both call sites read `MediaQuery.sizeOf(context).width * 0.78`, which is
/// the whole window. On one column that is the same number and the bug is
/// invisible; the day the thread lands beside the list in a [KvTwoPane] —
/// which is `expanded`'s whole shape, already built for the ledger — a bubble
/// gets 78 % of a window it occupies half of, and every one of them overflows
/// its own pane. It is a latent defect that only a wide device shows, which is
/// exactly the kind BG-33 exists to catch before the device does.
///
/// [LayoutBuilder] asks the parent instead of the screen, so the answer is the
/// column in every window class and needs no branch on one.
///
/// The share stays ~78 %: a bubble that spans its column reads as a document,
/// and the visible opposite margin is what makes a thread read as a
/// conversation.
/// **The composer's trailing key: a smile, or a keyboard while ours is up.**
///
/// Founder ruling, 2026-09-08. One control, two marks, and the mark always
/// names where the tap GOES rather than where you are — which is the way every
/// messenger draws it and the only reading that survives being pressed twice.
///
/// It sits inside the field's pill, at its far right, and it is deliberately
/// smaller than [KvSpace.touchTarget] as a mark while its tap area is not: the
/// field is 44 tall, and a 52 dp control inside it would set the height of the
/// thing it lives in.
class _EmojiKey extends StatelessWidget {
  const _EmojiKey({required this.showingEmoji, required this.onTap});

  final bool showingEmoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: showingEmoji ? 'Show the keyboard' : 'Show emoji',
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 36,
            child: Center(
              child: KvGlyphIcon(
                showingEmoji ? KvGlyph.keyboard : KvGlyph.smile,
                size: 20,
                tone: KvColor.inkMeta,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// **The emoji panel** — ours, not the keyboard's (see `_toggleEmoji` for why).
///
/// A curated set rather than the whole Unicode table: these are the ones people
/// actually send, they cost no dependency and no font (Android draws them from
/// the system emoji font), and a grid of two thousand glyphs is a scroll nobody
/// finishes.
///
/// **A GRID, not a `Wrap`.** The first cut laid fixed-width cells out with
/// `Wrap`, which leaves whatever does not divide the row as a ragged gap on the
/// right — the founder saw it immediately (*"no unnecessary gaps to the right
/// as it kinda is"*). A grid divides the width it is given, so the columns are
/// even at every geometry and the last one lands on the edge.
class _EmojiPanel extends StatelessWidget {
  const _EmojiPanel({
    required this.height,
    required this.onPick,
    required this.onBackspace,
  });

  final double height;
  final ValueChanged<String> onPick;

  /// **A keyboard has a backspace, so this does** (founder, 2026-09-08). An
  /// emoji is easy to tap twice and there is no other way back without
  /// dismissing the panel to reach the real keyboard.
  final VoidCallback onBackspace;

  /// Grouped the way a keyboard groups them, most-used first.
  static const List<(String, List<String>)> groups = [
    (
      'Smileys',
      [
        '😀',
        '😃',
        '😄',
        '😁',
        '😆',
        '😅',
        '🤣',
        '😂',
        '🙂',
        '🙃',
        '😉',
        '😊',
        '😇',
        '🥰',
        '😍',
        '🤩',
        '😘',
        '😗',
        '😚',
        '😙',
        '🥲',
        '😋',
        '😛',
        '😜',
        '🤪',
        '😝',
        '🤗',
        '🤭',
        '🤔',
        '🤐',
        '😐',
        '😑',
        '😶',
        '😏',
        '😒',
        '🙄',
        '😬',
        '😮',
        '😯',
        '😲',
        '😳',
        '🥺',
        '😢',
        '😭',
        '😤',
        '😠',
        '😡',
        '🤯',
        '😱',
        '😰',
        '😥',
        '😓',
        '🫡',
        '🫠',
        '🥳',
        '😴',
      ],
    ),
    (
      'People',
      [
        '👍',
        '👎',
        '👌',
        '🤌',
        '✌️',
        '🤞',
        '🤟',
        '🤙',
        '👈',
        '👉',
        '👆',
        '👇',
        '☝️',
        '✋',
        '🤚',
        '🖐️',
        '🖖',
        '👋',
        '🤝',
        '🙏',
        '💪',
        '🫶',
        '👏',
        '🙌',
        '🤲',
        '🫂',
        '👀',
        '🧠',
      ],
    ),
    (
      'Hearts',
      [
        '❤️',
        '🧡',
        '💛',
        '💚',
        '💙',
        '💜',
        '🖤',
        '🤍',
        '🤎',
        '💔',
        '❣️',
        '💕',
        '💞',
        '💓',
        '💗',
        '💖',
        '💘',
        '💝',
        '💯',
        '💢',
        '💥',
        '💫',
        '💦',
        '💨',
        '🔥',
        '✨',
        '⭐',
        '🌟',
      ],
    ),
    (
      'Things',
      [
        '🎉',
        '🎊',
        '🎁',
        '🏆',
        '🥇',
        '⚡',
        '💡',
        '🔑',
        '🔒',
        '📌',
        '📎',
        '📷',
        '🎧',
        '🎮',
        '⚽',
        '🏀',
        '🚀',
        '✈️',
        '🚗',
        '🏠',
        '🌍',
        '🌙',
        '☀️',
        '⛅',
        '🌧️',
        '❄️',
        '🍀',
        '🌸',
      ],
    ),
    (
      'Food',
      [
        '🍎',
        '🍌',
        '🍇',
        '🍓',
        '🍉',
        '🍒',
        '🥑',
        '🍞',
        '🧀',
        '🍔',
        '🍟',
        '🍕',
        '🌮',
        '🍣',
        '🍜',
        '🍰',
        '🍩',
        '🍪',
        '☕',
        '🍵',
        '🍺',
        '🍻',
        '🥂',
        '🍷',
        '🥤',
        '🧊',
        '🍫',
        '🍿',
      ],
    ),
    (
      'Money',
      [
        '💰',
        '💵',
        '💸',
        '💳',
        '🪙',
        '📈',
        '📉',
        '📊',
        '🧾',
        '⚖️',
        '🤑',
        '💎',
        '🏦',
        '🔗',
      ],
    ),
  ];

  /// The backspace strip's height, taken off the scroll so the key is always
  /// reachable rather than scrolling away with the glyphs.
  static const double _footHeight = 44;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Column(
        children: [
          Expanded(
            child: CustomScrollView(
              slivers: [
                for (final (name, set) in groups) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        KvSpace.xs,
                        KvSpace.sm,
                        KvSpace.xs,
                        KvSpace.xs,
                      ),
                      child: Text(
                        name.toUpperCase(),
                        style: const TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 11,
                          height: 16 / 11,
                          letterSpacing: 1.1,
                          fontWeight: FontWeight.w600,
                          fontVariations: KvWeight.w600,
                          color: KvColor.inkMeta,
                        ),
                      ),
                    ),
                  ),
                  SliverGrid(
                    // Eight to a row, which is what a phone keyboard uses and
                    // what keeps a 24 dp glyph comfortably tappable at 320 dp.
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 8,
                          childAspectRatio: 1.05,
                        ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onPick(set[i]),
                        child: Center(
                          child: Text(
                            set[i],
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                      ),
                      childCount: set.length,
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: KvSpace.s)),
              ],
            ),
          ),
          SizedBox(
            height: _footHeight,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Semantics(
                  button: true,
                  label: 'Backspace',
                  child: ExcludeSemantics(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onBackspace,
                      child: const SizedBox(
                        width: KvSpace.touchTarget,
                        height: _footHeight,
                        child: Center(
                          child: KvGlyphIcon(
                            KvGlyph.backspace,
                            size: 22,
                            tone: KvColor.inkDim,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// **A message, with the delivered mark tucked into its bottom-right corner.**
///
/// Founder ruling, 2026-09-08: *"the placement for it should be inside the chat
/// bubble … at the right corner bottom of the bubble, same color that is used
/// for the time"*, and — the constraint that shapes the whole part — *"dont
/// increase any padding, just slap it"*.
///
/// **So it costs no height in the common case.** The technique is the one
/// WhatsApp and Telegram use: an invisible inline span the width of the mark is
/// appended to the LAST line only, and the mark is painted into the corner over
/// it. A last line with room keeps the mark on it; a last line that is full
/// pushes the reserve — and only the reserve — onto a new one, which is the
/// same behaviour those apps have and the only case where the bubble grows.
///
/// Reserving with padding instead would have indented every line; a `Column`
/// with a trailing row would have added a line's height to every message. Both
/// were tried on paper and both are what "don't increase any padding" rules
/// out.
class _BubbleText extends StatelessWidget {
  const _BubbleText({
    required this.text,
    required this.delivered,
    required this.style,
  });

  final String text;
  final bool delivered;
  final TextStyle? style;

  /// The mark's box, and the gap before it. Small on purpose — it is the
  /// bubble's fourth signal, behind the words, the side and the time.
  static const double _mark = 14;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final body = Text(text, style: style);
    if (!delivered) return body;
    return Stack(
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: text),
              // The reserve. `WidgetSpan` participates in line breaking, so
              // this is what keeps the last line from running under the mark.
              const WidgetSpan(child: SizedBox(width: _mark + _gap, height: 1)),
            ],
          ),
          style: style,
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: KvGlyphIcon(
            KvGlyph.checkDouble,
            size: _mark,
            // The time's own ink, which is what he asked for and also what
            // keeps a fourth signal from competing with the words.
            tone: KvColor.inkMeta,
          ),
        ),
      ],
    );
  }
}

class _BubbleWidth extends StatelessWidget {
  const _BubbleWidth({required this.child});

  /// **How much of the column a bubble may take.**
  ///
  /// Raised from 0.78 on the founder's own measurement (2026-09-08): a message
  /// he sent took **five lines here and four in WhatsApp and Telegram**, with
  /// the fifth holding one word. The cap was the cause — 0.78 of the column
  /// minus 12 dp of padding each side left markedly less text width than
  /// either of those apps gives, and greedy wrapping then spends a whole line
  /// on the word that would not fit.
  ///
  /// 0.84 with the tighter padding below restores roughly the width they use,
  /// while still leaving the ragged edge that says a bubble is a bubble rather
  /// than a full-width paragraph.
  static const double share = 0.84;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // An unbounded parent (a horizontal scroll, a test harness) has no
        // column to take a share of — fall back to the window rather than
        // multiplying infinity.
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width * share),
          child: child,
        );
      },
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    super.key,
    required this.message,
    this.showTime = false,
    this.tail = true,
    this.continuesRun = false,
    this.archiveBoundary = false,
    this.allAboveRestored = false,
    this.chip = TxChipState.none,
    this.delivered = false,
    this.acceptedUnixMs,
    this.ghost = false,
    this.onSaveFile,
    this.onOpenFile,
    this.savedFile = false,
    this.imageBytes,
  });

  final ThreadMessageDto message;

  /// This message closes a run, so it carries the clock time. Suppressed on
  /// system rows, which are not something anyone said.
  final bool showTime;

  /// This message closes a run, so its bubble gets the tail corner.
  final bool tail;

  /// This message continues the run above ⇒ tighter spacing.
  final bool continuesRun;

  /// True on the LAST archive-sourced row of a run — the point where our own
  /// node's view of the thread takes over. See the builder in [_ThreadScreen].
  final bool archiveBoundary;

  /// True when every row above the boundary is archive-sourced — the only
  /// case where "everything above" is a true statement. The fill runs at
  /// every open and lands rows in block-time order, so archive rows
  /// interleave with the user's own sent messages; a mid-thread run must not
  /// claim those were restored.
  final bool allAboveRestored;

  /// V2 status chip for outbound rows ([TxChipState.none] renders nothing).
  final TxChipState chip;

  /// A block has accepted this message — the double check inside the bubble.
  /// Outbound rows only: a message somebody sent US was delivered by
  /// definition, and marking it would be telling them their own news.
  final bool delivered;

  /// **The accepting block's own header timestamp**, when the chain has one.
  ///
  /// Founder ruling, 2026-09-08: *"make the accepted honest the exact time a
  /// block finds it (very honest and just right on time!)"*. The row's own
  /// `unix_ms` is when THIS DEVICE recorded the send; this is when the network
  /// took it, and once the two are both known the honest one wins. Null until
  /// acceptance lands, or where the accepting block could not be fetched — the
  /// clock then keeps saying what it can back.
  final BigInt? acceptedUnixMs;

  /// V2 reorg ghost: the accepting block was displaced and hasn't returned —
  /// the row dims to the BG-8 stale opacity with an honest line, and lifts
  /// again if the network re-accepts it (reversible by construction).
  final bool ghost;

  /// Save this message's file attachment to the device (by txid).
  final void Function(String txid)? onSaveFile;

  /// Open the already-saved file (txid, media type).
  final void Function(String txid, String mime)? onOpenFile;

  /// True once this attachment has been saved — only then can it be opened,
  /// because opening points at the user's own file rather than a copy.
  final bool savedFile;

  /// Decoded bytes for an image we render in place.
  final Future<Uint8List> Function(String txid)? imageBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = message;
    final body = _content(context, theme);

    final ghosted = AnimatedOpacity(
      opacity: ghost ? KvFreshness.opacityStale : 1.0,
      duration: KvMotion.calm,
      curve: KvMotion.curve,
      child: body,
    );
    // ONE meta line under the bubble, never two stacked ones: the clock, the
    // reorg notice and the status chip all answer "what happened to this
    // message" and belong on the same row.
    //
    // A time is not shown on a system row — a handshake is not something
    // anyone said — and never on an unreadable one, where we hold a txid and
    // no message.
    final withTime = showTime && m.kind != 'handshake';
    // **The chip comes BEFORE the clock** (founder, 2026-09-08: *"let it show
    // before the time, not after it so that time can retain its position"*).
    // That ordering is the whole point of a transient label: `Accepted` arrives
    // to the LEFT of the clock, holds two seconds and dissolves, and the clock
    // has not moved — where a trailing chip would shove it sideways on the way
    // in and back on the way out.
    final meta = <Widget>[
      if (ghost)
        Text(
          'Displaced by the network',
          style: theme.textTheme.labelSmall?.copyWith(color: KvColor.inkMeta),
        )
      else if (chip != TxChipState.none)
        TxStatusChip(state: chip),
      if (withTime)
        Text(
          // The chain's own moment where it is known, this device's where it
          // is not (see [acceptedUnixMs]).
          _clock(context, acceptedUnixMs ?? m.unixMs),
          style: theme.textTheme.labelSmall?.copyWith(
            color: KvColor.inkMeta,
            fontFamily: KvFont.mono,
          ),
        ),
    ];
    // **The archive marker goes under the whole row — bubble AND clock.** It
    // wrapped the bubble alone, so the row's clock landed below "Everything
    // above was restored from an archive", outside the caveat, and for an
    // unconfirmed archive row that clock IS the archive-supplied value the
    // marker exists to qualify (F3; `ux-auditor`, UX-R8).
    if (meta.isEmpty) return _withProvenance(theme, m, ghosted);
    return _withProvenance(
      theme,
      m,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ghosted,
          Padding(
            padding: const EdgeInsets.only(top: KvSpace.xs, bottom: KvSpace.xs),
            child: Align(
              alignment: m.outbound
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, w) in meta.indexed) ...[
                    if (i > 0) const SizedBox(width: KvSpace.s),
                    w,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, ThemeData theme) {
    final m = message;

    if (m.kind == 'handshake') {
      // System row: the establishment/acceptance handshake — no body.
      //
      // This row can end an archive run and carry the boundary. It is
      // also the class that matters MOST: the
      // fill sweeps `handshakes/by-receiver` per receive address and folds each
      // result as a FillSourced row, which creates a conversation. So an archive
      // can manufacture a whole fake CONTACT, not merely append to a thread —
      // and an unmarked "Handshake received" is how that would look
      // (consensus-auditor, this wave).
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
        child: Center(
          child: Text(
            m.outbound ? 'Handshake sent' : 'Handshake received',
            style: theme.textTheme.labelSmall?.copyWith(color: KvColor.inkMeta),
          ),
        ),
      );
    }

    // A recognised `kv:1:` frame is not a surface (D-322): it falls through
    // to the plain bubble below and shows its readable line, exactly what a
    // Kasia user sees.

    final attachment = m.attachment;
    if (attachment != null) {
      return _AttachmentCard(
        file: attachment,
        outbound: m.outbound,
        heroTag: m.txid,
        tail: tail,
        onSave: onSaveFile == null ? null : () => onSaveFile!(m.txid),
        onOpen: (!savedFile || onOpenFile == null)
            ? null
            : () => onOpenFile!(m.txid, attachment.viewMime),
        imageBytes: attachment.kind == 'image' && imageBytes != null
            ? imageBytes!(m.txid)
            : null,
      );
    }

    return Padding(
      // A run reads as one utterance: tight above when it continues the run,
      // a normal breath when it starts one.
      padding: EdgeInsets.only(
        top: continuesRun ? 1 : KvSpace.xs,
        bottom: KvSpace.xs,
      ),
      child: Align(
        alignment: m.outbound ? Alignment.centerRight : Alignment.centerLeft,
        child: _BubbleWidth(
          child: GestureDetector(
            // Offered only where there are words to copy.
            onLongPress: m.readable && m.text.isNotEmpty
                ? () => _copyMessage(context, m.text)
                : null,
            child: Container(
              // **Tighter, and tighter at the top than the bottom**
              // (founder, 2026-09-08: *"reduce the padding top of the bubble
              // that houses the text, adds unnecessary height to the
              // message"*). 12 all round put a band of empty plate above
              // every line of every message; 10 horizontal buys text width
              // back for the wrap, and 6 over 8 sits the words optically
              // centred, because a line box already carries leading above
              // the cap that it does not carry below the baseline.
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              decoration: _bubbleDecoration(outbound: m.outbound, tail: tail),
              child: m.readable
                  ? _BubbleText(
                      text: m.text,
                      delivered: delivered,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        // Leading, not size: §4 owns the ramp, but a
                        // paragraph inside a bubble needs more air between
                        // lines than a label in a row does.
                        height: 1.35,
                      ),
                    )
                  : Text(
                      'Unreadable message',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: KvColor.inkMeta,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// Mark a row the app got from a history archive rather than from its own
  /// node.
  ///
  /// The store has always known this ([`RowSource::FillSourced`]); it simply
  /// never crossed the FFI, so an archive-supplied row was pixel-identical to
  /// node truth. It should not be: the app hands the archive the very address
  /// messages are sealed to, so a dishonest operator can compose a row our keys
  /// open and stamp any txid and time on it. Nothing about that is visible in
  /// the bytes — only in where the row came from (run 1, F3).
  ///
  /// `unknown` (pre-V5 rows) is deliberately NOT marked: those predate
  /// provenance entirely, so the badge would say "archive" about rows that were
  /// almost certainly node-scanned. They are claimed by the next node scan.
  Widget _withProvenance(ThemeData theme, ThreadMessageDto m, Widget child) {
    if (!archiveBoundary) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        Padding(
          padding: const EdgeInsets.symmetric(vertical: KvSpace.m),
          // **The sentence takes the width it needs; the rules split what is
          // left.** It sat in a `Flexible` between two `Expanded` rules, which
          // is a third of the row by construction — flex shares are not
          // handed back when a loose child uses less — so at 393 dp it wrapped
          // into four lines between two long rules (the first frame this seat
          // had, UX-R8). Bounded rather than bare, because a bare child took
          // its intrinsic width off a row that had already given the rest to
          // the rule and overflowed by 76 dp in a clamped column (U2-1's
          // defect one widget over). Each rule keeps at least a gutter.
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                const Expanded(child: Divider(color: KvColor.warn, height: 1)),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(0, box.maxWidth - 2 * KvSpace.xl),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // `warning`, not tertiary chrome: this says our view
                        // of the thread above the line may be wrong, and an
                        // authenticity marker must not be quieter than the
                        // content it qualifies (BG-8).
                        const KvGlyphIcon(
                          KvGlyph.archive,
                          size: 12,
                          tone: KvColor.warn,
                        ),
                        const SizedBox(width: KvSpace.xs),
                        Flexible(
                          child: Text(
                            allAboveRestored
                                ? 'Everything above was restored from an '
                                      'archive'
                                : 'Some messages above were restored from an '
                                      'archive',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: KvColor.warn,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Expanded(child: Divider(color: KvColor.warn, height: 1)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A file a counterparty sent.
///
/// Everything rendered here is OUR decode, never the sender's claim: the name
/// was scrubbed to a base name in Rust, the size is the bytes we actually
/// decoded, and the type is our own allowlisted bucket. A file we will not
/// interpret shows as an inert card — never opened, never executed, never
/// handed to a renderer that could act on it.
class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.file,
    required this.outbound,
    required this.heroTag,
    required this.tail,
    this.onSave,
    this.onOpen,
    this.imageBytes,
  });

  final AttachmentDto file;
  final bool outbound;

  /// The message txid — unique per attachment, so it can carry the thumbnail
  /// into the full-screen viewer without two images ever sharing a tag.
  final String heroTag;

  /// Closes a run ⇒ the bubble takes the tail corner, same as a text bubble.
  final bool tail;

  final VoidCallback? onSave;

  /// Set once the file has been saved — opening points at the user's own copy,
  /// so there is nothing to open before then.
  final VoidCallback? onOpen;

  /// Bytes for an image we show in place. Null for every other type: bytes we
  /// will not interpret never reach a decoder.
  final Future<Uint8List>? imageBytes;

  /// The card's secondary ink, by ground: `inkMeta` on the `plate` bubble a
  /// contact sent (4.75), `inkDim` on the `tealTint` bubble I sent (6.55) —
  /// `inkMeta` there is 3.82 and under BG-14 (`ux-auditor`, UX-R8 re-review).
  Color get _meta => outbound ? KvColor.inkDim : KvColor.inkMeta;

  /// `18.0 KB` as two faces: the figure mono, the unit Jakarta (BG-30).
  static TextSpan _sizeSpan(String pretty) {
    final cut = pretty.lastIndexOf(' ');
    if (cut < 0) return TextSpan(text: pretty);
    return TextSpan(
      children: [
        TextSpan(
          text: pretty.substring(0, cut),
          style: const TextStyle(
            fontFamily: KvFont.mono,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        TextSpan(text: pretty.substring(cut)),
      ],
    );
  }

  static String prettySize(BigInt bytes) {
    final n = bytes.toInt();
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // A picture, or a file: two marks, not three. `file-text` already means
  // the Contracts destination (BG-21, one meaning per glyph), and the card
  // names the kind in words beside the mark.
  KvGlyph get _mark => switch (file.kind) {
    'image' => KvGlyph.image,
    _ => KvGlyph.file,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = file.text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.xs),
      child: Align(
        alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding: const EdgeInsets.all(KvSpace.sm),
            decoration: _bubbleDecoration(outbound: outbound, tail: tail),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    KvGlyphIcon(
                      file.broken ? KvGlyph.alert : _mark,
                      size: 20,
                      tone: file.broken ? KvColor.inkMeta : KvColor.inkDim,
                    ),
                    const SizedBox(width: KvSpace.s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            file.broken ? "This file didn't decode" : file.name,
                            style: theme.textTheme.bodyMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (!file.broken)
                            // The figure in mono, its unit in Jakarta (BG-30),
                            // on ink that clears the card's own ground: a file
                            // I sent sits on `tealTint`, where `inkMeta` is
                            // 3.82 (`ux-auditor`, UX-R8 re-review).
                            Text.rich(
                              _sizeSpan(prettySize(file.sizeBytes)),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: _meta,
                                fontFamily: KvFont.ui,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // **`KvIconButton`, not `IconButton`** — §4's one icon
                    // control, which brings the 44-in-52 target and the
                    // pressed state a Material button on this surface never
                    // had, and identifies itself by its words rather than by
                    // its glyph (§1.2a).
                    if (!file.broken && onOpen != null)
                      KvIconButton(
                        mark: KvGlyph.external,
                        label: 'Open this file',
                        onTap: onOpen,
                      ),
                    if (!file.broken && onSave != null)
                      KvIconButton(
                        mark: KvGlyph.download,
                        label: 'Save to device',
                        onTap: onSave,
                      ),
                  ],
                ),
                // Images render in place. The bytes are already bounded by what
                // fits in one transaction (~70 KB), and `cacheWidth` caps what
                // the platform decoder allocates from a sender's file.
                if (imageBytes != null) ...[
                  const SizedBox(height: KvSpace.s),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(KvRadius.inner),
                    child: FutureBuilder<Uint8List>(
                      future: imageBytes,
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return Text(
                            "This image didn't decode",
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: _meta,
                            ),
                          );
                        }
                        if (!snap.hasData) {
                          return const SizedBox(
                            height: 120,
                            child: Center(child: KvLoader.inline()),
                          );
                        }
                        // Tap to fill the screen. A thumbnail cropped to a
                        // card is not a way to LOOK at a photo, and sending
                        // the user out to another app to see one they were
                        // already shown is a worse answer than showing it.
                        return GestureDetector(
                          onTap: () => _openImageViewer(
                            context,
                            bytes: snap.data!,
                            name: file.name,
                            heroTag: heroTag,
                          ),
                          child: Hero(
                            tag: heroTag,
                            child: Image.memory(
                              snap.data!,
                              cacheWidth: _thumbnailWidth,
                              fit: BoxFit.cover,
                              // A file that claims to be an image and is not
                              // must fail as a line of text, never as a red
                              // error box.
                              errorBuilder: (_, _, _) => Text(
                                "This image didn't decode",
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: _meta,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                // Text files show their content inline; anything we will not
                // interpret stays a card and nothing more.
                if (text != null && text.isNotEmpty) ...[
                  const SizedBox(height: KvSpace.s),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(KvSpace.s),
                    decoration: BoxDecoration(
                      color: KvColor.abyss,
                      borderRadius: BorderRadius.circular(KvRadius.inner),
                    ),
                    // Plain text, never markup — the sender chose these bytes,
                    // so nothing here may be interpreted as formatting.
                    child: SelectableText(
                      text,
                      // `maxLines` alone LOCKS the box at twenty lines (the
                      // editable's preferred height is maxLines when minLines
                      // is null): a one-line file drew a 456 dp plate with
                      // its header off the top of every frame (first frame of
                      // this card, UX-R8). One line grows to twenty.
                      minLines: 1,
                      maxLines: 20,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: KvFont.mono,
                      ),
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

/// Full-screen look at an image already shown in the thread.
///
/// Pushed over the thread rather than handed to another app: the bytes are
/// decrypted message content, and the whole point of the attachment lane is
/// that nothing leaves the app unless the user themselves saves it (§0.4).
/// Opaque `false` keeps the thread underneath, so the Hero has somewhere to
/// fly back to.
void _openImageViewer(
  BuildContext context, {
  required Uint8List bytes,
  required String name,
  required String heroTag,
}) {
  // §6: reduced motion arrives instantly. The Hero flies on the ROUTE's
  // animation, so zeroing the duration is what grounds the flight — a curve
  // swap would still sail the thumbnail across the screen.
  final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  final flight = reduced ? Duration.zero : KvMotion.fast;
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: KvColor.abyss,
      barrierDismissible: true,
      transitionDuration: flight,
      reverseTransitionDuration: flight,
      pageBuilder: (_, _, _) =>
          _ImageViewer(bytes: bytes, name: name, heroTag: heroTag),
    ),
  );
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({
    required this.bytes,
    required this.name,
    required this.heroTag,
  });

  final Uint8List bytes;
  final String name;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Tapping anywhere off the image closes it — the gesture people
          // already expect from every photo viewer they have used.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
            ),
          ),
          Center(
            child: Hero(
              tag: heroTag,
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 6,
                child: Image.memory(
                  bytes,
                  // Capped like the card's thumbnail, just larger: these are
                  // sender-chosen bytes, and `maxScale: 6` does not need a
                  // full-resolution decode to look right. Twice the screen's
                  // physical width is past what the panel can resolve.
                  cacheWidth:
                      (MediaQuery.sizeOf(context).width *
                              MediaQuery.devicePixelRatioOf(context) *
                              2)
                          .round(),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Text(
                    "This image didn't decode",
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: KvColor.inkMeta,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            // A scrim under the controls, not decoration. The bytes below are
            // sender-chosen and can be white, and a zoomed image covers the
            // whole screen — without this the close affordance and the file
            // name are painted straight onto an unknown background and can
            // vanish completely.
            //
            // The stops carry the whole §11 argument. This box also spans the
            // status-bar inset, so a plain 0.72→0 ramp spends its darkest part
            // on empty space and arrives at the control row at ~0.19–0.36 — a
            // scrim that looks like a fix and measures 1.5:1. Holding full
            // strength to 70% of the box puts the row inside the flat section
            // and fades below it, so it still reads as shading on the image
            // rather than a bar. The extra bottom padding is what the fade is
            // spent on.
            //
            // The file name takes `textPrimary`, not `textSecondary`: the
            // secondary token is calibrated against `abyss`, and this surface is
            // an unknown image behind 0.72 of it. Over white that composites to
            // 2.4:1 — it fails AA at any scrim short of an opaque bar. Primary
            // measures ~7:1 on the same ground.
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.7, 1],
                  colors: [
                    KvColor.abyss.withValues(alpha: 0.72),
                    KvColor.abyss.withValues(alpha: 0.72),
                    KvColor.abyss.withValues(alpha: 0),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(bottom: KvSpace.l),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: KvSpace.s,
                      vertical: KvSpace.xs,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Close',
                          icon: const KvGlyphIcon(
                            KvGlyph.close,
                            size: 20,
                            tone: KvColor.ink,
                          ),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: KvColor.ink,
                            ),
                          ),
                        ),
                      ],
                    ),
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

/// The NAME for the thread bar's disc, or null when the counterparty has none.
///
/// [KvContactAvatar] takes a name and does the monogram itself; this only has
/// to decide whether there IS one. `contactLabel` returns the address when
/// there is not, and this used to hand that straight on — so every stranger's
/// thread wore a teal **`K`**, from `kaspa:`. Its own comment claimed it took
/// the neutral mark instead; it did not (`wallet-security-auditor`, UX-R5 —
/// the L164 class: a doc asserting a defence the code never implemented).
String? _nameOf(String label) {
  final t = label.trim();
  if (t.isEmpty || t.startsWith('kaspa:') || t.startsWith('kaspatest:')) {
    return null;
  }
  return t;
}

/// The thread's overflow sheet. It holds what the composer row used to carry
/// as a permanent icon: `M4` draws two controls in that row and this is where
/// the third went.
class _ThreadActionsSheet extends StatelessWidget {
  const _ThreadActionsSheet({required this.canBlock});

  /// A block is keyed on the address (D-308).
  final bool canBlock;

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      title: 'This conversation',
      cancelLabel: 'Close',
      cancelTone: KvColor.inkDim,
      onCancel: () => Navigator.of(context).pop(),
      child: KvRowContainer(
        ground: KvColor.chip,
        children: [
          if (canBlock)
            KvRow(
              dense: true,
              ground: KvColor.chip,
              titleLines: 2,
              leading: const KvRowDisc.neutral(mark: KvGlyph.ban),
              title: 'Block contact',
              // The same line the list's long-press draws (BG-21): *no*,
              // until they knock again (D-308).
              sub: 'Ends the thread; only a new request reaches you',
              subLines: 2,
              trailing: const KvGlyphIcon(
                KvGlyph.chevron,
                size: 20,
                tone: KvColor.etch,
              ),
              onTap: () => Navigator.of(context).pop('block'),
            ),
        ],
      ),
    );
  }
}

/// **The composer's seat on a revived thread** (D-307): the state, its cost,
/// and the door — never behind a mark, because a figure about to be spent and
/// a consequence are the surface's subject (BG-34).
///
/// The plate is the composer's own (`plate` at the bubble radius, in the same
/// column), so the thread's bottom edge keeps its shape while the thing in it
/// changes from a field to a sentence. The act is `raised`, never `primary`:
/// it spends a bond, and §3 rations teal to the signing control that follows.
class _ReplyNeedsHandshake extends StatelessWidget {
  const _ReplyNeedsHandshake({
    super.key,
    required this.bond,
    required this.onSend,
  });

  /// The handshake bond, from Rust — never a Dart literal.
  final BigInt bond;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return KvColumn(
      child: Padding(
        padding: const EdgeInsets.only(top: KvSpace.s, bottom: KvSpace.sm),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            KvSpace.m,
            KvSpace.s14,
            KvSpace.m,
            KvSpace.s14,
          ),
          decoration: BoxDecoration(
            color: KvColor.plate,
            borderRadius: BorderRadius.circular(KvRadius.bubble),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "You can read them, but they can't read your replies yet.",
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 14,
                  height: 20 / 14,
                  fontWeight: FontWeight.w600,
                  fontVariations: KvWeight.w600,
                  color: KvColor.ink,
                ),
              ),
              const SizedBox(height: KvSpace.xs),
              // **The figure is mono** (BG-30) — the same span `M2`'s gloss
              // sets the bond in — and the last two sentences are the
              // `consensus-auditor`'s: this row was minted on its sender's
              // own message, which the user never accepted, so the address
              // in the bar is theirs to check before a bond goes to it.
              Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text:
                          'Their app knows you by an alias this phone no '
                          'longer has. A new handshake tells it your new one: ',
                    ),
                    TextSpan(
                      text: kasCanonical(bond),
                      style: const TextStyle(
                        fontFamily: KvFont.mono,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    // The unit beside a figure is Jakarta (BG-30).
                    const TextSpan(
                      text:
                          ' KAS, which their app keeps. You never accepted '
                          'this address yourself. Check it in the bar first.',
                    ),
                  ],
                ),
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 18 / 13,
                  fontWeight: FontWeight.w400,
                  fontVariations: KvWeight.w400,
                  color: KvColor.inkDim,
                ),
              ),
              const SizedBox(height: KvSpace.s),
              // The ellipsis is BG-11's: the tap opens the ceremony, and the
              // ceremony is where the bond is committed.
              KvAction.raised(label: 'Send handshake…', onTap: onSend),
            ],
          ),
        ),
      ),
    );
  }
}
