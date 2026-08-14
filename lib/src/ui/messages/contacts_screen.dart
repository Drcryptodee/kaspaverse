import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../../rust/api/transport.dart';
import '../../services/messaging_service.dart';
import '../format.dart';
import '../send/confirm_send_flow.dart';
import '../theme/kv_page_route.dart';
import '../error_text.dart';
import '../theme/tokens.dart';
import '../widgets/entrance.dart';
import '../widgets/haptics.dart';
import 'history_fill_sheet.dart';
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
    // The gap notice's inputs resolve in Rust seconds-to-minutes after
    // unlock (gap-age retry budget; the auto-fill runs after the node
    // catch-up) — with fill OFF and no inbound traffic no ping ever fires,
    // so re-ask on every entry to this surface (consensus-audit finding:
    // "never silence" must not depend on luck).
    _messaging.refreshFillState();
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
      contextNote:
          'Carries a 0.2 KAS bond — the network norm; it comes back to you '
          'when they accept.',
    );
  }

  Future<void> _accept(ConversationDto conversation) async {
    await _runPrepare(
      () => _messaging.prepareAccept(conversation.conversationId),
      contextNote:
          'Returns the 0.2 KAS bond to the sender and opens the conversation.',
    );
  }

  /// The shared ceremony over [runConfirmSend] (V5): the summary — mode,
  /// title, payload facts included — is Rust's decode (B7); this surface
  /// keeps only its own error style (snackbar) and list refresh.
  Future<void> _runPrepare(
    Future<SignableSummaryDto> Function() prepare, {
    required String contextNote,
  }) async {
    try {
      await runConfirmSend(
        context,
        prepare: prepare,
        commit: _messaging.commit,
        abandon: _messaging.abandon,
        contextNote: contextNote,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(displayError(e))));
    }
    await _messaging.refresh();
  }

  void _openThread(ConversationDto conversation) {
    Navigator.of(context).push(
      KvPageRoute<void>(
        builder: (_) => ThreadScreen(
          conversationId: conversation.conversationId,
          contactLabel: contactLabel(conversation),
          messaging: _messaging,
        ),
      ),
    );
  }

  /// The expired-invitation exit (V5, finding 15 — INV-6 instinct: every
  /// state has a unilateral out). One tap, founder-ruled: the card's copy
  /// already explains, so no second confirm. Same reversible hide lane
  /// as hide — the row is tombstoned, not deleted, so the counterparty's
  /// alias survives and a later message still finds its home.
  Future<void> _dismissExpired(ConversationDto conversation) async {
    KvHaptic.selection();
    await _messaging.hide(conversation.conversationId);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Invitation dismissed.')));
  }

  /// The zombie-cleanup affordance (D-068): long-press → confirm → hide. Local
  /// only; nothing leaves the device. The row is tombstoned, so their next
  /// message reopens the thread.
  Future<void> _hide(ConversationDto conversation) async {
    KvHaptic.selection();
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      // L87, the instance that outlived the lesson: without this the sheet is
      // capped at 9/16 of the screen, and at large text scales a confirm sheet
      // clips the very button it exists to ask for.
      isScrollControlled: true,
      builder: (_) => _HideSheet(
        label: contactLabel(conversation),
        isInvitation: conversation.status == 'pending_in',
      ),
    );
    if (confirmed != true) return;
    await _messaging.hide(conversation.conversationId);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Conversation hidden.')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          // The V2b visible toggle's home (D-074): reachable ALWAYS, not
          // only when the gap banner shows.
          IconButton(
            tooltip: 'Message history',
            icon: const Icon(Icons.history),
            onPressed: () {
              KvHaptic.selection();
              showHistoryFillSheet(context, _messaging);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add contact',
        onPressed: () {
          KvHaptic.selection();
          _addContact();
        },
        child: const Icon(Icons.person_add_alt),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // The honest gap notice (D-074: never silence) — renders only
            // when history may be incomplete; tap opens the fill sheet.
            HistoryNoticeBanner(messaging: _messaging),
            Expanded(
              child: ValueListenableBuilder<List<ConversationDto>>(
                valueListenable: _messaging.conversations,
                builder: (context, conversations, _) {
                  if (conversations.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(KvSpace.xl),
                        child: Text(
                          'No conversations yet.\nAdd a contact by address — '
                          'the handshake rides the Kaspa L1 itself.',
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
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: KvSpace.sm),
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      return Entrance(
                        index: index,
                        child: _ConversationCard(
                          conversation: conversation,
                          onOpen: () => _openThread(conversation),
                          onAccept: () => _accept(conversation),
                          onHide: () => _hide(conversation),
                          onDismissExpired: () => _dismissExpired(conversation),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
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

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    required this.conversation,
    required this.onOpen,
    required this.onAccept,
    required this.onHide,
    required this.onDismissExpired,
  });

  final ConversationDto conversation;
  final VoidCallback onOpen;
  final VoidCallback onAccept;
  final VoidCallback onHide;
  final VoidCallback onDismissExpired;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = conversation;
    // Rust's expiry taxonomy (V5, finding 15): an expired pending-inbound
    // invitation can NEVER be accepted (its bond is pruned) — the card tells
    // the truth and offers the exit instead of a dead Accept.
    final expired = c.status == 'pending_in' && c.inviteExpired;
    final pendingIn = c.status == 'pending_in' && !expired;
    final pendingOut = c.status == 'pending_out';

    final (String statusLine, Color statusColor) = expired
        ? ('Invitation expired', KvColor.textTertiary)
        : pendingIn
        ? ('Wants to connect', KvColor.info)
        : pendingOut
        ? ('Awaiting their accept', KvColor.textTertiary)
        : ('Active', KvColor.primaryMuted);

    return Material(
      color: KvColor.surface,
      borderRadius: BorderRadius.circular(KvRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(KvRadius.card),
        // A pending-inbound card's action is its own button (Accept, or the
        // expired-invitation Dismiss), not a thread.
        onTap: (pendingIn || expired) ? null : onOpen,
        // Long-press anywhere on the card → hide (zombie cleanup, D-068).
        onLongPress: onHide,
        child: Padding(
          padding: const EdgeInsets.all(KvSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    expired
                        ? Icons.mail_outline
                        : pendingIn
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
              if (expired) ...[
                const SizedBox(height: KvSpace.sm),
                Text(
                  // Honest terminal copy (founder-ruled wording, V5): the
                  // bond is pruned — no transient promise, and an exit.
                  'This invitation has expired and can no longer be accepted.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: KvColor.textSecondary,
                  ),
                ),
                const SizedBox(height: KvSpace.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: onDismissExpired,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Dismiss'),
                  ),
                ),
              ] else if (pendingIn) ...[
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

/// Confirm hiding a conversation (the zombie-cleanup affordance). Honest copy:
/// this is local only — it removes nothing from the chain and tells the
/// counterpart nothing.
class _HideSheet extends StatelessWidget {
  const _HideSheet({required this.label, this.isInvitation = false});

  final String label;

  /// Hiding means two different things, and the sheet must not promise the
  /// wrong one. On a conversation you already have it is a mute — they can
  /// still write and the thread comes back. On an invitation you never took
  /// up it is a block: their messages are refused from then on, because that
  /// card spends a bond and a stranger must not be able to re-arm it.
  final bool isInvitation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KvSpace.gutter,
          KvSpace.m,
          KvSpace.gutter,
          KvSpace.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                'Hide conversation',
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: KvSpace.m),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: KvFont.mono,
              ),
            ),
            const SizedBox(height: KvSpace.sm),
            Text(
              isInvitation
                  ? 'Turns down this invitation and clears it from your '
                        "device. Nothing is deleted on-chain and they aren't "
                        "notified, but you won't hear from them again unless "
                        'they send a new request.'
                  : 'Clears the messages from your device and hides the '
                        "thread. Nothing is deleted on-chain and they aren't "
                        'notified, so they can still write to you — a new '
                        'message brings the thread back.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: KvColor.textSecondary,
              ),
            ),
            const SizedBox(height: KvSpace.l),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Hide'),
            ),
            const SizedBox(height: KvSpace.s),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
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
