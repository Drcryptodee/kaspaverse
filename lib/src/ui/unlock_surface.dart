import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rust/api/vault.dart' as vault_api;
import '../services/vault_service.dart';
import 'biometric_copy.dart';
import 'passphrase_unlock_screen.dart';
import 'theme/kv_page_route.dart';
import 'theme/tokens.dart';
import 'widgets/kv_chrome.dart';
import 'widgets/kv_coming_soon.dart';
import 'widgets/kv_drawer.dart';
import 'widgets/kv_glyph.dart';
import 'widgets/kv_loader.dart';
import 'widgets/kv_lock_mark.dart';
import 'widgets/kv_notice.dart';
import 'widgets/kv_reading.dart';
import 'widgets/kv_rows.dart';
import 'widgets/kv_sheet.dart';
import 'widgets/kv_two_pane.dart';

/// **The locked surface — the only screen a sealed wallet ever shows** (D-036
/// biometric-first; render `Unlock-selection.png`, built UX-R7).
///
/// A vault exists and is sealed. This offers the Path-A biometric unlock and
/// hands off to the Path-B ceremony. It deliberately keys in **no** secret, so
/// it is not one of the §0.6 FLAG_SECURE secret screens; the passphrase
/// ceremony (with its FLAG_SECURE + a11y refusal) is [PassphraseUnlockScreen].
///
/// **The archetype is a door, not a ceremony** (§0b). Its two siblings —
/// create and restore — are ceremonies and share [KvCeremonyPage]; this one
/// does not, and that is a composition decision rather than an omission. A
/// ceremony page is a bar over a clamped column with a pinned foot, built to
/// carry a user through numbered steps. A door has no steps, no bar and no way
/// back: one emblem, one name, one act. Forcing the door into the ceremony's
/// scaffold would have given it chrome for a journey it does not make.
///
/// **Measured off the render at 4×** (786 × 1704 = 393 × 852 dp) — see
/// [_rhythmAbove] for the vertical rhythm and [KvLockMark] for the emblem.
///
/// Vault-calm throughout (BG-9): decelerate motion, no celebration, no
/// exclamation. Every platform lane is injected so the surface tests without a
/// channel.
class UnlockSurface extends StatefulWidget {
  const UnlockSurface({
    super.key,
    this.probe,
    this.unlock,
    this.inputKind,
    this.lockedAt,
    this.debugFooter,
  });

  /// Is a biometric (Path-A) unlock both enrolled and currently available?
  /// Defaults to the platform channel; injected in tests.
  final Future<bool> Function()? probe;

  /// Run the system biometric ceremony; true once Rust holds the seed.
  /// Defaults to the platform channel; injected in tests.
  final Future<bool> Function()? unlock;

  /// **Which secret this vault was sealed with** (D-312) — for the WORDS on
  /// the fallback pill, and for nothing else.
  ///
  /// This screen draws no pad, so the rule that governs the pad does not
  /// govern it: [PassphraseUnlockScreen] still reads the byte itself and
  /// still offers both pads whatever it says. Reading it here only stops the
  /// door from calling the secret by a name the room behind it does not use.
  /// It fails the same safe way for the same reason — any failure says
  /// *passphrase*, the word that fits either secret.
  final Future<vault_api.VaultInputKind> Function()? inputKind;

  /// When this process watched the vault lock. Defaults to the service's own
  /// observation; injected so a frame can draw a fixed time.
  final ValueListenable<DateTime?>? lockedAt;

  /// Debug-only escape hatch (the caged DevVaultPanel); null in release.
  final Widget? debugFooter;

  // Through VaultService, never the static ceremony channel. The §0.11 auto-lock
  // suppression is an INSTANCE guard on the service, so a caller that reaches
  // past it cannot be covered by it *by construction* — and this lane is the one
  // where that bites hardest: the prompt takes the foreground, the lifecycle
  // reports paused, and at the default grace of 0 the lock fires against the
  // vault the user's finger has just opened. (wallet-security-auditor, Track 2 —
  // three of the four ceremonies were routed and this one was left behind.)
  static Future<bool> _probeBiometric() async {
    final enrolled = await VaultService.instance.pathAEnrolled();
    final status = await VaultService.instance.biometricStatus();
    return enrolled && status == biometricReady;
  }

