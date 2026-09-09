import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/vault_service.dart';
import 'biometric_copy.dart';
import 'extra_word_copy.dart';
import 'secret/bip39_wordlist.dart';
import 'secret/masked_dots.dart';
import 'secret/secret_byte_buffer.dart';
import 'secret/secret_keyboard.dart';
import 'secret/secret_screen_guard.dart';
import 'secret/word_parts.dart';
import 'theme/kv_window.dart';
import 'theme/tokens.dart';
import 'widgets/ceremony_mark.dart';
import 'widgets/haptics.dart';
import 'widgets/kv_address.dart';
import 'widgets/kv_chrome.dart';
import 'widgets/kv_loader.dart';
import 'widgets/kv_tabs.dart';
import 'widgets/kv_toggle.dart';
import 'widgets/kv_two_pane.dart';

/// The restore ceremony's steps.
///
/// `enrolling` is the one that was missing, and its absence was the whole
/// defect: the create ceremony ended `seal → biometric offer → home`, restore
/// ended `commit → home`, and Path A had no other door in the entire app. A
/// restored wallet could therefore never enable fingerprint unlock — a shipped,
/// device-proven, fully-working native lane that no user could reach.
enum _Step { words, extraWord, preview, passphrase, enrolling }

/// Restore flow (P1.4 deliverable 2). §0.6/§0.7: FLAG_SECURE + a11y refusal via
/// [SecretScreenGuard]; seed words are PICKED from the in-app filtered wordlist
/// (no system IME) and captured as the ordered list of wordlist INDICES — the
/// assembled phrase is only ever bytes for the bridge, never a Dart `String`
/// (INV-3). Validation is Rust-side (INV-9). The derived first address is shown
/// before commit so a typo'd word opens a visibly-different wallet rather than a
/// silent empty one — the decoy/poisoning UX trap (wallet-security + ux).
///
/// Restore accepts 12 AND 24 words and ANY-UTF-8 extra word (the compatibility
/// path; ASCII is the create-only rule, D-031.5) — the address preview is the
/// safety net for a normalization mismatch.
class RestoreScreen extends StatefulWidget {
  const RestoreScreen({
    super.key,
    this.wordlist,
    this.preview,
    this.commit,
    this.biometricStatus,
    this.enroll,
    this.checkAccessibility,
    this.setSecure,
  });

  /// Test seams.
  final Bip39Wordlist? wordlist;
  final Future<String> Function(Uint8List phrase, Uint8List extra)? preview;
  final Future<void> Function(
    Uint8List phrase,
    Uint8List extra,
    Uint8List pass,
  )?
  commit;

  /// Why Path A is or is not offerable after the commit — a reason, not a bool
  /// (see `biometric_copy.dart`). Defaults to the lane.
  final Future<String> Function()? biometricStatus;

  /// Run the enrolment ceremony; throws [PlatformException] with a stable code.
  final Future<bool> Function()? enroll;

  final Future<bool> Function()? checkAccessibility;
  final Future<void> Function({required bool enable})? setSecure;

