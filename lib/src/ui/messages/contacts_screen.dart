import 'package:flutter/material.dart';

import '../../rust/api/error.dart';
import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import '../format.dart';
import '../send/confirm_send_sheet.dart';
import '../theme/tokens.dart';
import '../widgets/entrance.dart';
import '../widgets/haptics.dart';
import 'thread_screen.dart';

/// Transport contacts (P2.3 — §4: transport UI, not a messenger): the
/// conversation list, contact-add via address, and the incoming-handshake
/// accept card. Everything rendered here is public-wire-class data
/// (addresses, aliases, status) — decrypted content appears only inside a
/// [ThreadScreen] pull.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.messaging});

  /// Test seam; defaults to the singleton.
  final MessagingService? messaging;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  MessagingService get _messaging =>
      widget.messaging ?? MessagingService.instance;

  @override
  void initState() {
    super.initState();
    _messaging.refresh();
  }

  /// Map the transport summary onto the payment DTO the shared confirm sheet
  /// renders — field-for-field; the numbers stay Rust's (B7).
  SendSummaryDto _asSendSummary(TransportSendSummaryDto s) => SendSummaryDto(
    nonce: s.nonce,
    destination: s.destination,
    amountSompi: s.amountSompi,
    feeSompi: s.feeSompi,
    totalSompi: s.totalSompi,
    mass: s.mass,
    txCount: s.txCount,
    utxoCount: s.utxoCount,
  );

  Future<void> _confirmTransportSend(
    TransportSendSummaryDto summary, {
    required String title,
    required String contextNote,
  }) async {
    if (!mounted) return;
    await showModalBottomSheet<SendOutcomeDto>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ConfirmSendSheet(
        summary: _asSendSummary(summary),
        commit: _messaging.commit,
        abandon: _messaging.abandon,
        title: title,
        // B7: the payload line renders what Rust decoded from the BUILT tx
        // (kind + size), never an assumption about what was requested.
        contextNote:
            '$contextNote\n'
            'Carries: ${summary.payloadKind} payload, '
            '${summary.payloadLen} bytes (decoded from the built transaction).',
      ),
    );
    await _messaging.refresh();
  }

  Future<void> _addContact() async {
    final address = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddContactSheet(),
    );
    if (address == null || address.isEmpty) return;
    await _runPrepare(
      () => _messaging.prepareHandshake(address),
      title: 'Confirm contact request',
      contextNote:
          'Carries a 0.2 KAS bond — the network norm; it comes back to you '
          'when they accept.',
    );
  }

  Future<void> _accept(ConversationDto conversation) async {
    await _runPrepare(
      () => _messaging.prepareAccept(conversation.conversationId),
      title: 'Confirm accept',
      contextNote:
          'Returns the 0.2 KAS bond to the sender and opens the conversation.',
    );
  }

  Future<void> _runPrepare(
    Future<TransportSendSummaryDto> Function() prepare, {
    required String title,
    required String contextNote,
  }) async {
    try {
      final summary = await prepare();
      await _confirmTransportSend(
        summary,
        title: title,
        contextNote: contextNote,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
  }

  void _openThread(ConversationDto conversation) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ThreadScreen(
          conversationId: conversation.conversationId,
          contactLabel: contactLabel(conversation),
          messaging: _messaging,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add contact',
        onPressed: () {
          KvHaptic.selection();
          _addContact();
        },
        child: const Icon(Icons.person_add_alt),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<List<ConversationDto>>(
          valueListenable: _messaging.conversations,
          builder: (context, conversations, _) {
            if (conversations.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(KvSpace.xl),
                  child: Text(
                    'No conversations yet.\nAdd a contact by address — the '
                    'handshake rides the Kaspa L1 itself.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: KvColor.textSecondary,
                    ),
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(KvSpace.gutter),
              itemCount: conversations.length,
              separatorBuilder: (_, _) => const SizedBox(height: KvSpace.sm),
              itemBuilder: (context, index) {
                final conversation = conversations[index];
                return Entrance(
                  index: index,
                  child: _ConversationCard(
                    conversation: conversation,
                    onOpen: () => _openThread(conversation),
                    onAccept: () => _accept(conversation),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// Contact display label: the address (truncated payload) — identity stays
/// pubkeys + aliases (D-049); an inbound-pending row has no address yet.
String contactLabel(ConversationDto c) => c.contactAddress.isEmpty
    ? 'Unknown sender'
    : truncateAddressPayload(c.contactAddress);

/// AppError-aware message extraction for snackbars.
String displayError(Object e) {
  // The generated AppError has no toString override — Dart's default is
  // "Instance of 'AppError'", which swallows the honest message.
  if (e is AppError) return e.message;
  final s = e.toString();
  // FRB wraps AppError into its exception string; keep the message half.
  const marker = 'message: ';
  final at = s.indexOf(marker);
  if (at >= 0) {
    final rest = s.substring(at + marker.length);
    return rest.endsWith(')') ? rest.substring(0, rest.length - 1) : rest;
  }
  return s;
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    required this.conversation,
    required this.onOpen,
    required this.onAccept,
  });

  final ConversationDto conversation;
  final VoidCallback onOpen;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = conversation;
    final pendingIn = c.status == 'pending_in';
    final pendingOut = c.status == 'pending_out';

    final (String statusLine, Color statusColor) = pendingIn
        ? ('Wants to connect', KvColor.info)
        : pendingOut
        ? ('Awaiting their accept', KvColor.textTertiary)
        : ('Active', KvColor.primaryMuted);

    return Material(
      color: KvColor.surface,
      borderRadius: BorderRadius.circular(KvRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(KvRadius.card),
        // A pending-inbound card's action is the accept button, not a thread.
        onTap: pendingIn ? null : onOpen,
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    pendingIn
                        ? Icons.mark_email_unread_outlined
                        : Icons.forum_outlined,
                    size: 20,
                    color: statusColor,
                  ),
                  const SizedBox(width: KvSpace.s),
                  Expanded(
                    child: Text(
                      contactLabel(c),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: KvFont.mono,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: KvSpace.xs),
              Text(
                statusLine,
                style: theme.textTheme.labelSmall?.copyWith(color: statusColor),
              ),
              if (pendingIn) ...[
                const SizedBox(height: KvSpace.sm),
                Text(
                  'Accepting returns their 0.2 KAS bond and opens an '
                  'encrypted conversation.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                ),
                const SizedBox(height: KvSpace.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      KvHaptic.selection();
                      onAccept();
                    },
                    icon: const Icon(Icons.handshake_outlined, size: 18),
                    label: const Text('Accept'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Address entry for a new contact — validation stays in Rust (the prepare
/// call is the authority); this sheet only collects the string.
class _AddContactSheet extends StatefulWidget {
  const _AddContactSheet();

  @override
  State<_AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends State<_AddContactSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.m,
          KvSpace.gutter,
          KvSpace.l + inset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text('Add contact', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: KvSpace.l),
            TextField(
              controller: _controller,
              autofocus: true,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: KvFont.mono,
              ),
              decoration: const InputDecoration(
                labelText: 'Kaspa address',
                hintText: 'kaspa:…',
              ),
              maxLines: 2,
              minLines: 1,
            ),
            const SizedBox(height: KvSpace.s),
            Text(
              'A contact request costs a 0.2 KAS bond — refunded when they '
              'accept. Both of you message over Kaspa itself; no server.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
            const SizedBox(height: KvSpace.l),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_controller.text.trim()),
              child: const Text('Review request'),
            ),
          ],
        ),
      ),
    );
  }
}