  static Future<bool> _runBiometricUnlock() =>
      VaultService.instance.unlockBiometric();

  /// **The render's vertical rhythm, as the two spans that produce it.**
  ///
  /// Measured at 4×: the emblem's centre sits 299 dp down a 852 dp screen and
  /// the group (ring · chip · locked-at) ends at ~460, with the pill's top at
  /// 712. So the air above the group is 239 and the air below it 252 — near
  /// enough to equal that the eye reads the group as centred, far enough from
  /// it that the screen reads as a door with its handle at the foot rather
  /// than a form with its fields in the middle.
  ///
  /// Kept as flex weights rather than dp so the composition is the render's
  /// at 852 and *proportionally* the render's everywhere else — a fixed 239
  /// would put the emblem below the fold on a short window and leave a hole
  /// on a tall one (BG-33: layout transforms, never stretches).
  static const int _rhythmAbove = 239;
  static const int _rhythmBelow = 252;

  /// The render's gaps inside the group: ring → chip, chip → locked-at.
  static const double _ringToChip = 26;
  static const double _chipToLockedAt = 12;

  @override
  State<UnlockSurface> createState() => _UnlockSurfaceState();
}

class _UnlockSurfaceState extends State<UnlockSurface> {
  bool? _biometricReady; // null while probing
  bool _unlocking = false;
  String? _message;

  /// **The fingerprint lane is gone until it is set up again**, as distinct
  /// from "this attempt failed" ([_message]).
  ///
  /// Android permanently invalidates the Keystore key when the phone's
  /// fingerprints change. That is §0.5 working, not a fault, and it is the
  /// state render `Unlock-selection (1).png` draws as a standing notice above
  /// the pill rather than as a line that scrolls past. It has to persist,
  /// because the user's next action is in a different app's settings.
  bool _keyInvalidated = false;

  /// The word this vault's secret goes by. Starts on *passphrase* and only
  /// ever moves on a successful read — see [UnlockSurface.inputKind].
  vault_api.VaultInputKind _pad = vault_api.VaultInputKind.passphrase;
  bool get _isPin => _pad == vault_api.VaultInputKind.digits;

  /// **One act, one pair of names** (BG-21) — the same rule
  /// `PassphraseUnlockScreen._padSwitchLabel` keeps, so the door and the room
  /// behind it call the secret the same thing.
  String get _secretNoun => _isPin ? 'PIN' : 'passphrase';

  ValueListenable<DateTime?> get _lockedAt =>
      widget.lockedAt ?? VaultService.instance.lockedAt;

  @override
  void initState() {
    super.initState();
    _probe();
    _resolvePad();
  }

  Future<void> _probe() async {
    final probe = widget.probe ?? UnlockSurface._probeBiometric;
    try {
      final ready = await probe();
      if (mounted) setState(() => _biometricReady = ready);
    } catch (_) {
      // `catch (_)`, not `on PlatformException`: a `MissingPluginException` is
      // not one, and an uncaught throw here leaves `_biometricReady` null — a
      // permanent spinner on the one screen standing between the user and their
      // funds, with the "Unlock with passphrase" escape never rendered. INV-6's
      // liveness shadow (wallet-security-auditor).
      if (mounted) setState(() => _biometricReady = false);
    }
  }

  Future<void> _resolvePad() async {
    final read = widget.inputKind ?? VaultService.instance.vaultInputKind;
    vault_api.VaultInputKind kind;
    try {
      kind = await read();
    } catch (_) {
      return; // keep the default — the word that fits either secret
    }
    if (!mounted) return;
    setState(() => _pad = kind);
  }

