import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api/error.dart';
import '../rust/api/send.dart';
import '../rust/api/transport.dart';

/// Conversations + threads over the P2.3 bridge surface. PULL-shaped by
/// design (§0.4 plaintext discipline): the only stream is a content-free
/// conversation-id ping — decrypted text is fetched per view via
/// [thread], rendered, and dropped with the widget. Nothing decrypted is
/// held in this service (no state manager carries message content).
///
/// Started from the home screen alongside [WalletService] (post-unlock —
/// the Rust hub needs the unlocked vault's decryptor); idempotent while the
/// vault stays unlocked, and safe to call again after a re-unlock (the hub
/// rebuilds against the fresh vault).
class MessagingService {
  MessagingService._();

  static final MessagingService instance = MessagingService._();

  /// Test seams (the service-family pattern): tests swap fakes so no native
  /// library is needed.
  @visibleForTesting
  static Future<void> Function() startFn = transportStart;

  @visibleForTesting
  static Stream<String> Function() pingFactory = subscribeThreadPings;

  @visibleForTesting
  static Future<List<ConversationDto>> Function() conversationsFn =
      transportConversations;

  @visibleForTesting
  static Future<List<ThreadMessageDto>> Function(String conversationId)
  threadFn = (conversationId) =>
      transportThread(conversationId: conversationId);

  @visibleForTesting
  static Future<TransportSendSummaryDto> Function(String destination)
  prepareHandshakeFn = (destination) =>
      transportPrepareHandshake(destination: destination);

  @visibleForTesting
  static Future<TransportSendSummaryDto> Function(String conversationId)
  prepareAcceptFn = (conversationId) =>
      transportPrepareAccept(conversationId: conversationId);

  @visibleForTesting
  static Future<TransportSendSummaryDto> Function(
    String conversationId,
    String text,
  )
  prepareCommFn = (conversationId, text) =>
      transportPrepareComm(conversationId: conversationId, text: text);

  @visibleForTesting
  static Future<SendOutcomeDto> Function(BigInt nonce) commitFn = (nonce) =>
      transportCommit(nonce: nonce);

  @visibleForTesting
  static Future<void> Function() abandonFn = transportAbandon;

  @visibleForTesting
  static Future<void> Function(String conversationId) hideFn =
      (conversationId) =>
          transportHideConversation(conversationId: conversationId);

  /// All conversations, most recently active first (public-wire-class data).
  final ValueNotifier<List<ConversationDto>> conversations = ValueNotifier(
    const <ConversationDto>[],
  );

  /// Last ping's conversation id — thread views watch this to re-pull
  /// exactly when their conversation changed. Content-free by construction.
  final ValueNotifier<String?> lastPing = ValueNotifier(null);

  /// Last bridge/stream error message, null while healthy.
  final ValueNotifier<String?> error = ValueNotifier(null);

  StreamSubscription<String>? _subscription;

  /// Start the Rust transport hub and attach the app-lifetime ping
  /// subscription; then pull the initial conversation list. Idempotent.
  Future<void> start() async {
    _subscription ??= pingFactory().listen(
      (conversationId) {
        // ValueNotifier skips equal values — a second message in the SAME
        // conversation must still re-notify open thread views.
        if (lastPing.value == conversationId) lastPing.value = null;
        lastPing.value = conversationId;
        refresh();
      },
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
    );
    try {
      await startFn();
      await refresh();
      error.value = null;
    } on AppError catch (e) {
      error.value = e.message;
    }
  }

  /// Re-pull the conversation list (cheap; store-backed in Rust).
  Future<void> refresh() async {
    try {
      conversations.value = await conversationsFn();
    } on AppError catch (e) {
      error.value = e.message;
    }
  }

  /// A conversation's thread, oldest first — decrypt-on-view in Rust. The
  /// caller renders and drops it; nothing is cached here (§0.4). Throws
  /// [AppError] with a locked message while the vault is locked.
  Future<List<ThreadMessageDto>> thread(String conversationId) =>
      threadFn(conversationId);

  /// Phase 1 flows — each returns the Rust-decoded summary (B7) for the
  /// shared hold-to-sign confirm; phase 2 is [commit] with the nonce.
  Future<TransportSendSummaryDto> prepareHandshake(String destination) =>
      prepareHandshakeFn(destination);

  Future<TransportSendSummaryDto> prepareAccept(String conversationId) =>
      prepareAcceptFn(conversationId);

  Future<TransportSendSummaryDto> prepareComm(
    String conversationId,
    String text,
  ) => prepareCommFn(conversationId, text);

  Future<SendOutcomeDto> commit(BigInt nonce) => commitFn(nonce);

  Future<void> abandon() => abandonFn();

  /// Hide (tombstone) a conversation locally — the zombie-cleanup affordance
  /// (D-068). Removes nothing on-chain; a fresh handshake re-creates the row.
  /// Re-pulls the list so the row drops immediately.
  Future<void> hide(String conversationId) async {
    try {
      await hideFn(conversationId);
      await refresh();
    } on AppError catch (e) {
      error.value = e.message;
    }
  }

  @visibleForTesting
  Future<void> reset() async {
    await _subscription?.cancel();
    _subscription = null;
    conversations.value = const <ConversationDto>[];
    lastPing.value = null;
    error.value = null;
  }
}
