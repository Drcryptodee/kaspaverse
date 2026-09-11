import 'package:flutter/foundation.dart';

import '../../rust/api/vault.dart' as vault_api;
import 'package:flutter/widgets.dart';

import '../../rust/api/send.dart'
    show ConsolidateEstimateDto, SendOutcomeDto, SignableSummaryDto;
import '../../rust/api/wallet.dart' show DeepScanReport, WalletAddressDto;

/// The seams the settings group is built on — **one file, so the four screens
/// share a contract rather than four opinions of one** (the V5 scope pattern,
/// D-086: seams, never singletons, so a widget test runs with no platform
/// channel under it).
///
/// A scope carries what its *domain* owns. The root screen reads every one of
/// them, because `T1`'s law is that **every row's sub-line is its own current
/// state** and a state has to come from the seam that owns it or it is a
/// placeholder wearing a fact's clothes.

/// Everything the Security domain drives.
@immutable
class SecurityScope {
  const SecurityScope({
    required this.biometricStatus,
    required this.pathAState,
    required this.enroll,
    required this.clearEnrollment,
    required this.lockGraceSecs,
    required this.setLockGraceSecs,
    this.lockNow,
    this.inputKind,
  });

  /// What the vault's own secret is — a PIN or a passphrase — so every
  /// sentence the fingerprint lane says about "the other way in" names it as
  /// the door does (`UnlockSurface.inputKind`, BG-21). Null reads the
  /// service; a failed read keeps *passphrase*, the word that fits either.
  final Future<vault_api.VaultInputKind> Function()? inputKind;

  /// `ready` · `none_enrolled` · `no_hardware` · `unavailable` ·
  /// `security_update_required` · `unknown`. A reason, never a bool — see
  /// `biometricStateLabel` for why that distinction is the whole point:
  /// "never set up" and "no sensor on this phone" need different sentences
  /// and different remedies, and as a bool they were the same "Off".
  final Future<String> Function() biometricStatus;

  /// `none` · `ready` · `invalidated`. A state, not a bool, for the same
  /// reason: enrolled-then-invalidated by a new fingerprint reads as "On"
  /// over a lane that can no longer open anything (run 1, F4).
  final Future<String> Function() pathAState;

  /// Throws `PlatformException` with a stable code so a cancel can be told
  /// from a failure.
  final Future<bool> Function() enroll;
  final Future<void> Function() clearEnrollment;

  final ValueListenable<int> lockGraceSecs;
  final Future<void> Function(int secs) setLockGraceSecs;

  /// `T1`'s raised pill. Null ⇒ the pill is absent rather than inert — the
  /// dead-destination anti-pattern is the one thing a settings screen must
  /// not teach (§8).
  final Future<void> Function()? lockNow;
}

/// Everything the Wallet domain drives.
@immutable
class WalletSettingsScope {
  const WalletSettingsScope({
    required this.receiveAddress,
    required this.deepScan,
    this.listAddresses,
    this.coinsChanged,
    this.receiveRoute,
    this.consolidate,
    this.consolidateEstimate,
    this.commitSend,
    this.abandonSend,
  });

  final Future<String> Function() receiveAddress;

  /// The manual deep scan (`T4`'s `Scan for more addresses`). Long-running by
  /// design and bounded Rust-side; the row owns the busy state.
  final Future<DeepScanReport> Function() deepScan;

  /// Every receive address in the watch window with what it holds — `T4`'s
  /// `ADDRESSES` list.
  ///
  /// **Nullable, and the screen degrades rather than lying.** Absent ⇒ `T4`
  /// draws the single receive address it can always answer for, which is what
  /// it shipped before this seam existed. A list that renders a spinner
  /// forever, or an empty card over a funded wallet, would both say something
  /// false about the user's money (§8).
  final Future<List<WalletAddressDto>> Function()? listAddresses;

  /// Fires when the wallet's coins may have moved, so the address list can
  /// re-read rather than going stale under a user who is watching it.
  ///
  /// **The mature balance, not a clock.** A snapshot tick fires on every
  /// stream frame; the balance changes only when coins actually move — and a
  /// move is the only thing that can change what an address holds. A self-send
  /// between our own addresses still moves it, because it pays a fee.
  final Listenable? coinsChanged;

  /// Opens Receive over **one** address — the list hands it the address the
  /// user tapped, so the QR is never a different address than the row.
  ///
  /// `index` is the `receive/N` slot, and it is not decoration: Receive names
  /// the address from it and records the handout against it (UX-R4b). The
  /// stand-in row, which has no list to take an index from, passes 0 — the one
  /// address the wallet can always name.
  final Widget Function(String address, int index)? receiveRoute;

  /// Merge coins: Rust builds and stashes the plan, the screen opens the ONE
  /// signing surface over its summary. All three seams present ⇒ the row
  /// renders; absent ⇒ hidden.
  final Future<SignableSummaryDto> Function()? consolidate;

  /// What a merge would cost and move, **without stashing a plan** — the
  /// resting action bar's fee and the merge row's coin counts. Separate from
  /// [consolidate] on purpose: that one stashes a plan the ceremony must then
  /// commit or abandon, and pricing a button from it would strand one every
  /// time the screen was opened and left.
  final Future<ConsolidateEstimateDto> Function()? consolidateEstimate;
  final Future<SendOutcomeDto> Function(BigInt nonce)? commitSend;
  final Future<void> Function()? abandonSend;

  bool get canMerge =>
      consolidate != null && commitSend != null && abandonSend != null;
}

/// The Network domain: one door, and a summary of what is behind it.
///
/// **The summary reports the CHOICE, never the health.** "Public community
/// nodes" is a setting; "connected" is a state that changes without the user,
/// and putting it here would be a second rendering of the link — the C7
/// disagreement the retired network sheet actually caused.
@immutable
class NetworkSettingsScope {
  const NetworkSettingsScope({
    required this.route,
    required this.pinnedNode,
    this.rateEnabled,
  });

  /// Builds **the** node surface — never a copy of it. The money plate's
  /// network chip and `T1`'s Network row open the same builder.
  final WidgetBuilder route;

  final ValueListenable<String?> pinnedNode;

  /// Null when the rate seam is not wired — and the notifier's own value is
  /// null until the stored posture has been read. The summary says nothing
  /// about a price in either case rather than guessing at one.
  final ValueListenable<bool?>? rateEnabled;
}

/// The build's public identity, for `T6`.
@immutable
class AboutScope {
  const AboutScope({required this.packageInfo, this.openUrl});

  /// `version` · `build` · `signature` (SHA-256, lowercase hex).
  final Future<Map<String, String>> Function() packageInfo;

  /// Hands a URL to the platform. Null ⇒ the source row is a record rather
  /// than a control.
  final Future<bool> Function(String url)? openUrl;
}
