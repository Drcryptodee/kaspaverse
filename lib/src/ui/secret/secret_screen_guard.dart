import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/vault_service.dart';
import '../theme/tokens.dart';
import '../widgets/ceremony_mark.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_loader.dart';
import '../widgets/kv_two_pane.dart';

/// Wraps a §0.6 secret screen with the two platform guarantees locked at
/// P1 §0.6 (D-028):
///
/// 1. **FLAG_SECURE** on while the screen is shown — no screenshots, no recents
///    thumbnail (set on the native window via the ceremony `MethodChannel`).
/// 2. **Accessibility refusal** — the screen will NOT render its secret child
///    while any accessibility service is enabled; it shows a plain-language
///    explanation instead (the maximum-paranoia posture, founder call D-028 —
///    a third-party service can read the screen, so custody ceremonies refuse).
///
/// The platform PROOF of both (screenshot visibly blocked; refusal under
/// TalkBack) is the on-glass P1.4 device pass; this wires the mechanism and the
/// refusal UX, with seams so the gating logic is unit-tested without a channel.
///
/// Fail-closed: if the a11y query cannot be answered (only the host-test
/// no-channel case on a real build), the screen REFUSES rather than risk showing
/// a secret to an unverified screen — BG-10, "assume a hostile screen".
class SecretScreenGuard extends StatefulWidget {
  const SecretScreenGuard({
    super.key,
    required this.child,
    this.title,
    this.setSecure,
    this.checkAccessibility,
  });

  /// The secret screen to protect (rendered only when a11y is confirmed off).
  final Widget child;

  /// Optional context line for the refusal screen (e.g. "your recovery words").
  final String? title;

  /// Test seam: toggle FLAG_SECURE. Defaults to the ceremony channel.
  final Future<void> Function({required bool enable})? setSecure;

  /// Test seam: is any accessibility service active? Defaults to the channel.
  final Future<bool> Function()? checkAccessibility;

  static Future<void> _setSecure({required bool enable}) async {
    await VaultService.ceremony.invokeMethod<void>('setSecure', enable);
  }

  static Future<bool> _checkAccessibility() async {
    final active = await VaultService.ceremony.invokeMethod<bool>(
      'isAccessibilityActive',
    );
    return active ?? false;
  }

  @override
  State<SecretScreenGuard> createState() => _SecretScreenGuardState();
}

class _SecretScreenGuardState extends State<SecretScreenGuard>
    with WidgetsBindingObserver {
  late final Future<void> Function({required bool enable}) _setSecure =
      widget.setSecure ?? SecretScreenGuard._setSecure;
  late final Future<bool> Function() _checkA11y =
      widget.checkAccessibility ?? SecretScreenGuard._checkAccessibility;

  /// null = still checking; true = refuse (a11y on or unverifiable); false = ok.
  bool? _refuse;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enter();
  }

  Future<void> _enter() async {
    // FLAG_SECURE the instant the route mounts (best-effort; a host test has no
    // channel — the a11y gate below still protects the secret).
    try {
      await _setSecure(enable: true);
    } on PlatformException {
      /* platform gap — gating still applies */
    } on MissingPluginException {
      /* host test — no channel */
    }
    await _recheck();
  }

  Future<void> _recheck() async {
    bool refuse;
    try {
      refuse = await _checkA11y();
    } catch (_) {
      refuse = true; // fail-closed: cannot verify → do not show the secret
    }
    if (mounted) setState(() => _refuse = refuse);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A user could enable TalkBack while we are backgrounded; re-gate on resume
    // so the refusal fires before any secret is shown again.
    if (state == AppLifecycleState.resumed) _recheck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Clear FLAG_SECURE on the way out (flat secret-screen usage; best-effort).
    _setSecure(enable: false).catchError((Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final refuse = _refuse;
    if (refuse == null) return const _GuardSplash();
    if (refuse) {
      return _AccessibilityRefusal(onRecheck: _recheck, subject: widget.title);
    }
    return widget.child;
  }
}

class _GuardSplash extends StatelessWidget {
  const _GuardSplash();

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: KvColor.abyss,
    body: Center(child: KvLoader()),
  );
}

/// **The refusal, re-toned at UX-R7 — and nothing but its paint moved.**
///
/// This surface appears when an accessibility service is active, which means
/// it appears **in front of a user who is very probably relying on one**. That
/// makes its words and its semantics the substance here and the styling the
/// decoration, so: the heading is marked as a header rather than merely being
/// large, the mark is excluded from the tree (it says nothing the words do not
/// say), and the copy still leads with what the app is doing and why before it
/// asks for anything.
///
/// **What did not change, because §3 says it must not**: when the guard
/// refuses, how long it takes to decide, and what it renders while deciding.
/// Those live in [_SecretScreenGuardState] and this sitting did not touch
/// them — a re-tone that quietly moved the refusal's trigger would be a
/// custody change wearing a skin change's clothes.
class _AccessibilityRefusal extends StatelessWidget {
  const _AccessibilityRefusal({required this.onRecheck, this.subject});

  final VoidCallback onRecheck;

  /// [SecretScreenGuard.title] — *your PIN*, *your passphrase*, *your recovery
  /// words*. The caller has always set it and this screen has always ignored
  /// it, so a PIN vault was told about a "passphrase" it does not have. Same
  /// defect `biometric_copy.dart` fixed one file over in this sitting, stopped
  /// one file short (`ux-auditor`, UX-R7). Null keeps the general phrasing,
  /// which is the safe direction: it names both.
  final String? subject;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: KvColumn(
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The house mark, not `Icons.*` — BG-25: every mark the app
                  // draws, it owns. `eyeOff` is the glyph the app already uses
                  // for concealment, so the refusal and the reveal control
                  // speak about the same thing in the same shape.
                  const Center(child: CeremonyMark(KvGlyph.eyeOff)),
                  const SizedBox(height: KvSpace.l),
                  Semantics(
                    header: true,
                    child: const Text(
                      'Secure screen paused',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 22,
                        height: 28 / 22,
                        fontWeight: FontWeight.w700,
                        fontVariations: KvWeight.w700,
                        letterSpacing: -0.22,
                        color: KvColor.ink,
                      ),
                    ),
                  ),
                  const SizedBox(height: KvSpace.sm),
                  Text(
                    'An accessibility service is active. To keep '
                    '${subject ?? 'your recovery words and passphrase'} '
                    'private, KaspaVerse will not show '
                    '${subject == null ? 'them' : 'it'} while another app can '
                    'read the screen.\n\nTurn off accessibility services, '
                    'then tap below to continue.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 15,
                      height: 22 / 15,
                      color: KvColor.inkDim,
                    ),
                  ),
                  const SizedBox(height: KvSpace.xl),
                  // `raised`, not the primary pill: §8's glow belongs to the
                  // act a screen is FOR, and this screen is for refusing. The
                  // control merely asks the question again.
                  KvAction.raised(
                    label: 'I have turned them off',
                    onTap: onRecheck,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
