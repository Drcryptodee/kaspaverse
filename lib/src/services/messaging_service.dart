import 'dart:async';
import 'package:flutter/foundation.dart';

import '../rust/api/error.dart';
import '../rust/api/send.dart';
import '../rust/api/transport.dart';
import '../rust/api/wallet.dart' show uiMark;
import 'vault_service.dart';

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
  static Future<ThreadDeltaDto> Function(
    String conversationId,
    String? afterTxid,
  )
  threadSinceFn = (conversationId, afterTxid) => transportThreadSince(
    conversationId: conversationId,
    afterTxid: afterTxid,
  );

  @visibleForTesting
  static Future<SignableSummaryDto> Function(String destination)
  prepareHandshakeFn = (destination) =>
      transportPrepareHandshake(destination: destination);

  @visibleForTesting
  static Future<SignableSummaryDto> Function(String conversationId)
  prepareAcceptFn = (conversationId) =>
      transportPrepareAccept(conversationId: conversationId);

  @visibleForTesting
  static Future<SignableSummaryDto> Function(String conversationId, String text)
  prepareCommFn = (conversationId, text) =>
      transportPrepareComm(conversationId: conversationId, text: text);

  @visibleForTesting
  static Future<SignableSummaryDto> Function(
    String conversationId,
    String? stake,
  )
  prepareChallengeFn = (conversationId, stake) =>
      transportPrepareChallenge(conversationId: conversationId, stake: stake);

  @visibleForTesting
  static Future<SignableSummaryDto> Function(
    String conversationId,
    String refId,
  )
  prepareChallengeAcceptFn = (conversationId, refId) =>
      transportPrepareChallengeAccept(
        conversationId: conversationId,
        refId: refId,
      );

  @visibleForTesting
  static Future<SignableSummaryDto> Function(String conversationId, String text)
  prepareTauntFn = (conversationId, text) =>
      transportPrepareTaunt(conversationId: conversationId, text: text);

  @visibleForTesting
  static Future<SendOutcomeDto> Function(BigInt nonce) commitFn = (nonce) =>
      transportCommit(nonce: nonce);

  @visibleForTesting
  static Future<BigInt?> Function(String conversationId, String text)
  commFeePreviewFn = (conversationId, text) =>
      transportCommFeePreview(conversationId: conversationId, text: text);

  @visibleForTesting
  static Future<SendOutcomeDto> Function(String conversationId, String text)
  sendCommNowFn = (conversationId, text) =>
      transportSendCommNow(conversationId: conversationId, text: text);

  @visibleForTesting
  static Future<bool> Function() messageSigningFn = transportMessageSigning;

  @visibleForTesting
  static Future<void> Function(bool sign) setMessageSigningFn = (sign) =>
      transportSetMessageSigning(signMessages: sign);

  @visibleForTesting
  static Future<bool> Function(String conversationId) markReadFn =
      (conversationId) => transportMarkRead(conversationId: conversationId);

  @visibleForTesting
  static Future<void> Function() abandonFn = transportAbandon;

  // V2b history-fill seams (D-074).
  @visibleForTesting
  static Future<GapAgeDto?> Function() gapAgeFn = transportGapAge;

  @visibleForTesting
  static Future<FillConfigDto> Function() fillConfigFn = transportFillConfig;

  @visibleForTesting
  static Future<void> Function(bool enabled, String endpoint) setFillConfigFn =
      (enabled, endpoint) =>
          transportSetFillConfig(enabled: enabled, endpoint: endpoint);

  @visibleForTesting
  static Future<FillReportDto> Function() fillNowFn = transportFillNow;

  @visibleForTesting
  static Future<FillReportDto?> Function() fillStatusFn = transportFillStatus;

  // D-138 conversation-backup seams (`self_stash`).
  @visibleForTesting
  static Future<SignableSummaryDto> Function() prepareStashFn =
      transportPrepareStash;

  @visibleForTesting
  static Future<StashStateDto> Function() stashStateFn = transportStashState;

  @visibleForTesting
  static Future<ContactRouteDto?> Function(String address)
  existingConversationFn = (address) =>
      transportExistingConversation(address: address);

  @visibleForTesting
  static Future<String?> Function(String address, String name)
  setContactNameFn = (address, name) =>
      transportSetContactName(address: address, name: name);

  @visibleForTesting
  static Future<AttachmentBytesDto> Function(String conversationId, String txid)
  attachmentBytesFn = (conversationId, txid) =>
      transportAttachmentBytes(conversationId: conversationId, txid: txid);

  /// Platform write seam — swapped in tests, and the ONLY place decrypted
  /// bytes leave the app. `false` means the user backed out.
  @visibleForTesting
  static Future<String?> Function(String name, Uint8List bytes) writeFileFn =
      VaultService.instance.saveFile;

  /// Hand an already-saved file to the phone's own apps.
  @visibleForTesting
  static Future<bool> Function(String uri, String mime) openFileFn =
      VaultService.instance.openFile;

  @visibleForTesting
  static Future<void> Function(String conversationId) hideFn =
      (conversationId) =>
          transportHideConversation(conversationId: conversationId);

  @visibleForTesting
  static Future<WipeReportDto> Function(String conversationId) clearMessagesFn =
      (conversationId) =>
          transportClearMessages(conversationId: conversationId);

  @visibleForTesting
  static Future<WipeReportDto> Function() wipeAllFn = transportWipeAll;

  @visibleForTesting
  static Future<WipeReportDto> Function() wipePreviewFn = transportWipePreview;

  /// All conversations, most recently active first.
  ///
  /// **Not public-wire-class since D-303.** `ConversationDto.preview` is one
  /// decrypted line per thread, so this notifier holds message content — which
  /// is why [dropDecrypted] exists and why the shell calls it the moment the
  /// vault leaves `home`.
  final ValueNotifier<List<ConversationDto>> conversations = ValueNotifier(
    const <ConversationDto>[],
  );

  /// Last ping's conversation id — thread views watch this to re-pull
  /// exactly when their conversation changed. Content-free by construction.
  final ValueNotifier<String?> lastPing = ValueNotifier(null);

  /// Last bridge/stream error message, null while healthy.
  final ValueNotifier<String?> error = ValueNotifier(null);

  /// V2b honest-notice inputs (D-074): this open's history gap (V1 signal),
  /// the fill posture, and the last fill run's report. All public-wire-class
  /// metadata — counts and flags, never content.
  final ValueNotifier<GapAgeDto?> gapAge = ValueNotifier(null);
  final ValueNotifier<FillConfigDto?> fillConfig = ValueNotifier(null);
  final ValueNotifier<FillReportDto?> lastFill = ValueNotifier(null);

  /// Backup coverage (D-138). `null` until Rust has answered once — the notice
  /// stays silent rather than claiming a zero it has not measured.
  final ValueNotifier<StashStateDto?> stashState = ValueNotifier(null);

  /// **The handshake bond, in sompi, from Rust** (`HANDSHAKE_BOND_SOMPI`).
  ///
  /// Synchronous and I/O-free on the Rust side, so a surface can price the
  /// handshake in its first frame. It is read through a seam like every other
  /// bridge call — a widget test has no native library, and a screen that
  /// prints the price of a spend must not be untestable because of it.
  ///
  /// **No fallback, and that is the point.** This first shipped wrapped in a
  /// `catch (_)` returning a hard-coded `20000000` "for widget tests", which
  /// re-created in Dart the exact literal the Rust fn was added to delete —
  /// and worse, swallowed a genuine bridge failure into a money figure the
  /// crate never produced (`ffi-leak-auditor`, UX-R5). A test with no native
  /// library sets [handshakeBondFn], which is what the seam is for.
  @visibleForTesting
  static BigInt Function() handshakeBondFn = transportHandshakeBondSompi;

  BigInt get handshakeBondSompi => handshakeBondFn();

  StreamSubscription<String>? _subscription;

  /// Consumer apply-echo through the ONE build-flavor-proof log lane (three
  /// lights, V3/L55 — Dart prints die on profile builds). Content-free:
  /// sentinel flag only, never an id or text (INV-3). Never throws.
  @visibleForTesting
  static Future<void> Function(String marker) uiMarkFn = (marker) =>
      uiMark(marker: marker);

  void _mark(String marker) {
    try {
      unawaited(uiMarkFn(marker).catchError((_) {}));
    } catch (_) {
      // Native lib absent (widget tests) — silence is fine.
    }
  }

  /// Start the Rust transport hub and attach the app-lifetime ping
  /// subscription; then pull the initial conversation list. Idempotent.
  Future<void> start() async {
    _subscription ??= pingFactory().listen(
      (conversationId) {
        // Three-lights apply echo: pairs with the producer's
        // "transport: ping emit" (a fold without this echo convicts the
        // Dart delivery lane — the register item 10 method, on this lane).
        _mark('ping apply sentinel=${conversationId.isEmpty}');
        // The EMPTY id is the V2b notice sentinel (content-free like every
        // ping): Rust sends it when the gap-age resolves or a fill run
        // reports — the notice inputs changed, no conversation did.
        if (conversationId.isEmpty) {
          refreshFillState();
          return;
        }
        // ValueNotifier skips equal values — a second message in the SAME
        // conversation must still re-notify open thread views.
        if (lastPing.value == conversationId) lastPing.value = null;
        lastPing.value = conversationId;
        refresh();
      },
      onError: (Object e) {
        error.value = e is AppError ? e.message : e.toString();
      },
      // Detach light only — no blind re-attach: this lane has no diagnosed
      // death mode yet (the wallet lane's heal followed its diagnosis; L55
      // lights come BEFORE heals). The pull twin ([refresh]) still serves.
      onDone: () {
        _subscription = null;
        _mark('ping stream done');
      },
    );
    try {
      await startFn();
      await refresh();
      await refreshFillState();
      error.value = null;
    } on AppError catch (e) {
      error.value = e.message;
    }
  }

  /// **Bumped by [dropDecrypted], captured by [refresh].**
  ///
  /// A refresh in flight when the vault locks would otherwise land AFTER the
  /// drop and re-install the decrypted previews into an app-lifetime notifier,
  /// which is exactly the residue the drop exists to prevent — and it is
  /// reachable in the foreground, because the lock is timer-driven and a ping
  /// can be decrypting one envelope per conversation at that moment
  /// (`ffi-leak-auditor`, this sitting).
  int _contentEpoch = 0;

  /// Re-pull the conversation list (cheap; store-backed in Rust).
  ///
  /// The answer carries one decrypted line per conversation
  /// (`ConversationDto.preview`, D-303), so a late answer is dropped rather
  /// than assigned — see [_contentEpoch].
  Future<void> refresh() async {
    final epoch = _contentEpoch;
    try {
      final rows = await conversationsFn();
      if (epoch != _contentEpoch) return;
      conversations.value = rows;
    } on AppError catch (e) {
      error.value = e.message;
    }
  }

  /// Re-pull the V2b notice inputs (gap age, fill config, last report).
  /// Cheap (file/memory-backed in Rust); errors are non-fatal — the notice
  /// simply keeps its last inputs.
  Future<void> refreshFillState() async {
    try {
      gapAge.value = await gapAgeFn();
      fillConfig.value = await fillConfigFn();
      lastFill.value = await fillStatusFn();
      stashState.value = await stashStateFn();
    } on AppError {
      // Locked vault / hub restarting — keep prior values; never a crash lane.
    }
  }

  /// Build the D-138 conversation backup (one self-stash carrying every
  /// conversation). The caller drives the ordinary confirm ceremony from here.
  Future<SignableSummaryDto> prepareStash() => prepareStashFn();

  /// Where "add this contact" should go for [address] — an existing thread,
  /// an invitation of theirs worth accepting, or null when it really is a new
  /// contact. Rust owns the rule; this is the question, not a second copy of
  /// the answer.
  Future<ContactRouteDto?> existingConversation(String address) =>
      existingConversationFn(address);

  /// Fetch a file attachment's bytes and write them where the user chooses.
  ///
  /// Returns the file name when written, or null when the user backed out — a
  /// cancel is a decision, and the caller must stay silent about it. The bytes
  /// are fetched only here, never with a thread pull.
  Future<SavedFile?> saveAttachment(String conversationId, String txid) async {
    final file = await attachmentBytesFn(conversationId, txid);
    final uri = await writeFileFn(file.name, file.bytes);
    return uri == null ? null : SavedFile(name: file.name, uri: uri);
  }

  /// Open a file the user already saved, with whatever the phone has.
  Future<bool> openSavedFile(String uri, String mime) => openFileFn(uri, mime);

  /// The decoded bytes of a file attachment, for rendering it in place.
  Future<Uint8List> attachmentBytes(String conversationId, String txid) async =>
      (await attachmentBytesFn(conversationId, txid)).bytes;

  /// Name (or clear the name of) a contact, then re-pull so every surface
  /// showing that address updates at once.
  Future<void> setContactName(String address, String name) async {
    await setContactNameFn(address, name);
    await refresh();
  }

  /// Persist the fill posture, then run a fill immediately when enabling
  /// (the founder's test: flip on → history appears without a restart).
  /// Returns THAT run's report (null = disabled, or the run failed at the
  /// bridge) so the sheet reports this tap's outcome, never a stale one.
  Future<FillReportDto?> setFillConfig({
    required bool enabled,
    required String endpoint,
  }) async {
    await setFillConfigFn(enabled, endpoint);
    await refreshFillState();
    if (!enabled) return null;
    return fillNow();
  }

  /// Run the fill now (the sheet's explicit check; also used on enable).
  /// Returns the report; state notifiers refresh alongside.
  Future<FillReportDto?> fillNow() async {
    try {
      final report = await fillNowFn();
      lastFill.value = report;
      await refresh();
      return report;
    } on AppError catch (e) {
      error.value = e.message;
      return null;
    }
  }

  /// A conversation's thread, oldest first — decrypt-on-view in Rust. The
  /// caller renders and drops it; nothing is cached here (§0.4). Throws
  /// [AppError] with a locked message while the vault is locked.
  Future<List<ThreadMessageDto>> thread(String conversationId) =>
      threadFn(conversationId);

  /// Incremental thread pull (V2): decrypts only the rows after [afterTxid]
  /// (null ⇒ the full thread) and returns the live status of EVERY row —
  /// tombstone flips and acceptance transitions of already-rendered rows
  /// land without re-decrypting the conversation. Same §0.4 discipline and
  /// locked-vault behavior as [thread].
  Future<ThreadDeltaDto> threadSince(
    String conversationId,
    String? afterTxid,
  ) => threadSinceFn(conversationId, afterTxid);

  /// Phase 1 flows — each returns the Rust-decoded summary (B7) for the
  /// shared hold-to-sign confirm; phase 2 is [commit] with the nonce.
  Future<SignableSummaryDto> prepareHandshake(String destination) =>
      prepareHandshakeFn(destination);

  Future<SignableSummaryDto> prepareAccept(String conversationId) =>
      prepareAcceptFn(conversationId);

  Future<SignableSummaryDto> prepareComm(String conversationId, String text) =>
      prepareCommFn(conversationId, text);

  /// Compose a `kv:1:` Attack & Defend challenge (self-send comm). [stake] is a
  /// DISPLAY value in KAS (null ⇒ a friendly duel); it binds no value — the
  /// wager binds at the P3 covenant. Confirmed through the shared ceremony.
  Future<SignableSummaryDto> prepareChallenge(
    String conversationId,
    String? stake,
  ) => prepareChallengeFn(conversationId, stake);

  /// Compose a social `kv:1:accept` for challenge [refId] — a self-send comm,
  /// NOT a wager: confirmed through the normal ceremony, never auto-broadcast.
  Future<SignableSummaryDto> prepareChallengeAccept(
    String conversationId,
    String refId,
  ) => prepareChallengeAcceptFn(conversationId, refId);

  /// Compose a `kv:1:taunt` (personality) as a self-send comm.
  Future<SignableSummaryDto> prepareTaunt(String conversationId, String text) =>
      prepareTauntFn(conversationId, text);

  Future<SendOutcomeDto> commit(BigInt nonce) => commitFn(nonce);

  /// **What this exact message would cost, right now** — the composer's live
  /// figure. Signerless, stash-free and safe on every keystroke; `null`
  /// whenever no transaction can be built, and the caller then shows no
  /// figure rather than a guess.
  ///
  /// Deliberately does NOT touch [error]: a fee that cannot be quoted is not
  /// a failure the user has to be told about — the send itself will say what
  /// is wrong, in Rust's own words, if they go on to tap it.
  Future<BigInt?> commFeePreview(String conversationId, String text) =>
      commFeePreviewFn(conversationId, text);

  /// **Send a message with no confirm sheet** — only reachable when the user
  /// has turned message signing off, and refused by Rust otherwise.
  ///
  /// Every bound lives in Rust (`transport_send_comm_now`): the preference,
  /// the comm-class scope, the self-send destination check on the BUILT
  /// transaction, and the fee ceiling. Nothing here decides anything; a
  /// refusal comes back as an [AppError] with the sentence to show.
  Future<SendOutcomeDto> sendCommNow(String conversationId, String text) =>
      sendCommNowFn(conversationId, text);

  /// Whether sending a message stops at the confirm sheet. `true` by default.
  Future<bool> messageSigning() => messageSigningFn();

  /// Set it, and refresh nothing — the preference changes a ceremony, not a
  /// conversation.
  Future<void> setMessageSigning(bool sign) => setMessageSigningFn(sign);

  /// **Everything inbound in this thread has been seen.** Called by the open
  /// thread only; the list never marks. Idempotent and forward-only in Rust.
  /// Returns whether the mark moved, which is when a badge disappears.
  Future<bool> markRead(String conversationId) => markReadFn(conversationId);

  Future<void> abandon() => abandonFn();

  /// Hide (tombstone) a conversation locally — the zombie-cleanup affordance
  /// (D-068). Removes nothing on-chain. The row is TOMBSTONED, not deleted:
  /// the contact's alias survives, and their next message reopens the thread.
  /// Re-pulls the list so the row drops immediately.
  Future<void> hide(String conversationId) async {
    try {
      await hideFn(conversationId);
      await refresh();
    } on AppError catch (e) {
      error.value = e.message;
    }
  }

  /// Forget the words in one conversation, keep the conversation. The row
  /// stays listed and stays sendable — only the thread empties. Nothing is
  /// removed on-chain. Returns how many rows went.
  /// Rethrows, like [wipeAll]. Returning 0 on failure would render "0 messages
  /// cleared." over a partial delete that really happened — Rust deliberately
  /// fails mid-loop rather than warning past a write error, and swallowing it
  /// here would undo that honesty at the last step.
  Future<WipeReportDto> clearMessages(String conversationId) async {
    try {
      final cleared = await clearMessagesFn(conversationId);
      await refresh();
      return cleared;
    } on AppError catch (e) {
      error.value = e.message;
      await refresh();
      rethrow;
    }
  }

  /// What a [wipeAll] would destroy — the number the confirm sheet must show.
  ///
  /// NOT the length of [conversations]: that list hides tombstoned rows and
  /// the wipe destroys them too, so the visible count under-promises by
  /// exactly the rows the user already tried to put out of sight.
  Future<WipeReportDto> wipePreview() => wipePreviewFn();

  /// Erase every conversation and every message on this device.
  ///
  /// Irreversible, and deliberately total: a single-conversation delete would
  /// orphan a counterparty who never re-announces themselves, which is why
  /// [hide] tombstones. Nothing is removed on-chain — the ciphertext is public
  /// and permanent, and the confirm copy says so. Rethrows so the caller can
  /// tell the user it did not happen rather than silently reporting success.
  Future<WipeReportDto> wipeAll() async {
    try {
      final report = await wipeAllFn();
      await refresh();
      await refreshFillState();
      return report;
    } on AppError catch (e) {
      error.value = e.message;
      // Refresh on the way out, like the sibling erase paths: the wipe can fail
      // AFTER `transport_abandon` and the floor stamp have already changed
      // state, so the list on screen may no longer be the truth.
      await refresh();
      rethrow;
    }
  }

  /// **Drop every decrypted line this service is holding** — called when the
  /// vault locks.
  ///
  /// `ConversationDto.preview` is decrypted message text (D-303), and this
  /// service is an app-lifetime singleton whose `conversations` notifier is
  /// not owned by any screen. Rust drops its keys on a lock and the widget
  /// tree is swapped for the locked surface, but the plaintext itself would
  /// otherwise sit in this list for the life of the process — surviving a
  /// background lock, which BG-13 defines as *a discard, not a pause*
  /// (`wallet-security-auditor`, this sitting).
  ///
  /// **Content only.** The subscription and the fill/gap facts are public-wire
  /// class and cost a re-pull to rebuild for nothing; what must not survive a
  /// lock is what was said. A re-pull after unlock refills the list, and
  /// `transport_conversations` refuses to produce previews while locked
  /// anyway, so an early one is simply blank.
  void dropDecrypted() {
    // FIRST, and unconditionally: a refresh already in flight must not land
    // after this, even when the list is currently empty.
    _contentEpoch++;
    if (conversations.value.isEmpty) return;
    conversations.value = const <ConversationDto>[];
  }

  @visibleForTesting
  Future<void> reset() async {
    await _subscription?.cancel();
    _subscription = null;
    conversations.value = const <ConversationDto>[];
    lastPing.value = null;
    error.value = null;
    gapAge.value = null;
    fillConfig.value = null;
    lastFill.value = null;
  }
}

/// Where a saved attachment landed — the name for the user, the destination so
/// it can be opened again without copying it anywhere.
class SavedFile {
  const SavedFile({required this.name, required this.uri});
  final String name;
  final String uri;
}
