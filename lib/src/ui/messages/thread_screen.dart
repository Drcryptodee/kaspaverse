import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import '../send/confirm_send_sheet.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import 'contacts_screen.dart' show displayError;

/// One conversation thread (P2.3 plain view + P2.4 `kv:1:` game frames).
///
/// Decrypt-on-view (§0.4): every render PULLS the thread from Rust — sealed
/// rows open there while the vault is unlocked; the decrypted text lives in
/// this widget's ephemeral state exactly as long as the screen shows it, and
/// is dropped on dispose. Nothing is cached in a service; vault locked ⇒ the
/// pull errs and the locked state renders instead of content.
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

  List<ThreadMessageDto> _messages = const [];

  /// Challenge ids the user has locally declined this view. Decline sends no
  /// frame (no `decline` kind exists, §0.5) — it just retires the card's
  /// actions. View-scoped, like the decrypted rows.
  final Set<String> _declined = {};

  String? _lockedMessage;
  bool _loading = true;

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
    _messages = const [];
    super.dispose();
  }

  void _onPing() {
    if (_messaging.lastPing.value == widget.conversationId) _pull();
  }

  Future<void> _pull() async {
    try {
      final messages = await _messaging.thread(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _lockedMessage = null;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages = const [];
        _lockedMessage = displayError(e);
        _loading = false;
      });
    }
  }

  /// The ONE spend path for every comm-carried kind: prepare in Rust, then open
  /// the shared hold-to-sign ceremony. Never auto-broadcasts (broadcast fires
  /// only inside a completed hold, [ConfirmSendSheet]). Returns whether the
  /// user actually submitted. Re-pulls the thread afterwards.
  Future<bool> _confirmSend({
    required Future<TransportSendSummaryDto> Function() prepare,
    required String title,
  }) async {
    try {
      final summary = await prepare();
      if (!mounted) return false;
      final outcome = await showModalBottomSheet<SendOutcomeDto>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ConfirmSendSheet(
          summary: SendSummaryDto(
            nonce: summary.nonce,
            destination: summary.destination,
            amountSompi: summary.amountSompi,
            feeSompi: summary.feeSompi,
            totalSompi: summary.totalSompi,
            mass: summary.mass,
            txCount: summary.txCount,
            utxoCount: summary.utxoCount,
          ),
          commit: _messaging.commit,
          abandon: _messaging.abandon,
          title: title,
          // Comm-carried kinds are self-sends (D-069): value returns as change,
          // the sheet leads with the fee. B7: payload facts from the BUILT tx.
          selfSend: true,
          contextNote:
              'Carries a ${summary.payloadKind} payload, ${summary.payloadLen} '
              'bytes (decoded from the built transaction).',
        ),
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
      return const Center(child: CircularProgressIndicator());
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
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.all(KvSpace.m),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final m = _messages[index];
        return _MessageRow(
          message: m,
          declined: m.frame != null && _declined.contains(m.frame!.id),
          onAccept: _acceptChallenge,
          onDecline: _declineChallenge,
        );
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
    required this.message,
    required this.declined,
    this.onAccept,
    this.onDecline,
  });

  final ThreadMessageDto message;
  final bool declined;
  final void Function(String refId)? onAccept;
  final void Function(String refId)? onDecline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = message;

    if (m.kind == 'handshake') {
      // System row: the establishment/acceptance handshake — no body.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
        child: Center(
          child: Text(
            m.outbound ? 'Handshake sent' : 'Handshake received',
            style: theme.textTheme.labelSmall?.copyWith(
              color: KvColor.textTertiary,
            ),
          ),
        ),
      );
    }

    final frame = m.frame;
    if (frame != null) {
      if (frame.kind == 'challenge') {
        return _ChallengeCard(
          frame: frame,
          outbound: m.outbound,
          declined: declined,
          onAccept: onAccept,
          onDecline: onDecline,
        );
      }
      // accept / result / taunt — light surfaces (a forged one is inert: no
      // action, display-only, a CLAIM not a settled outcome).
      return _FrameLightSurface(
        kind: frame.kind,
        text: m.text,
        outbound: m.outbound,
      );
    }

    final bubbleColor = m.outbound ? KvColor.surfaceAlt : KvColor.surface;
    return Padding(
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
                                  style: TextStyle(
                                    color: staked
                                        ? KvColor.primary
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
