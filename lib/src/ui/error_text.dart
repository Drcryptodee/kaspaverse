/// Turning a thrown thing into the sentence Rust meant to say.
///
/// The generated [AppError] has no `toString()` override — and it cannot be
/// given one, because it is generated and generated bindings are never edited
/// (L20). Dart's default is therefore `Instance of 'AppError'`, and any surface
/// that does `e.toString()` renders exactly that where the honest message
/// belonged. Three message surfaces had already solved this privately; the send
/// lane — the one that moves money — had not, and printed the type name into
/// the failure body (product-audit run 1, F8).
///
/// One implementation, one import, so a fourth surface cannot re-derive a fourth
/// answer. Copy that DECIDES something (a lockout, a cancel) belongs with its
/// ceremony; this only extracts.
library;

import '../rust/api/error.dart';

/// The honest message inside [e], whatever wrapper it arrived in.
String displayError(Object e) {
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

/// Does [e] carry the bridge's rate-limit refusal?
///
/// Matched against the EXTRACTED message, never `e.toString()`. Against a raw
/// `AppError` that comparison ran on the literal string `Instance of 'AppError'`
/// — so the lockout branch was dead code and a rate-limited user was told their
/// passphrase was wrong instead of that they were locked out (run 1, F8).
bool isLockedOut(Object e) => displayError(e).contains('locked out');
