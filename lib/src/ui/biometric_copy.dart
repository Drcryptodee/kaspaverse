/// The words the app uses about Path-A biometric unlock, in one place.
///
/// Three surfaces render these now — the create ceremony, the restore ceremony
/// and Settings — and they are custody copy: they tell a user whether a control
/// protecting their funds is on, why it is not available, and whether something
/// just failed. Three hand-written copies of that is three chances to say
/// different things about one fact, and the version that drifts is always the
/// one nobody is looking at.
///
/// The status strings are the platform contract (`KeystoreVault.biometricStatus`);
/// the error codes are the ceremony contract (`KeystoreVault.Failure.code`).
library;

/// Path A can be offered right now.
const String biometricReady = 'ready';

/// The phone has a usable sensor but no fingerprint registered with Android.
///
/// The most important state on this list. It is the common case on a fresh
/// phone, it is the only one the user can *act* on, and while the probe returned
/// a bare bool it was indistinguishable from "this hardware cannot" — so the
/// enrolment offer simply never appeared and nothing explained why.
const String biometricNoneEnrolled = 'none_enrolled';

/// Path-A enrolment states (`KeystoreVault.pathAState`).
///
/// [pathAInvalidated] is the state that has to be said out loud. The user
/// changed their fingerprints, Android permanently invalidated the key the seed
/// was sealed against — which is §0.5 working exactly as designed — and from the
/// glass it is indistinguishable from a broken wallet. Reported as a bare "not
/// enrolled" it explains nothing; reported as "On" (the pre-fix behaviour) it
/// put a live-looking button over a lane that could never open again (run 1, F4).
const String pathANone = 'none';
const String pathAReady = 'ready';
const String pathAInvalidated = 'invalidated';

/// What to say when the fingerprint lane has been invalidated by a new
/// enrolment, on the locked surface and in Settings.
///
/// Ends where every custody message must: what is still true about the money.
/// Nothing is lost — Path B is the vault's real key and was never touched.
const String biometricInvalidatedCopy =
    'Your fingerprints changed, so this phone locked the wallet out of the '
    'fingerprint key — that is the wallet protecting you, not a fault. Unlock '
    'with your passphrase, then turn fingerprint unlock on again in Settings. '
    'Your funds are safe.';

/// Why Path A is unavailable, in the user's terms, with the action where there
/// is one.
String biometricUnavailableCopy(String status) => switch (status) {
  biometricNoneEnrolled =>
    'This phone has no fingerprint set up yet. Add one in Android Settings → '
        'Security, then turn this on in Settings → Security.',
  'no_hardware' =>
    'This phone has no fingerprint sensor the wallet can trust. Your '
        'passphrase is the unlock.',
  'unavailable' =>
    'The fingerprint sensor is not available right now. Try again in a moment.',
  'security_update_required' =>
    'Android needs a security update before the wallet can use the fingerprint '
        'sensor here.',
  _ =>
    "The wallet can't tell whether this phone supports fingerprint unlock. Your "
        'passphrase is the unlock.',
};

/// What to say when an enrolment ceremony did not complete.
///
/// A `cancelled` code never reaches here — backing out of a system prompt is a
/// choice, not a failure, and a wallet that shows an error banner for it is
/// lying about what happened. Callers branch on that code before calling.
///
/// Every line ends where a custody message has to end: what is still true about
/// the user's money. Losing an enrolment attempt costs nothing — Path B is the
/// vault's real key and is untouched throughout.
String enrollFailureCopy(String code) => switch (code) {
  'lockout' =>
    'Too many attempts. Wait a moment and try again — your funds are safe.',
  // Should no longer reach here — enrolment now deletes and rebuilds an
  // invalidated key rather than reusing it — but a code with no consumer is a
  // silent failure by construction, so it keeps a sentence of its own.
  biometricKeyInvalidated => biometricInvalidatedCopy,
  // The lifecycle race, said plainly: the vault re-locked while the system
  // prompt held the foreground, so there was no seed to seal. Swallowed, this
  // was the "I tapped it and nothing happened" report.
  'vault' =>
    'The wallet locked while the prompt was open. Unlock and try again from '
        'Settings.',
  'keystore' =>
    "This phone's secure hardware refused the key. Your passphrase still "
        'unlocks the wallet.',
  _ =>
    "Fingerprint setup didn't complete. Your funds are safe — you can turn it "
        'on any time in Settings.',
};

/// The ceremony error code for "a new fingerprint invalidated the key"
/// (`KeystoreVault.CODE_KEY_INVALIDATED`).
const String biometricKeyInvalidated = 'key_invalidated';

/// What to say when a Path-A **unlock** did not complete.
///
/// Separate from [enrollFailureCopy] because the stakes read differently: the
/// user is standing in front of a locked wallet, so every arm has to end with
/// the way in that still works.
String unlockFailureCopy(String code) => switch (code) {
  biometricKeyInvalidated => biometricInvalidatedCopy,
  'lockout' =>
    'Too many fingerprint attempts. Wait a moment, or unlock with your '
        'passphrase. Your funds are safe.',
  'no_enrollment' =>
    'Fingerprint unlock is not set up on this phone any more. Unlock with your '
        'passphrase, then turn it on again in Settings.',
  // `vault` is the code EVERY unseal/JNI failure on this lane carries, and
  // `keystore` every hardware refusal. Both fell through to the generic arm,
  // which is checklist 15 applied to one code and not carried across — the
  // commonest real failure came out as the most content-free sentence.
  'vault' =>
    "The wallet couldn't open with your fingerprint. Unlock with your "
        'passphrase — that always works, and your funds are safe.',
  'keystore' =>
    "This phone's secure hardware refused the key. Unlock with your passphrase "
        'and turn fingerprint unlock on again in Settings.',
  _ => 'Unlock is unavailable right now. Your funds are safe.',
};

/// The trailing label for a biometric row: on, off, or the reason it cannot be.
///
/// The unknown arm is an em dash, not "Unavailable". BG-8 gives three honest
/// states and *unknown* is one of them — asserting "Unavailable" would state a
/// platform fact the app has just admitted it cannot determine, and would
/// contradict [biometricUnavailableCopy], which says "the wallet can't tell" for
/// the same status one tap away (ux-auditor, Track 2).
String biometricStateLabel(
  String status,
  String pathAState,
) => switch (status) {
  // "Off" is a choice the user made; "Needs setting up again" is a state the
  // phone imposed on them. Collapsing the second into the first is what let a
  // dead fingerprint lane keep reporting itself as a working control (run 1, F4).
  biometricReady => switch (pathAState) {
    pathAReady => 'On',
    pathAInvalidated => 'Needs setting up again',
    _ => 'Off',
  },
  biometricNoneEnrolled => 'No fingerprint on this phone',
  'no_hardware' => 'Not supported',
  'unavailable' => 'Unavailable right now',
  'security_update_required' => 'Needs a security update',
  _ => '—',
};

/// Is [status] a state the user should read as degraded rather than as ordinary?
/// Drives the row tint — §3 rations colour, and a failure must not wear the same
/// ambient teal as "On".
bool biometricStateIsDegraded(String status) =>
    status != biometricReady && status != biometricUnknown;

/// The app could not determine whether Path A is available.
const String biometricUnknown = 'unknown';

/// An unknown status is neither healthy nor degraded — it is BG-8's third state,
/// and rendering its `—` in the healthy-active teal would give it the same voice
/// as "On" (ux-auditor, Track 2).
bool biometricStateIsUnknown(String status) => status == biometricUnknown;
