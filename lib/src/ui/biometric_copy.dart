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

/// The trailing label for a biometric row: on, off, or the reason it cannot be.
///
/// The unknown arm is an em dash, not "Unavailable". DS-1 gives three honest
/// states and *unknown* is one of them — asserting "Unavailable" would state a
/// platform fact the app has just admitted it cannot determine, and would
/// contradict [biometricUnavailableCopy], which says "the wallet can't tell" for
/// the same status one tap away (ux-auditor, Track 2).
String biometricStateLabel(String status, bool enrolled) => switch (status) {
  biometricReady => enrolled ? 'On' : 'Off',
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

/// An unknown status is neither healthy nor degraded — it is DS-1's third state,
/// and rendering its `—` in the healthy-active teal would give it the same voice
/// as "On" (ux-auditor, Track 2).
bool biometricStateIsUnknown(String status) => status == biometricUnknown;
