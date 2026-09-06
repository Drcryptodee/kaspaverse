import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../biometric_copy.dart';
import '../theme/kv_page_route.dart';
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_coming_soon.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_sheet.dart';
import '../widgets/kv_toggle.dart';
import '../widgets/kv_two_pane.dart';
import 'settings_scopes.dart';
import 'settings_screen.dart' show graceFragment;

/// **`T2 · Security`** — the custody controls, in the render's three sections.
///
/// A settings-group screen (playbook §3.5): row containers under bare caps
/// labels, every row's sub-line its own current state, a control whose change
/// has consequences opening a **ceremony sheet** rather than switching
/// in place. `Lock when I leave` is that ceremony (`T3`).
///
/// **What the render draws that this build does not, said out loud in the
/// sitting rather than only here:**
///
///  * *Ask for passphrase on large sends · 100 KAS* — there is no threshold
///    seam in the vault. A number on this row that nothing enforces is the
///    worst kind of lie a custody screen can tell, so the row is absent rather
///    than decorative.
///  * *Change passphrase* — the passphrase is set once inside the create
///    ceremony and there is no re-key path in `vault.rs`. It reaches this
///    screen as the Coming soon door, which states that in words.
///  * *Block screenshots* is drawn with a switch. **BG-10 does not let it be
///    one**: secret screens set `FLAG_SECURE` and refuse accessibility
///    unconditionally, and a switch that turns that off is a switch that
///    breaks a safety law. It is a record with its value and its reason —
///    which is also how it reads, where a switch that cannot move renders dim
///    and reads as broken.
///
/// **`SIGNING` is not here, on his word** (2026-09-06, on glass: *"Remove
/// SIGNING — i like the stub there so just log it as an idea later"*). It held
/// two true guarantees — `Hold to sign · 0.8 s` read from `KvMotion.deliberate`
/// so BG-6's duration and the row could not disagree, and `Blind signing ·
/// Off` — and neither was a control, which is what made it read as a stub. The
/// section worth building is the render's: those two beside *Ask for passphrase
/// on large sends* with a real threshold behind it, so it states what cannot be
/// changed **and** what the user can set. Logged in `IDEAS_BACKLOG.md` with
/// both rows' copy, so removing them did not delete them.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key, required this.scope});

  final SecurityScope scope;

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen>
    with WidgetsBindingObserver {
  String _status = biometricUnknown;
  String _pathA = pathANone;
  bool _busy = false;

  /// The last enrolment refusal, in our words. Rendered under the toggle,
  /// where the refusal happened — never as a toast that leaves the screen
  /// (§9.30's open question does not get a ninth `showSnackBar`).
  String? _fault;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.scope.lockGraceSecs.addListener(_onGrace);
    _probe();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _probe();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.scope.lockGraceSecs.removeListener(_onGrace);
    super.dispose();
  }

  void _onGrace() => setState(() {});

  /// **Each probe fails on its own, and neither failure invents the other's
  /// answer** (BG-8, L170).
  ///
  /// One `try` around both awaits looked honest and was not: when the first
  /// succeeded and the second threw, `status` kept the true `ready` while
  /// `state` was still its `pathANone` seed — so the toggle painted a
  /// confident, *enabled* **Off** over a wallet whose biometric unlock was on,
  /// on exactly the resume path the lifecycle hook exists to drive. A mark
  /// derived from the absence of a reading must hold its last answer across a
  /// null, and where there is no last answer the honest one is `unknown`.
  Future<void> _probe() async {
    String status;
    try {
      status = await widget.scope.biometricStatus();
    } catch (_) {
      status = biometricUnknown;
    }
    String? state;
    try {
      state = await widget.scope.pathAState();
    } catch (_) {
      // Keep what we last knew; a failed read is not a state change.
      state = null;
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      if (state != null) _pathA = state;
    });
  }

  bool get _hardware => _status == biometricReady;
  bool get _enrolled => _pathA == pathAReady;
  bool get _invalidated => _hardware && _pathA == pathAInvalidated;

  /// Why the toggle cannot be pressed, in words — **the disable switch and
  /// the sentence are one field**, so they cannot drift apart (BG-12).
  String? get _biometricRefusal {
    if (_busy) return 'The phone is asking you now.';
    if (biometricStateIsUnknown(_status)) {
      return 'This build cannot see the fingerprint sensor.';
    }
    if (!_hardware) return biometricUnavailableCopy(_status);
    return null;
  }

  Future<void> _setBiometric(bool on) async {
    setState(() {
      _busy = true;
      _fault = null;
    });
    try {
      if (on) {
        await widget.scope.enroll();
      } else {
        KvHaptic.destructiveArmed();
        await widget.scope.clearEnrollment();
      }
      await _probe();
    } on PlatformException catch (e) {
      // A cancel is a CHOICE, not a failure — nothing to apologise for.
      if (mounted && e.code != 'cancelled') {
        setState(() => _fault = enrollFailureCopy(e.code));
      }
    } catch (_) {
      if (mounted) setState(() => _fault = enrollFailureCopy('failed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLockTimer() async {
    KvHaptic.selection();
    final chosen = await showLockTimerSheet(
      context,
      current: widget.scope.lockGraceSecs.value,
    );
    if (chosen == null || !mounted) return;
    try {
      await widget.scope.setLockGraceSecs(chosen);
    } catch (_) {
      if (mounted) {
        setState(
          () => _fault =
              'That could not be saved. The wallet still '
              'locks on the setting shown.',
        );
      }
    }
  }

  void _comingSoon(String name, String sentence) {
    KvHaptic.selection();
    Navigator.of(context).push(
      KvPageRoute<void>(
        builder: (_) => KvComingSoonPage(
          mark: KvGlyph.shield,
          name: name,
          sentence: sentence,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grace = widget.scope.lockGraceSecs.value;
    final refusal = _biometricRefusal;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: 'Security',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: KvColumn(
                gutter: false,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    KvWindow.of(context).gutter,
                    KvSpace.xs,
                    KvWindow.of(context).gutter,
                    KvSpace.l,
                  ),
                  children: [
                    const KvSectionHeader('Unlock'),
                    KvRowContainer(
                      children: [
                        KvToggle(
                          bare: true,
                          on: _enrolled,
                          title: 'Biometric unlock',
                          sub: _invalidated
                              ? 'Set up again — a new fingerprint on this '
                                    'phone retired the old key'
                              : 'Your passphrase is always available as a '
                                    'fallback',
                          disabledReason: refusal,
                          onChanged: refusal == null ? _setBiometric : null,
                        ),
                        KvRow(
                          title: 'Lock when I leave',
                          sub:
                              'Locking clears the screen. It is rebuilt from '
                              'the chain when you come back.',
                          subLines: 3,
                          // At 320 dp / 1.3× this title came out `Lock whe…`
                          // beside its reading — read off the floor frame,
                          // fixed the way the house fixes a label (§19.6).
                          titleLines: 2,
                          dense: true,
                          trailing: _ValueAndChevron(graceValue(grace)),
                          semanticLabel:
                              'Lock when I leave. ${graceFragment(grace)}',
                          onTap: _openLockTimer,
                        ),
                      ],
                    ),
                    if (_fault case final fault?) _Fault(fault),
                    const KvSectionHeader('Recovery'),
                    KvRowContainer(
                      children: [
                        KvRow(
                          title: 'Recovery words',
                          sub:
                              'Written down and checked when this wallet was '
                              'created',
                          subLines: 2,
                          dense: true,
                          trailing: const KvGlyphIcon(
                            KvGlyph.chevron,
                            size: 16,
                            tone: KvColor.etch,
                          ),
                          onTap: () => _comingSoon(
                            'Recovery words',
                            'Showing them again needs its own native reveal '
                                'ceremony. Until it is built, the words you '
                                'wrote down at setup are the wallet.',
                          ),
                        ),
                        // **BG-10 is not a preference**, so this is not a
                        // control. `T2` draws a switch; a switch that cannot
                        // move renders dim and reads as broken, and the honest
                        // shape for a guarantee is the one `Hold to sign`
                        // above it already uses — a record with its value.
                        KvRow(
                          title: 'Block screenshots',
                          sub:
                              'On every secret screen. It cannot be turned '
                              'off: a photo of your recovery words is your '
                              'wallet.',
                          subLines: 3,
                          dense: true,
                          trailing: const _Value('On'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A reading and the chevron that opens it, on ONE line (`T2`, measured: the
/// value sits left of the mark, both centred on the row).
class _ValueAndChevron extends StatelessWidget {
  const _ValueAndChevron(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(child: _Value(text)),
      const SizedBox(width: KvSpace.xs),
      const KvGlyphIcon(KvGlyph.chevron, size: 16, tone: KvColor.etch),
    ],
  );
}

/// A trailing reading on a settings row — **`fact` 13 / 500 `inkDim`, with the
/// figures in mono and every word and unit in Jakarta** (BG-30, and `T2` draws
/// exactly that split: `After` and `s` in Jakarta, `30` in mono).
///
/// The first cut set the whole run in JetBrains Mono, which put `Immediately`,
/// `After`, `Off`, `On` and the `s` of `0.8 s` in the counting face. *The
/// reader should know, before reading, whether a run is to be read or
/// checked* — so the split is done here, once, rather than at five call sites.
class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  /// Digits and the separators that belong to them. Everything else is a word.
  static final RegExp _figure = RegExp(r'[0-9]+(?:[.,][0-9]+)*');

  @override
  Widget build(BuildContext context) {
    const word = TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 13,
      height: 20 / 13,
      fontWeight: FontWeight.w500,
      fontVariations: KvWeight.w500,
      color: KvColor.inkDim,
    );
    const figure = TextStyle(
      fontFamily: KvFont.mono,
      fontSize: 13,
      height: 20 / 13,
      fontWeight: FontWeight.w500,
      fontVariations: KvWeight.w500,
      color: KvColor.inkDim,
    );
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in _figure.allMatches(text)) {
      if (m.start > at) {
        spans.add(TextSpan(text: text.substring(at, m.start), style: word));
      }
      spans.add(TextSpan(text: m[0], style: figure));
      at = m.end;
    }
    if (at < text.length) {
      spans.add(TextSpan(text: text.substring(at), style: word));
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      semanticsLabel: text,
      style: word,
    );
  }
}

/// A refusal, where the refusal happened.
class _Fault extends StatelessWidget {
  const _Fault(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: KvSpace.s),
    child: Text(
      text,
      style: const TextStyle(
        fontFamily: KvFont.ui,
        fontSize: 12,
        height: 17 / 12,
        color: KvColor.warn,
      ),
    ),
  );
}

/// `After 30 s` — the trailing value on the row. The sheet and the root say
/// the same duration in their own registers ([graceFragment]).
String graceValue(int secs) => switch (secs) {
  0 => 'Immediately',
  30 => 'After 30 s',
  60 => 'After 1 min',
  300 => 'After 5 min',
  900 => 'After 15 min',
  _ => 'After $secs s',
};

/// **`T3 · Lock timer` — the settings ceremony** (D-275, D-277).
///
/// The sheet law's four clauses, each provable: `Cancel` in `risk`; a tap on
/// the scrim leaves it; one sentence at the top where the choice is made, not
/// a paragraph stacked over the button; **one act in the foot, disabled with
/// its reason** until the choice differs from what is already set.
///
/// **The render draws `Cancel` in `inkDim`.** D-277 is the founder's own
/// house-wide ruling, made on glass after these renders were approved, that
/// the way out of a sheet is red on every sheet — and his eye outranks the
/// render (D-262). Said in the sitting.
///
/// Returns the chosen grace in seconds, or null if the sheet was left.
Future<int?> showLockTimerSheet(BuildContext context, {required int current}) {
  return Navigator.of(context).push<int>(
    KvSheetRoute<int>(
      builder: (sheetContext) => _LockTimerSheet(current: current),
    ),
  );
}

class _LockTimerSheet extends StatefulWidget {
  const _LockTimerSheet({required this.current});

  final int current;

  @override
  State<_LockTimerSheet> createState() => _LockTimerSheetState();
}

class _LockTimerSheetState extends State<_LockTimerSheet> {
  late int _chosen = widget.current;

  /// **Five, not the render's six.** `T3` offers **Never**; `vault.rs` clamps
  /// the auto-lock grace at `MAX_LOCK_GRACE_SECS` = 900 and stores it as a
  /// `u32`, so "never lock" does not exist on the Rust side — offering it
  /// would be a control that silently did something else (it would land on 15
  /// minutes). The vault's ceiling IS the answer to that option, and the cost
  /// the render says out loud under **Never** moves to the longest wait that
  /// really exists.
  static const List<int> options = [0, 30, 60, 300, 900];

  static String _title(int secs) => switch (secs) {
    0 => 'Immediately',
    30 => '30 seconds',
    60 => '1 minute',
    300 => '5 minutes',
    _ => '15 minutes',
  };

  @override
  Widget build(BuildContext context) {
    final changed = _chosen != widget.current;
    return KvSheet(
      title: 'Lock when I leave',
      onCancel: () => Navigator.of(context).pop(),
      foot: KvAction(
        label: 'Done',
        primary: true,
        onTap: () => Navigator.of(context).pop(_chosen),
        // **The reason names the setting, not the situation.** The render
        // draws `5 minutes is already set`, which tells the user what is in
        // force as well as why the act is waiting — one line doing two jobs,
        // where `This is already the setting` did one.
        disabledReason: changed
            ? null
            : '${_title(widget.current)} is already set',
      ),
      // **The body scrolls, the foot does not** — the house sheet pattern
      // (`KvSheet`'s own contract, D-221 §1). At 320 dp / 1.3× the five
      // options and their two annotations are 11 dp taller than the panel's
      // 90 % cap, and a bare `Column` there overflows instead of scrolling.
      // The act stays reachable because it is laid out below this.
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // One sentence, where the choice is made. Not a paragraph over
            // the act (D-277 clause 3).
            const Text(
              'How long the wallet stays open after you switch apps or turn the '
              'screen off.',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 19 / 13,
                color: KvColor.inkDim,
              ),
            ),
            const SizedBox(height: KvSpace.m),
            KvChoiceCard(
              children: [
                for (final secs in options)
                  KvChoiceRow(
                    title: _title(secs),
                    // The two the render annotates, and only those: one names
                    // the recommendation, the other names what the choice
                    // COSTS. Amber, because "anyone holding the phone can
                    // spend" is the not-yet-safe state BG-7 gives `warn` to —
                    // and it is said in words as well as in hue.
                    sub: switch (secs) {
                      30 => 'Recommended',
                      900 =>
                        'Anyone holding the phone in that window can spend',
                      _ => null,
                    },
                    // **`risk`, not `warn`** (the render, measured `#F26D5F`).
                    // BG-7 gives amber to *not yet certain* and red to **at
                    // risk**, and money anyone holding the phone can spend is
                    // the second. The first cut read it as a warning about a
                    // delay; it is a statement about exposure.
                    subTone: secs == 900 ? KvColor.risk : null,
                    selected: _chosen == secs,
                    onTap: () {
                      KvHaptic.selection();
                      setState(() => _chosen = secs);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
