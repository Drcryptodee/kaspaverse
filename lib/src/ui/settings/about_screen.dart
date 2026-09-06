import 'package:flutter/material.dart';

import '../roadmap_screen.dart' show RoadmapScreen;
import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import '../widgets/haptics.dart';
import '../widgets/kv_chrome.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_mark.dart';
import '../widgets/kv_rows.dart';
import '../widgets/kv_two_pane.dart';
import 'settings_scopes.dart';

/// **`T6 · About`** — what this build is, how to check it is ours, and what is
/// coming, with a status against every line.
///
/// **Two things the render draws that a wallet must not claim about itself,
/// said in the sitting:**
///
///  * *Up to date*, with a green check. Knowing whether a build is current
///    means asking a server, and **INV-8 is that this app phones nobody**.
///    The card states what the build *is* — version, build number — and stops
///    there. A freshness claim it cannot make would be the first lie on the
///    screen whose whole job is provenance.
///  * *SHA-256 · matches the published key ✓ Verified*. A build cannot verify
///    its own signature meaningfully: a tampered build carries a tampered
///    expectation and would print the same green tick. So the card prints the
///    **whole fingerprint** — all 64 characters, in the groups
///    `apksigner verify --print-certs` prints, so a user comparing an install
///    against a published value is comparing like with like — and says who has
///    to do the comparing. That is the check that is worth anything, and the
///    tick is what would have made it worthless (BG-11, BG-29: the check means
///    *confirmed*, and nothing here has confirmed anything).
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, required this.scope});

  final AboutScope scope;

  /// The repository the code is published from. **MIT, and the whole point**:
  /// the row that names it is the only way a user can get from this screen to
  /// the thing the fingerprint above it is a fingerprint *of*.
  static const String repository = 'https://github.com/Drcryptodee/kaspaverse';

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String? _version;
  String? _build;

  /// The signing fingerprint as the platform gave it — **all 64 hex
  /// characters**. Shortening on arrival destroyed the only copy, so the
  /// surface that exists to show the whole thing had a quarter of it, and a
  /// user following `RELEASE.md` could never match it. Elide at render only —
  /// and this screen does not elide at all.
  String? _signature;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final info = await widget.scope.packageInfo();
      if (!mounted) return;
      setState(() {
        _version = info['version'];
        _build = info['build'];
        _signature = info['signature'];
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final openUrl = widget.scope.openUrl;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        child: Column(
          children: [
            KvTopBar(
              title: 'About',
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
                    KvSpace.s,
                  ),
                  children: [
                    _identity(),
                    const KvSectionHeader('App signature'),
                    _signatureCard(),
                    const KvSectionHeader("What's coming"),
                    _roadmap(),
                    const SizedBox(height: KvSpace.s),
                    KvRowContainer(
                      children: [
                        KvRow(
                          leading: const KvRowDisc.neutral(
                            mark: KvGlyph.github,
                          ),
                          title: 'Source code',
                          sub: 'github.com/Drcryptodee/kaspaverse',
                          dense: true,
                          trailing: openUrl == null
                              ? null
                              : const KvGlyphIcon(
                                  KvGlyph.external,
                                  size: 16,
                                  tone: KvColor.etch,
                                ),
                          semanticLabel:
                              'Source code, github.com/Drcryptodee/kaspaverse. '
                              'Leaves the app',
                          onTap: openUrl == null
                              ? null
                              : () {
                                  KvHaptic.selection();
                                  openUrl(AboutScreen.repository);
                                },
                        ),
                        KvRow(
                          leading: const KvRowDisc.neutral(mark: KvGlyph.info),
                          title: 'Licences',
                          sub: 'Every package this build is made of',
                          dense: true,
                          trailing: const KvGlyphIcon(
                            KvGlyph.chevron,
                            size: 16,
                            tone: KvColor.etch,
                          ),
                          onTap: () {
                            KvHaptic.selection();
                            // The SDK's own screen, deliberately: it is the
                            // COMPLETE licence list and a legal artefact
                            // rather than a designed one. `kv_theme` pins the
                            // `cardColor` it resolves. The version is omitted
                            // until it is read, never passed as a blank.
                            showLicensePage(
                              context: context,
                              applicationName: 'KaspaVerse',
                              applicationVersion: _version ?? '',
                            );
                          },
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

  /// The identity card: the mark, the name, and the build in mono. `T6` draws
  /// the mark at 64 with its halo — the one illustrative disc on the screen
  /// (§2a rule 6).
  Widget _identity() => KvRowContainer(
    divided: false,
    inset: const EdgeInsets.all(KvSpace.sm),
    children: [
      Row(
        children: [
          const KvMark(size: 64),
          const SizedBox(width: KvSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'KaspaVerse',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 22,
                    height: 26 / 22,
                    letterSpacing: -0.2,
                    fontWeight: FontWeight.w700,
                    fontVariations: KvWeight.w700,
                    color: KvColor.ink,
                  ),
                ),
                const SizedBox(height: KvSpace.xs),
                Text(
                  _buildLine,
                  style: TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 13,
                    height: 20 / 13,
                    fontWeight: FontWeight.w500,
                    fontVariations: KvWeight.w500,
                    color: _failed ? KvColor.warn : KvColor.inkDim,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ],
  );

  /// `3.0.0 · build 3041`. BG-8: an unknown datum is a dash and says so — it
  /// is never invented and never a plausible-looking zero.
  String get _buildLine {
    if (_failed) return 'build metadata unavailable';
    final version = _version;
    final build = _build;
    if (version == null) return 'reading…';
    return build == null ? version : '$version · build $build';
  }

  Widget _signatureCard() {
    final signature = _signature;
    return KvRowContainer(
      divided: false,
      inset: const EdgeInsets.all(KvSpace.sm),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              signature == null
                  ? 'SHA-256 of the certificate this build was signed with'
                  : 'SHA-256 of the certificate this build was signed with. A '
                        'release that matches the fingerprint published beside '
                        'it was built by us.',
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 19 / 13,
                color: KvColor.inkDim,
              ),
            ),
            const SizedBox(height: KvSpace.s),
            SelectableText(
              // Public data — selecting and copying is fine here. The
              // no-clipboard law is BG-10 and it is about seeds.
              _groups(signature),
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 13,
                height: 20 / 13,
                fontWeight: FontWeight.w500,
                fontVariations: KvWeight.w500,
                color: signature == null ? KvColor.warn : KvColor.ink,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// `A1F3 9C20 4B7E …` — the render's grouping, which is also
  /// `apksigner`'s, so the two can be read side by side.
  static String _groups(String? hex) {
    if (hex == null) return '—  unreadable on this build';
    final upper = hex.toUpperCase().replaceAll(':', '');
    final out = <String>[];
    for (var i = 0; i < upper.length; i += 4) {
      out.add(upper.substring(i, (i + 4).clamp(0, upper.length)));
    }
    return out.join(' ');
  }

  /// **A status against every line, with no blanks** — and the statuses are
  /// ones the project can keep. `Next` is what the phase index is actually
  /// building; everything else is `Planned`. Quarters are not promised,
  /// because nothing here can keep a quarter.
  Widget _roadmap() => KvRowContainer(
    children: [
      for (final d in RoadmapScreen.destinations)
        KvRow(
          title: d.name,
          sub: d.line,
          // Two, and the copy shortened to the house band so nothing
          // truncates at it — 53 of the 83 dp the fit guard was short.
          subLines: 2,
          dense: true,
          trailing: _Tag(
            d.name == RoadmapScreen.next ? 'Next' : 'Planned',
            emphatic: d.name == RoadmapScreen.next,
          ),
        ),
    ],
  );
}

/// A status tag (§4 `chipLabel`, 11 / 600). `Next` takes the amber tint the
/// render spends on it — "not yet, but next" is BG-7's amber exactly; every
/// other row is a quiet `chip` pill, because a plan is information and
/// information is colourless.
class _Tag extends StatelessWidget {
  const _Tag(this.words, {this.emphatic = false});

  final String words;
  final bool emphatic;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: KvSpace.s10,
      vertical: KvSpace.xs,
    ),
    decoration: BoxDecoration(
      color: emphatic ? KvColor.warnTint : KvColor.chip,
      borderRadius: BorderRadius.circular(KvRadius.control),
    ),
    child: Text(
      words,
      maxLines: 1,
      style: TextStyle(
        fontFamily: KvFont.ui,
        fontSize: 11,
        height: 16 / 11,
        fontWeight: FontWeight.w600,
        fontVariations: KvWeight.w600,
        color: emphatic ? KvColor.warn : KvColor.inkDim,
      ),
    ),
  );
}
