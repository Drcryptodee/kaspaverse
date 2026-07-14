import 'package:flutter/material.dart';

import '../../rust/api/send.dart';
import '../theme/tokens.dart';
import 'confirm_send_sheet.dart';

/// THE one confirm-send ceremony (V5): prepare in Rust → open the shared
/// hold-to-sign sheet over the Rust-decoded [SignableSummaryDto] (B7) →
/// return the outcome (null = dismissed without signing; the sheet's own
/// dispose already abandoned the stash).
///
/// Deliberately owns ONLY the shared shape. Prepare errors PROPAGATE — each
/// caller keeps its own surface (send screen: inline error; messaging
/// surfaces: snackbar) — and each caller runs its own refresh after the
/// sheet closes. Never auto-broadcasts: broadcast fires only inside a
/// completed hold ([ConfirmSendSheet]).
Future<SendOutcomeDto?> runConfirmSend(
  BuildContext context, {
  required Future<SignableSummaryDto> Function() prepare,
  required Future<SendOutcomeDto> Function(BigInt nonce) commit,
  required Future<void> Function() abandon,
  String? title,
  String? contextNote,
}) async {
  final summary = await prepare();
  if (!context.mounted) {
    // The surface died between prepare and the sheet: nobody can ever commit
    // this plan — release the Rust stash instead of leaving an unsigned,
    // nonce-guarded orphan until the next prepare overwrites it (V5
    // wallet-security note, closed).
    await abandon();
    return null;
  }
  return showModalBottomSheet<SendOutcomeDto>(
    context: context,
    backgroundColor: KvColor.surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => ConfirmSendSheet(
      summary: summary,
      commit: commit,
      abandon: abandon,
      title: title,
      contextNote: contextNote,
    ),
  );
}
