import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import '../send/confirm_send_flow.dart';
import '../error_text.dart';
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
    this.superseded = false,
    this.messaging,
  });

  final String conversationId;
  final String contactLabel;

  /// The counterparty's address, for the bar's second line. Empty on a row
  /// whose sender the node has not resolved yet — the bar then names the
  /// person and claims no key, which is the honest half of the pair.
  final String contactAddress;

  /// A newer live conversation with this same contact exists, so this thread's
  /// alias reaches nobody. Read-only: the history is real and stays readable,
  /// but the composer is replaced by a notice. Passed in rather than re-fetched
  /// because the list already holds the answer and the send path in Rust
  /// refuses independently — this is the courtesy, not the guarantee.
  final bool superseded;

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

  @override
  void initState() {
    super.initState();
    _messaging.lastPing.addListener(_onPing);
    _compose.addListener(_onDraft);
    _pull();
  }

  void _onDraft() {
    final draft = _compose.text;
    // Only when the ANSWER changes — a rebuild per keystroke over a thread
    // list is what BG-18's own rule warns about.
    if (draft.trim().isEmpty != _draft.trim().isEmpty) {
      setState(() => _draft = draft);
    } else {
      _draft = draft;
    }
  }

  @override
  void dispose() {
    _messaging.lastPing.removeListener(_onPing);
    _compose.removeListener(_onDraft);
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
  }) async {
    try {
      final outcome = await runConfirmSend(
        context,
        prepare: prepare,
        commit: _messaging.commit,
        abandon: _messaging.abandon,
        title: title,
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

  Future<void> _send() async {
    final text = _compose.text.trim();
    if (text.isEmpty) return;
    final sent = await _confirmSend(
      prepare: () => _messaging.prepareComm(widget.conversationId, text),
      title: 'Confirm message',
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
            if (widget.superseded)
              _ReplacedNotice(theme: theme)
            else
              KvColumn(
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: KvSpace.s,
                    bottom: KvSpace.l,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        fit: FlexFit.tight,
                        child: Container(
                          constraints: const BoxConstraints(
                            minHeight: KvSpace.touchTarget,
                            minWidth: _fieldMin,
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
                      // **`M4` prints `0.0001 KAS` under `Send` and this
                      // build does not.** A comm is a SELF-SEND: the value
                      // returns to the wallet and only the network fee is
                      // spent, so there is no fixed amount to print — and the
                      // fee itself is not known until Rust has built the
                      // transaction, which happens after this tap. A figure
                      // here would be a claim about a spend nobody has priced
                      // yet, on the control that commits it. The words are
                      // what the app can back; the ceremony behind the tap
                      // shows the real figure before anything is signed.
                      // **The pill sizes to its own content**, with `M4`'s
                      // 108 dp as the floor rather than the answer. The render
                      // measures 108 around `0.0001 KAS`; this pill carries
                      // different words, and forcing the render's number onto
                      // them broke one — the frame rendered `Networ / k fee`,
                      // the top bar's defect again. What the render actually
                      // fixes is the PROPORTION: a compact pill beside a field
                      // that takes the rest, which an intrinsic width keeps at
                      // every window class.
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: _sendWidth,
                          maxWidth: _sendMax,
                        ),
                        child: IntrinsicWidth(
                          child: KvAction(
                            label: 'Send',
                            primary: true,
                            // **BG-27: a control with nothing to commit is
                            // not lit.** It was unconditionally teal and its
                            // tap returned silently on an empty draft, which
                            // is D-185's own gate — a control that looks live
                            // and does nothing teaches distrust of every
                            // other control on the screen (`ux-auditor`
                            // BLOCK, UX-R5). `_compose` is now listened to,
                            // so the pill arms on the first character.
                            disabledReason: _draft.trim().isEmpty
                                ? 'Write a message first'
                                : null,
                            // The pill is 108 dp beside a field; the reason is
                            // 21 characters. It paints the verb and announces
                            // the reason (see [KvAction.disabledLabel]).
                            disabledLabel: 'Send',
                            // Not an unmade choice.
                            disabledMark: false,
                            // **`M4` draws an arrow here and this build does
                            // not**, and it is a trade rather than an
                            // omission. The mark costs 26 dp (18 + the gap),
                            // and at 320 dp / 1.3× those 26 dp came out of the
                            // field beside it — the composer's own placeholder
                            // rendered `Messag / e`. Between an arrow beside
                            // the word `Send` and the line that says what
                            // sending costs, the words are the information and
                            // the arrow is the decoration. Said in the sitting.
                            labelWidget: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Send',
                                  style: TextStyle(
                                    fontFamily: KvFont.ui,
                                    fontSize: 15,
                                    height: 18 / 15,
                                    fontWeight: FontWeight.w700,
                                    fontVariations: KvWeight.w700,
                                    color: KvColor.onPrimary,
                                  ),
                                ),
                                Text(
                                  'Network fee',
                                  style: TextStyle(
                                    fontFamily: KvFont.ui,
                                    fontSize: 11,
                                    height: 14 / 11,
                                    fontWeight: FontWeight.w500,
                                    fontVariations: KvWeight.w500,
                                    color: KvColor.onPrimary,
                                  ),
                                ),
                              ],
                            ),
                            onTap: () {
                              KvHaptic.selection();
                              _send();
                            },
                          ),
                        ),
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

  /// `M4` measures the send pill at x 260.0..368.0 — 108 dp beside a field
  /// that takes the rest of the column.
  static const double _sendWidth = 108;

  /// The widest the pill may grow, and the least the field may shrink to.
  ///
  /// Both are stated rather than emergent. The pill's label is variable — a
  /// verb, or a refusal — and a `Row` whose only flex child is the field hands
  /// an unbounded intrinsic sibling everything: at 320 dp / 1.3× the disabled
  /// label's 21 characters took the whole row and the message field measured
  /// **0.0 dp**, its hint painting at zero width, which `find.text` still
  /// matches and no presence assertion can see (L131, `ux-auditor` BLOCK,
  /// UX-R5).
  static const double _sendMax = 148;
  static const double _fieldMin = 96;

  /// The thread's own overflow. The arcade composer used to be a permanent
  /// icon in the composer row, where it competed with the two controls the
  /// screen is actually for; `M4` draws neither it nor a seat for it, and an
  /// action used once a session does not earn a seat beside the one used
  /// every time.
  Future<void> _threadActions() async {
    KvHaptic.selection();
    final action = await Navigator.of(context).push<String>(
      KvSheetRoute<String>(
        builder: (_) => _ThreadActionsSheet(superseded: widget.superseded),
      ),
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

/// What stands where the composer was on a replaced thread.
///
/// A disabled text field would still read as "type here" and leave the user
/// wondering why nothing happens. Replacing it outright says the thread is
/// closed, and says why — which is the whole point: the failure this prevents
/// was silent, and silence is what made it cost hours.
class _ReplacedNotice extends StatelessWidget {
  const _ReplacedNotice({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(KvSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const KvGlyphIcon(KvGlyph.history, size: 20, tone: KvColor.inkMeta),
          const SizedBox(width: KvSpace.s),
          Expanded(
            child: Text(
              'This conversation was replaced. Your contact started a new one '
              'with you — messages sent here would not reach them. Open the '
              'newer thread from the contacts list.',
              style: theme.textTheme.bodySmall?.copyWith(color: KvColor.inkDim),
            ),
          ),
        ],
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
  const _ThreadActionsSheet({required this.superseded});

  /// A replaced thread can be read and cannot be typed in, so it can carry no
  /// action that composes. Offering one would be a control that looks live and
  /// fails behind the confirm (BG-12).
  final bool superseded;

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
          if (superseded)
            const KvRow(
              dense: true,
              ground: KvColor.chip,
              leading: KvRowDisc.neutral(mark: KvGlyph.history),
              title: 'Read only',
              sub:
                  'They started a newer conversation with you — open that '
                  'thread to message them',
              subLines: 3,
            )
          else
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
