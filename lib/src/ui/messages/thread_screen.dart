import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/error.dart';
import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import 'contacts_screen.dart' show signingToggleSub, signingToggleTitle;
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
import '../widgets/kv_tabs.dart';
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
/// P2.4: a recognized `kv:1:` frame renders as a tappable card (challenge) or a
/// light surface (accept/result/taunt); the card is built from the frame's JSON
/// FIELDS, never the readable line, so a tampered line can't misrepresent it.
/// Frames are hints — nothing here moves value; Accept opens the normal confirm
/// ceremony and never auto-broadcasts (§0.3/§0.5).
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

  /// Challenge ids the user has locally declined this view. Decline sends no
  /// frame (no `decline` kind exists, §0.5) — it just retires the card's
  /// actions. View-scoped, like the decrypted rows.
  final Set<String> _declined = {};

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
    _pull();
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
            duration: KvMotion.normal,
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
              duration: KvMotion.normal,
              curve: KvMotion.out,
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
        // Every send this funnel makes lands in the thread as a message —
        // the comm frame, the challenge, the taunt and the accept alike.
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
      // **The toggle rides the PLAIN MESSAGE ceremony only.** This funnel is
      // shared with the challenge, the taunt and the challenge-accept, and the
      // preference governs none of them — a switch on a sheet it does not
      // change is a control that lies (`wallet-security-auditor`, this
      // sitting). Challenge-accept especially: P3 turns that into a staked
      // commitment.
      footer: _SigningToggle(messaging: _messaging),
    );
    if (sent) _compose.clear();
  }

  /// Accept a received challenge — routes through the confirm ceremony and
  /// sends only a social `accept` frame (a self-send fee). NEVER binds a stake
  /// or auto-spends (§0.5 law a); the real wager binds at the P3 covenant.
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

  Future<void> _acceptChallenge(String refId) => _confirmSend(
    prepare: () =>
        _messaging.prepareChallengeAccept(widget.conversationId, refId),
    title: 'Confirm accept',
  );

  void _declineChallenge(String refId) {
    KvHaptic.selection();
    setState(() => _declined.add(refId));
  }

  Future<void> _openArcadeComposer() async {
    KvHaptic.selection();
    final result = await Navigator.of(context).push<_ArcadeCompose>(
      KvSheetRoute<_ArcadeCompose>(builder: (_) => const _ArcadeComposeSheet()),
    );
    if (result == null || !mounted) return;
    switch (result) {
      case _ChallengeCompose(:final stake):
        await _confirmSend(
          prepare: () =>
              _messaging.prepareChallenge(widget.conversationId, stake),
          title: 'Confirm challenge',
        );
      case _TauntCompose(:final text):
        await _confirmSend(
          prepare: () => _messaging.prepareTaunt(widget.conversationId, text),
          title: 'Confirm taunt',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
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
                tone: KvColor.inkNav,
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
            KvColumn(
              child: Padding(
                padding: const EdgeInsets.only(
                  top: KvSpace.s,
                  bottom: KvSpace.l,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // **One right edge** (A11, the founder's own ragged-edge
                    // finding): the mark is a 44 dp disc centred in a 52 dp
                    // target, so a figure right-aligned to the ROW overhangs
                    // the disc it belongs to by the 4 dp inset.
                    Padding(
                      padding: const EdgeInsets.only(
                        right: (KvSpace.touchTarget - KvSpace.iconButton) / 2,
                        bottom: 2,
                      ),
                      child: _ComposerFee(sompi: _fee),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // **The field takes the row.** It was `Flexible` beside an
                        // intrinsic pill whose label could be a 21-character
                        // refusal, which is how the composer once measured 0.0 dp
                        // at 320 dp / 1.3× (L131). Now the only thing beside it is
                        // a fixed-width control, so the field's width is stated by
                        // subtraction rather than negotiated.
                        Expanded(
                          child: Container(
                            constraints: const BoxConstraints(
                              minHeight: KvSpace.touchTarget,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: KvSpace.s20,
                              vertical: KvSpace.sm,
                            ),
                            decoration: BoxDecoration(
                              color: KvColor.plate,
                              borderRadius: BorderRadius.circular(
                                KvRadius.control,
                              ),
                            ),
                            child: TextField(
                              controller: _compose,
                              minLines: 1,
                              maxLines: 4,
                              textInputAction: TextInputAction.newline,
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
                          ),
                        ),
                        const SizedBox(width: KvSpace.touchGap),
                        _SendMark(
                          armed: _draft.trim().isNotEmpty && !_sending,
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
          ],
        ),
      ),
    );
  }

  /// The thread's own overflow. The arcade composer used to be a permanent
  /// icon in the composer row, where it competed with the two controls the
  /// screen is actually for; `M4` draws neither it nor a seat for it, and an
  /// action used once a session does not earn a seat beside the one used
  /// every time.
  Future<void> _threadActions() async {
    KvHaptic.selection();
    final action = await Navigator.of(context).push<String>(
      KvSheetRoute<String>(builder: (_) => const _ThreadActionsSheet()),
    );
    if (!mounted || action == null) return;
    if (action == 'arcade') await _openArcadeComposer();
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
              const Icon(
                Icons.lock_outline,
                color: KvColor.inkDim,
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
        final curved = CurvedAnimation(parent: animation, curve: KvMotion.out);
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
          ghost: _ghostFor(m),
          declined: m.frame != null && _declined.contains(m.frame!.id),
          onAccept: _acceptChallenge,
          onSaveFile: _saveAttachment,
          onOpenFile: _openSaved,
          savedFile: _saved[m.txid] != null,
          imageBytes: _imageBytes,
          onDecline: _declineChallenge,
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
      // **Its own full-width line, above the composer row.**
      //
      // It began beside the send mark, in a non-flex column next to an
      // `Expanded` field — so the field's width was negotiated against a
      // string that changes as the user types: measured off the frames,
      // 299 → 271 dp at 393 on the first keystroke, and 228 → 177 dp at
      // 320 dp / 1.3×, which is what wrapped a short draft onto two lines
      // (BG-24, `ux-auditor` BLOCK; this comment used to assert the opposite
      // as settled fact, which is the scar the fix is for).
      //
      // A 52 dp slot beside the mark was the other candidate and it fails
      // differently: `0.000143 KAS` scaled into the control's own width lands
      // near 8.7 dp, under BG-14's 11 dp floor. A full-width line owes the
      // field nothing, holds the figure at full size, and still puts it
      // exactly where the founder asked — *"tiny above the send button"* —
      // because it right-aligns to the same edge the mark does.
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
          alignment: Alignment.centerRight,
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
            textAlign: TextAlign.end,
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

/// **The send control: a mark, and nothing else** (founder, 2026-09-08: *"a
/// nice send button that isnt taking too much space … The send button can be a
/// send icon only"*).
///
/// It replaces a pill that carried the word `Send` over the words `Network
/// fee`, and the trade is deliberate: the fee is now a real figure above the
/// control, so the words under the verb had nothing left to say, and the
/// ~104 dp they were spending goes to the field — which is the other half of
/// the same ruling (*"i want the text input in a chat to be wider"*).
///
/// **It is [KvIconButton], not a new control.** This app has one icon button —
/// 44 dp of drawn disc inside a 52 dp target, one press feel — and the only
/// thing the composer needed was for it to be able to LIGHT (BG-27), which is
/// now a parameter on that part rather than a second widget here.
///
/// Unarmed it is a `plate` disc with an `etch` mark and no tap at all, and it
/// says why in words: a control that looks live and does nothing teaches
/// distrust of every other control on the screen (D-185).
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
    return KvIconButton(
      mark: KvGlyph.send,
      label: 'Send',
      hint: armed ? null : reason,
      tone: armed ? KvColor.onPrimary : KvColor.etch,
      fill: armed ? KvColor.primary : KvColor.plate,
      fillPressed: armed ? KvColor.primaryPressed : KvColor.chip,
      onTap: armed ? onTap : null,
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
        child: Text(
          _label().toUpperCase(),
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
    const SnackBar(content: Text('Message copied'), duration: KvMotion.slow),
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

/// Native card identity (Material icon + name) for a game slug. Rendered with a
/// tinted `Icon`, not an emoji (design_system §13 — emoji personality rides the
/// Kasia-facing wire line only, generated in `core::frames`). An unknown slug
/// (a future/hostile sender) renders a SAFE generic label, never the raw
/// counterparty string (a display-spoof surface otherwise).
(IconData, String) _gameTitle(String game) => switch (game) {
  'attack_defend' => (Icons.sports_kabaddi, 'Attack & Defend'),
  _ => (Icons.sports_kabaddi, 'Challenge'),
};

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
class _BubbleWidth extends StatelessWidget {
  const _BubbleWidth({required this.child});

  static const double share = 0.78;

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
    required this.declined,
    this.showTime = false,
    this.tail = true,
    this.continuesRun = false,
    this.archiveBoundary = false,
    this.allAboveRestored = false,
    this.chip = TxChipState.none,
    this.ghost = false,
    this.onAccept,
    this.onDecline,
    this.onSaveFile,
    this.onOpenFile,
    this.savedFile = false,
    this.imageBytes,
  });

  final ThreadMessageDto message;
  final bool declined;

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

  /// V2 reorg ghost: the accepting block was displaced and hasn't returned —
  /// the row dims to the BG-8 stale opacity with an honest line, and lifts
  /// again if the network re-accepts it (reversible by construction).
  final bool ghost;

  final void Function(String refId)? onAccept;
  final void Function(String refId)? onDecline;

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
      duration: KvMotion.normal,
      curve: KvMotion.out,
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
    final meta = <Widget>[
      if (withTime)
        Text(
          _clock(context, m.unixMs),
          style: theme.textTheme.labelSmall?.copyWith(
            color: KvColor.inkMeta,
            fontFamily: KvFont.mono,
          ),
        ),
      if (ghost)
        Text(
          'Displaced by the network',
          style: theme.textTheme.labelSmall?.copyWith(color: KvColor.inkMeta),
        )
      else if (chip != TxChipState.none)
        TxStatusChip(state: chip),
    ];
    if (meta.isEmpty) return ghosted;
    return Column(
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
      return _withProvenance(
        theme,
        m,
        Padding(
          padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
          child: Center(
            child: Text(
              m.outbound ? 'Handshake sent' : 'Handshake received',
              style: theme.textTheme.labelSmall?.copyWith(
                color: KvColor.inkMeta,
              ),
            ),
          ),
        ),
        align: CrossAxisAlignment.center,
      );
    }

    final frame = m.frame;
    if (frame != null) {
      if (frame.kind == 'challenge') {
        return _withProvenance(
          theme,
          m,
          _ChallengeCard(
            frame: frame,
            outbound: m.outbound,
            declined: declined,
            onAccept: onAccept,
            onDecline: onDecline,
          ),
        );
      }
      // accept / result / taunt — light surfaces (a forged one is inert: no
      // action, display-only, a CLAIM not a settled outcome).
      return _withProvenance(
        theme,
        m,
        _FrameLightSurface(
          kind: frame.kind,
          text: m.text,
          outbound: m.outbound,
        ),
      );
    }

    final attachment = m.attachment;
    if (attachment != null) {
      return _withProvenance(
        theme,
        m,
        _AttachmentCard(
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
        ),
      );
    }

    return _withProvenance(
      theme,
      m,
      Padding(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: KvSpace.sm,
                  vertical: KvSpace.sm,
                ),
                decoration: _bubbleDecoration(outbound: m.outbound, tail: tail),
                child: m.readable
                    ? Text(
                        m.text,
                        // Leading, not size: §4 owns the ramp, but a paragraph
                        // inside a bubble needs more air between lines than a
                        // label in a row does.
                        style: theme.textTheme.bodyMedium?.copyWith(
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
  Widget _withProvenance(
    ThemeData theme,
    ThreadMessageDto m,
    Widget child, {
    CrossAxisAlignment? align,
  }) {
    if (!archiveBoundary) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        child,
        Padding(
          padding: const EdgeInsets.symmetric(vertical: KvSpace.m),
          child: Row(
            children: [
              const Expanded(child: Divider(color: KvColor.warn, height: 1)),
              // **`Flexible`, not a bare child.** The label is a whole
              // sentence and it took its intrinsic width off a `Row` that had
              // already given the rest away to the rule — so the row
              // overflowed by 76 dp the moment the thread sat in a clamped
              // column rather than the full window. Exactly U2-1's defect one
              // widget over: content sized against the window instead of
              // against the column it is in.
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // `warning`, not tertiary chrome: this says our view of
                      // the thread above the line may be wrong, and an
                      // authenticity marker must not be quieter than the content
                      // it qualifies (BG-8).
                      const Icon(
                        Icons.inventory_2_outlined,
                        size: 12,
                        color: KvColor.warn,
                      ),
                      const SizedBox(width: KvSpace.xs),
                      Flexible(
                        child: Text(
                          allAboveRestored
                              ? 'Everything above was restored from an archive'
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
      ],
    );
  }
}

/// The tappable challenge card — game · stake · Accept/Decline. Rendered from
/// the frame's JSON fields (spoof-proof), never the readable line.
class _ChallengeCard extends StatelessWidget {
  const _ChallengeCard({
    required this.frame,
    required this.outbound,
    required this.declined,
    this.onAccept,
    this.onDecline,
  });

  final FrameDto frame;
  final bool outbound;
  final bool declined;
  final void Function(String refId)? onAccept;
  final void Function(String refId)? onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, name) = _gameTitle(frame.game);
    final staked = frame.stake.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
      child: Align(
        alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
        child: _BubbleWidth(
          child: Container(
            padding: const EdgeInsets.all(KvSpace.m),
            decoration: BoxDecoration(
              color: KvColor.plate,
              borderRadius: BorderRadius.circular(KvRadius.card),
              // **A plate on the ground has no edge** (BG-4). Both of these
              // cards drew one, which is the boundary said twice — the tone
              // step is the whole boundary (`ux-auditor` BLOCK, UX-R5).
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: KvColor.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(KvRadius.data),
                      ),
                      child: Icon(
                        icon,
                        size: KvSpace.l,
                        color: KvColor.primary,
                      ),
                    ),
                    const SizedBox(width: KvSpace.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: theme.textTheme.titleMedium),
                          const SizedBox(height: KvSpace.xs),
                          Text.rich(
                            TextSpan(
                              children: [
                                const TextSpan(text: 'Stake · '),
                                TextSpan(
                                  text: staked
                                      ? '${frame.stake} KAS'
                                      : 'Friendly',
                                  // NOT brand-primary. `frame.stake` is a
                                  // counterparty-supplied wire string validated
                                  // only for shape, and the accent is how this
                                  // app says "our money, our number" — dressing
                                  // an unbacked claim in it is the styling half
                                  // of the same defect the disclosure line
                                  // below fixes (ux-auditor, this wave).
                                  style: TextStyle(
                                    color: staked
                                        ? KvColor.ink
                                        : KvColor.inkDim,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: KvColor.inkDim,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // The disclosure the RECIPIENT never got. A stake renders in
                // brand-primary bold with Accept directly beneath it, which
                // reads as money about to be committed — and on chain it is
                // not: a frame binds nothing (§0.3, chain-proven by run 1).
                // The sender's compose sheet said so; the person being asked
                // to accept was told nothing at all (run 1, F9).
                if (staked && !outbound) ...[
                  const SizedBox(height: KvSpace.xs),
                  Text(
                    'Accepting binds no money — this is a claim in a message, '
                    'not an on-chain wager.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: KvColor.inkMeta,
                    ),
                  ),
                ],
                const SizedBox(height: KvSpace.m),
                _actions(context, theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actions(BuildContext context, ThemeData theme) {
    final caption = theme.textTheme.labelSmall?.copyWith(
      color: KvColor.inkMeta,
    );
    if (outbound) {
      return Align(
        alignment: Alignment.centerRight,
        child: Text('Challenge sent', style: caption),
      );
    }
    if (declined) {
      return Align(
        alignment: Alignment.centerRight,
        child: Text('Declined', style: caption),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: onDecline == null ? null : () => onDecline!(frame.id),
          child: const Text('Decline'),
        ),
        const SizedBox(width: KvSpace.s),
        FilledButton(
          onPressed: onAccept == null
              ? null
              : () {
                  KvHaptic.selection();
                  onAccept!(frame.id);
                },
          child: const Text('Accept'),
        ),
      ],
    );
  }
}

/// A light surface for `accept` / `result` / `taunt` — a leading glyph + the
/// frame's readable line. `result` is framed as a CLAIM (display-only in P2.4;
/// truth binds at the P3 covenant), never a settled outcome.
class _FrameLightSurface extends StatelessWidget {
  const _FrameLightSurface({
    required this.kind,
    required this.text,
    required this.outbound,
  });

  final String kind;
  final String text;
  final bool outbound;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Material icons tinted by tokens (not emoji — design_system §13). Colors
    // are DS-rationed: `success` (chain-confirmed) and `warning` (degraded) are
    // NOT for social acknowledgements — accept/taunt ride `primaryMuted`, and a
    // result stays muted-`textSecondary` to reinforce it's an unverified claim.
    final (glyph, tint) = switch (kind) {
      'accept' => (Icons.check, KvColor.primaryMuted),
      'result' => (Icons.flag_outlined, KvColor.inkDim),
      'taunt' => (Icons.chat_bubble_outline, KvColor.primaryMuted),
      _ => (Icons.circle, KvColor.inkDim),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.xs),
      child: Align(
        alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: KvSpace.sm,
              vertical: KvSpace.s,
            ),
            decoration: BoxDecoration(
              color: KvColor.chip,
              borderRadius: BorderRadius.circular(KvRadius.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (kind == 'result')
                  Padding(
                    padding: const EdgeInsets.only(bottom: KvSpace.xs),
                    child: Text(
                      'Reported result — unverified until played',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: KvColor.inkMeta,
                      ),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(glyph, size: KvSpace.m, color: tint),
                    const SizedBox(width: KvSpace.s),
                    Flexible(
                      child: Text(text, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Arcade composer sheet ────────────────────────────────────────────────────

/// What the composer sheet returns — a challenge (optional stake) or a taunt.
sealed class _ArcadeCompose {
  const _ArcadeCompose();
}

class _ChallengeCompose extends _ArcadeCompose {
  const _ChallengeCompose(this.stake);

  /// Display stake in KAS; null ⇒ a friendly, no-stake duel.
  final String? stake;
}

class _TauntCompose extends _ArcadeCompose {
  const _TauntCompose(this.text);

  final String text;
}

enum _ArcadeMode { challenge, taunt }

class _ArcadeComposeSheet extends StatefulWidget {
  const _ArcadeComposeSheet();

  @override
  State<_ArcadeComposeSheet> createState() => _ArcadeComposeSheetState();
}

class _ArcadeComposeSheetState extends State<_ArcadeComposeSheet> {
  _ArcadeMode _mode = _ArcadeMode.challenge;
  final _stake = TextEditingController();
  final _taunt = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _stake.dispose();
    _taunt.dispose();
    super.dispose();
  }

  /// Mirrors `core::frames::validate_stake`: a plain decimal (digits + at most
  /// one `.`), so the UI and the wire agree on what a stake may be.
  bool _validStake(String s) {
    if (s.isEmpty || s == '.' || s.length > 64) return false;
    if ('.'.allMatches(s).length > 1) return false;
    return s.runes.every((r) => (r >= 0x30 && r <= 0x39) || r == 0x2e);
  }

  void _submit() {
    KvHaptic.selection();
    if (_mode == _ArcadeMode.challenge) {
      final raw = _stake.text.trim();
      if (raw.isNotEmpty && !_validStake(raw)) {
        setState(
          () => _error = 'Enter an amount like 10 or 2.5, or leave empty',
        );
        return;
      }
      Navigator.of(context).pop(_ChallengeCompose(raw.isEmpty ? null : raw));
    } else {
      final t = _taunt.text.trim();
      if (t.isEmpty) {
        setState(() => _error = 'Enter a taunt');
        return;
      }
      Navigator.of(context).pop(_TauntCompose(t));
    }
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _mode == _ArcadeMode.challenge;
    // **The sixth sheet** (`ux-auditor` BLOCK, UX-R5). It was the last raw
    // `showModalBottomSheet` on the messages surface: a `titleMedium` heading,
    // a `SegmentedButton`, three `Icons.*` — one of them painted `primary`,
    // which is a Material glyph carrying a teal emission (BG-2/BG-25) — and a
    // `FilledButton`. No render covers the arcade composer, so the house parts
    // ARE the design here: `KvSheet`, `KvSegmented`, `KvGlyph`, `KvAction`.
    return KvSheet(
      title: 'Attack & Defend',
      onCancel: () => Navigator.of(context).pop(),
      foot: KvAction(
        label: challenge ? 'Review challenge' : 'Review taunt',
        primary: true,
        onTap: _submit,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KvSegmented(
              options: const [
                KvSegmentedOption('Challenge'),
                KvSegmentedOption('Taunt'),
              ],
              index: challenge ? 0 : 1,
              onSelect: (i) => setState(() {
                _mode = i == 0 ? _ArcadeMode.challenge : _ArcadeMode.taunt;
                _error = null;
              }),
            ),
            const SizedBox(height: KvSpace.l),
            if (challenge) ...[
              const KvSectionHeader('Stake', gloss: 'optional'),
              _ArcadeField(
                controller: _stake,
                hint: 'e.g. 10',
                suffix: 'KAS',
                mono: true,
              ),
              const SizedBox(height: KvSpace.sm),
              const Text(
                'Leave empty for a friendly duel. The stake is shown to your '
                'opponent now; it binds when you play, not here.',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 18 / 13,
                  fontWeight: FontWeight.w400,
                  fontVariations: KvWeight.w400,
                  color: KvColor.inkDim,
                ),
              ),
            ] else ...[
              const KvSectionHeader('Taunt'),
              _ArcadeField(controller: _taunt, hint: 'trash talk…'),
              const SizedBox(height: KvSpace.sm),
              const Text(
                'A jab, sent as a message. It costs the network fee like any '
                'other.',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 18 / 13,
                  fontWeight: FontWeight.w400,
                  fontVariations: KvWeight.w400,
                  color: KvColor.inkDim,
                ),
              ),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: KvSpace.sm),
              Text(
                error,
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 18 / 13,
                  fontWeight: FontWeight.w400,
                  fontVariations: KvWeight.w400,
                  color: KvColor.warn,
                ),
              ),
            ],
          ],
        ),
      ),
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

  static String prettySize(BigInt bytes) {
    final n = bytes.toInt();
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData get _icon => switch (file.kind) {
    'text' => Icons.description_outlined,
    'image' => Icons.image_outlined,
    _ => Icons.insert_drive_file_outlined,
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
                    Icon(
                      file.broken ? Icons.error_outline : _icon,
                      size: 20,
                      color: file.broken ? KvColor.inkMeta : KvColor.inkDim,
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
                            Text(
                              prettySize(file.sizeBytes),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: KvColor.inkMeta,
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
                    borderRadius: BorderRadius.circular(KvRadius.data),
                    child: FutureBuilder<Uint8List>(
                      future: imageBytes,
                      builder: (context, snap) {
                        if (snap.hasError) {
                          return Text(
                            "This image didn't decode",
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: KvColor.inkMeta,
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
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: KvColor.inkMeta,
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
                      borderRadius: BorderRadius.circular(KvRadius.data),
                    ),
                    // Plain text, never markup — the sender chose these bytes,
                    // so nothing here may be interpreted as formatting.
                    child: SelectableText(
                      text,
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
                    style: theme.textTheme.bodySmall?.copyWith(
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
  const _ThreadActionsSheet();

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
          KvRow(
            dense: true,
            ground: KvColor.chip,
            leading: const KvRowDisc.neutral(mark: KvGlyph.games),
            title: 'Challenge or taunt',
            sub: 'Send a duel invitation or a jab',
            trailing: const KvGlyphIcon(
              KvGlyph.chevron,
              size: 20,
              tone: KvColor.etch,
            ),
            onTap: () => Navigator.of(context).pop('arcade'),
          ),
        ],
      ),
    );
  }
}

/// One field on the arcade composer — the same pill the handshake screen
/// draws, with an optional unit after it.
class _ArcadeField extends StatelessWidget {
  const _ArcadeField({
    required this.controller,
    required this.hint,
    this.suffix,
    this.mono = false,
  });

  final TextEditingController controller;
  final String hint;
  final String? suffix;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final suffix = this.suffix;
    return Container(
      constraints: const BoxConstraints(minHeight: KvSpace.control),
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s20),
      decoration: BoxDecoration(
        color: KvColor.chip,
        borderRadius: BorderRadius.circular(KvRadius.control),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              cursorColor: KvColor.primary,
              keyboardType: mono
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : null,
              style: TextStyle(
                fontFamily: mono ? KvFont.mono : KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w400,
                fontVariations: KvWeight.w400,
                color: KvColor.ink,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: KvSpace.m),
                hintText: hint,
                hintStyle: TextStyle(
                  fontFamily: mono ? KvFont.mono : KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w400,
                  fontVariations: KvWeight.w400,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ),
          if (suffix != null)
            Text(
              suffix,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w500,
                fontVariations: KvWeight.w500,
                color: KvColor.inkDim,
              ),
            ),
        ],
      ),
    );
  }
}
