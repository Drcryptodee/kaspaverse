import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import '../send/confirm_send_sheet.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import 'contacts_screen.dart' show displayError;

/// One conversation thread (P2.3 — plain view, §4: not a messenger).
///
/// Decrypt-on-view (§0.4): every render PULLS the thread from Rust — sealed
/// rows open there while the vault is unlocked; the decrypted text lives in
/// this widget's ephemeral state exactly as long as the screen shows it, and
/// is dropped on dispose. Nothing is cached in a service; vault locked ⇒ the
/// pull errs and the locked state renders instead of content.
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

  Future<void> _send() async {
    final text = _compose.text.trim();
    if (text.isEmpty) return;
    try {
      final summary = await _messaging.prepareComm(widget.conversationId, text);
      if (!mounted) return;
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
          title: 'Confirm message',
          // A message is a self-send (D-069): the value returns as change, the
          // sheet leads with the fee. B7: payload facts from the BUILT tx.
          selfSend: true,
          contextNote:
              'Carries a ${summary.payloadKind} payload, ${summary.payloadLen} '
              'bytes (decoded from the built transaction).',
        ),
      );
      if (outcome != null && outcome.submitted > 0) {
        _compose.clear();
      }
      await _pull();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
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
                KvSpace.m,
                KvSpace.s,
                KvSpace.s,
                KvSpace.s,
              ),
              child: Row(
                children: [
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
      itemBuilder: (context, index) => _MessageRow(message: _messages[index]),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});

  final ThreadMessageDto message;

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
