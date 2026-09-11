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

/// **Whether the vault refused because it is bound to a phone this is not**
/// (D-312, core `CoreError::DeviceBinding`).
///
/// It has to be distinguishable from a wrong secret, and only the message says
/// so: the two are the same shape of failure to the caller and *opposite* facts
/// to the user. One means try again; the other means this file will never open
/// here and the way back is the recovery words. Matched on the extracted
/// message for the same reason [isLockedOut] is (run 1, F8).
bool isDeviceBinding(Object e) =>
    displayError(e).contains("bound to its phone's hardware key");

/// **Whether the vault refused because the secret was wrong** — the core's
/// `WrongPassphraseOrCorrupt`, the one error that IS a fact about what was
/// typed. Every other failure (a blob that could not be read, a lock that
/// landed mid-call, a write that failed) is not, and a surface that says
/// *that is not your PIN* over one of those tells a correct PIN it is wrong
/// (`ux-auditor`, REKEY-1). Matched on the extracted message, as its siblings.
bool isWrongSecret(Object e) =>
    displayError(e).contains('wrong passphrase or corrupted');

/// **The two refusals every typed-secret surface says in the same words.**
///
/// The door (`PassphraseUnlockScreen`) and the re-key ceremony both meet a
/// lockout and a device-binding refusal, and both must end where a custody
/// message ends — with what is still true about the money. One string each,
/// so the sentence a user reads at the door is the sentence they read in
/// Settings (BG-21).
const String lockedOutCopy =
    'Too many attempts. Wait a moment, then try again — your funds are safe.';

/// **Not "wrong passphrase" — the secret may be perfectly correct.** A
/// device-bound vault (D-312) is unopenable on any phone but the one that
/// sealed it, and telling somebody to try again would be telling them to
/// keep retyping the right answer. The way out is the recovery words, and the
/// copy says so instead of hiding it behind a retry.
const String deviceBindingCopy =
    'This wallet is locked to the phone that made it, and this phone cannot '
    'open it. Restore from your recovery words instead — your funds are safe.';
