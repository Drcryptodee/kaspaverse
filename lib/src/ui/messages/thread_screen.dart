import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import '../send/confirm_send_flow.dart';
import '../error_text.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_loader.dart';
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
    this.messaging,
  });

  final String conversationId;
  final String contactLabel;

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

  String? _lockedMessage;
  bool _loading = true;

  /// First paint lands at the bottom instantly; later arrivals glide.
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _messaging.lastPing.addListener(_onPing);
    _pull();
  }

  @override
  void dispose() {
    _messaging.lastPing.removeListener(_onPing);
    _compose.dispose();
    _scroll.dispose();
    // The decrypted rows die with this state object (§0.4 — view-scoped).
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
    final result = await showModalBottomSheet<_ArcadeCompose>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ArcadeComposeSheet(),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.contactLabel,
          style: theme.textTheme.titleMedium?.copyWith(fontFamily: KvFont.mono),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _body(theme)),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                KvSpace.s,
                KvSpace.s,
                KvSpace.s,
                KvSpace.s,
              ),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'New challenge or taunt',
                    onPressed: _openArcadeComposer,
                    icon: const Icon(Icons.sports_esports_outlined),
                    color: KvColor.primaryMuted,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _compose,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Encrypted message…',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Review & send',
                    onPressed: () {
                      KvHaptic.selection();
                      _send();
                    },
                    icon: const Icon(Icons.send_outlined),
                    color: KvColor.primary,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
                color: KvColor.textSecondary,
                size: KvSpace.xl,
              ),
              const SizedBox(height: KvSpace.m),
              Text(
                _lockedMessage!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: KvColor.textSecondary,
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
          style: theme.textTheme.bodyMedium?.copyWith(
            color: KvColor.textSecondary,
          ),
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
          chip: _chipFor(m),
          ghost: _ghostFor(m),
          declined: m.frame != null && _declined.contains(m.frame!.id),
          onAccept: _acceptChallenge,
          onDecline: _declineChallenge,
        );
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
/// Native card identity (Material icon + name) for a game slug. Rendered with a
/// tinted `Icon`, not an emoji (design_system §13 — emoji personality rides the
/// Kasia-facing wire line only, generated in `core::frames`). An unknown slug
/// (a future/hostile sender) renders a SAFE generic label, never the raw
/// counterparty string (a display-spoof surface otherwise).
(IconData, String) _gameTitle(String game) => switch (game) {
  'attack_defend' => (Icons.sports_kabaddi, 'Attack & Defend'),
  _ => (Icons.sports_kabaddi, 'Challenge'),
};

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    super.key,
    required this.message,
    required this.declined,
    this.chip = TxChipState.none,
    this.ghost = false,
    this.onAccept,
    this.onDecline,
  });

  final ThreadMessageDto message;
  final bool declined;

  /// V2 status chip for outbound rows ([TxChipState.none] renders nothing).
  final TxChipState chip;

  /// V2 reorg ghost: the accepting block was displaced and hasn't returned —
  /// the row dims to the DS-1 stale opacity with an honest line, and lifts
  /// again if the network re-accepts it (reversible by construction).
  final bool ghost;

  final void Function(String refId)? onAccept;
  final void Function(String refId)? onDecline;

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
    if (!ghost && chip == TxChipState.none) return ghosted;

    final annotation = ghost
        ? Text(
            'Displaced by the network',
            style: theme.textTheme.labelSmall?.copyWith(
              color: KvColor.textTertiary,
            ),
          )
        : TxStatusChip(state: chip);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ghosted,
        Padding(
          padding: const EdgeInsets.only(bottom: KvSpace.xs),
          child: Align(
            alignment: m.outbound
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: annotation,
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
      // This row gets the badge too, and it is the one that matters MOST: the
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
                color: KvColor.textTertiary,
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

    final bubbleColor = m.outbound ? KvColor.surfaceAlt : KvColor.surface;
    return _withProvenance(
      theme,
      m,
      Padding(
        padding: const EdgeInsets.symmetric(vertical: KvSpace.xs),
        child: Align(
          alignment: m.outbound ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: KvSpace.sm,
                vertical: KvSpace.s,
              ),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(KvRadius.card),
                border: m.outbound ? null : Border.all(color: KvColor.border),
              ),
              child: m.readable
                  ? Text(m.text, style: theme.textTheme.bodyMedium)
                  : Text(
                      'Unreadable message',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: KvColor.textTertiary,
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
  Widget _withProvenance(
    ThemeData theme,
    ThreadMessageDto m,
    Widget child, {
    CrossAxisAlignment? align,
  }) {
    if (m.provenance != 'archive') return child;
    return Column(
      crossAxisAlignment:
          align ??
          (m.outbound ? CrossAxisAlignment.end : CrossAxisAlignment.start),
      children: [
        child,
        Padding(
          padding: const EdgeInsets.only(
            left: KvSpace.xs,
            right: KvSpace.xs,
            bottom: KvSpace.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // `warning`, not tertiary chrome: this says our view of the
              // thread may be wrong, and an authenticity marker must not be
              // quieter than the content it qualifies (DS-1). Same reasoning
              // the home cockpit's _StatusCaption already carries.
              const Icon(
                Icons.inventory_2_outlined,
                size: 12,
                color: KvColor.warning,
              ),
              const SizedBox(width: KvSpace.xs),
              Flexible(
                child: Text(
                  'From an archive — not seen by your own node',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: KvColor.warning,
                  ),
                ),
              ),
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Container(
            padding: const EdgeInsets.all(KvSpace.m),
            decoration: BoxDecoration(
              color: KvColor.surface,
              borderRadius: BorderRadius.circular(KvRadius.card),
              border: Border.all(color: KvColor.border),
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
                                        ? KvColor.textPrimary
                                        : KvColor.textSecondary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: KvColor.textSecondary,
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
                      color: KvColor.textTertiary,
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
      color: KvColor.textTertiary,
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
      'result' => (Icons.flag_outlined, KvColor.textSecondary),
      'taunt' => (Icons.chat_bubble_outline, KvColor.primaryMuted),
      _ => (Icons.circle, KvColor.textSecondary),
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
              color: KvColor.surfaceAlt,
              borderRadius: BorderRadius.circular(KvRadius.card),
              border: Border.all(color: KvColor.border),
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
                        color: KvColor.textTertiary,
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
    final theme = Theme.of(context);
    final challenge = _mode == _ArcadeMode.challenge;
    return Padding(
      padding: EdgeInsets.only(
        left: KvSpace.l,
        right: KvSpace.l,
        top: KvSpace.l,
        bottom: KvSpace.l + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.sports_kabaddi,
                size: KvSpace.l,
                color: KvColor.primary,
              ),
              const SizedBox(width: KvSpace.sm),
              Text('Attack & Defend', style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: KvSpace.l),
          SegmentedButton<_ArcadeMode>(
            segments: const [
              ButtonSegment(
                value: _ArcadeMode.challenge,
                label: Text('Challenge'),
                icon: Icon(Icons.sports_esports_outlined),
              ),
              ButtonSegment(
                value: _ArcadeMode.taunt,
                label: Text('Taunt'),
                icon: Icon(Icons.chat_bubble_outline),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() {
              _mode = s.first;
              _error = null;
            }),
          ),
          const SizedBox(height: KvSpace.l),
          if (challenge) ...[
            TextField(
              controller: _stake,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Stake',
                hintText: 'e.g. 10',
                suffixText: 'KAS',
              ),
            ),
            const SizedBox(height: KvSpace.s),
            Text(
              'Leave empty for a friendly duel. The stake is shown to your '
              'opponent now; it binds when you play, not here.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
          ] else
            TextField(
              controller: _taunt,
              minLines: 1,
              maxLines: 3,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Taunt',
                hintText: 'trash talk…',
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: KvSpace.s),
            Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: KvColor.error),
            ),
          ],
          const SizedBox(height: KvSpace.l),
          FilledButton(
            onPressed: _submit,
            child: Text(challenge ? 'Review challenge' : 'Review taunt'),
          ),
        ],
      ),
    );
  }
}