  @override
  State<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends State<RestoreScreen>
    with WidgetsBindingObserver {
  Bip39Wordlist? _wordlist;
  int _target = 12;
  final List<int> _indices = []; // selected wordlist indices — the secret order
  String _filter = ''; // transient prefix (a public-word search query)
  final SecretByteBuffer _extra = SecretByteBuffer();
  final SecretByteBuffer _passphrase = SecretByteBuffer();
  _Step _step = _Step.words;
  String? _previewAddress;
  bool _busy = false;
  String? _message;

  /// Whether the picked words are being held revealed.
  ///
  /// They used to render in plaintext for the whole entry — so by word twelve
  /// the entire recovery phrase, in order, sat on screen for as long as the
  /// user took to finish. A restore is exactly when someone is reading from a
  /// piece of paper in a room they may not control, and the phrase is worth the
  /// wallet. Masked by default, shown only while the reveal control is held
  /// (§0.6's register — reveal-on-hold, never reveal-by-default), so checking
  /// your typing stays possible and is a deliberate act with a known duration.
  bool _wordsRevealed = false;

  /// **Whether this wallet was made with an extra word** — `O7`'s switch.
  ///
  /// Off by default. It governs only whether the extra-word STEP is offered:
  /// off goes straight from the words to the address preview, which is exactly
  /// what leaving that step blank did before, minus a screen nobody with a
  /// plain phrase needed. The bytes handed to `restorePreview` and
  /// `restoreAndPersist` are identical either way — an untouched buffer and a
  /// wiped one snapshot to the same empty `Uint8List` — and the address
  /// preview remains the net that catches a user who had one and said no.
  bool _use25th = false;

  /// Why Path A is (un)available, resolved once after the commit.
  String _biometricStatus = 'unknown';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A hold does not survive leaving the app. Nothing guarantees a pointer
    // cancel is delivered when the platform takes the window away, so without
    // this the screen could come back with the whole recovery phrase unmasked
    // and no finger down — the same latch just closed for multi-touch, and it
    // would make the "only while held" claim above untrue.
    if (state != AppLifecycleState.resumed && _wordsRevealed) {
      setState(() => _wordsRevealed = false);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final injected = widget.wordlist;
    if (injected != null) {
      _wordlist = injected;
    } else {
      Bip39Wordlist.load().then((w) {
        if (mounted) setState(() => _wordlist = w);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _extra.dispose();
    _passphrase.dispose();
    // The picked words ARE the phrase. A back-gesture out of the flow left them
    // resident until the next GC saw fit; `SecretByteBuffer` was wiped here and
    // this list was not.
    //
    // PARTIAL, and said so: `_indices` grows by `add`, so reallocation leaves
    // earlier backing stores holding prefix copies that `clear()` cannot reach.
    // Same class as `_assemblePhrase`'s growable buffer. Both are pre-existing
    // and both need a fixed-length allocation to close properly — backlogged
    // with a trigger rather than half-done here (ffi-leak-auditor, Track 2).
    _indices.clear();
    super.dispose();
  }

  // ── phrase assembly (bytes only — never a full-phrase String) ────────────
  Uint8List _assemblePhrase() {
    final out = <int>[];
    for (var k = 0; k < _indices.length; k++) {
      if (k > 0) out.add(0x20); // space
      out.addAll(_wordlist!.words[_indices[k]].codeUnits); // ASCII BIP39 words
    }
    return Uint8List.fromList(out); // service wipes this throwaway copy
  }

  // ── words step actions ───────────────────────────────────────────────────
  void _select(String word) {
    final idx = _wordlist!.indexOf(word);
    if (idx < 0 || _indices.length >= _target) return;
    KvHaptic.selection(); // word-select (§7)
    setState(() {
      _indices.add(idx);
      _filter = '';
    });
  }

  void _wordsBackspace() {
    setState(() {
      if (_filter.isNotEmpty) {
        _filter = _filter.substring(0, _filter.length - 1);
      } else if (_indices.isNotEmpty) {
        _indices.removeLast();
      }
      // **The hold pill's OTHER unmount route.** It is mounted only while
      // there is something to reveal, so erasing the last word with one finger
      // while another holds the pill disposes the recognizer mid-press —
      // firing neither `onEnd` nor `onCancel`, exactly as tapping Continue
      // does — and the latch would survive. Re-picking a word would then draw
      // the phrase unmasked with no finger down. Same multi-touch shape as the
      // Continue guard below, and as the scar in `RevealActivity`
      // (`ffi-leak-auditor`, UX-R6).
      if (_indices.isEmpty) _wordsRevealed = false;
    });
  }

  /// **Leaving the words — and the address is DERIVED either way.**
  ///
  /// `ffi-leak-auditor` + `wallet-security-auditor` BLOCK, UX-R6: the first
  /// draft of the switch routed the off path straight to `_Step.preview`,
  /// which is the one step that cannot draw itself. `_runPreview` has exactly
  /// one job and one caller, and skipping it left `_previewAddress` null — an
  /// **empty plate under the words *Is this your wallet?*** with a live
  /// `This is my wallet` beneath it. Permanent false assurance on the one
  /// screen that exists to catch a wrong word, and a wrong restore is a brick:
  /// Rust refuses to seal over an existing blob and there is no delete path.
  ///
  /// It also skipped the **Rust-side validation** — `MnemonicCeremony::restore`
  /// runs inside `restore_preview`, so a bad checksum would have surfaced as a
  /// generic commit failure instead of *"Those words are not a valid recovery
  /// phrase"*.
  ///
  /// At HEAD this was structurally impossible: the words step always went to
  /// the extra-word step and that step's only action was the preview. The
  /// switch made a second route, and a second route to a screen that renders
  /// state somebody else computes needs the same computation.
  Future<void> _leaveWords() async {
    // Clear the hold latch on the way out. A long-press held with one finger
    // while another taps Continue disposes the recognizer without ever firing
    // `onEnd`, so the flag would survive — and coming back would then render
    // the whole phrase unmasked with no hold at all. Same multi-touch shape
    // already scarred in RevealActivity.
    setState(() => _wordsRevealed = false);
    if (_use25th) {
      // Entering the step wipes, so a second visit types onto an empty
      // buffer rather than appending to the first one (see `_enterExtraWord`).
      _enterExtraWord();
      return;
    }
    _extra.wipe();
    await _runPreview();
  }

  /// Entering the extra-word step **starts from empty**.
  ///
  /// `wallet-security-auditor` BLOCK, UX-R6. Neither way out of this step
  /// wiped `_extra`, and both ways back in re-entered with it loaded — so a
  /// user who retyped **appended**, sealing `word+word` as the PBKDF2 salt.
  /// Restore has no confirm-repeat, so the only net was the preview address;
  /// and the preview's own remedy — *a word or the extra word is wrong, go
  /// back and fix it* — is exactly what sends the user back to retype. Each
  /// round doubled the salt, the address stayed wrong, and the app's own
  /// advice made it worse.
  void _enterExtraWord() {
    _extra.wipe();
    setState(() {
      _step = _Step.extraWord;
      _message = null;
    });
  }

  Future<void> _runPreview() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final preview = widget.preview ?? VaultService.instance.restorePreview;
    try {
      final addr = await preview(_assemblePhrase(), _extra.snapshot());
      if (mounted) {
        setState(() {
          _previewAddress = addr;
          _step = _Step.preview;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message =
              'Those words are not a valid recovery phrase. Check each word and '
              'try again.';
        });
      }
    }
  }

  Future<void> _runCommit() async {
    if (_passphrase.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final commit = widget.commit ?? VaultService.instance.restoreAndPersist;
    try {
      await commit(
        _assemblePhrase(),
        _extra.snapshot(),
        _passphrase.snapshot(),
      );
      // Consumed. Wipe BEFORE the enrol step, not at dispose.
      //
      // Until this step existed a successful commit popped within milliseconds
      // and `dispose` did it. The enrol offer holds the screen for an unbounded
      // time — deliberately spanning an app-background, since the biometric
      // prompt pauses Flutter — and `_indices` is the complete mnemonic as
      // BIP39 wordlist indices. Nothing reachable from `_Step.enrolling` reads
      // any of the three (wallet-security-auditor, Track 2).
      _extra.wipe();
      _passphrase.wipe();
      _indices.clear();
      if (!mounted) return;
      // The vault is now sealed and unlocked — the same state the create flow
      // reaches after its seal, so it gets the same offer. This used to pop
      // straight home, which is why a restored wallet could never enable Path A.
      final status = await _safeBiometricProbe();
      if (!mounted) return;
      if (_offersEnrolStep(status)) {
        setState(() {
          _busy = false;
          _biometricStatus = status;
          _step = _Step.enrolling;
        });
      } else {
        _finish();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Could not restore. Your funds are safe — try again.';
        });
      }
    }
  }

  // ── Path A offer, mirroring create_screen.dart ───────────────────────────
  // Routed through VaultService, never the static ceremony channel, so the
  // §0.11 auto-lock suppression actually covers the prompt (the instance-flag
  // reason spelled out in create_screen).

  Future<String> _safeBiometricProbe() async {
    try {
      final probe =
          widget.biometricStatus ?? VaultService.instance.biometricStatus;
      return await probe();
    } catch (_) {
      return 'unknown'; // a question we could not ask is not a "no"
    }
  }

  /// Stop for the enrol step only where the user can act: `ready` (offer it) or
  /// `none_enrolled` (say how to get there). See `create_screen.dart`.
  static bool _offersEnrolStep(String status) =>
      status == biometricReady || status == biometricNoneEnrolled;

  Future<void> _runEnroll() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final enroll = widget.enroll ?? VaultService.instance.enrollBiometric;
      await enroll();
      _finish();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = e.code == 'cancelled' ? null : enrollFailureCopy(e.code);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = enrollFailureCopy('failed');
      });
    }
  }

  /// The wallet exists and is unlocked; popping reveals home beneath.
  void _finish() {
    if (mounted) Navigator.of(context).pop();
  }

  /// **Back walks the ceremony; it does not leave it.**
  ///
  /// Every step already had a correct back ARROW — and none of them was wired
  /// to the phone's back button, which fell through to the route and popped
  /// the whole restore. The founder hit it while typing the 13th word: the
  /// system button threw away a phrase he had just entered word by word, and
  /// landed him on Welcome. `create_screen` had a [PopScope] for exactly this
  /// and this screen never got one.
  ///
  /// The arrows now call this too, so there is one description of what "back"
  /// means per step rather than two that can drift apart.
  void _handleBack() {
    switch (_step) {
      case _Step.words:
        // The first beat. Behind it there is only Welcome, and leaving here
        // has taken nothing but the picking — nothing is sealed.
        Navigator.of(context).pop();
      case _Step.extraWord:
        // **The buffer does not survive the step it belongs to.** Same rule as
        // `create_screen`'s: a half-typed extra word left loaded is a secret
        // held on a screen that is not asking for it, and re-entry would
        // append to it (`wallet-security-auditor`, UX-R6).
        _extra.wipe();
        setState(() {
          _step = _Step.words;
          _message = null;
        });
      case _Step.preview:
        setState(() {
          _wordsRevealed = false; // re-entering masked, never latched on
          _previewAddress = null;
        });
        if (_use25th) {
          _enterExtraWord();
        } else {
          setState(() => _step = _Step.words);
        }
      case _Step.passphrase:
        setState(() => _step = _Step.preview);
      case _Step.enrolling:
        _finish(); // the vault exists — back here just means "go home"
    }
  }

  // ── views (`O7`, and the group's shared `O2` / `O6` legs) ────────────────

  /// §2 `display`, the onboarding rung.
  static const TextStyle _display = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 30,
    height: 34 / 30,
    fontWeight: FontWeight.w800,
    fontVariations: KvWeight.w800,
    letterSpacing: -0.75,
    color: KvColor.ink,
  );

  static const TextStyle _body = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 15,
    height: 22 / 15,
    color: KvColor.inkDim,
  );

  /// **A smaller register at `short`.** `display` is a phone-portrait rung; at
  /// 915 × 412 the body is ~42 dp and a 34 dp line with a descender is cut at
  /// the fold — type clipped through its glyphs, which is the thing BG-14
  /// refuses. §3a's `short` class is the chrome giving way, and this is the
  /// chrome: the heading keeps its job at `barTitle`'s size.
  TextStyle get _headingStyle => _short
      ? const TextStyle(
          fontFamily: KvFont.ui,
          fontSize: 18,
          height: 22 / 18,
          fontWeight: FontWeight.w700,
          fontVariations: KvWeight.w700,
          letterSpacing: -0.18,
          color: KvColor.ink,
        )
      : _display;

  Widget _heading(String text, {TextAlign align = TextAlign.start}) => SizedBox(
    width: double.infinity,
    child: Text(text, style: _headingStyle, textAlign: align),
  );

  /// **§3a's `short` class: phone landscape, where the chrome gives way.**
  ///
  /// The law's own row for `< 480` dp of height says *onboarding illustration
  /// discs drop*, and the reason generalises: at 915 × 412 a ceremony's bar,
  /// its pinned keyboard and its foot take 383 of the 412, leaving ~110 dp of
  /// body. Spent on a `display` heading and a four-line explainer, that body
  /// shows the user nothing they did not already know and hides the one thing
  /// the screen is about — the words they have entered.
  ///
  /// So at `short` the **explainer drops** and the heading stays. The
  /// explainer is the sentence you read once; the heading is what the screen
  /// is asking, and `O6`'s heading IS the question. Nothing is clipped either
  /// way — the body scrolls — this is about what the first 110 dp are spent
  /// on. Found in the 915 × 412 frame, which is the geometry that finds it.
  bool get _short => KvWindow.of(context).heightClass == KvHeightClass.short;

  Widget _sub(String text, {TextAlign align = TextAlign.start}) {
    if (_short) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.sm),
      child: SizedBox(
        width: double.infinity,
        child: Text(text, style: _body, textAlign: align),
      ),
    );
  }

  Widget _reason() {
    final message = _message;
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: KvSpace.m),
      child: Text(message, style: _body),
    );
  }

  /// **`7 of 24`** — `O7`'s bar reading. BG-30: the figures are mono, the
  /// word between them is not.
  Widget _counter() {
    final at = _indices.length + (_indices.length == _target ? 0 : 1);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$at', style: _figure),
          const TextSpan(text: ' of ', style: _word),
          TextSpan(text: '$_target', style: _figure),
        ],
      ),
      maxLines: 1,
    );
  }

  static const TextStyle _figure = TextStyle(
    fontFamily: KvFont.mono,
    fontSize: 15,
    height: 20 / 15,
    fontWeight: FontWeight.w500,
    fontVariations: KvWeight.w500,
    color: KvColor.inkDim,
  );
  static const TextStyle _word = TextStyle(
    fontFamily: KvFont.ui,
    fontSize: 15,
    height: 20 / 15,
    color: KvColor.inkMeta,
  );

  @override
  Widget build(BuildContext context) {
    // OUTSIDE the guard. The enrol step runs after the wallet is committed and
    // holds no secret, and BG-10's FLAG_SECURE + accessibility-refusal list is
    // locked at five screens (D-028) — extending it to a sixth would exclude
    // screen-reader users from a step that has nothing to hide. Its mirror in
    // `create_screen` is outside too, and the two ceremonies must not disagree
    // about whether the identical step is a secret screen (ux-auditor).
    //
    // The chrome differs for the same reason: this step must not claim the
    // restore is still under way, and it suppresses the back arrow that one
    // step earlier meant *abandon the restore*.
    if (_step == _Step.enrolling) {
      return _guardBack(
        _page(
          title: 'Almost done',
          onBack: null,
          centred: true,
          children: _enrollBody(),
          foot: _enrollFoot(),
        ),
      );
    }
    return _guardBack(
      SecretScreenGuard(
        title: 'your recovery words',
        setSecure: widget.setSecure,
        checkAccessibility: widget.checkAccessibility,
        child: _wordlist == null
            ? Scaffold(
                backgroundColor: KvColor.abyss,
                body: const SafeArea(child: Center(child: KvLoader())),
              )
            : switch (_step) {
                _Step.words => _wordsStep(),
                _Step.extraWord => _extraWordStep(),
                _Step.preview => _previewStep(),
                _Step.passphrase => _passphraseStep(),
                _Step.enrolling => const SizedBox.shrink(), // handled above
              },
      ),
    );
  }

  /// **The system back button is a step, not an exit** (founder, UX-R6 glass).
  ///
  /// `create_screen` has had this since it was built; this screen never did, so
  /// its five correct back ARROWS were shadowed by a phone button that popped
  /// the route. `canPop: false` routes the gesture, the hardware key and the
  /// predictive-back swipe through [_handleBack], which is the same code the
  /// arrows call — so there is exactly one answer to *what is behind this
  /// screen*, and `_Step.words` is the only step that answers it with the pop.
  Widget _guardBack(Widget child) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _handleBack();
    },
    child: child,
  );

  /// The group's page: ground, bar, clamped column, optional pinned foot.
  Widget _page({
    required String title,
    required List<Widget> children,
    Widget? centre,
    Widget? foot,

    /// **Rendered full-bleed, outside the content gutter.** [KvColumn] clamps to
    /// 560 and insets by the window class's gutter, which is right for a pill and
    /// wrong for a keyboard: the founder read the strip of ground down each side
    /// of the pad as unfinished (UX-R6 glass beat). A keypad is chrome for the
    /// whole screen, not content inside the column — so it gets its own slot.
    /// Whatever sits above it in [foot] keeps the gutter, because a pill IS
    /// content.
    Widget? bleed,

    /// **Centre the body in whatever room is left.** `O6` draws its mark and its
    /// question in the middle of the screen; the build stacked them at the top,
    /// which the founder read on glass as the content having fallen upward. A
    /// [SliverFillRemaining] with no scroll body centres when there is room and
    /// scrolls when there is not — the one idiom that does both without asking
    /// the layout for its height (BG-33 forbids reading a breakpoint here).
    bool centred = false,
    VoidCallback? onBack,
  }) => Scaffold(
    backgroundColor: KvColor.abyss,
    body: SafeArea(
      child: Column(
        children: [
          KvTopBar(title: title, centre: centre, onBack: onBack),
          Expanded(
            child: KvColumn(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    // **No air at `short`.** 48 dp of top-and-bottom padding is
                    // right on a phone and is more than the whole body at
                    // 915 × 412, where a bar and a pinned foot leave ~42
                    // (`ux-auditor` BLOCK, UX-R6).
                    padding: EdgeInsets.symmetric(
                      vertical: _short ? 0 : KvSpace.l,
                    ),
                    sliver: SliverFillRemaining(
                      hasScrollBody: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: centred
                            ? MainAxisAlignment.center
                            : MainAxisAlignment.start,
                        children: children,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Inside the column's gutter — a part in a clamped column owns no
          // horizontal air of its own (L195). The keypad is the exception and
          // travels in [bleed].
          if (foot != null) KvColumn(child: foot),
          ?bleed,
        ],
      ),
    ),
  );

  // ── `O6 · Biometrics` — the same step the create ceremony ends on ────────
  List<Widget> _enrollBody() {
    final ready = _biometricStatus == biometricReady;
    return [
      // §3a's own words for this class: *onboarding illustration discs drop*.
      if (!_short) ...[
        const SizedBox(height: KvSpace.xl),
        const Center(child: CeremonyMarkPair()),
        const SizedBox(height: KvSpace.xl),
      ],
      _heading(
        ready ? 'Open with biometrics?' : 'Biometrics, when you want them',
        align: TextAlign.center,
      ),
      // **Nothing under the question when the answer is a yes/no** — the
      // founder's call on glass, and `create_screen`'s twin does the same
      // (BG-21: the identical step in two ceremonies is one composition). The
      // `not ready` copy stays because it is actionable and is the only thing
      // that says why no offer appeared.
      if (!ready)
        _sub(
          biometricUnavailableCopy(_biometricStatus),
          align: TextAlign.center,
        ),
      _reason(),
    ];
  }

  /// The two ways on, in the thumb arc — `create_screen`'s twin (BG-21: the
  /// identical step in two ceremonies is one composition).
  Widget _enrollFoot() {
    final ready = _biometricStatus == biometricReady;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ready)
          KvAction(
            label: _busy ? 'Setting up…' : 'Use biometrics',
            primary: true,
            onTap: _busy ? () {} : _runEnroll,
            disabledReason: _busy ? 'Setting up…' : null,
          ),
        Center(
          child: KvTextAction(
            label: ready ? 'Passphrase only' : 'Continue',
            onTap: _busy ? null : _finish,
          ),
        ),
        const SizedBox(height: KvSpace.s),
      ],
    );
  }

  // ── `O7 · Restore` — pick the words ──────────────────────────────────────

  /// **The render draws the tray unmasked, and this build masks it.**
  ///
  /// `O7` shows its chips reading `anchor`, `gravity`, `orbit` — which is what
  /// the screen looks like WHILE the reveal is held, and a render can only
  /// draw one state. Masked by default with reveal-on-hold is BG-10's own
  /// register and an auditor fix besides: a restore is exactly when someone is
  /// reading from paper in a room they may not control, and a phrase left
  /// legible for as long as entry takes is worth the wallet. The hold pill is
  /// `O3`'s own — a `chip` stadium with the `eye` mark and a `primaryMuted`
  /// label — so the two screens that show recovery words show them the same
  /// way.
  Widget _wordsStep() {
    final suggestions = _wordlist!.startingWith(_filter);
    final complete = _indices.length == _target;
    return _page(
      title: 'Restore wallet',
      centre: _counter(),
      onBack: _handleBack,
      children: [
        _heading('Enter your recovery words'),
        _sub(
          'Type a few letters and tap the word — nobody should ever spell one '
          'wrong.',
        ),
        const SizedBox(height: KvSpace.m),
        _lengthRow(),
        // Tight to the row above it: the length choice and the extra-word
        // switch are settings ABOUT this grid, and the founder read the old
        // `m` gap as the grid floating away from its own controls.
        const SizedBox(height: KvSpace.s),
        _tray(),
        const SizedBox(height: KvSpace.m),
        if (_indices.isNotEmpty)
          Center(
            child: KvRevealHold(
              revealed: _wordsRevealed,
              onChanged: (r) => setState(() => _wordsRevealed = r),
            ),
          ),
        _reason(),
      ],
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // **What to do next is PINNED above the keyboard, never laid out
          // after the tray** (L191). The tray grows by a chip a word — up to
          // twenty-four, more at 1.3× — so a suggestion strip placed under it
          // inherits its motion and walks off the bottom of the screen: at the
          // reference geometry the twelfth word's suggestions sat at y 586
          // behind the keyboard, findable by a test and untappable by a
          // thumb. The seat is fixed and its occupant changes.
          Padding(
            padding: const EdgeInsets.only(bottom: KvSpace.sm),
            child: complete
                ? KvAction(
                    label: _busy ? 'Checking…' : 'Continue',
                    primary: true,
                    onTap: _busy ? () {} : _leaveWords,
                    disabledReason: _busy ? 'Checking…' : null,
                  )
                : _filter.isNotEmpty
                ? _suggestions(suggestions)
                // **A minimum, not a height.** Fixed at the pill's 48 the
                // sentence wrapped to two lines at 320 dp / 1.3× and the
                // second one was cut in half — a clipped instruction on the
                // screen that is teaching the user how to enter a recovery
                // phrase. A label wraps; only a figure may not (BG-14).
                : ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: KvSuggestion.height,
                    ),
                    child: Center(
                      child: Text(
                        'Type each word, then tap it from the suggestions.',
                        textAlign: TextAlign.center,
                        style: _body.copyWith(color: KvColor.inkMeta),
                      ),
                    ),
                  ),
          ),
          // Letters are inert once complete: the suggestion strip is not
          // rendered there, so a keystroke would silently fill `_filter` and
          // then have to be drained by ⌫ before it reached a word — a stretch
          // where nothing the user does responds.
          // **`O7`'s foot row is gone** (founder, UX-R6 glass beat). It held
          // `Remove last` and an `N to go` counter, and both were duplicates:
          // backspace on the keyboard directly below already removes the last
          // word, and the bar's `8 of 12` already says what is left. He called
          // the pair noise, and on a screen whose whole job is careful
          // transcription, a second way to say the same number is a second
          // thing to read. The `_short` special-case that dropped only the
          // counter goes with it — there is nothing left to drop.
        ],
      ),
      bleed: SecretKeyboard(
        mode: SecretKeyboardMode.lowercaseLetters,
        onChar: complete ? (_) {} : (c) => setState(() => _filter += c),
        onBackspace: _wordsBackspace,
      ),
    );
  }

  /// `O7`'s header line: the length choice, and whether an extra word is in
  /// play. Both are settings about the phrase, and the render puts them on one
  /// line above the tray because both stop being changeable once it fills.
  Widget _lengthRow() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      KvSegmented(
        options: const [KvSegmentedOption('12'), KvSegmentedOption('24')],
        index: _target == 12 ? 0 : 1,
        onSelect: (i) {
          // Locked once a word is in: changing the target mid-phrase would
          // silently redefine what "complete" means.
          if (_indices.isNotEmpty) return;
          KvHaptic.selection();
          setState(() => _target = i == 0 ? 12 : 24);
        },
      ),
      Semantics(
        toggled: _use25th,
        label: extraWordToggle(_target),
        button: true,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            KvHaptic.selection();
            setState(() {
              _use25th = !_use25th;
              if (!_use25th) _extra.wipe();
            });
          },
          child: SizedBox(
            height: KvSpace.touchTarget,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${extraWordOrdinal(_target)} word',
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w600,
                    fontVariations: KvWeight.w600,
                    color: KvColor.inkDim,
                  ),
                ),
                const SizedBox(width: KvSpace.sm),
                KvSwitch(on: _use25th),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  /// The picked words, and the one being typed. `O7`'s `plate` card.
  ///
  /// **A fixed grid, not a `Wrap`** (founder, UX-R6 glass beat). Chips are
  /// sized by their content, so a `Wrap` re-flowed the entire tray the instant
  /// hold-to-reveal swapped four mask dots for a word: rows re-broke and a word
  /// appeared in a different place than its mask had been, on the one screen
  /// whose whole job is checking that each word is in the right position. He
  /// asked for "the same row and column they are arranged when not revealed",
  /// which a fixed three-column grid gives by construction.
  ///
  /// Three columns is also what `O3` draws natively, so the phrase a user
  /// writes down and the phrase they type back now occupy the same shape
  /// across the process seam.
  Widget _tray() {
    const cols = 3;
    final rows = (_target / cols).ceil();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KvSpace.s),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.plate),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var r = 0; r < rows; r++)
            Padding(
              padding: EdgeInsets.only(top: r == 0 ? 0 : KvSpace.s),
              child: Row(
                children: [
                  for (var c = 0; c < cols; c++) ...[
                    if (c > 0) const SizedBox(width: KvSpace.s),
                    Expanded(child: _slot(r * cols + c)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// One seat in the grid: a picked word, the word being typed, or an empty
  /// slot still waiting. The seat exists either way — that is the point.
  Widget _slot(int k) {
    if (k >= _target) return const SizedBox.shrink();
    if (k < _indices.length) {
      return KvWordChip(
        index: k + 1,
        word: _wordsRevealed ? _wordlist!.words[_indices[k]] : null,
      );
    }
    if (k == _indices.length) {
      return KvWordChip.typing(index: k + 1, prefix: _filter);
    }
    return SizedBox(height: KvWordChip.height);
  }

  Widget _suggestions(List<String> words) => SizedBox(
    height: KvSuggestion.height,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final w in words)
          Padding(
            padding: const EdgeInsets.only(right: KvSpace.s),
            child: KvSuggestion(word: w, onTap: () => _select(w)),
          ),
      ],
    ),
  );

  // ── step: the optional extra word ────────────────────────────────────────
  Widget _extraWordStep() => _page(
    title: 'Restore wallet',
    onBack: _handleBack,
    children: [
      _heading(extraWordHeading(_target)),
      _sub(
        'Enter the extra word you chose when this wallet was made. Case and '
        'spaces matter, and the address on the next screen is what tells you '
        'it was right.',
      ),
      KvSectionHeader('Your ${extraWordOrdinal(_target)} word'),
      KvSecretField(
        length: _extra.length,
        active: true,
        placeholder: 'Type it here',
      ),
      _reason(),
    ],
    // Pinned, like every other act in this group — the BG-21 half of the
    // finding that moved `O5`'s two acts out of a scrolling body.
    foot: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: KvSpace.sm),
          child: KvAction(
            label: _busy ? 'Checking…' : 'Show my address',
            primary: true,
            onTap: _busy ? () {} : _runPreview,
            disabledReason: _busy ? 'Checking…' : null,
          ),
        ),
        // **Inert while the ceremony is in flight.** `_runPreview` and
        // `_runCommit` wipe deliberately and then `await` a platform lane with
        // this keyboard still mounted; an ungated key press writes bytes back
        // in AFTER the wipe, and nothing wipes them again until dispose. The
        // words step already uses this idiom for `complete`
        // (`ffi-leak-auditor`, UX-R6).
      ],
    ),
    bleed: SecretKeyboard(
      onChar: _busy ? (_) {} : _extra.appendChar,
      onBackspace: _busy ? () {} : _extra.backspace,
    ),
  );

  // ── step: address preview (the decoy/typo trap) ──────────────────────────
  Widget _previewStep() => _page(
    title: 'Restore wallet',
    onBack: _handleBack,
    children: [
      _heading('Is this your wallet?'),
      _sub(
        'These words open the wallet at the address below. If it is not the '
        'one you expect, a word or the extra word is wrong — go back and fix '
        'it.',
      ),
      const KvSectionHeader('First address'),
      // **Chunked, and selectable.** This is the one address in the app a
      // user checks character by character against a wallet they already
      // know, which is the whole reason the step exists: a typo'd word opens
      // a visibly DIFFERENT wallet rather than a silently empty one. The
      // widget paints its own plate.
      KvAddress(
        _previewAddress ?? '',
        form: KvAddressForm.chunked,
        selectable: true,
      ),
      _reason(),
      const SizedBox(height: KvSpace.l),
      KvAction(
        label: 'This is my wallet',
        primary: true,
        onTap: () => setState(() => _step = _Step.passphrase),
      ),
      const SizedBox(height: KvSpace.s),
      Center(
        child: KvTextAction(
          label: 'Go back and fix a word',
          onTap: () => setState(() {
            _wordsRevealed = false;
            _step = _Step.words;
            _previewAddress = null;
            // The remedy this button offers is *retype the word*, so it must
            // not hand the user a buffer that will append to it.
            _extra.wipe();
          }),
        ),
      ),
    ],
  );

  // ── step: set passphrase, then commit (`O2`'s form) ──────────────────────
  Widget _passphraseStep() => _page(
    title: 'Restore wallet',
    onBack: _handleBack,
    children: [
      _heading('Choose an unlock passphrase'),
      _sub(
        'It opens this app on this phone only — it is not your recovery '
        'phrase; those are the words you have just entered.',
      ),
      const SizedBox(height: KvSpace.xl),
      Center(
        child: MaskedDots(
          length: _passphrase.length,
          emptyHint: 'Type it on the keyboard below',
        ),
      ),
      _reason(),
      const SizedBox(height: KvSpace.l),
      KvAction(
        label: _busy ? 'Restoring…' : 'Restore wallet',
        primary: true,
        onTap: _busy ? () {} : _runCommit,
        disabledReason: _busy ? 'Restoring…' : null,
      ),
    ],
    foot: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // **It drops at `short`, and the heading is why.** 412 dp of
        // landscape less a bar, a pill and a 220 dp keypad leaves ~76: with
        // this line the screen's own heading scrolled out entirely and the
        // passphrase step said nothing about what it was asking for. Of the
        // two, the caption is the one whose subject is visible anyway — the
        // keyboard is on the glass, in the app, plainly not the phone's — and
        // the heading is the archetype's *one instruction*.
        //
        // **`inkMeta`, and this is the one place the build wins over the
        // render.** `O2` sets this line in `etch`, which measures **2.53:1 on
        // `abyss`** — under the 3:1 non-text floor and far under 4.5. `etch` is
        // decorative by definition (§1.3), and this string is the screen's
        // sovereignty disclosure: it is the sentence that says why this
        // keyboard looks unlike the phone's. §4's `KvSectionHeader` gloss row
        // already settled the identical case in the same words — *`etch` on an
        // information-bearing string is a BG-14 refusal* (`ux-auditor` BLOCK,
        // UX-R6).
      ],
    ),
    bleed: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SecretKeyboard(
          onChar: _busy ? (_) {} : _passphrase.appendChar,
          onBackspace: _busy ? () {} : _passphrase.backspace,
        ),
        if (!_short)
          KvColumn(
            child: const Padding(
              padding: EdgeInsets.only(bottom: KvSpace.s),
              child: Text(
                'In-app keypad — the system keyboard never sees this',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 12,
                  height: 16 / 12,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