  Future<void> _unlock() async {
    final unlock = widget.unlock ?? UnlockSurface._runBiometricUnlock;
    setState(() {
      _unlocking = true;
      _message = null;
    });
    var succeeded = false;
    try {
      final ok = await unlock();
      succeeded = ok;
      if (!ok && mounted) {
        setState(
          () => _message =
              "Unlock didn't complete. Your funds are safe — try again.",
        );
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        // Tapping "Use passphrase" on the system prompt is a CHOICE, and on this
        // screen it is the common one — reporting it as "unavailable right now"
        // told the user something false about their own deliberate action every
        // single time. Same contract as create/restore/settings.
        _message = e.code == 'cancelled'
            ? null
            : unlockFailureCopy(e.code, _secretNoun);
        // A key invalidated by a new fingerprint is not a transient failure —
        // this lane is gone until re-enrolment, so stop offering it and put the
        // passphrase where the finger already is. The notice, not the retry
        // line, is what carries it from here (`Unlock-selection (1).png`).
        if (e.code == biometricKeyInvalidated) {
          _biometricReady = false;
          _keyInvalidated = true;
          _message = null;
        }
      });
    } catch (_) {
      // NOT `on PlatformException` alone. A MissingPluginException is not one,
      // and neither is a channel reply that never arrives at all — which is
      // exactly what an unguarded platform throw produced, because Flutter's
      // DartMessenger swallows it and simply never replies. Uncaught, that left
      // `_unlocking` true forever: a disabled button reading "Unlocking…" on the
      // one screen standing between the user and their funds (run 1, F4). Same
      // reasoning as `_probe()` above — solved one method up, never carried down.
      if (!mounted) return;
      setState(
        () =>
            _message = 'Unlock is unavailable right now. Your funds are safe.',
      );
    } finally {
      // The ONE place `_unlocking` is released, so no future branch can forget.
      // On success we deliberately stay busy: the status stream flips and
      // AppShell swaps this surface for home, and releasing here would flash the
      // button back to idle first (P1.3 watch-out). Every other path releases —
      // including the ones that used to throw straight past this method.
      if (!succeeded && mounted) {
        setState(() => _unlocking = false);
      }
    }
  }

  /// Hand off to the §0.6 passphrase unlock screen (Path B) — pushed over the
  /// shell; on success the status stream flips unlocked and the shell shows home
  /// beneath, and that screen pops itself.
  void _openPassphrase() {
    Navigator.of(
      context,
    ).push(KvPageRoute<void>(builder: (_) => const PassphraseUnlockScreen()));
  }

  /// **The wallet switcher, shown before it is built** (D-313 §1, founder
  /// 2026-09-09: *"i want it built so i see the UI and the feel of it. the
  /// future build of it comes untop of it."*).
  ///
  /// `Unlock-selection (2).png` draws three wallets with initial discs,
  /// truncated addresses, a `watch-only` tag and *Add or import a wallet*.
  /// **The app holds exactly one vault** — `seal_and_persist` refuses to
  /// overwrite — so every one of those rows is a feature, not data. The sheet
  /// is therefore drawn in the app's own coming-soon register: the render's
  /// composition, and nothing in it that could be read as an offer to make a
  /// second wallet today (§8's dead-destination rule is why the chip opens
  /// this at all rather than going inert under the thumb).
  void _openWallets() {
    Navigator.of(context).push(
      KvSheetRoute<void>(
        builder: (sheetContext) => KvSheet(
          title: 'Wallets on this phone',
          onCancel: () => Navigator.of(sheetContext).pop(),
          child: const _WalletsComingSoon(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: KvColumn(
          // **Centres when it fits, scrolls when it does not.**
          //
          // The rhythm below is built from flex, which needs a bounded height;
          // the door also has to survive 915 x 412 with a 109 dp notice on it,
          // where the fixed content alone is 53 dp taller than the window.
          // `IntrinsicHeight` under a `minHeight` of the viewport is the one
          // idiom that does both: at every geometry that fits, the spacers
          // take the slack and the composition is the render's; where it does
          // not, they collapse to zero and the column scrolls instead of
          // overflowing. No breakpoint is read (BG-33).
          // **And it says so when there is more below** (`ux-auditor`,
          // UX-R7). At 915 x 412 with the key-invalidated notice up, the
          // pill's ink ends at y=408 of 412 and the recovery escape is
          // entirely off-screen — the one state that most needs it, at the
          // geometry the founder actually holds this phone in second-most
          // often, with nothing on the glass saying to scroll. The app owns
          // the fade; the door was not using it.
          child: KvScrollEdge(
            ground: KvColor.abyss,
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Spacer(flex: UnlockSurface._rhythmAbove),
                        const Center(child: KvLockMark()),
                        const SizedBox(height: UnlockSurface._ringToChip),
                        Center(
                          child: _WalletChip(
                            name: KvWalletIdentity.soleWalletName,
                            onTap: _openWallets,
                          ),
                        ),
                        const SizedBox(height: UnlockSurface._chipToLockedAt),
                        _LockedAtLine(lockedAt: _lockedAt),
                        const Spacer(flex: UnlockSurface._rhythmBelow),
                        // **The foot changes length, so it MOVES** (BG-24). A 109 dp
                        // notice arriving when the key is invalidated, a message block
                        // appearing under a failed attempt, and a whole 52 dp action
                        // landing the instant the probe answers were three uneased
                        // jumps on a custody surface — and `KvCeremonyPage`, extracted
                        // in this same sitting, already wraps its own pad for exactly
                        // this reason (`ux-auditor`, UX-R7).
                        AnimatedSize(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : KvMotion.calm,
                          curve: KvMotion.curve,
                          alignment: Alignment.bottomCenter,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: _foot(),
                          ),
                        ),
                        if (widget.debugFooter != null) ...[
                          const SizedBox(height: KvSpace.m),
                          widget.debugFooter!,
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The pill and whatever the state puts above and below it.
  List<Widget> _foot() {
    final ready = _biometricReady;
    if (ready == null) {
      // Probing. The pill's seat is HELD rather than left empty, so the foot
      // does not jump 56 dp the instant the probe answers (BG-24).
      //
      // **And the recovery escape renders anyway**, outside this early
      // return. `_probe()`'s `catch (_)` cannot reach the one failure that
      // matters here: a MethodChannel reply that never arrives at all, which
      // `DartMessenger` swallows, so the future simply stays pending. That is
      // live rather than theoretical — a `java.lang.Error` escaping the
      // platform handler is not caught by a `catch (Exception)` — and it is
      // run 1's F4 scar one state over. Without this the door would sit on a
      // spinner for ever with no pill, no hand-off and no way out stated:
      // INV-6's liveness shadow on the one screen between a user and their
      // funds (`wallet-security-auditor`, UX-R7, proven against a wedged
      // probe).
      return [
        const SizedBox(
          height: KvSpace.control,
          child: Center(child: KvLoader()),
        ),
      ];
    }
    return [
      if (_keyInvalidated) ...[
        // The render's amber plate, with the app's own audited sentence in it.
        //
        // **The render's copy is not used, and this is the one place in the
        // group where that is true.** It reads *"A new fingerprint was added
        // to this phone. Unlock with your passphrase once to trust it."* — a
        // promise this app does not keep: an invalidated key is rebuilt by the
        // enrolment ceremony in Settings, never as a side effect of a Path-B
        // unlock. Painting it would be BG-8 in the same class as the
        // `none_enrolled` defect D-310 fixed, and the sentence it replaces was
        // written by the custody auditors. The render is the authority on the
        // plate, its tone and its seat; it is not an authority on what the
        // mechanism behind it does (D-259 governs form).
        KvNotice(text: biometricInvalidatedCopy(_secretNoun)),
        const SizedBox(height: KvSpace.m),
      ],
      if (_message != null) ...[
        Text(
          _message!,
          // Inter (prose), not the mono data role; neutral, not error-red — a
          // retry prompt is not fund risk, and red is rationed to fund risk
          // only (§3/§4). The copy already says funds are safe; the colour
          // must agree.
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            height: 19 / 13,
            color: KvColor.inkDim,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: KvSpace.m),
      ],
      _pill(ready),
      // **9.5 dp in the render, and it is a custody number here.** The first
      // cut left 4 dp under the pill and 0 between the two actions, so a thumb
      // a hair low on the unlock hand-off landed on the sheet that tells the
      // user to clear the app's storage (`ux-auditor` BLOCK, item 21/BG-12).
      const SizedBox(height: KvSpace.s10),
      // **The render's one text action, and only that** (founder, on glass
      // 2026-09-10: *"remove the whole info icon and remove the lost
      // passphrase/pin thingy. just remove it."*).
      //
      // What went with it is recorded rather than quietly dropped, because an
      // auditor put it here twice: wallet-security's run-1 **F6** seated a
      // *Lost your secret?* sheet on this surface, and `ffi-leak-auditor`
      // moved it BACK here this sitting when a mid-sitting relocation to
      // `PassphraseUnlockScreen` put it behind `SecretScreenGuard`. The
      // founder has now removed the sheet itself, which is a product call and
      // his (D-316 §6). **The consequence, stated so nobody re-adds it by
      // reflex:** a user who kept their twelve words and lost their secret is
      // told nothing in-app, and the route out — clear storage, then restore —
      // is not guessable, because `restore_and_persist` refuses while a sealed
      // blob exists. Nothing about the money changed: the words are still the
      // wallet.
      if (ready)
        KvTextAction(
          label: 'Use $_secretNoun instead',
          onTap: _unlocking ? null : _openPassphrase,
        ),
    ];
  }

  Widget _pill(bool ready) {
    if (!ready) {
      // No Path-A enrolled, unavailable, or invalidated — Path B *is* the
      // unlock lane, so it takes the primary pill rather than sitting under a
      // dead one (`Unlock-selection (1).png` draws exactly this).
      return KvAction(
        label: 'Enter $_secretNoun',
        primary: true,
        mark: KvGlyph.keyboard,
        onTap: _openPassphrase,
      );
    }
    return KvAction(
      label: 'Unlock',
      primary: true,
      onTap: _unlock,
      disabledReason: _unlocking ? 'Unlocking…' : null,
      // **Both marks, and only where both are honest.** The render draws a
      // face and a fingerprint with a hairline between them, which reads as a
      // promise the phone offers both — and `biometricStatus()` answers
      // `ready` / `none_enrolled` / `no_hardware` and *nothing finer*, so the
      // app cannot know which. The pair is therefore the LEAST specific
      // honest statement available: either single mark would claim more than
      // the app has been told. It is the same argument `CeremonyMarkPair`
      // already won on `O6`, and it holds here for the extra reason that the
      // pair is drawn only on the branch where a biometric is genuinely
      // offered — when it is not, the pill above says *Enter passphrase* and
      // no mark is drawn at all. So the claim "this phone opens with a
      // biometric" is true exactly when it is painted (BG-8).
      labelWidget: const _BiometricLabel(),
    );
  }
}

/// The render's leading pair — face · hairline · fingerprint — then the verb.
class _BiometricLabel extends StatelessWidget {
  const _BiometricLabel();

  /// **22, against `KvAction.glyph`'s 18** (founder, on glass 2026-09-10:
  /// *"increase the fingerprint and face ID icon a little bit and align the
  /// 'Unlock' word well while at it"*).
  ///
  /// A pill's leading mark is normally a label's companion and takes 18. These
  /// two are not that: they are the OFFER — the thing the user is being asked
  /// to present — and at 18 against a 16/700 verb they read as decoration
  /// beside the word rather than as the subject of it. 22 is the next rung
  /// that keeps the pair inside the 56 dp pill with its own air intact.
  static const double glyph = 22;

  /// The rule between the marks (`Unlock-selection.png`: a 1 dp dark hairline
  /// at the pill's own ink, quietened so it separates without reading as a
  /// third mark). It grows with them.
  static const double rule = 1;
  static const double ruleHeight = 22;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const KvGlyphIcon(KvGlyph.face, size: glyph, tone: KvColor.onPrimary),
      const SizedBox(width: KvSpace.s10),
      Container(
        width: rule,
        height: ruleHeight,
        color: KvColor.onPrimary.withValues(alpha: 0.3),
      ),
      const SizedBox(width: KvSpace.s10),
      const KvGlyphIcon(
        KvGlyph.fingerprint,
        size: glyph,
        tone: KvColor.onPrimary,
      ),
      const SizedBox(width: KvSpace.m),
      // **The verb rides the marks' optical centre, not the row's baseline.**
      // A 20 dp line box beside a 22 dp glyph sits a shade high against it,
      // and on a pill this wide the eye reads the mismatch as the word being
      // off rather than the marks being big. `Text` has no descender to spare
      // here — *Unlock* is all x-height and a k — so the correction is one dp
      // down rather than a baseline change (founder, same beat).
      const Padding(
        padding: EdgeInsets.only(top: 1),
        child: Text(
          'Unlock',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 16,
            height: 20 / 16,
            fontWeight: FontWeight.w700,
            fontVariations: KvWeight.w700,
            color: KvColor.onPrimary,
          ),
        ),
      ),
    ],
  );
}

/// **The wallet's name, in a `plate` stadium with a chevron** — the render's
/// chip, and the seat the switcher will occupy (D-313).
class _WalletChip extends StatelessWidget {
  const _WalletChip({required this.name, required this.onTap});

  final String name;
  final VoidCallback onTap;

  /// **44, not the render's 56** (founder, on glass 2026-09-10: *"the text has
  /// padding top and bottom in that pill housing it, reduce the space untop
  /// and below of the 'Main wallet' text so its more neat-looking"*).
  ///
  /// `Unlock-selection.png` measures 112 px = 56 dp and that is what the first
  /// build drew — but a 56 dp stadium around a 22 dp line box leaves 17 dp of
  /// air a side, and on glass it read as a control waiting for something
  /// rather than as a name. 44 leaves 11. **The touch target does not shrink
  /// with it**: the gesture box stays [KvSpace.touchTarget] and the stadium is
  /// centred inside it, so BG-12 is untouched by the trim — only the paint
  /// moves. This is a render divergence taken on his own eye (D-262: glass
  /// outranks the render).
  static const double height = 44;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$name. Choose a wallet.',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: KvSpace.touchTarget,
        child: Center(
          child: Container(
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: KvSpace.s20),
            decoration: BoxDecoration(
              color: KvColor.plate,
              borderRadius: BorderRadius.circular(KvRadius.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 17,
                      height: 22 / 17,
                      fontWeight: FontWeight.w700,
                      fontVariations: KvWeight.w700,
                      color: KvColor.ink,
                    ),
                  ),
                ),
                const SizedBox(width: KvSpace.s),
                // Down, not right: the chip opens a sheet beneath it. §4a's one
                // chevron, turned — the app owns one and rotates it (BG-25).
                const RotatedBox(
                  quarterTurns: 1,
                  child: KvGlyphIcon(
                    KvGlyph.chevron,
                    size: 18,
                    tone: KvColor.inkDim,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// **`Locked at 09:41` — or nothing at all.**
///
/// The render prints the time the vault sealed. [VaultService.lockedAt] is
/// null unless this process actually WATCHED it lock, and null draws an empty
/// seat rather than a guess: a cold start onto a sealed vault has no
/// transition to have seen, and formatting `DateTime.now()` there would read
/// correctly at every moment except the one a user would check it (BG-8).
///
/// The seat keeps its height either way, so the group above the fold does not
/// shift by a line between a cold start and a lock the app saw (BG-24).
class _LockedAtLine extends StatelessWidget {
  const _LockedAtLine({required this.lockedAt});

  final ValueListenable<DateTime?> lockedAt;

  /// One line of the 13/19 meta rung, **scaled** — a rendered line box is not
  /// a constant (Scar 0). At 1.3x a 13/19 line measures 24.7 dp, so a fixed 19
  /// under-reserves by 5.7 and the words paint out of their seat into the
  /// chip's air above (`ux-auditor`, UX-R7).
  static const double lineHeight = 19;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.textScalerOf(context).scale(lineHeight),
    child: ValueListenableBuilder<DateTime?>(
      valueListenable: lockedAt,
      builder: (context, at, _) {
        if (at == null) return const SizedBox.shrink();
        // The phone's own 12/24-hour setting, never a hard-coded pattern —
        // the render's `09:41` is a 24-hour locale's rendering of this, not a
        // format to impose on one that reads 9:41 AM.
        final time = TimeOfDay.fromDateTime(at).format(context);
        // **Only the digits are mono** (BG-30). `format` returns the whole
        // localised string, so on a 12-hour phone that is `9:41 AM` — and the
        // first cut set the meridiem in the figure's face too, which put a
        // label in the data role and a visibly wide mono space in front of it.
        // The render's `09:41` has no meridiem, so this is a case the render
        // does not settle and the law does. Split on the first space that
        // follows a digit; a locale that returns none simply has no suffix.
        final split = RegExp(r'(?<=\d)\s').firstMatch(time);
        final digits = split == null ? time : time.substring(0, split.start);
        final suffix = split == null ? '' : time.substring(split.start);
        return Center(
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Locked at '),
                TextSpan(
                  text: digits,
                  style: const TextStyle(fontFamily: KvFont.mono),
                ),
                TextSpan(text: suffix),
              ],
            ),
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkMeta,
            ),
          ),
        );
      },
    ),
  );
}

/// `Unlock-selection (2).png`'s composition, in the coming-soon register
/// (D-313 §1). The rows are the render's; none of them is reachable, and
/// nothing here implies a second wallet can be made today.
class _WalletsComingSoon extends StatelessWidget {
  const _WalletsComingSoon();

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    // **The body scrolls, the foot does not** — the house sheet pattern
    // (`KvSheet`'s own contract, D-221 §1). At 320 dp / 1.3x the heading, the
    // chosen row and the coming-soon plate are 70 dp taller than the panel's
    // 90 % cap, and a bare `Column` there overflows instead of scrolling.
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Each unlocks on its own.',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 15,
            height: 22 / 15,
            color: KvColor.inkDim,
          ),
        ),
        const SizedBox(height: KvSpace.m),
        // **The one wallet there is, in the app's own selection vocabulary.**
        //
        // The render draws three rows with initial discs, truncated addresses
        // and a `watch-only` tag. Two things stop that being copied literally.
        // Its discs are `KvRowDisc.initial`, a part UX-R5 **retired** — it drew
        // `tealTint` + `primaryMuted`, the face §4 reserves for the wallet's own
        // mark, and reviving it would put one object back into two faces
        // (`ux-auditor` BLOCK, BG-21). And three rows of plausible addresses on
        // a locked screen are three wallets a user may believe they have; the
        // sheet is a preview of a feature, and a preview must not be mistakable
        // for state (BG-8). So the list draws what is TRUE — one wallet, chosen
        // — in `KvChoiceCard`, which is the selected-row form the render is
        // reaching for and the one the switcher will use when it is built.
        KvChoiceCard(
          children: [
            KvChoiceRow(
              title: KvWalletIdentity.soleWalletName,
              sub: 'The wallet on this phone',
              selected: true,
              // Null, not a no-op: it is already chosen, and a control that
              // answers a tap by doing nothing is §8's dead destination.
              onTap: null,
            ),
          ],
        ),
        const SizedBox(height: KvSpace.m),
        // The feature, standing exactly where it will live — the switcher, the
        // second wallet and the import are one session (D-313 §2), so they get
        // one seat rather than three dead rows.
        const KvComingSoon(
          mark: KvGlyph.money,
          name: 'More than one wallet',
          sentence:
              'Not built yet. Adding, importing and switching between wallets '
              'will live here.',
        ),
      ],
    ),
  );
}
