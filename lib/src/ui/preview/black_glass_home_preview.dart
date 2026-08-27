/// Black Glass — the money surface, as a feel test.
///
/// **This is a prototype, not the build.** It exists so the composition can be
/// judged on a real device before `Pre_P3.1` spends eight sessions on it —
/// "premium" is not a property anyone can read off a spec file. It is
/// debug-only, reachable from the dev launcher, imports nothing from the
/// shipped screens and is imported by nothing.
///
/// Everything here is deliberately in ONE file. UX-1 extracts the real
/// primitives into `widgets/` with tests; until it does, a half-designed
/// primitive sitting in `widgets/` is an invitation for a shipped screen to
/// import it (L22's shape: an unfinished destination is worse than none).
///
/// Where this goes beyond the export, and why — the export's own §2 admits it
/// "reads generic" and offers a third font as the cure, which the two-family
/// law refuses. So the character has to come from geometry instead:
///   1. **The datum carries tick marks and a decimal notch.** The export drew a
///      plain hairline. A gauge's datum is graduated, and that single move is
///      what makes the number read as a measurement rather than a label.
///   2. **Functional micro-labels**, mono caps at +1.6 tracking, sitting where
///      an instrument would silk-screen them.
///   3. **The unit and the reading time are engraved BELOW the datum**, right-
///      aligned, the way a panel meter labels its own scale.
/// Everything else follows the bible verbatim (BG-1…BG-16).
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import '../receive/qr_tile.dart';
import '../theme/tokens.dart';
import '../widgets/kv_cadence.dart';
import '../widgets/kv_datum.dart';
import '../widgets/kv_glyph.dart';
import '../widgets/kv_toggle.dart';

// ─────────────────────────────────────────────────────────────────────────────
// The states the money surface has to hold (SCREEN_INVENTORY 7a–7e).
// ─────────────────────────────────────────────────────────────────────────────

enum MoneyState { empty, live, syncing, inFlight, degraded }

/// **Plated is the ratified reading** (founder call, 2026-08-26): the balance
/// earns a container, the trust statement sits inside it beside the number it
/// vouches for, and the label is sentence case. The instrument register — tracked
/// mono caps, a graduated datum, the unit engraved beneath a scale — read as
/// telemetry on glass, and money is owned rather than measured.
///
/// **The graduated datum was not discarded; it was relocated.** It now draws the
/// confirmation gauge on the transaction-detail surface, where there genuinely is
/// a scale and a reading.
enum HeroVariant { plated, engraved, instrument }

extension on HeroVariant {
  bool get instrumentRegister => this == HeroVariant.instrument;
}

extension on MoneyState {
  /// **Silence is the healthy state.** A permanent "Node responding" beside a
  /// permanently animating meter says nothing changed, twice — and the Mainnet
  /// chip in the plate already carries a lit lamp, so a healthy screen was
  /// wearing two liveness indicators that agreed with each other. The trust
  /// line now EARNS its place by appearing: it shows up when the link is not
  /// live, and the chip carries the good news on its own.
  ///
  /// This tightens BG-8 rather than loosening it. The law requires that a
  /// chain-derived value wire live · stale · unknown — it never required a
  /// standing badge for "fine". The age line under the figure already reports
  /// freshness; what was redundant was the reassurance.
  bool get trustLineSpeaks =>
      this == MoneyState.syncing || this == MoneyState.degraded;

  /// **Motion means something is happening.** The cadence rides the trust line,
  /// so it is the app's loading indicator and its link-lost tell — never ambient
  /// decoration on a settled screen. Stillness is what "nothing to worry about"
  /// looks like.

  String get label => switch (this) {
    MoneyState.empty => 'empty',
    MoneyState.live => 'live',
    MoneyState.syncing => 'syncing',
    MoneyState.inFlight => 'in flight',
    MoneyState.degraded => 'degraded',
  };

  /// Chain-derived values dim to 45% with a visible age when the link is not
  /// live (BG-8). Buttons never dim — they are the user's, not the chain's.
  bool get stale => this == MoneyState.degraded;

  bool get cadenceRunning =>
      this == MoneyState.live ||
      this == MoneyState.syncing ||
      this == MoneyState.inFlight;
}

class BlackGlassHomePreview extends StatefulWidget {
  const BlackGlassHomePreview({super.key});

  @override
  State<BlackGlassHomePreview> createState() => _BlackGlassHomePreviewState();
}

class _BlackGlassHomePreviewState extends State<BlackGlassHomePreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _nav = AnimationController(
    vsync: this,
    duration: KvMotion.enter,
    reverseDuration: KvMotion.calm,
  );
  MoneyState _state = MoneyState.live;
  final HeroVariant _variant = HeroVariant.plated;
  // C compact, founder-chosen 2026-08-26. The switcher stays for now:
  // "feels kinda modern but not quite yet" is not a closed decision.
  PanelStyle _panel = PanelStyle.compact;
  double _dragX = 0;

  /// **The extent is measured, not stated.** A `SliverPersistentHeader` demands
  /// a height it cannot work out for itself, and the first version of this
  /// carried a hand-guessed number under a comment claiming it had been
  /// measured — which overflowed the plate by 19dp the moment the padding
  /// changed. A stated extent is a claim that goes stale on the next edit.
  ///
  /// So a zero-height measuring copy of the plate lays out beside the real one,
  /// reports its natural height, and the header adopts it. It cannot be wrong,
  /// and it cannot drift: change the plate and the number follows.
  double _plateExtent = 240;

  final GlobalKey _measureKey = GlobalKey();

  void _syncExtent() {
    final box = _measureKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final h = box.size.height + KvSpace.sm + KvSpace.m;
    if ((h - _plateExtent).abs() > 0.5) {
      setState(() => _plateExtent = h);
    }
  }

  @override
  void dispose() {
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncExtent());
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: Stack(
        children: [
          // A left swipe pulls the panel in from the right edge it lives on.
          // The gesture and the geometry agree, which is what makes it
          // learnable without being told.
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            // Accumulated travel, not end velocity. A flick's velocity is only
            // read once the recogniser has already won the arena, and against
            // a scroll view full of tappable rows that is not reliable —
            // measured on device, the velocity form never fired.
            onHorizontalDragStart: (_) => _dragX = 0,
            onHorizontalDragUpdate: (d) {
              _dragX += d.delta.dx;
              if (_dragX < -48 && _nav.status == AnimationStatus.dismissed) {
                _nav.forward();
              }
            },
            child: SafeArea(top: false, child: _body(context)),
          ),
          // BG-13: the panel is mortal. It never survives a lock, and it is
          // summoned rather than resident — there is no rail and no tab bar
          // holding a permanent claim on the screen.
          _NavPanel(controller: _nav, style: _panel, onDismiss: _nav.reverse),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    return Column(
      children: [
        // BG-14: the top 52dp belongs to the real status bar. Nothing is
        // painted there and no status bar is ever drawn.
        const SizedBox(height: KvSpace.statusBarReserve),
        _TopRail(variant: _variant, onNav: _nav.forward),
        Expanded(
          // The balance is PINNED and the ledger scrolls under it: what you
          // own is not something you should have to scroll back up to see.
          // Pull-to-refresh is hosted by the whole scroll view rather than
          // by the list, so the gesture works from the balance as well —
          // which is where a user reaches for it first.
          child: RefreshIndicator(
            onRefresh: () async {
              await Future<void>.delayed(const Duration(milliseconds: 900));
            },
            // Not teal: a refresh is a mechanism, not the one primary
            // action, and teal is rationed to three emissions (BG-2).
            color: KvColor.ink,
            backgroundColor: KvColor.key,
            strokeWidth: 2,
            child: CustomScrollView(
              // Always scrollable, so the pull gesture exists even when the
              // ledger is short or empty.
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _PlateHeader(
                    extent: _plateExtent,
                    child: _Hero(state: _state, variant: _variant),
                  ),
                ),
                if (_state == MoneyState.degraded)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: KvSpace.m),
                      child: _DegradedNotice(),
                    ),
                  ),
                if (_state != MoneyState.empty)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _SectionHeader(state: _state, variant: _variant),
                  ),
                SliverToBoxAdapter(
                  child: _Feed(state: _state, variant: _variant),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: KvSpace.l)),
              ],
            ),
          ),
        ),
        _ThumbActions(state: _state),
        // The measuring copy. Zero height, laid out with an unbounded
        // vertical constraint so it reports its NATURAL size, invisible and
        // untouchable. This is what makes the pinned extent a fact.
        SizedBox(
          height: 0,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minHeight: 0,
            maxHeight: double.infinity,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Opacity(
                  opacity: 0,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: KvSpace.gutter,
                    ),
                    child: KeyedSubtree(
                      key: _measureKey,
                      child: _Hero(state: _state, variant: _variant),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        _Switcher(
          values: MoneyState.values,
          value: _state,
          label: (s) => s.label,
          onChanged: (s) => setState(() => _state = s),
        ),
        _Switcher(
          values: PanelStyle.values,
          value: _panel,
          label: (v) => v.label,
          onChanged: (v) => setState(() {
            _panel = v;
            _nav.forward();
          }),
        ),
      ],
    );
  }
}

/// Pins the balance while the ledger scrolls beneath it. It paints the ground
/// itself, so rows passing underneath never show through — a transparent pinned
/// header is how a sticky plate ends up with text sliding across it.
class _PlateHeader extends SliverPersistentHeaderDelegate {
  const _PlateHeader({required this.extent, required this.child});

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return Container(
      color: KvColor.abyss,
      alignment: Alignment.topCenter,
      padding: const EdgeInsets.only(top: KvSpace.sm, bottom: KvSpace.m),
      child: child,
    );
  }

  @override
  bool shouldRebuild(_PlateHeader old) =>
      old.extent != extent || old.child != child;
}

// ─────────────────────────────────────────────────────────────────────────────
// Top rail — the nav trigger and nothing else. A 44dp glyph inside a 48dp
// target, stated here because BG-12 requires the smaller visual to be declared.
// ─────────────────────────────────────────────────────────────────────────────

class _TopRail extends StatelessWidget {
  const _TopRail({required this.variant, required this.onNav});

  final HeroVariant variant;
  final VoidCallback onNav;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.m, 0, KvSpace.m, 0),
      child: Row(
        children: [
          const SizedBox(width: KvSpace.s),
          // The wordmark, engraved rather than set: mono caps, wide tracking,
          // sitting at the same optical weight as a silk-screened panel label.
          if (variant.instrumentRegister)
            const Text(
              'KASPAVERSE',
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 11,
                height: 16 / 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 2.4,
                color: KvColor.inkMeta,
              ),
            )
          else
            const Text(
              'KaspaVerse',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
                color: KvColor.inkNav,
              ),
            ),
          const Spacer(),
          // The trigger sits with the panel it opens: right-anchored, so the
          // hand that reaches for it is already there (BG-12's thumb arc).
          Semantics(
            button: true,
            label: 'Open navigation',
            child: InkWell(
              onTap: onNav,
              borderRadius: BorderRadius.circular(KvRadius.pill),
              // A 24dp mark inside a 48dp target — the smaller visual is
              // permitted only because the code says so (BG-12).
              child: const SizedBox(
                width: KvSpace.touchTarget,
                height: KvSpace.touchTarget,
                child: Center(
                  child: CustomPaint(
                    size: Size(KvGlyph.grid, KvGlyph.grid),
                    painter: _GlyphPainter(_Glyph.navDots),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The hero — the instrument face.
// ─────────────────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  const _Hero({required this.state, required this.variant});

  final MoneyState state;
  final HeroVariant variant;

  static const _integer = '1,284';
  static const _fraction = '5027';

  @override
  Widget build(BuildContext context) {
    final empty = state == MoneyState.empty;
    // BG-5: a real zero renders as a real zero; it is never a skeleton and
    // never a fabricated number standing in for an unknown one.
    final integer = empty ? '0' : _integer;
    final fraction = empty ? '0000' : _fraction;

    final body = switch (variant) {
      HeroVariant.plated => _Plated(
        state: state,
        integer: integer,
        fraction: fraction,
      ),
      HeroVariant.engraved => _Engraved(
        state: state,
        integer: integer,
        fraction: fraction,
      ),
      HeroVariant.instrument => _Instrument(
        state: state,
        integer: integer,
        fraction: fraction,
      ),
    };

    return Opacity(
      opacity: state.stale ? KvFreshness.opacityStale : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              label: empty ? 'Balance zero KAS' : 'Balance 1,284.5027 KAS',
              child: ExcludeSemantics(child: body),
            ),
            if (state == MoneyState.inFlight) ...[
              const SizedBox(height: KvSpace.sm),
              const _InFlightLine(),
            ],
          ],
        ),
      ),
    );
  }
}

/// The number itself. Same in all three variants — what changes around it is
/// how much technical furniture it wears.
class _Figure extends StatelessWidget {
  const _Figure({required this.integer, required this.fraction});

  final String integer;
  final String fraction;

  /// The plated and engraved variants both read at 42 — one step down from the
  /// instrument's 46, because the unit now sits beside the number instead of
  /// being engraved under it, and the line has to hold both.
  static const double size = 42;

  @override
  Widget build(BuildContext context) {
    // A number scales down before it ever truncates (BG-5), which is also what
    // carries it through 1.3x text scale at 320dp.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            integer,
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: size,
              height: 1.14,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.5,
              color: KvColor.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            '.$fraction',
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: size * 0.48,
              fontWeight: FontWeight.w400,
              color: KvColor.inkDim,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: KvSpace.s),
          // The unit sits WITH the number, the way a price is written — not
          // engraved beneath it as a scale label. This is most of what makes
          // the plated and engraved variants read as money.
          Text(
            'KAS',
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: size * 0.33,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.6,
              // The one word on this screen that IS the brand. `primaryMuted`
              // is ambient teal, not an emission, so it costs nothing against
              // BG-2's cap of three — see §1.5.
              color: KvColor.primaryMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// **A · Plated.** The balance earns a container, and the trust statement lives
/// inside it beside the number it vouches for. Sentence case throughout; the
/// only rule is a hairline separating the figure from its provenance. Warmest
/// of the three, and the closest to something a person reads as their money.
class _Plated extends StatelessWidget {
  const _Plated({
    required this.state,
    required this.integer,
    required this.fraction,
  });

  final MoneyState state;
  final String integer;
  final String fraction;

  @override
  Widget build(BuildContext context) {
    final (Color lamp, String words) = _trust(state);
    return Container(
      width: double.infinity,
      // The plate is TALL rather than compressed: the money is the reason the
      // screen exists, so it gets the room, and the chrome above it gets less.
      padding: const EdgeInsets.fromLTRB(
        KvSpace.l,
        KvSpace.l,
        KvSpace.l,
        KvSpace.m,
      ),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.panel),
        border: Border.all(color: KvColor.plateEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SoftLabel('Total balance'),
              const Spacer(),
              // Tapping the network opens the node surface — who serves you,
              // how freshly, and the standing offer to serve yourself. The
              // sovereign-node session owns what lives behind it.
              _NetworkChip(state: state),
            ],
          ),
          const SizedBox(height: KvSpace.sm),
          _Figure(integer: integer, fraction: fraction),
          const SizedBox(height: KvSpace.s),
          _ValueLine(
            empty: integer == '0',
            rate: 0.0752,
            // Fresh says nothing; stale says how old. BG-8 requires the age to
            // be VISIBLE when a reading is dimmed — the retired variant carried
            // it and the ratified one had lost it.
            ageLabel: state.stale ? 'as of 14:02:41 · 3 m ago' : '',
          ),
          const SizedBox(height: KvSpace.m),
          Container(height: 1, color: KvColor.plateDivider),
          const SizedBox(height: KvSpace.sm),
          if (state.trustLineSpeaks) ...[
            Row(
              children: [
                _Lamp(lamp),
                const SizedBox(width: KvSpace.s),
                Expanded(
                  child: Text(
                    words,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 13,
                      height: 18 / 13,
                      color: KvColor.inkDim,
                    ),
                  ),
                ),
                const SizedBox(width: KvSpace.s),
                _Cadence(running: state.cadenceRunning),
              ],
            ),
            const SizedBox(height: 6),
          ],
          // The chain clock, where an instrument puts its reading: small,
          // mono, tabular, and never competing with the money above it.
          Text(
            'DAA 523,216,421',
            style: const TextStyle(
              fontFamily: KvFont.mono,
              fontSize: 11,
              height: 15 / 11,
              color: KvColor.inkMetaLow,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// **B · Engraved.** No container — the figure still floats in void, but the
/// telemetry furniture is gone: sentence case, the unit with the number, and a
/// datum that is a clean rule with end stops rather than a graduated scale.
class _Engraved extends StatelessWidget {
  const _Engraved({
    required this.state,
    required this.integer,
    required this.fraction,
  });

  final MoneyState state;
  final String integer;
  final String fraction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SoftLabel('Total balance'),
        const SizedBox(height: KvSpace.s),
        _Figure(integer: integer, fraction: fraction),
        const SizedBox(height: KvSpace.sm),
        const SizedBox(
          height: 5,
          width: double.infinity,
          child: CustomPaint(painter: _DatumPainter(graduated: false)),
        ),
        const SizedBox(height: KvSpace.s),
        Text(
          switch (state) {
            MoneyState.degraded => 'As of 14:02:41 · 3 m ago',
            MoneyState.syncing => 'Still counting',
            _ => 'Updated just now',
          },
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 12,
            height: 16 / 12,
            color: state.stale ? KvColor.warn : KvColor.inkMetaLow,
          ),
        ),
      ],
    );
  }
}

/// **C · Instrument.** The export's own reading, kept for comparison: tracked
/// mono caps, a graduated datum, the unit and the reading time engraved beneath
/// the scale. Precise, and on glass it reads as telemetry rather than money.
class _Instrument extends StatelessWidget {
  const _Instrument({
    required this.state,
    required this.integer,
    required this.fraction,
  });

  final MoneyState state;
  final String integer;
  final String fraction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _MicroLabel('TOTAL BALANCE'),
        const SizedBox(height: KvSpace.sm),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                integer,
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 46,
                  height: 52 / 46,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.5,
                  color: KvColor.ink,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                '.$fraction',
                style: const TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 22,
                  fontWeight: FontWeight.w400,
                  color: KvColor.inkDim,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: KvSpace.s),
        const SizedBox(
          height: 7,
          width: double.infinity,
          child: CustomPaint(painter: _DatumPainter(graduated: true)),
        ),
        const SizedBox(height: KvSpace.s),
        Row(
          children: [
            const _MicroLabel('KAS'),
            const Spacer(),
            _MicroLabel(switch (state) {
              MoneyState.degraded => 'AS OF 14:02:41 · 3 M AGO',
              MoneyState.syncing => 'STILL COUNTING',
              _ => 'UPDATED JUST NOW',
            }, tone: state.stale ? KvColor.warn : KvColor.inkMetaLow),
          ],
        ),
      ],
    );
  }
}

(Color, String) _trust(MoneyState state) => switch (state) {
  MoneyState.degraded => (KvColor.warn, 'Link lost — showing last known'),
  MoneyState.syncing => (KvColor.warn, 'Counting your coins'),
  _ => (KvColor.ok, 'Node responding'),
};

/// The network, as a control rather than a caption. A lamp, the network name,
/// and a chevron that says it goes somewhere — 48dp of target around a 28dp
/// visual (BG-12 requires the smaller visual to be declared).
class _NetworkChip extends StatelessWidget {
  const _NetworkChip({required this.state});

  final MoneyState state;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Mainnet. Open network and node settings',
      child: Builder(
        builder: (context) => InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const _NetworkPreview()),
          ),
          borderRadius: BorderRadius.circular(KvRadius.control),
          // A 28dp visual inside a 48dp target. It sits beside a 42dp balance
          // and was competing with it; a network chip is a way OUT of this
          // screen, not a thing on it. The smaller visual is declared (BG-12).
          child: SizedBox(
            height: KvSpace.touchTarget,
            child: Center(
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: KvColor.control,
                  borderRadius: BorderRadius.circular(KvRadius.control),
                  border: Border.all(color: KvColor.edgeHi),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // NOT const. A lamp that can only be green is not an
                    // indicator, and this one sat beside an amber "Link lost"
                    // on the same plate (BG-8, the P0.3 scar).
                    _Lamp(state.trustLineSpeaks ? KvColor.warn : KvColor.ok),
                    const SizedBox(width: 6),
                    const Text(
                      'Mainnet',
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 11,
                        height: 15 / 11,
                        fontWeight: FontWeight.w500,
                        color: KvColor.inkDim,
                      ),
                    ),
                    const SizedBox(width: 3),
                    CustomPaint(
                      size: const Size(11, 11),
                      painter: const _GlyphPainter(
                        _Glyph.chevron,
                        tone: KvColor.inkMeta,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the balance is worth, in fiat.
///
/// **Founder call, 2026-08-26 (D-191): fiat exists.** The rate comes from
/// `api.kaspa.org`, a named and user-replaceable endpoint, and the whole feature
/// is disable-able. A price is the one claim in this app that consensus cannot
/// re-verify — no node, no chain and no proof can check it — so INV-8's
/// carve-out carries conditions, and this widget is where three of them live:
///
///   * it is **subordinate by scale and tone**, and prefixed `≈`, because KAS is
///     the unit of account and this is a convenience beside it;
///   * it **wears its age** at the point of display, like every other reading
///     the wallet did not derive itself (BG-8) — the SOURCE is disclosed where
///     the source is chosen (the network surface and Settings), not shouted on
///     the money screen, because a hostname beside a balance is clutter that
///     stops being read on day two;
///   * unknown renders **`—`**, never a fabricated number (BG-5).
///
/// The fourth condition is enforced by its absence: this widget appears on no
/// signing surface. What you sign is denominated in the thing that moves.
class _ValueLine extends StatelessWidget {
  const _ValueLine({required this.empty, this.rate, required this.ageLabel});

  final bool empty;

  /// Null when no rate has been fetched, or when the user switched it off.
  final double? rate;
  final String ageLabel;

  @override
  Widget build(BuildContext context) {
    if (empty) return const SizedBox.shrink();
    final r = rate;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          r == null ? '≈ —' : '≈ ${(1284.5027 * r).toStringAsFixed(2)} USD',
          style: const TextStyle(
            fontFamily: KvFont.mono,
            fontSize: 13,
            height: 18 / 13,
            color: KvColor.inkMeta,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        // BG-8, as amended at D-192: a fresh reading says nothing. The age
        // appears only when the rate has gone stale enough to mislead, which
        // is the same rule the trust line follows.
        if (r == null || ageLabel.isNotEmpty) ...[
          const SizedBox(width: KvSpace.s),
          Text(
            r == null ? 'no rate yet' : ageLabel,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              // The carve-out that permits fiat requires this to be readable.
              color: KvColor.inkMetaLow,
            ),
          ),
        ],
      ],
    );
  }
}

/// Sentence case, Inter, no tracking — a label a person reads, not one an
/// instrument wears.
class _SoftLabel extends StatelessWidget {
  const _SoftLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontFamily: KvFont.ui,
      fontSize: 13,
      height: 18 / 13,
      color: KvColor.inkDim,
    ),
  );
}

/// Extracted to `widgets/kv_datum.dart` at UX-1, and aliased here so the
/// prototype and the primitive cannot disagree. The default flipped in the
/// move — plain, not graduated — because end stops turn a line into a scale
/// and most rules in this app are not scales (D-195); the two call sites here
/// name what they want.
typedef _DatumPainter = KvDatumPainter;

class _InFlightLine extends StatelessWidget {
  const _InFlightLine();

  @override
  Widget build(BuildContext context) {
    // BG-8: money in flight lives on a surface that stays until it settles.
    // Never a toast.
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.sm,
      ),
      decoration: BoxDecoration(
        color: KvColor.chip,
        borderRadius: BorderRadius.circular(KvRadius.plate),
        border: Border.all(color: KvColor.plateDivider),
      ),
      child: Row(
        children: [
          const _Lamp(KvColor.warn),
          const SizedBox(width: KvSpace.sm),
          const Expanded(
            child: Text(
              'Leaving now',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: KvColor.inkDim,
              ),
            ),
          ),
          Text(
            '− 12.40000000',
            style: const TextStyle(
              fontFamily: KvFont.mono,
              fontSize: 13,
              color: KvColor.risk,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Trust line — a lamp, plain English, and the cadence.
// ─────────────────────────────────────────────────────────────────────────────

/// A 6dp lamp under an 8dp bloom, no spread — §1.5's only simulated light
/// besides the cadence and the sign ring. The words beside it carry the
/// meaning; the lamp is never alone (BG-7).
class _Lamp extends StatelessWidget {
  const _Lamp(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) {
    final bloom = switch (color) {
      KvColor.ok => KvColor.okBloom,
      KvColor.risk => KvColor.riskBloom,
      _ => KvColor.warnBloom,
    };
    return ExcludeSemantics(
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: bloom, blurRadius: 8)],
        ),
      ),
    );
  }
}

/// Extracted to `widgets/kv_cadence.dart` at UX-1, and aliased here so the
/// prototype and the primitive cannot disagree. The move fixed one thing on
/// the way: under reduced motion the private copy stopped the controller,
/// which rendered a RUNNING cadence identically to a frozen one — the exact
/// lie BG-8 exists to forbid. The primitive holds the bars bright instead.
typedef _Cadence = KvCadence;

class _DegradedNotice extends StatelessWidget {
  const _DegradedNotice();

  @override
  Widget build(BuildContext context) {
    // Amber, because the truth is incomplete — not red, which would claim
    // money is at risk when none is (BG-7).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: KvSpace.m,
          vertical: KvSpace.sm,
        ),
        decoration: BoxDecoration(
          color: KvColor.noticeWarnFill,
          borderRadius: BorderRadius.circular(KvRadius.plate),
          border: Border.all(color: KvColor.noticeWarnEdge),
        ),
        child: Row(
          children: [
            const _Lamp(KvColor.warn),
            const SizedBox(width: KvSpace.sm),
            const Expanded(
              child: Text(
                'Your money is safe. This is the last balance the network '
                'confirmed — it may have moved since.',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 19 / 13,
                  color: KvColor.inkDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The feed — a ledger, not cards. Rhythm from spacing (BG-1).
// ─────────────────────────────────────────────────────────────────────────────

class _Entry {
  const _Entry(
    this.glyph,
    this.title,
    this.peer,
    this.amount,
    this.tone,
    this.weight,
    this.status,
    this.statusLamp,
    this.age,
  );

  final _Glyph glyph;
  final String title;
  final String peer;
  final String amount;
  final Color tone;
  final FontWeight weight;
  final String status;
  final Color statusLamp;
  final String age;
}

const _entries = <_Entry>[
  _Entry(
    _Glyph.arrowIn,
    'Received',
    'from kaspa:qz0k4vnr…s8fjm2wa',
    '+ 24.00',
    KvColor.ok,
    FontWeight.w600,
    'final',
    KvColor.ok,
    '12 s',
  ),
  _Entry(
    _Glyph.arrowOut,
    'Sent',
    'to kaspa:qpzt3vw8…x2mne4ka',
    '− 12.40',
    KvColor.risk,
    FontWeight.w400,
    'settling 4/10',
    KvColor.warn,
    '1 m',
  ),
  _Entry(
    _Glyph.arrowIn,
    'Received',
    'from kaspa:qz0k4vnr…s8fjm2wa',
    '+ 180.00',
    KvColor.ok,
    FontWeight.w600,
    'final',
    KvColor.ok,
    '2 h',
  ),
  _Entry(
    _Glyph.selfSend,
    'Consolidated',
    'internal · coins merged',
    '0.00',
    KvColor.inkDim,
    FontWeight.w400,
    'final · fee 0.00001',
    KvColor.ok,
    '1 d',
  ),
];

/// The section header pins under the plate: scrolling a ledger should never
/// leave you unsure which ledger you are in.
class _SectionHeader extends SliverPersistentHeaderDelegate {
  const _SectionHeader({required this.state, required this.variant});

  final MoneyState state;
  final HeroVariant variant;

  @override
  double get minExtent => 40;

  @override
  double get maxExtent => 40;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return Container(
      color: KvColor.abyss,
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          if (variant.instrumentRegister) ...[
            Container(width: 2, height: 10, color: KvColor.primaryMuted),
            const SizedBox(width: KvSpace.s),
            const _MicroLabel('ACTIVITY'),
          ] else
            const Text(
              'Activity',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w600,
                color: KvColor.ink,
              ),
            ),
          if (state == MoneyState.degraded) ...[
            const Spacer(),
            const Text(
              'Complete to 14:02',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 12,
                height: 16 / 12,
                color: KvColor.warn,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_SectionHeader old) =>
      old.state != state || old.variant != variant;
}

/// A hairline between two facts.
class _RowRule extends StatelessWidget {
  const _RowRule();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: KvColor.plateDivider);
}

class _Feed extends StatelessWidget {
  const _Feed({required this.state, required this.variant});

  final MoneyState state;
  final HeroVariant variant;

  @override
  Widget build(BuildContext context) {
    if (state == MoneyState.empty) return const _EmptyState();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: KvSpace.s),
        for (var i = 0; i < _entries.length; i++) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: KvSpace.gutter),
              child: _RowRule(),
            ),
          _Row(entry: _entries[i], stale: state.stale),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry, required this.stale});

  final _Entry entry;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: stale ? KvFreshness.opacityStale : 1,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _TransactionDetailPreview(entry: entry),
          ),
        ),
        child: Padding(
          // 20dp rhythm, no dividers in motion — the ledger reads by spacing.
          padding: const EdgeInsets.fromLTRB(
            KvSpace.gutter,
            10,
            KvSpace.gutter,
            10,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: CustomPaint(
                  size: const Size(KvGlyph.grid, KvGlyph.grid),
                  painter: _GlyphPainter(entry.glyph, tone: entry.tone),
                ),
              ),
              const SizedBox(width: KvSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 15,
                        height: 20 / 15,
                        fontWeight: FontWeight.w500,
                        color: KvColor.ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    // Full width, so the compact form is never truncated twice.
                    Text(
                      entry.peer,
                      maxLines: 1,
                      // Clip, never ellipsis: a tail cut on an address throws
                      // away the last eight payload characters and leaves the
                      // `kaspa:q…` shape BG-15 forbids. At 320dp / 1.3x this
                      // row is ~50dp short — which no 412dp device shows.
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: const TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 12,
                        height: 16 / 12,
                        color: KvColor.inkMeta,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Lamp(entry.statusLamp),
                        const SizedBox(width: 5),
                        Text(
                          '${entry.status} · ${entry.age}',
                          style: const TextStyle(
                            fontFamily: KvFont.mono,
                            fontSize: 11,
                            height: 15 / 11,
                            color: KvColor.inkMetaLow,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: KvSpace.sm),
              // Direction rides four ways at once — word, sign, colour and
              // weight — so the row survives greyscale, colour-blindness and a
              // screen reader (BG-7).
              Text(
                entry.amount,
                style: TextStyle(
                  fontFamily: KvFont.mono,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: entry.weight,
                  color: entry.tone,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one empty-state pattern: etched glyph, one truth, one nudge. Emptiness
/// is a real state of a real wallet — never an apology, never an illustration.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.gutter,
        KvSpace.xl,
        KvSpace.gutter,
        0,
      ),
      child: Column(
        children: [
          const CustomPaint(
            size: Size(KvGlyph.grid, KvGlyph.grid),
            painter: _GlyphPainter(_Glyph.diamond, tone: KvColor.etch),
          ),
          const SizedBox(height: KvSpace.m),
          const Text(
            'Nothing has moved yet',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 15,
              height: 22 / 15,
              color: KvColor.inkDim,
            ),
          ),
          const SizedBox(height: KvSpace.xs),
          const Text(
            'Your address is ready to receive.',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkMetaLow,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Thumb arc — Send and Receive. On an empty wallet the light flips to Receive,
// because the brightest thing on screen is always the most sensible next act.
// ─────────────────────────────────────────────────────────────────────────────

class _ThumbActions extends StatelessWidget {
  const _ThumbActions({required this.state});

  final MoneyState state;

  @override
  Widget build(BuildContext context) {
    final empty = state == MoneyState.empty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.gutter,
        KvSpace.sm,
        KvSpace.gutter,
        KvSpace.m,
      ),
      child: Row(
        children: [
          Expanded(
            child: _Action(
              label: 'Receive',
              primary: empty,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const _ReceivePreview(),
                ),
              ),
            ),
          ),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: _Action(
              label: 'Send',
              primary: !empty,
              // BG-12: a disabled control always says why, in words.
              disabledReason: empty ? 'Nothing to send yet' : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const _SendPreview()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.primary,
    required this.onTap,
    this.disabledReason,
  });

  final String label;
  final bool primary;
  final VoidCallback onTap;
  final String? disabledReason;

  @override
  Widget build(BuildContext context) {
    final disabled = disabledReason != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          enabled: !disabled,
          child: InkWell(
            onTap: disabled ? null : onTap,
            borderRadius: BorderRadius.circular(KvRadius.control),
            child: Container(
              height: KvSpace.control,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // Teal fills exactly one thing on this screen: the single
                // primary action (BG-2).
                // Teal fills exactly one thing per screen: the single primary
                // action (BG-2). Everything else recedes to `control`.
                color: primary && !disabled ? KvColor.primary : KvColor.control,
                borderRadius: BorderRadius.circular(KvRadius.control),
                border: primary && !disabled
                    ? null
                    : Border.all(color: KvColor.edgeHi),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  color: primary && !disabled
                      ? KvColor.onPrimary
                      : (disabled ? KvColor.inkMeta : KvColor.ink),
                ),
              ),
            ),
          ),
        ),
        if (disabled) ...[
          const SizedBox(height: KvSpace.xs),
          Text(
            disabledReason!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 11,
              height: 15 / 11,
              color: KvColor.inkMetaLow,
            ),
          ),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits.
// ─────────────────────────────────────────────────────────────────────────────

/// Silk-screened panel labelling: mono caps, wide tracking, smallest tone that
/// still clears AA on every surface it can land on.
class _MicroLabel extends StatelessWidget {
  const _MicroLabel(this.text, {this.tone = KvColor.inkMetaLow});

  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontFamily: KvFont.mono,
      fontSize: 11,
      height: 16 / 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 1.6,
      color: tone,
    ),
  );
}

/// The prototype drew this set privately; UX-1 extracted it to
/// `widgets/kv_glyph.dart` with tests. Aliased rather than re-declared so the
/// two cannot drift while the remaining preview screens are still standing —
/// a second copy of a component is two places to disagree about one design.
typedef _Glyph = KvMark;
typedef _GlyphPainter = KvGlyphPainter;

/// Debug-only. Not part of the design — it exists so every state and every
/// balance treatment can be compared in one sitting instead of five builds.
class _Switcher<T> extends StatelessWidget {
  const _Switcher({
    required this.values,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final List<T> values;
  final T value;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: KvColor.well,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
        child: Row(
          children: [
            for (final v in values)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: InkWell(
                  onTap: () => onChanged(v),
                  borderRadius: BorderRadius.circular(KvRadius.chip),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: v == value ? KvColor.keyPressed : KvColor.abyss,
                      borderRadius: BorderRadius.circular(KvRadius.chip),
                      border: Border.all(
                        color: v == value ? KvColor.edgeHi : KvColor.hairline,
                      ),
                    ),
                    child: Text(
                      label(v),
                      style: TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 11,
                        color: v == value ? KvColor.ink : KvColor.inkMeta,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Transaction detail — where the instrument register belongs.
//
// The graduated datum was built for the balance and read as telemetry there,
// because money is owned rather than measured. Here there IS a scale and there
// IS a reading: burial depth, from the first confirmation to the point where
// arguing about it stops being interesting. So the gesture moves, and the
// tracked mono caps come with it.
// ─────────────────────────────────────────────────────────────────────────────

/// The depths worth being able to see at once, so the founder can watch the
/// mark arrive. Debug affordance, not design.
const _depths = <int>[0, 1, 12, 99, 100, 418, 999, 1000];

/// The two thresholds that mean something, and the words for the three zones
/// between them.
///
/// **Amber was wrong past a hundred.** `warn` means *not yet certain*, and a
/// transaction a hundred blocks deep is certain enough to act on — holding it
/// amber until a thousand tells the user to keep worrying for another fifteen
/// minutes about something already settled. So the gauge has three zones, not
/// two: **settling** (amber, genuinely uncertain), **safe** (green, deep enough
/// to rely on), and **final** (green, and the thousand mark closes).
///
/// Two thresholds, one hue change: green arrives at safety, and finality is
/// carried by the mark filling rather than by a fourth colour the palette does
/// not have (BG-7 — one hue, one meaning).
const int kSafeDepth = 100;
const int kFinalDepth = 1000;

/// The explorers that actually exist. **`kas.fyi` shut down** — it was in this
/// file's copy and in two historical records, and a wallet that hands you a
/// dead link is worse than one that offers none.
///
/// The choice belongs in Settings (UX-3 builds it); it lives here so the
/// disclosure can name the destination it is actually about to hand your data
/// to. A generic "an explorer" cannot be a sovereignty decision.
enum Explorer { kaspaOrg, kaspaStream }

extension on Explorer {
  String get host => switch (this) {
    Explorer.kaspaOrg => 'explorer.kaspa.org',
    Explorer.kaspaStream => 'kaspa.stream',
  };

  String get label => switch (this) {
    Explorer.kaspaOrg => 'explorer.kaspa.org',
    Explorer.kaspaStream => 'kaspa.stream',
  };
}

class _TransactionDetailPreview extends StatefulWidget {
  const _TransactionDetailPreview({required this.entry});

  final _Entry entry;

  @override
  State<_TransactionDetailPreview> createState() =>
      _TransactionDetailPreviewState();
}

class _TransactionDetailPreviewState extends State<_TransactionDetailPreview> {
  int _depth = 418;
  Explorer _explorer = Explorer.kaspaOrg;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final safe = _depth >= kSafeDepth;
    final settled = _depth >= kFinalDepth;
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            _DetailRail(onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
                children: [
                  const SizedBox(height: KvSpace.m),
                  Row(
                    children: [
                      CustomPaint(
                        size: const Size(KvGlyph.grid, KvGlyph.grid),
                        painter: _GlyphPainter(e.glyph, tone: e.tone),
                      ),
                      const SizedBox(width: KvSpace.sm),
                      Text(
                        e.title,
                        style: const TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 22,
                          height: 28 / 22,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                          color: KvColor.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: KvSpace.sm),
                  // A detail surface shows all eight decimals. This is the
                  // place a number IS a measurement (BG-5).
                  Text(
                    e.title == 'Sent'
                        ? '− 12.40000000 KAS'
                        : '+ 24.00000000 KAS',
                    style: TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 32,
                      height: 38 / 32,
                      fontWeight: FontWeight.w500,
                      color: e.tone,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: KvSpace.xl),

                  // ── The gauge ──────────────────────────────────────────────
                  const _MicroLabel('BURIAL DEPTH'),
                  const SizedBox(height: KvSpace.sm),
                  SizedBox(
                    height: 34,
                    width: double.infinity,
                    child: CustomPaint(painter: _GaugePainter(depth: _depth)),
                  ),
                  const SizedBox(height: KvSpace.s),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        _depth == 0 ? '—' : '$_depth',
                        style: const TextStyle(
                          fontFamily: KvFont.mono,
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                          color: KvColor.ink,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'confirmations',
                        style: TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 13,
                          color: KvColor.inkMeta,
                        ),
                      ),
                      const Spacer(),
                      _Lamp(safe ? KvColor.ok : KvColor.warn),
                      const SizedBox(width: 6),
                      Text(
                        _depth == 0
                            ? 'broadcast — not in a block yet'
                            : settled
                            ? 'final'
                            : safe
                            ? 'safe to rely on'
                            : 'settling',
                        style: TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 13,
                          fontWeight: settled
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: safe ? KvColor.ok : KvColor.warn,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: KvSpace.xl),

                  // ── The truth rows ────────────────────────────────────────
                  // Ruled rows: the hairline is what turns a list of facts
                  // into a ledger you can read down.
                  const _DetailRow(
                    'From',
                    'kaspa:qz0k4vnr…s8fjm2wa',
                    mono: true,
                  ),
                  const _RowRule(),
                  const _DetailRow('Fee', '0.00001000 KAS', mono: true),
                  const _RowRule(),
                  const _DetailRow('Accepted', '14:02:41 · 26 Aug 2026'),
                  const _RowRule(),
                  const _DetailRow('DAA', '523,216,421', mono: true),
                  const _RowRule(),
                  const _DetailRow(
                    'Transaction id',
                    'a91f0c…4e77b2',
                    mono: true,
                    copy: true,
                  ),
                  const SizedBox(height: KvSpace.l),

                  // Leaving is a sovereignty decision, so it names exactly what
                  // it hands over rather than reading as a casual link.
                  Container(
                    padding: const EdgeInsets.all(KvSpace.m),
                    decoration: BoxDecoration(
                      color: KvColor.chip,
                      borderRadius: BorderRadius.circular(KvRadius.plate),
                      border: Border.all(color: KvColor.plateDivider),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'View in explorer',
                                style: TextStyle(
                                  fontFamily: KvFont.ui,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: KvColor.ink,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Hands ${_explorer.host} this transaction id '
                                'and your network address.',
                                style: const TextStyle(
                                  fontFamily: KvFont.ui,
                                  fontSize: 12,
                                  height: 17 / 12,
                                  color: KvColor.inkMeta,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: KvSpace.sm),
                        CustomPaint(
                          size: const Size(18, 18),
                          painter: const _GlyphPainter(
                            _Glyph.chevron,
                            tone: KvColor.inkMeta,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: KvSpace.sm),
                  Row(
                    children: [
                      const Text(
                        'Explorer',
                        style: TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 12,
                          color: KvColor.inkMeta,
                        ),
                      ),
                      const SizedBox(width: KvSpace.sm),
                      for (final e in Explorer.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: () => setState(() => _explorer = e),
                            borderRadius: BorderRadius.circular(KvRadius.chip),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: KvSpace.s,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: e == _explorer
                                    ? KvColor.keyPressed
                                    : KvColor.abyss,
                                borderRadius: BorderRadius.circular(
                                  KvRadius.chip,
                                ),
                                border: Border.all(
                                  color: e == _explorer
                                      ? KvColor.edgeHi
                                      : KvColor.hairline,
                                ),
                              ),
                              child: Text(
                                e.label,
                                style: TextStyle(
                                  fontFamily: KvFont.mono,
                                  fontSize: 11,
                                  color: e == _explorer
                                      ? KvColor.ink
                                      : KvColor.inkMeta,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'This chooser lives in Settings — it sits here so the '
                    'disclosure above can name a real destination.',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 11,
                      height: 15 / 11,
                      color: KvColor.etch,
                    ),
                  ),
                  const SizedBox(height: KvSpace.xl),
                ],
              ),
            ),
            _Switcher<int>(
              values: _depths,
              value: _depth,
              label: (d) => d == 0 ? '0' : '$d',
              onChanged: (d) => setState(() => _depth = d),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRail extends StatelessWidget {
  const _DetailRail({
    required this.onBack,
    this.title = 'Transaction',
    this.actions = const <Widget>[],
  });

  final VoidCallback onBack;
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.m, KvSpace.s, KvSpace.m, 0),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: 'Back',
            child: InkWell(
              onTap: onBack,
              borderRadius: BorderRadius.circular(KvRadius.pill),
              child: const SizedBox(
                width: KvSpace.touchTarget,
                height: KvSpace.touchTarget,
                child: Center(
                  child: RotatedBox(
                    quarterTurns: 2,
                    child: CustomPaint(
                      size: Size(KvGlyph.grid, KvGlyph.grid),
                      painter: _GlyphPainter(
                        _Glyph.chevron,
                        tone: KvColor.inkNav,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          Text(
            title,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: KvColor.inkDim,
            ),
          ),
          const Spacer(),
          if (actions.isEmpty)
            const SizedBox(width: KvSpace.touchTarget)
          else
            ...actions,
        ],
      ),
    );
  }
}

/// A rail action: 24dp of glyph in a 48dp target.
class _RailAction extends StatelessWidget {
  const _RailAction(this.glyph, this.label, {required this.onTap});

  final _Glyph glyph;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KvRadius.control),
        child: SizedBox(
          width: KvSpace.touchTarget,
          height: KvSpace.touchTarget,
          child: Center(
            child: CustomPaint(
              size: const Size(22, 22),
              painter: _GlyphPainter(glyph, tone: KvColor.inkNav),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(
    this.label,
    this.value, {
    this.mono = false,
    this.copy = false,
  });

  final String label;
  final String value;
  final bool mono;
  final bool copy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 18 / 13,
                color: KvColor.inkMeta,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: mono ? KvFont.mono : KvFont.ui,
                fontSize: 13,
                height: 18 / 13,
                color: KvColor.ink,
                fontFeatures: mono
                    ? const [FontFeature.tabularFigures()]
                    : null,
              ),
            ),
          ),
          if (copy)
            const Text(
              'copy',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: KvColor.primaryMuted,
              ),
            ),
        ],
      ),
    );
  }
}

/// The burial gauge. **Logarithmic**, because linear depth makes one
/// confirmation invisible next to a thousand and the first one is the one the
/// user is actually waiting for. Graduated at 1 · 10 · 100 · 1,000, and the
/// thousand mark is taller, brighter and labelled — it is the point the scale
/// exists to reach.
///
/// The fill is amber while settling and green once buried, because that is a
/// value judgement about certainty (BG-7). It is never teal: teal is light, not
/// a status.
class _GaugePainter extends CustomPainter {
  const _GaugePainter({required this.depth});

  final int depth;

  static double _pos(num n) {
    if (n <= 0) return 0;
    final p = math.log(1 + n) / math.log(1 + kFinalDepth);
    return p.clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const railY = 20.0;
    final w = size.width;

    // The datum the whole scale hangs from.
    final rule = Paint()
      ..color = KvColor.datum
      ..strokeWidth = 1
      ..isAntiAlias = false;
    canvas.drawLine(const Offset(0, railY), Offset(w, railY), rule);

    // Graduations: a dense run so the scale reads as a scale, plus named stops.
    final minor = Paint()
      ..color = KvColor.datum
      ..strokeWidth = 1
      ..isAntiAlias = false;
    for (var i = 1; i <= 60; i++) {
      final x = (w * i / 61).floorToDouble() + 0.5;
      canvas.drawLine(Offset(x, railY + 1), Offset(x, railY + 3), minor);
    }

    // The fill, from zero to where this transaction actually is. Green arrives
    // at SAFE, not at final — see kSafeDepth.
    final safe = depth >= kSafeDepth;
    final settled = depth >= kFinalDepth;
    final fill = Paint()
      ..color = safe ? KvColor.ok : KvColor.warn
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.butt;
    final x = (w * _pos(depth)).clamp(0.0, w);
    if (x > 0) {
      canvas.drawLine(Offset(0, railY - 3.5), Offset(x, railY - 3.5), fill);
    }

    // Named stops.
    final stop = Paint()
      ..color = KvColor.tick
      ..strokeWidth = 1
      ..isAntiAlias = false;
    for (final n in const [1, 10]) {
      final sx = (w * _pos(n)).floorToDouble() + 0.5;
      canvas.drawLine(Offset(sx, railY + 1), Offset(sx, railY + 7), stop);
      _label(canvas, '$n', sx, railY + 10, KvColor.inkMetaLow);
    }

    // The SAFE threshold — a named stop, not just a number, because it is the
    // point the user can stop watching.
    final safeX = (w * _pos(kSafeDepth)).floorToDouble() + 0.5;
    final safePaint = Paint()
      ..color = safe ? KvColor.ok : KvColor.inkMetaLow
      ..strokeWidth = 1.5
      ..isAntiAlias = false;
    canvas.drawLine(
      Offset(safeX, railY - 6),
      Offset(safeX, railY + 7),
      safePaint,
    );
    _label(
      canvas,
      'safe',
      safeX,
      railY + 10,
      safe ? KvColor.ok : KvColor.inkMetaLow,
    );

    // The thousand mark. Finality is carried by the mark CLOSING — an open
    // bracket that fills — rather than by a fourth hue the palette does not
    // have. Reaching it is the one moment on this screen worth marking.
    final mx = w - 1.5;
    final markPaint = Paint()
      ..color = settled ? KvColor.ok : KvColor.inkMeta
      ..strokeWidth = settled ? 3 : 1.5
      ..isAntiAlias = false;
    canvas.drawLine(Offset(mx, railY - 9), Offset(mx, railY + 9), markPaint);
    if (settled) {
      // The bracket closes: two short returns, like a gauge's end stop seated.
      canvas.drawLine(
        Offset(mx - 5, railY - 9),
        Offset(mx, railY - 9),
        markPaint,
      );
      canvas.drawLine(
        Offset(mx - 5, railY + 9),
        Offset(mx, railY + 9),
        markPaint,
      );
    }
    _label(
      canvas,
      settled ? 'final' : '1,000',
      mx + 1.5,
      railY + 10,
      settled ? KvColor.ok : KvColor.inkMeta,
      alignEnd: true,
    );
  }

  void _label(
    Canvas canvas,
    String text,
    double x,
    double y,
    Color color, {
    bool alignEnd = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: KvFont.mono,
          fontSize: 10,
          height: 14 / 10,
          letterSpacing: 0.8,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(alignEnd ? x - tp.width : x - tp.width / 2, y));
  }

  @override
  bool shouldRepaint(_GaugePainter old) => old.depth != depth;
}

// ─────────────────────────────────────────────────────────────────────────────
// Navigation — WITHDRAWN (D-190). Do not extract this.
//
// The founder judged it on glass and rejected it in favour of a Twitter-style
// PUSH nav from Claude Design: one that translates the whole app sideways
// rather than overlaying it, and therefore needs no blur at all. What survives
// is the reasoning below, not the shape — unequal destinations, one milled
// block with engraved PLANNED tags rather than four dead buttons, a count that
// is a number and never a dot, the ringed socket, and BG-13. Those go into the
// brief; everything geometric here is void.
//
// Navigation — summoned, unequal by design, and mortal.
//
// Not a rail and not a tab bar: a permanent bar spends the screen's most
// valuable strip on destinations most people open once a week, and it forces
// every future surface to fit five slots. This is summoned from the top corner,
// takes the screen's ONE blur, and dies with the lock (BG-13).
//
// **The plates are deliberately unequal**, because pretending six destinations
// matter the same amount is a lie the layout tells. Money is opened constantly,
// so it is taller, one tone lighter, and wears a teal indicator down its edge.
// Messages is plain. The unbuilt four are milled into ONE block with engraved
// PLANNED tags — so "not yet" reads as information rather than as damage, and
// four dead buttons do not sit at the same rank as two live ones.
// ─────────────────────────────────────────────────────────────────────────────

/// Three readings of the same panel. The founder's two notes were **anchor it
/// right** and **it is too wide** — 322dp on a 393dp screen is 82% of the
/// display, which is a drawer swallowing the app rather than a panel summoned
/// over it.
///
/// The trigger moves to the top-right with it. A right-anchored panel opened
/// from a left-corner button makes the hand cross the whole screen and then
/// come back; pairing them is what makes it one-handed, and it puts the
/// wordmark where a wordmark goes.
enum PanelStyle { panel, card, compact }

extension on PanelStyle {
  double get width => switch (this) {
    PanelStyle.panel => 288,
    PanelStyle.card => 268,
    PanelStyle.compact => 244,
  };

  /// The card floats clear of the edges, so it reads as an object laid over the
  /// screen rather than a drawer glued to its side.
  bool get floating => this == PanelStyle.card;

  /// Compact drops the one-line blurbs: names and tags only.
  bool get terse => this == PanelStyle.compact;

  String get label => switch (this) {
    PanelStyle.panel => 'A panel 288',
    PanelStyle.card => 'B card 268',
    PanelStyle.compact => 'C compact 244',
  };
}

class _Destination {
  const _Destination(this.glyph, this.name, this.blurb, {this.count});

  final _Glyph glyph;
  final String name;
  final String blurb;
  final String? count;
}

const _built = <_Destination>[
  _Destination(_Glyph.money, 'Money', 'your balance and everything that moved'),
  _Destination(
    _Glyph.chat,
    'Messages',
    'encrypted, on chain, no server',
    count: '2',
  ),
];

const _planned = <_Destination>[
  _Destination(_Glyph.games, 'Games', 'provably fair, player against player'),
  _Destination(_Glyph.contracts, 'Contracts', 'agreements with no admin key'),
  _Destination(_Glyph.finance, 'Finance', 'money owned by rules you can read'),
  _Destination(_Glyph.assets, 'Assets', 'tokens others issued, shown honestly'),
];

class _NavPanel extends StatelessWidget {
  const _NavPanel({
    required this.controller,
    required this.style,
    required this.onDismiss,
  });

  final AnimationController controller;
  final PanelStyle style;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = KvMotion.out.transform(controller.value);
        if (t == 0) return const SizedBox.shrink();
        return Stack(
          children: [
            // The screen's ONE live blur (BG-4), under a summoned layer and
            // never inside a scroll. The money behind stays legible as shape
            // but stops being readable as data — it is not the subject now.
            Positioned.fill(
              child: GestureDetector(
                onTap: controller.reverse,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: KvGlass.blurSigma * t,
                    sigmaY: KvGlass.blurSigma * t,
                  ),
                  child: Container(
                    color: KvColor.abyss.withValues(alpha: 0.62 * t),
                  ),
                ),
              ),
            ),
            Positioned(
              right: style.floating ? KvSpace.sm : 0,
              top: style.floating ? KvSpace.sm : 0,
              bottom: style.floating ? KvSpace.sm : 0,
              // Slides in from the right and settles — a short travel, fading
              // as it arrives, decelerating. Never a full-width race from off
              // screen, which reads as a drawer being yanked (BG-9).
              child: Transform.translate(
                offset: Offset(28 * (1 - t), 0),
                child: Opacity(
                  opacity: t,
                  child: _PanelBody(style: style),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({required this.style});

  final PanelStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: style.width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: KvColor.key,
        borderRadius: style.floating
            ? BorderRadius.circular(KvRadius.panel)
            : null,
        border: style.floating
            ? Border.all(color: KvColor.edgeHi)
            : const Border(left: BorderSide(color: KvColor.edgeHi)),
      ),
      child: SafeArea(
        top: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            KvSpace.sm,
            style.floating
                ? KvSpace.statusBarReserve
                : KvSpace.statusBarReserve + KvSpace.sm,
            KvSpace.sm,
            KvSpace.m,
          ),
          children: [
            Row(
              children: [
                const Text(
                  'KaspaVerse',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w600,
                    color: KvColor.inkNav,
                  ),
                ),
                const Spacer(),
                _PanelAction(_Glyph.lock, 'Lock', onTap: () {}),
              ],
            ),
            const SizedBox(height: KvSpace.l),

            // Money — taller, one tone lighter, teal down its edge. The one
            // teal emission this panel spends (BG-2).
            _DestinationPlate(
              _built[0],
              tall: true,
              current: true,
              terse: style.terse,
            ),
            const SizedBox(height: KvSpace.s),
            Builder(
              builder: (context) => _DestinationPlate(
                _built[1],
                terse: style.terse,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _MessagesPreview(),
                  ),
                ),
              ),
            ),

            const SizedBox(height: KvSpace.l),
            const Row(
              children: [
                // inkMeta, not the sub-AA grey the export used here — this is
                // information text and it lands on a raised panel.
                Text(
                  'ON THE ROADMAP',
                  style: TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 10,
                    height: 14 / 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.8,
                    color: KvColor.inkMeta,
                  ),
                ),
              ],
            ),
            const SizedBox(height: KvSpace.sm),

            // One milled block, not four buttons: rank follows reality.
            Container(
              decoration: BoxDecoration(
                color: KvColor.chip,
                borderRadius: BorderRadius.circular(KvRadius.panel),
                border: Border.all(color: KvColor.plateDivider),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < _planned.length; i++) ...[
                    if (i > 0)
                      Container(height: 1, color: KvColor.plateDivider),
                    _PlannedRow(_planned[i], terse: style.terse),
                  ],
                ],
              ),
            ),

            const SizedBox(height: KvSpace.l),
            Container(height: 1, color: KvColor.plateDivider),
            const SizedBox(height: KvSpace.sm),
            Builder(
              builder: (context) => _PanelAction(
                _Glyph.settings,
                'Splash & onboarding',
                wide: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _SweepPreview(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: KvSpace.s),
            Builder(
              builder: (context) => _PanelAction(
                _Glyph.lock,
                'Secret surfaces',
                wide: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _SecretPreview(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: KvSpace.s),
            const Text(
              'The panel does not survive a lock.',
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 11,
                height: 15 / 11,
                color: KvColor.etch,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A destination: its glyph seated in a ringed socket, its name, and one line
/// saying what it is for. The socket is what makes the panel read as a designed
/// object rather than a drawer of text.
class _DestinationPlate extends StatelessWidget {
  const _DestinationPlate(
    this.dest, {
    this.tall = false,
    this.current = false,
    this.terse = false,
    this.onTap,
  });

  final _Destination dest;
  final bool tall;
  final bool current;
  final bool terse;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: current,
      child: InkWell(
        onTap: onTap ?? () {},
        borderRadius: BorderRadius.circular(KvRadius.panel),
        child: Container(
          padding: EdgeInsets.fromLTRB(
            KvSpace.sm,
            tall ? KvSpace.m : KvSpace.sm,
            KvSpace.sm,
            tall ? KvSpace.m : KvSpace.sm,
          ),
          decoration: BoxDecoration(
            color: tall ? KvColor.summoned : KvColor.chip,
            borderRadius: BorderRadius.circular(KvRadius.panel),
            border: Border.all(
              color: tall ? KvColor.summonedEdge : KvColor.plateDivider,
            ),
          ),
          child: Row(
            children: [
              if (current) ...[
                Container(
                  width: 2,
                  height: tall ? 36 : 28,
                  decoration: BoxDecoration(
                    color: KvColor.primary,
                    borderRadius: BorderRadius.circular(KvRadius.pill),
                  ),
                ),
                const SizedBox(width: KvSpace.sm),
              ],
              _Socket(dest.glyph, lit: current),
              const SizedBox(width: KvSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      dest.name,
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: tall ? 17 : 15,
                        height: 22 / 17,
                        fontWeight: FontWeight.w600,
                        color: KvColor.ink,
                      ),
                    ),
                    if (!terse) ...[
                      const SizedBox(height: 1),
                      Text(
                        dest.blurb,
                        style: const TextStyle(
                          fontFamily: KvFont.ui,
                          fontSize: 11,
                          height: 15 / 11,
                          color: KvColor.inkMeta,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (dest.count != null)
                // A number, never a dot: a dot begs, and here begging costs the
                // user a fee.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: KvColor.keyPressed,
                    borderRadius: BorderRadius.circular(KvRadius.pill),
                    border: Border.all(color: KvColor.edgeHi),
                  ),
                  child: Text(
                    dest.count!,
                    style: const TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 11,
                      color: KvColor.ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlannedRow extends StatelessWidget {
  const _PlannedRow(this.dest, {this.terse = false});

  final _Destination dest;
  final bool terse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm, vertical: 10),
      child: Row(
        children: [
          _Socket(dest.glyph, dim: true),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dest.name,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 14,
                    height: 19 / 14,
                    fontWeight: FontWeight.w600,
                    color: KvColor.inkNav,
                  ),
                ),
                if (!terse)
                  Text(
                    dest.blurb,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 11,
                      height: 15 / 11,
                      color: KvColor.inkMeta,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: KvSpace.s),
          // Engraved, not stamped: recessed fill, hairline edge, mono caps.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: KvColor.well,
              borderRadius: BorderRadius.circular(KvRadius.chip),
              border: Border.all(color: KvColor.noticeEdge),
            ),
            child: const Text(
              'PLANNED',
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 9,
                height: 13 / 9,
                fontWeight: FontWeight.w500,
                letterSpacing: 1,
                color: KvColor.inkMeta,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ringed socket. A glyph sitting loose on a plate reads as clip art; the
/// same glyph seated in a machined ring reads as a control.
class _Socket extends StatelessWidget {
  const _Socket(this.glyph, {this.lit = false, this.dim = false});

  final _Glyph glyph;
  final bool lit;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: KvColor.well,
        border: Border.all(
          color: lit ? KvColor.primaryMuted : KvColor.hairline,
        ),
      ),
      child: Center(
        child: CustomPaint(
          size: const Size(18, 18),
          painter: _GlyphPainter(
            glyph,
            tone: dim ? KvColor.inkMeta : KvColor.inkNav,
          ),
        ),
      ),
    );
  }
}

class _PanelAction extends StatelessWidget {
  const _PanelAction(
    this.glyph,
    this.label, {
    required this.onTap,
    this.wide = false,
  });

  final _Glyph glyph;
  final String label;
  final VoidCallback onTap;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KvRadius.chip),
        child: Container(
          constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.s),
          child: Row(
            mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(16, 16),
                painter: _GlyphPainter(glyph, tone: KvColor.inkNav),
              ),
              const SizedBox(width: KvSpace.s),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  height: 18 / 13,
                  fontWeight: FontWeight.w600,
                  color: KvColor.inkBright,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Send — amount and destination. NOTHING signs here.
//
// Entry is cheap and reversible, so the screen stays light: no ceremony, no
// warnings, no friction proportional to a risk that has not been taken yet.
// Every blocked state says why in words and in amber, because amber means "this
// needs checking" and red would claim money is at risk when none is (BG-7).
//
// The amount pad is the secure keypad in its PLAIN skin — the same primitive
// that takes a passphrase. One muscle memory for the whole app, one codepath to
// audit, and amounts inherit the no-system-keyboard guarantee for free.
// ─────────────────────────────────────────────────────────────────────────────

enum SendState { empty, belowMinimum, invalidAddress, ready, everything }

extension on SendState {
  String get label => switch (this) {
    SendState.empty => 'empty',
    SendState.belowMinimum => 'below min',
    SendState.invalidAddress => 'bad address',
    SendState.ready => 'ready',
    SendState.everything => 'everything',
  };
}

const _available = '1,284.50270000';

class _SendPreview extends StatefulWidget {
  const _SendPreview();

  @override
  State<_SendPreview> createState() => _SendPreviewState();
}

class _SendPreviewState extends State<_SendPreview> {
  SendState _state = SendState.ready;

  String get _amount => switch (_state) {
    SendState.empty => '0',
    SendState.belowMinimum => '0.00000042',
    SendState.everything => '1,284.50169000',
    _ => '12.40000000',
  };

  String get _address => switch (_state) {
    SendState.empty => '',
    SendState.invalidAddress => 'kaspa:qpzt3vw8x2mne4ka0000',
    _ => 'kaspa:qpzt3vw8…x2mne4ka',
  };

  bool get _blocked =>
      _state == SendState.empty ||
      _state == SendState.belowMinimum ||
      _state == SendState.invalidAddress;

  String? get _why => switch (_state) {
    SendState.empty => 'Enter an amount and a destination',
    SendState.belowMinimum => 'This amount is below the network minimum',
    SendState.invalidAddress => 'That address is not a mainnet Kaspa address',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            _DetailRail(
              onBack: () => Navigator.of(context).pop(),
              title: 'Send',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
                children: [
                  const SizedBox(height: KvSpace.m),
                  const _RuledLabel('Amount'),
                  const SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          _amount,
                          style: TextStyle(
                            fontFamily: KvFont.mono,
                            fontSize: 32,
                            height: 38 / 32,
                            fontWeight: FontWeight.w500,
                            color: _state == SendState.empty
                                ? KvColor.inkMeta
                                : KvColor.ink,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'KAS',
                          style: TextStyle(
                            fontFamily: KvFont.mono,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.6,
                            color: KvColor.primaryMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: KvSpace.sm),
                  Container(height: 1, color: KvColor.hairline),
                  const SizedBox(height: KvSpace.s),
                  Row(
                    children: [
                      Text(
                        'available $_available',
                        style: const TextStyle(
                          fontFamily: KvFont.mono,
                          fontSize: 12,
                          height: 16 / 12,
                          color: KvColor.inkMetaLow,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Spacer(),
                      _MaxChip(
                        onTap: () =>
                            setState(() => _state = SendState.everything),
                      ),
                    ],
                  ),
                  const SizedBox(height: KvSpace.l),

                  const _RuledLabel('To'),
                  const SizedBox(height: 6),
                  _AddressField(
                    address: _address,
                    invalid: _state == SendState.invalidAddress,
                  ),

                  if (_state == SendState.everything) ...[
                    const SizedBox(height: KvSpace.sm),
                    // The one chip this screen ever wears. Amber because the
                    // truth needs attention, not because the user is wrong.
                    const _Notice(
                      'Sending everything leaves 0.00101000 KAS behind to '
                      'cover the fee. Nothing else will fit.',
                    ),
                  ],
                  if (_state == SendState.belowMinimum) ...[
                    const SizedBox(height: KvSpace.sm),
                    const _Notice(
                      'The network will not relay less than 0.00002036 KAS. '
                      'You are 0.00001994 KAS short.',
                    ),
                  ],
                  if (_state == SendState.invalidAddress) ...[
                    const SizedBox(height: KvSpace.sm),
                    const _Notice(
                      'That is 24 characters. A mainnet address is 67, and '
                      'this one fails its checksum.',
                    ),
                  ],
                  const SizedBox(height: KvSpace.l),
                  const _Keypad(),
                  const SizedBox(height: KvSpace.l),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                KvSpace.gutter,
                0,
                KvSpace.gutter,
                KvSpace.m,
              ),
              child: Column(
                children: [
                  _Action(
                    label: 'Review this send',
                    primary: !_blocked,
                    disabledReason: _why,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _ConfirmPreview(),
                      ),
                    ),
                  ),
                  if (!_blocked) ...[
                    const SizedBox(height: KvSpace.s),
                    const Text(
                      'Nothing is signed until you hold to send.',
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 11,
                        height: 15 / 11,
                        color: KvColor.inkMetaLow,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _Switcher(
              values: SendState.values,
              value: _state,
              label: (v) => v.label,
              onChanged: (v) => setState(() => _state = v),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddressField extends StatelessWidget {
  const _AddressField({required this.address, required this.invalid});

  final String address;
  final bool invalid;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.sm,
      ),
      constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
      decoration: BoxDecoration(
        // Entry is sunken (§1.1), and a blocked field is amber — never red.
        color: KvColor.control,
        borderRadius: BorderRadius.circular(KvRadius.control),
        border: Border.all(color: invalid ? KvColor.warn : KvColor.hairline),
      ),
      child: Row(
        children: [
          const _FieldAction(_Glyph.paste, 'Paste'),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: Text(
              address.isEmpty
                  ? 'Paste or scan a Kaspa address'
                  : compactAddress(address),
              maxLines: 1,
              // Never ellipsis on an address: a tail cut spends the prefix on
              // the scheme and throws away the last eight payload characters,
              // which is the exact `kaspa:q…` shape BG-15 forbids.
              overflow: TextOverflow.clip,
              softWrap: false,
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 13,
                height: 22 / 13,
                color: address.isEmpty ? KvColor.inkMeta : KvColor.ink,
              ),
            ),
          ),
          if (address.isNotEmpty)
            // It was styled as an action with no target and no semantics —
            // a control that looks pressable and is not (BG-12).
            Semantics(
              button: true,
              label: 'Clear the destination address',
              child: InkWell(
                onTap: () {},
                borderRadius: BorderRadius.circular(KvRadius.control),
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: KvSpace.touchTarget,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: KvSpace.s),
                  alignment: Alignment.center,
                  child: const Text(
                    'Clear',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: KvColor.primaryMuted,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(width: KvSpace.sm),
          const _FieldAction(_Glyph.scan, 'Scan a QR code'),
        ],
      ),
    );
  }
}

/// A ruled label: a short engraved dash, then the word. It is the smallest
/// machined gesture in the system and it costs one 8dp line.
class _RuledLabel extends StatelessWidget {
  const _RuledLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(width: 8, height: 1, color: KvColor.inkMeta),
      const SizedBox(width: KvSpace.s),
      _SoftLabel(text),
    ],
  );
}

/// An icon inside the address field: **20dp of glyph in a 48×48 target**, which
/// is what the code below actually builds. The first version of this comment
/// claimed 48 while the code shipped 28 wide — L121 by the same hand that wrote
/// L121, which is why item 0 exists.
class _FieldAction extends StatelessWidget {
  const _FieldAction(this.glyph, this.label);

  final _Glyph glyph;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(KvRadius.chip),
        child: SizedBox(
          width: KvSpace.touchTarget,
          height: KvSpace.touchTarget,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: _FieldGlyph(glyph: glyph),
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldGlyph extends StatelessWidget {
  const _FieldGlyph({this.glyph = _Glyph.paste});

  final _Glyph glyph;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(20, 20),
    painter: _GlyphPainter(glyph, tone: KvColor.inkMeta),
  );
}

/// Send max. It sits with `available` because that is the number it means, and
/// it is a chip rather than a button because it fills a field — it does not
/// commit anything.
class _MaxChip extends StatelessWidget {
  const _MaxChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Send the maximum, leaving only the fee',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KvRadius.control),
        child: Container(
          // 48, not 32. Re-skinning a control is the moment to re-measure it.
          constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: KvColor.control,
            borderRadius: BorderRadius.circular(KvRadius.control),
            border: Border.all(color: KvColor.edgeHi),
          ),
          child: const Text(
            'Send max',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 12,
              height: 16 / 12,
              fontWeight: FontWeight.w600,
              color: KvColor.inkBright,
            ),
          ),
        ),
      ),
    );
  }
}

/// **The compact form, computed here rather than trusted from the caller**
/// (BG-15): scheme + first 8 + last 8 of the PAYLOAD. Truncation that counts
/// from the front spends its whole budget on `kaspa:q`, which carries near-zero
/// distinguishing bits and is a gift to address poisoning.
String compactAddress(String full) {
  final colon = full.indexOf(':');
  if (colon < 0) return full;
  final scheme = full.substring(0, colon + 1);
  final payload = full.substring(colon + 1);
  if (payload.length <= 18) return full;
  return '$scheme${payload.substring(0, 8)}…'
      '${payload.substring(payload.length - 8)}';
}

/// Amber, with the exact number. "Too small" is a shrug; "you are 0.00001994
/// short" is something the user can act on (BG-11's three beats, compressed).
class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: KvSpace.m,
        vertical: KvSpace.sm,
      ),
      decoration: BoxDecoration(
        color: KvColor.noticeWarnFill,
        borderRadius: BorderRadius.circular(KvRadius.plate),
        border: Border.all(color: KvColor.noticeWarnEdge),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: _Lamp(KvColor.warn),
          ),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 19 / 13,
                color: KvColor.inkDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The secure keypad in its plain skin. The masked skin takes passphrases and
/// recovery words; this one takes amounts. Same primitive, same press feel,
/// same guarantee that the system keyboard never sees the input.
class _Keypad extends StatelessWidget {
  const _Keypad();

  static const _keys = [
    '1', '2', '3', //
    '4', '5', '6', //
    '7', '8', '9', //
    '.', '0', '⌫', //
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: KvSpace.s,
      crossAxisSpacing: KvSpace.s,
      childAspectRatio: 1.75,
      children: [
        for (final k in _keys)
          Material(
            color: KvColor.key,
            borderRadius: BorderRadius.circular(KvRadius.key),
            child: InkWell(
              onTap: () {},
              borderRadius: BorderRadius.circular(KvRadius.key),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(KvRadius.key),
                  border: Border.all(color: KvColor.keyEdge),
                ),
                child: Text(
                  k,
                  style: TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: k == '⌫' ? KvColor.inkMeta : KvColor.ink,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The signing ceremony — one surface, every action.
//
// It restates what the wallet ACTUALLY BUILT, never what was typed: all eight
// decimals, the full destination chunked in fours, the exact fee, the change
// coming back. Nothing signs on a tap; the hold is 800ms and never shortens,
// including under reduced motion; back always cancels safely.
//
// There is no undo on an unpatchable ledger, so every gram of safety in this
// app lives on this screen, before the signature.
// ─────────────────────────────────────────────────────────────────────────────

enum SignPhase { review, holding, prepared, sent, partial, failed }

extension on SignPhase {
  String get label => switch (this) {
    SignPhase.review => 'review',
    SignPhase.holding => 'holding',
    SignPhase.prepared => 'staged wait',
    SignPhase.sent => 'sent',
    SignPhase.partial => 'partial',
    SignPhase.failed => 'failed',
  };
}

class _ConfirmPreview extends StatefulWidget {
  const _ConfirmPreview();

  @override
  State<_ConfirmPreview> createState() => _ConfirmPreviewState();
}

class _ConfirmPreviewState extends State<_ConfirmPreview>
    with SingleTickerProviderStateMixin {
  SignPhase _phase = SignPhase.review;
  int _stage = 0;

  /// **800ms, and it is a constant with no configuration surface** (BG-6).
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: KvMotion.deliberate)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) _stagedWait();
        });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  void _down(_) {
    if (_phase != SignPhase.review) return;
    setState(() => _phase = SignPhase.holding);
    _hold.forward();
  }

  /// Releasing early always cancels. The ring falls back fast and decelerating
  /// — an early release is not a failure and must not feel like one.
  void _up(_) {
    if (_hold.isCompleted) return;
    _hold.reverse();
    setState(() => _phase = SignPhase.review);
  }

  /// The honest shape of a measured 1.3–3.8s submit→accepted. Each stage is
  /// NAMED, because an indefinite spinner over money is a lie about progress.
  void _stagedWait() {
    setState(() {
      _phase = SignPhase.prepared;
      _stage = 0;
    });
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _stage = 1);
    });
    Future<void>.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _stage = 2);
    });
    Future<void>.delayed(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _phase = SignPhase.sent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            _DetailRail(
              onBack: () => Navigator.of(context).pop(),
              title: 'Review this send',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
                children: [
                  const SizedBox(height: KvSpace.m),
                  const _RuledLabel('Sending'),
                  const SizedBox(height: 6),
                  // Every one of the eight decimals. This is a signing
                  // surface, and a hidden digit is a lie of omission (BG-6).
                  const Text(
                    '12.40000000 KAS',
                    style: TextStyle(
                      fontFamily: KvFont.mono,
                      fontSize: 32,
                      height: 38 / 32,
                      fontWeight: FontWeight.w500,
                      color: KvColor.ink,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: KvSpace.l),
                  const _RuledLabel('To'),
                  const SizedBox(height: 6),
                  const _ChunkedAddress(),
                  const SizedBox(height: KvSpace.l),
                  const _RowRule(),
                  const _DetailRow('Fee', '0.00001000 KAS', mono: true),
                  const _RowRule(),
                  const _DetailRow(
                    'Change back',
                    '1,272.10269000 KAS',
                    mono: true,
                  ),
                  const _RowRule(),
                  const SizedBox(height: KvSpace.m),
                  Row(
                    children: [
                      const _Lamp(KvColor.risk),
                      const SizedBox(width: KvSpace.sm),
                      const Expanded(
                        child: Text(
                          'Once this is signed it cannot be reversed.',
                          style: TextStyle(
                            fontFamily: KvFont.ui,
                            fontSize: 13,
                            height: 18 / 13,
                            color: KvColor.inkDim,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: KvSpace.l),
                  if (_phase == SignPhase.prepared) _StagedWait(stage: _stage),
                  if (_phase == SignPhase.sent) const _Outcome.sent(),
                  if (_phase == SignPhase.partial) const _Outcome.partial(),
                  if (_phase == SignPhase.failed) const _Outcome.failed(),
                  const SizedBox(height: KvSpace.l),
                ],
              ),
            ),
            if (_phase == SignPhase.review || _phase == SignPhase.holding)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  KvSpace.gutter,
                  0,
                  KvSpace.gutter,
                  KvSpace.m,
                ),
                child: _HoldToSign(progress: _hold, onDown: _down, onUp: _up),
              ),
            _Switcher(
              values: SignPhase.values,
              value: _phase,
              label: (v) => v.label,
              onChanged: (v) => setState(() {
                _phase = v;
                _stage = 2;
                _hold.value = v == SignPhase.review ? 0 : 1;
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// Groups of four, with the first and last group carrying extra weight. An
/// address-poisoning attack buys a prefix and a suffix that LOOK right; the
/// weighting puts the eye exactly where the attack has to succeed.
class _ChunkedAddress extends StatelessWidget {
  const _ChunkedAddress({this.full = _confirmAddress});

  final String full;

  /// 67 characters — `kaspa:` + a 61-char payload, which is what the network
  /// actually produces. A real payload yields 15 groups of four plus a
  /// **one-character weighted last group**, which is exactly where BG-15 puts
  /// the eye.
  ///
  /// **Taken from the Rust transport-store fixtures, not typed** (L125). The
  /// version this replaces was 68 characters under this same comment, so it
  /// chunked to a TWO-character last group and the ceremony was device-judged
  /// at the wrong width — the comment's reasoning was right and its data was
  /// not. `KvAddress`'s tests now assert the length.
  static const _confirmAddress =
      'kaspa:qp408svlz585vyvj50yaljm8xdxrkcmmed8vxlx0wf0cl5wpt3vzyh74xs46e';

  List<String> get _groups {
    final payload = full.substring(full.indexOf(':') + 1);
    final out = <String>[];
    for (var i = 0; i < payload.length; i += 4) {
      out.add(payload.substring(i, math.min(i + 4, payload.length)));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KvSpace.m),
      decoration: BoxDecoration(
        color: KvColor.well,
        borderRadius: BorderRadius.circular(KvRadius.plate),
        border: Border.all(color: KvColor.hairline),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          const Text(
            'kaspa:',
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: 13,
              height: 20 / 13,
              color: KvColor.inkMeta,
            ),
          ),
          for (var i = 0; i < groups.length; i++)
            Text(
              groups[i],
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 13,
                height: 20 / 13,
                // First and last groups weighted: an address-poisoning attack
                // buys a prefix and a suffix that LOOK right, so the eye is put
                // exactly where the attack has to succeed.
                fontWeight: (i == 0 || i == groups.length - 1)
                    ? FontWeight.w600
                    : FontWeight.w400,
                color: (i == 0 || i == groups.length - 1)
                    ? KvColor.ink
                    : KvColor.inkDim,
              ),
            ),
        ],
      ),
    );
  }
}

/// The hold. A 44dp ring inside a 64dp pill, filling over 800ms. **No tap path
/// bypasses it**, and the label names the action and its object — never
/// "Confirm" (BG-11).
///
/// **There is no haptic here and the previous docstring claimed one.** §6
/// requires `mediumImpact` at the threshold and `heavyImpact` on acceptance;
/// the prototype fires neither, and UX-4 wires them. Recorded rather than left
/// as a comment that describes a feature it does not implement (item 0).
class _HoldToSign extends StatelessWidget {
  const _HoldToSign({
    required this.progress,
    required this.onDown,
    required this.onUp,
  });

  final Animation<double> progress;
  final void Function(TapDownDetails) onDown;
  final void Function(TapUpDetails) onUp;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: onDown,
      onTapUp: onUp,
      onTapCancel: () => onUp(TapUpDetails(kind: PointerDeviceKind.touch)),
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, _) {
          final t = progress.value;
          return Container(
            height: 64,
            decoration: BoxDecoration(
              color: KvColor.control,
              borderRadius: BorderRadius.circular(KvRadius.control),
              border: Border.all(
                color: t > 0 ? KvColor.primaryMuted : KvColor.edgeHi,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: CustomPaint(painter: _RingPainter(t)),
                ),
                const SizedBox(width: KvSpace.sm),
                const Text(
                  'Hold to send 12.40000000 KAS',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w600,
                    color: KvColor.ink,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 3;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = KvColor.edgeHi,
    );

    // The arrow of the thing this control does, sitting inside the ring it
    // fills. Teal, because the sign ring is one of exactly three things in the
    // app that emit (BG-2) — and this is the same emission, not a second one.
    // Smaller than the ring it sits in: the ring is the mechanism, the arrow is
    // only its label. At full size it competed with the fill it annotates.
    final k = (size.width * 0.56) / 24;
    canvas.save();
    canvas.translate(size.width * 0.22, size.height * 0.22);
    final arrow = Paint()
      ..color = KvColor.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = KvGlyph.stroke * k
      ..strokeCap = KvGlyph.cap
      ..strokeJoin = StrokeJoin.miter;
    final a = Path()
      ..moveTo(12 * k, 17 * k)
      ..lineTo(12 * k, 7 * k)
      ..moveTo(8 * k, 11 * k)
      ..lineTo(12 * k, 7 * k)
      ..lineTo(16 * k, 11 * k);
    canvas.drawPath(a, arrow);
    canvas.restore();

    if (t <= 0) return;
    // The filling ring. Fat enough to read as a gauge closing rather than a
    // hairline creeping — this is the last thing that happens before money
    // leaves, and it should feel like a mechanism seating.
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * t,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round
        ..color = KvColor.primary,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t;
}

/// Signed → broadcast → accepted, each named as it happens. A single spinner
/// for two and a half seconds tells the user nothing about which half of the
/// operation could still fail.
class _StagedWait extends StatelessWidget {
  const _StagedWait({required this.stage});

  final int stage;

  static const _steps = [
    'Signed on this device',
    'Broadcast to the network',
    'Accepted by a node',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < _steps.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                _Lamp(i <= stage ? KvColor.ok : KvColor.warn),
                const SizedBox(width: KvSpace.sm),
                Expanded(
                  child: Text(
                    _steps[i],
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 13,
                      height: 18 / 13,
                      fontWeight: i == stage
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: i <= stage ? KvColor.ink : KvColor.inkMeta,
                    ),
                  ),
                ),
                if (i == stage && stage < 2) const _Cadence(running: true),
              ],
            ),
          ),
      ],
    );
  }
}

/// Three beats: what happened → what it means for the funds → what to do.
/// "Your funds are safe" appears ONLY when provably true — and then always.
class _Outcome extends StatelessWidget {
  const _Outcome.sent()
    : lamp = KvColor.ok,
      head = 'Sent',
      body = 'The network accepted it. It will settle over the next minutes.',
      safe = null,
      action = 'copy transaction id';
  const _Outcome.partial()
    : lamp = KvColor.risk,
      head = 'Partially sent',
      body =
          'One of two destinations went through. The second did not, and that '
          'amount is still yours.',
      safe = null,
      action = 'see what moved';
  const _Outcome.failed()
    : lamp = KvColor.warn,
      head = 'The network refused it',
      body = 'A node rejected the transaction before it was relayed.',
      safe = 'Your funds are safe — nothing left your wallet.',
      action = 'see the raw error';

  final Color lamp;
  final String head;
  final String body;
  final String? safe;
  final String action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KvSpace.m),
      decoration: BoxDecoration(
        color: KvColor.plate,
        borderRadius: BorderRadius.circular(KvRadius.panel),
        border: Border.all(color: KvColor.plateEdge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Lamp(lamp),
              const SizedBox(width: KvSpace.sm),
              Text(
                head,
                style: const TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 17,
                  height: 22 / 17,
                  fontWeight: FontWeight.w600,
                  color: KvColor.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: KvSpace.s),
          Text(
            body,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: KvColor.inkDim,
            ),
          ),
          if (safe != null) ...[
            const SizedBox(height: 6),
            Text(
              safe!,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 13,
                height: 19 / 13,
                fontWeight: FontWeight.w600,
                color: KvColor.ok,
              ),
            ),
          ],
          const SizedBox(height: KvSpace.sm),
          Text(
            action,
            style: const TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: KvColor.primaryMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Receive — the one light object in the app.
//
// Scannability is the function, so the tile is dark-on-light regardless of the
// theme and always will be: a dark QR defeats scanners, and a code that does
// not scan is decoration defeating purpose. It is framed like a paper token
// deliberately laid on the glass — not an apology for breaking the theme.
//
// Two forms of the same address, for two different jobs: the COMPACT form for a
// glance, and the CHUNKED form for reading character by character against
// whatever the other party is showing you. Copy always copies all 67.
// ─────────────────────────────────────────────────────────────────────────────

enum ReceiveState { ready, deriving, error }

extension on ReceiveState {
  String get label => switch (this) {
    ReceiveState.ready => 'ready',
    ReceiveState.deriving => 'deriving',
    ReceiveState.error => 'error',
  };
}

const _receiveAddress =
    'kaspa:qr7mzv4dka9tep0lxh2wnfscjg8y5u3e6vddwm0s3jnp4khce2muaq7lgfx9t';

class _ReceivePreview extends StatefulWidget {
  const _ReceivePreview();

  @override
  State<_ReceivePreview> createState() => _ReceivePreviewState();
}

class _ReceivePreviewState extends State<_ReceivePreview> {
  ReceiveState _state = ReceiveState.ready;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            _DetailRail(
              onBack: () => Navigator.of(context).pop(),
              title: 'Receive',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
                children: [
                  const SizedBox(height: KvSpace.m),
                  Center(child: _Tile(state: _state)),
                  const SizedBox(height: KvSpace.m),

                  // The glance form. Never `kaspa:q…` — a truncation that
                  // counts from the front spends its whole budget on the
                  // scheme and hands an attacker the rest (BG-15).
                  Center(
                    child: Text(
                      _state == ReceiveState.ready
                          ? compactAddress(_receiveAddress)
                          : '—',
                      style: const TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 15,
                        height: 22 / 15,
                        color: KvColor.ink,
                      ),
                    ),
                  ),
                  const SizedBox(height: KvSpace.l),

                  const _RuledLabel('Your address'),
                  const SizedBox(height: 6),
                  if (_state == ReceiveState.ready)
                    const _ChunkedAddress(full: _receiveAddress)
                  else
                    const _AddressPending(),
                  const SizedBox(height: KvSpace.m),

                  const Text(
                    'Scan to send KAS to this wallet',
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 13,
                      height: 19 / 13,
                      color: KvColor.inkMeta,
                    ),
                  ),
                  const SizedBox(height: KvSpace.l),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                KvSpace.gutter,
                0,
                KvSpace.gutter,
                KvSpace.m,
              ),
              child: _Action(
                label: 'Copy address',
                primary: _state == ReceiveState.ready,
                // BG-12: a disabled control always says why.
                disabledReason: _state == ReceiveState.ready
                    ? null
                    : 'No address yet',
                onTap: () {},
              ),
            ),
            _Switcher(
              values: ReceiveState.values,
              value: _state,
              label: (v) => v.label,
              onChanged: (v) => setState(() => _state = v),
            ),
          ],
        ),
      ),
    );
  }
}

/// **Every state keeps the tile's footprint**, so the layout never jumps under
/// a hand already reaching for it. Loading puts the cadence inside the same
/// square; error dashes the same square. A screen that reflows while the user
/// is aiming at it is a screen that makes them miss.
class _Tile extends StatelessWidget {
  const _Tile({required this.state});

  final ReceiveState state;

  static const double side = 248;

  @override
  Widget build(BuildContext context) {
    if (state == ReceiveState.ready) {
      return const QrTile(data: _receiveAddress, size: side);
    }
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(KvRadius.panel),
        border: Border.all(
          color: state == ReceiveState.error ? KvColor.warn : KvColor.hairline,
        ),
      ),
      child: state == ReceiveState.deriving
          ? const Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  height: 14,
                  child: Center(child: _Cadence(running: true)),
                ),
                SizedBox(height: KvSpace.sm),
                Text(
                  'Loading your address',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 13,
                    color: KvColor.inkMeta,
                  ),
                ),
              ],
            )
          : const Padding(
              padding: EdgeInsets.all(KvSpace.l),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Lamp(KvColor.warn),
                  SizedBox(height: KvSpace.sm),
                  Text(
                    'Could not load the receive address.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 14,
                      height: 20 / 14,
                      color: KvColor.inkDim,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _AddressPending extends StatelessWidget {
  const _AddressPending();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KvSpace.m),
      decoration: BoxDecoration(
        color: KvColor.well,
        borderRadius: BorderRadius.circular(KvRadius.plate),
        border: Border.all(color: KvColor.hairline),
      ),
      // BG-5: unknown renders `—`, never a placeholder shaped like an address.
      child: const Text(
        '—',
        style: TextStyle(
          fontFamily: KvFont.mono,
          fontSize: 13,
          height: 20 / 13,
          color: KvColor.inkMeta,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Messages.
//
// Copy is taken from the shipped screens, not invented. Two lanes: people
// already talking, and strangers asking to start. The request count is a
// number, never a dot — each request asks the user to spend, and a dot begs.
// ─────────────────────────────────────────────────────────────────────────────

class _Chat {
  const _Chat(this.who, this.sub, this.last, this.time, {this.unread});

  final String who;
  final String? sub;
  final String last;
  final String time;
  final String? unread;
}

const _chats = <_Chat>[
  _Chat('Ana', null, 'Settled — thank you again', '2 m', unread: '2'),
  _Chat('Marco', null, 'You: sending the file now', '1 h'),
  _Chat(
    'kaspa:qr7mzv4d…q7lgfx9t',
    'no local name set',
    'Invitation accepted',
    'Tue',
  ),
];

class _Request {
  const _Request(this.who, this.note);

  final String who;
  final String note;
}

const _requests = <_Request>[
  _Request('kaspa:qz9t2mvw…e4kaxh2w', '“Dana here — from the reading group”'),
  _Request('kaspa:qp0s3jnp…mua7lgfx', 'no note attached'),
];

class _MessagesPreview extends StatefulWidget {
  const _MessagesPreview();

  @override
  State<_MessagesPreview> createState() => _MessagesPreviewState();
}

class _MessagesPreviewState extends State<_MessagesPreview> {
  int _lane = 0;

  /// The overflow, on the shipped app's own strings. Destruction sits last and
  /// alone, in risk red, outside the reach of a mis-tap.
  void _showMore(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: KvColor.summoned,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(KvRadius.panel),
        ),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            KvSpace.gutter,
            KvSpace.m,
            KvSpace.gutter,
            KvSpace.m,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _RuledLabel('Messages'),
              const SizedBox(height: KvSpace.sm),
              _MoreRow(
                'History & backup',
                'Parks your conversation list on Kaspa, sealed to your own key',
                onTap: () => Navigator.of(context).pop(),
              ),
              const _RowRule(),
              _MoreRow(
                'Add contact',
                'Carries a 0.2 KAS bond — the network norm',
                onTap: () => Navigator.of(context).pop(),
              ),
              const _RowRule(),
              _MoreRow(
                'Delete all messages',
                'Every conversation, on this device',
                tone: KvColor.risk,
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            _DetailRail(
              onBack: () => Navigator.of(context).pop(),
              title: 'Messages',
              // Where the shipped app puts them: a history icon and an
              // overflow, top right. A full-width button for a rarely-used
              // backup surface was spending the thumb arc on the wrong thing.
              actions: [
                _RailAction(_Glyph.history, 'History & backup', onTap: () {}),
                _RailAction(
                  _Glyph.kebab,
                  'More',
                  onTap: () => _showMore(context),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                KvSpace.gutter,
                KvSpace.sm,
                KvSpace.gutter,
                KvSpace.sm,
              ),
              child: Row(
                children: [
                  _Lane(
                    label: 'Messages',
                    selected: _lane == 0,
                    onTap: () => setState(() => _lane = 0),
                  ),
                  const SizedBox(width: KvSpace.s),
                  _Lane(
                    label: 'Requests',
                    // A number in a quiet chip. Information, not alarm.
                    count: '${_requests.length}',
                    selected: _lane == 1,
                    onTap: () => setState(() => _lane = 1),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _lane == 0 ? const _ChatLane() : const _RequestLane(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                KvSpace.gutter,
                0,
                KvSpace.gutter,
                KvSpace.m,
              ),
              child: _Action(label: 'Add contact', primary: true, onTap: () {}),
            ),
          ],
        ),
      ),
    );
  }
}

class _Lane extends StatelessWidget {
  const _Lane({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KvRadius.control),
        child: Container(
          height: KvSpace.touchTarget,
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? KvColor.keyPressed : KvColor.control,
            borderRadius: BorderRadius.circular(KvRadius.control),
            border: Border.all(
              color: selected ? KvColor.edgeHi : KvColor.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? KvColor.ink : KvColor.inkDim,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text(
                  count!,
                  style: const TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 12,
                    color: KvColor.inkMeta,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatLane extends StatelessWidget {
  const _ChatLane();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      children: [
        for (var i = 0; i < _chats.length; i++) ...[
          if (i > 0) const _RowRule(),
          _ChatRow(_chats[i]),
        ],
      ],
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow(this.chat);

  final _Chat chat;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => _ThreadPreview(chat: chat)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: KvSpace.sm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.who,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 15,
                      height: 20 / 15,
                      fontWeight: FontWeight.w600,
                      color: KvColor.ink,
                    ),
                  ),
                  if (chat.sub != null)
                    Text(
                      chat.sub!,
                      style: const TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 11,
                        height: 15 / 11,
                        color: KvColor.etch,
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    chat.last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 13,
                      height: 18 / 13,
                      color: KvColor.inkMeta,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: KvSpace.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  chat.time,
                  style: const TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 11,
                    color: KvColor.inkMetaLow,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (chat.unread != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: KvColor.keyPressed,
                      borderRadius: BorderRadius.circular(KvRadius.control),
                      border: Border.all(color: KvColor.edgeHi),
                    ),
                    child: Text(
                      chat.unread!,
                      style: const TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 11,
                        color: KvColor.ink,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestLane extends StatelessWidget {
  const _RequestLane();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      children: [
        for (final r in _requests) ...[
          Container(
            margin: const EdgeInsets.only(bottom: KvSpace.sm),
            padding: const EdgeInsets.all(KvSpace.m),
            decoration: BoxDecoration(
              color: KvColor.plate,
              borderRadius: BorderRadius.circular(KvRadius.panel),
              border: Border.all(color: KvColor.plateEdge),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.who,
                  style: const TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 13,
                    height: 18 / 13,
                    color: KvColor.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  r.note,
                  style: const TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 13,
                    height: 18 / 13,
                    color: KvColor.inkMeta,
                  ),
                ),
                const SizedBox(height: KvSpace.sm),
                const Text(
                  // The accept-path string, not the invite-path one. This card
                  // is shown to the RECIPIENT, who did not pay the bond — the
                  // old copy told them it "comes back when they accept", about
                  // money that was never theirs.
                  'Accepting returns their 0.2 KAS bond and opens the '
                  'conversation.',
                  style: TextStyle(
                    fontFamily: KvFont.ui,
                    fontSize: 12,
                    height: 17 / 12,
                    // etch is 2.84:1 and never carries information alone.
                    color: KvColor.inkDim,
                  ),
                ),
                const SizedBox(height: KvSpace.sm),
                Row(
                  children: [
                    // Accept ends in an ellipsis: a ceremony follows, and it
                    // spends 0.2 KAS. Ignore costs nothing and says so by
                    // costing no ink.
                    _SmallAction('Accept…', onTap: () {}),
                    const SizedBox(width: KvSpace.sm),
                    const Text(
                      'Ignore',
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 13,
                        color: KvColor.inkMeta,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SmallAction extends StatelessWidget {
  const _SmallAction(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KvRadius.control),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: KvColor.control,
          borderRadius: BorderRadius.circular(KvRadius.control),
          border: Border.all(color: KvColor.edgeHi),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: KvColor.ink,
          ),
        ),
      ),
    );
  }
}

// ── The thread ───────────────────────────────────────────────────────────────

class _Msg {
  const _Msg(this.out, this.text, this.status, this.time, {this.ghost = false});

  final bool out;
  final String text;
  final String status;
  final String time;
  final bool ghost;
}

const _thread = <_Msg>[
  _Msg(false, 'Did the payment land?', 'final ✓', '09:41'),
  _Msg(
    true,
    'Yes — 24 KAS, already buried 214 blocks deep.',
    'final ✓ · fee 0.00021',
    '09:42',
  ),
  _Msg(true, 'Sending the invoice file now.', 'settling 3/10', '09:44'),
  _Msg(
    true,
    'And the follow-up for February.',
    'undone by a chain reorganisation — resending',
    '09:45',
    ghost: true,
  ),
  _Msg(
    true,
    'Ping me when it clears.',
    'failed — never left this device',
    '09:46',
  ),
];

class _ThreadPreview extends StatelessWidget {
  const _ThreadPreview({required this.chat});

  final _Chat chat;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            _DetailRail(
              onBack: () => Navigator.of(context).pop(),
              title: chat.who,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  KvSpace.gutter,
                  KvSpace.m,
                  KvSpace.gutter,
                  KvSpace.m,
                ),
                children: [for (final m in _thread) _Bubble(m)],
              ),
            ),
            const _Composer(),
          ],
        ),
      ),
    );
  }
}

/// Direction rides three ways: side, hue, and the tail corner. Status sits
/// UNDER the plate in mono — never inside it, where it would compete with the
/// words someone wrote.
class _Bubble extends StatelessWidget {
  const _Bubble(this.msg);

  final _Msg msg;

  @override
  Widget build(BuildContext context) {
    final settling = msg.status.startsWith('settling') || msg.ghost;
    return Padding(
      padding: const EdgeInsets.only(bottom: KvSpace.sm),
      child: Column(
        crossAxisAlignment: msg.out
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(maxWidth: 280),
            padding: const EdgeInsets.symmetric(
              horizontal: KvSpace.sm,
              vertical: KvSpace.s,
            ),
            decoration: BoxDecoration(
              color: msg.out ? KvColor.messageMine : KvColor.messageTheirs,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(KvRadius.bubble),
                topRight: const Radius.circular(KvRadius.bubble),
                bottomLeft: Radius.circular(
                  msg.out ? KvRadius.bubble : KvRadius.bubbleTail,
                ),
                bottomRight: Radius.circular(
                  msg.out ? KvRadius.bubbleTail : KvRadius.bubble,
                ),
              ),
              border: Border.all(
                color: msg.ghost
                    ? KvColor.warn
                    : msg.out
                    ? KvColor.messageMineEdge
                    : KvColor.messageTheirsEdge,
              ),
            ),
            child: Text(
              msg.text,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 21 / 15,
                color: KvColor.ink,
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${msg.time} · ${msg.status}',
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: 11,
              height: 15 / 11,
              color: settling ? KvColor.warn : KvColor.inkMetaLow,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// **One action, with the exact cost printed on the control that fires it.**
/// Founder directive; the carve-out is bound to `SignableKind::SelfSendFrame`,
/// so a message fires on a tap and a bond or a wager never does.
///
/// **And it is gated on a non-empty draft** — condition 5 of the eight
/// wallet-security set. A one-tap control that spends a fee must not be armed
/// while there is nothing to send. The prototype shows it always enabled; UX-6
/// wires the gate.
class _Composer extends StatelessWidget {
  const _Composer();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KvSpace.gutter,
        0,
        KvSpace.gutter,
        KvSpace.m,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
              padding: const EdgeInsets.symmetric(
                horizontal: KvSpace.m,
                vertical: KvSpace.sm,
              ),
              decoration: BoxDecoration(
                color: KvColor.control,
                borderRadius: BorderRadius.circular(KvRadius.control),
                border: Border.all(color: KvColor.hairline),
              ),
              child: const Text(
                'Encrypted message…',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 15,
                  height: 21 / 15,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ),
          const SizedBox(width: KvSpace.s),
          Semantics(
            button: true,
            label: 'Send, fee 0.00021 KAS',
            child: InkWell(
              onTap: () {},
              borderRadius: BorderRadius.circular(KvRadius.control),
              child: Container(
                height: KvSpace.touchTarget,
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
                decoration: BoxDecoration(
                  color: KvColor.primary,
                  borderRadius: BorderRadius.circular(KvRadius.control),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Send',
                      style: TextStyle(
                        fontFamily: KvFont.ui,
                        fontSize: 14,
                        height: 18 / 14,
                        fontWeight: FontWeight.w600,
                        color: KvColor.onPrimary,
                      ),
                    ),
                    // The exact fee, on the control that spends it. 11dp is
                    // the floor for anything a user must read (§2) — the
                    // export printed this at 8.
                    Text(
                      '0.00021 KAS',
                      style: TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 11,
                        height: 14 / 11,
                        fontWeight: FontWeight.w500,
                        color: KvColor.onPrimaryDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow(
    this.title,
    this.sub, {
    required this.onTap,
    this.tone = KvColor.ink,
  });

  final String title;
  final String sub;
  final VoidCallback onTap;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: KvSpace.touchTarget),
        padding: const EdgeInsets.symmetric(vertical: KvSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                height: 20 / 15,
                fontWeight: FontWeight.w600,
                color: tone,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              sub,
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 12,
                height: 16 / 12,
                color: KvColor.inkMeta,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Secret surfaces — READ THIS BEFORE EXTRACTING ANYTHING BELOW.
//
// These are LOOK REFERENCES. The phase file promotes this prototype to UX-7's
// input specification, and a mock promoted to a specification without the
// specification's constraints is how a security property gets designed away.
// Four prohibitions, from `wallet-security-auditor` at the UX-0 wrap (D-203):
//
//   1. **Real recovery words never render in Dart.** Reveal and verify live in
//      `android/.../RevealActivity.kt` and nowhere else (D-039); a word never
//      exists as a Dart `String` (INV-1). `_Reveal` and `_Verify` below are to
//      be DELETED, never extracted. UX-7's scope on those two screens is
//      restyling the native file.
//   2. **The verify board is all twelve words plus decoys on top, never a
//      subset.** A subset drawn from the answers IS the answer set. That
//      design was built, measured at 3/8, and reverted on 2026-08-16
//      (F1/D-136, amended D-161). `vault_architecture.md` "Verify step" owns
//      the mechanism; `RevealActivity.buildChipSet` owns the implementation.
//   3. **`SecretScreenGuard` is not chrome.** Any Dart secret surface UX-7 does
//      build — passphrase entry, unlock, lockout — keeps FLAG_SECURE, the
//      accessibility refusal, and the fail-closed posture on an unanswerable
//      a11y query. None of the three is visible in a mock.
//   4. **No copy affordance, no system keyboard, no variable-width mask.** This
//      file gets all three right by accident of being a mock. They are
//      load-bearing.
//
// BG-10: assume a watched screen. Reveal on hold, fixed-width masks (a variable
// mask leaks length), no copy path anywhere in the codebase, screenshots and the
// recents thumbnail blocked, typed only on the in-app keypad, shown once.
//
// Copy is the shipped app's. These five are the FLAG_SECURE list locked at
// P1 §0.6 — nothing here is a place to be clever.
// ─────────────────────────────────────────────────────────────────────────────

enum SecretScreen { passphrase, reveal, verify, verifyWrong, locked, lockout }

extension on SecretScreen {
  String get label => switch (this) {
    SecretScreen.passphrase => 'passphrase',
    SecretScreen.reveal => 'reveal',
    SecretScreen.verify => 'verify',
    SecretScreen.verifyWrong => 'wrong',
    SecretScreen.locked => 'locked',
    SecretScreen.lockout => 'lockout',
  };
}

/// Deliberately non-derivable. No screenshot of this document is worth
/// anything, and that is a shipping rule for marketing assets too.
const _words = <String>[
  'anchor',
  'gravity',
  'orbit',
  'ripple',
  'fossil',
  'cousin',
  'ladder',
  'engine',
  'saddle',
  'canyon',
  'velvet',
  'maple',
];

class _SecretPreview extends StatefulWidget {
  const _SecretPreview();

  @override
  State<_SecretPreview> createState() => _SecretPreviewState();
}

class _SecretPreviewState extends State<_SecretPreview> {
  SecretScreen _screen = SecretScreen.passphrase;
  bool _revealed = false;
  int _filled = 3;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            _DetailRail(
              onBack: () => Navigator.of(context).pop(),
              title: switch (_screen) {
                SecretScreen.passphrase => 'Create wallet',
                SecretScreen.reveal ||
                SecretScreen.verify ||
                SecretScreen.verifyWrong => 'Your recovery words',
                _ => 'Vault locked',
              },
            ),
            Expanded(child: _body()),
            _Switcher(
              values: SecretScreen.values,
              value: _screen,
              label: (v) => v.label,
              onChanged: (v) => setState(() {
                _screen = v;
                _revealed = false;
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() => switch (_screen) {
    SecretScreen.passphrase => _Passphrase(filled: _filled, onKey: _key),
    SecretScreen.reveal => _Reveal(
      revealed: _revealed,
      onHold: (v) => setState(() => _revealed = v),
    ),
    SecretScreen.verify => const _Verify(wrong: false),
    SecretScreen.verifyWrong => const _Verify(wrong: true),
    SecretScreen.locked => const _Gate(lockout: false),
    SecretScreen.lockout => const _Gate(lockout: true),
  };

  void _key(bool add) => setState(
    () => _filled = add ? (_filled + 1).clamp(0, 6) : (_filled - 1).clamp(0, 6),
  );
}

/// Six FIXED wells. A well per typed character would leak the length of the
/// passphrase to anyone watching the screen, which is the whole reason the
/// masked skin exists.
class _Passphrase extends StatelessWidget {
  const _Passphrase({required this.filled, required this.onKey});

  final int filled;
  final void Function(bool add) onKey;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      children: [
        const SizedBox(height: KvSpace.m),
        const Text(
          'Set an unlock passphrase',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 22,
            height: 28 / 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: KvColor.ink,
          ),
        ),
        const SizedBox(height: KvSpace.s),
        const Text(
          'Your 12 recovery words are the wallet. The passphrase only unlocks '
          'this phone.',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            height: 19 / 13,
            color: KvColor.inkMeta,
          ),
        ),
        const SizedBox(height: KvSpace.xl),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 6; i++)
              Container(
                width: 40,
                height: 48,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: KvColor.well,
                  borderRadius: BorderRadius.circular(KvRadius.key),
                  border: Border.all(
                    color: i < filled ? KvColor.edgeHi : KvColor.hairline,
                  ),
                ),
                child: i < filled
                    ? Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: KvColor.ink,
                        ),
                      )
                    : null,
              ),
          ],
        ),
        const SizedBox(height: KvSpace.xl),
        _SecureKeypad(onKey: onKey),
        const SizedBox(height: KvSpace.l),
      ],
    );
  }
}

/// The same primitive as the amount pad, in its masked skin. One muscle memory,
/// one codepath to audit — and the system keyboard, with its cloud dictionary,
/// never sees a character of this.
class _SecureKeypad extends StatelessWidget {
  const _SecureKeypad({required this.onKey});

  final void Function(bool add) onKey;

  static const _keys = [
    '1', '2', '3', //
    '4', '5', '6', //
    '7', '8', '9', //
    'ABC', '0', '⌫', //
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: KvSpace.s,
      crossAxisSpacing: KvSpace.s,
      childAspectRatio: 1.75,
      children: [
        for (final k in _keys)
          Material(
            color: KvColor.key,
            borderRadius: BorderRadius.circular(KvRadius.key),
            child: InkWell(
              onTap: () => onKey(k != '⌫' && k != 'ABC'),
              borderRadius: BorderRadius.circular(KvRadius.key),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(KvRadius.key),
                  border: Border.all(color: KvColor.keyEdge),
                ),
                child: Text(
                  k,
                  style: TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: k == 'ABC' ? 13 : 20,
                    fontWeight: FontWeight.w500,
                    color: (k == '⌫' || k == 'ABC')
                        ? KvColor.inkMeta
                        : KvColor.ink,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// **Reveal on hold, never a toggle**, and the veil is a fixed four-dot mask
/// rather than a blur — a blur of a real word leaks its length and its shape.
/// No copy affordance exists, here or anywhere in the codebase.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.revealed, required this.onHold});

  final bool revealed;
  final ValueChanged<bool> onHold;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      children: [
        const SizedBox(height: KvSpace.m),
        const Text(
          'Your twelve recovery words',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 22,
            height: 28 / 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: KvColor.ink,
          ),
        ),
        const SizedBox(height: KvSpace.s),
        const Text(
          'Shown once. Write them down — anyone with these words has the '
          'wallet.',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            height: 19 / 13,
            color: KvColor.inkMeta,
          ),
        ),
        const SizedBox(height: KvSpace.l),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: KvSpace.s,
          crossAxisSpacing: KvSpace.s,
          childAspectRatio: 2.6,
          children: [
            for (var i = 0; i < _words.length; i++)
              Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: KvColor.key,
                  borderRadius: BorderRadius.circular(KvRadius.key),
                  border: Border.all(color: KvColor.keyEdge),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${i + 1}'.padLeft(2, '0'),
                      style: const TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 11,
                        color: KvColor.inkMetaLow,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      // Fixed width whether hidden or shown: the mask must not
                      // report how long the word is.
                      revealed ? _words[i] : '••••',
                      style: TextStyle(
                        fontFamily: KvFont.mono,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: revealed ? KvColor.ink : KvColor.inkMeta,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: KvSpace.l),
        GestureDetector(
          onTapDown: (_) => onHold(true),
          onTapUp: (_) => onHold(false),
          onTapCancel: () => onHold(false),
          child: Container(
            height: KvSpace.control,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: revealed ? KvColor.keyPressed : KvColor.control,
              borderRadius: BorderRadius.circular(KvRadius.control),
              border: Border.all(
                color: revealed ? KvColor.primaryMuted : KvColor.edgeHi,
              ),
            ),
            child: Text(
              revealed ? 'Release to hide' : 'Hold to show your words',
              style: const TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: KvColor.ink,
              ),
            ),
          ),
        ),
        const SizedBox(height: KvSpace.l),
      ],
    );
  }
}

/// A **look reference only** — `RevealActivity.buildChipSet` owns this
/// ceremony and its security properties. A wrong answer is **amber, not red**:
/// a practice quiz cannot lose funds, and red stays rationed to money.
///
/// The board below is **all twelve words plus decoys on top**. The first
/// version was ten of twelve, which is the design that was measured at 3/8 and
/// reverted on 2026-08-16 — a subset drawn from the answers *is* the answer
/// set, and the docstring that used to sit here claimed "the decoys make a
/// lucky guess worthless" about a board where they did not.
class _Verify extends StatelessWidget {
  const _Verify({required this.wrong});

  final bool wrong;

  /// All twelve, plus decoys on top — never fewer (D-136, amended D-161).
  static const _pool = <String>[
    ..._words,
    'marble',
    'timber',
    'lantern',
    'harbour',
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      children: [
        const SizedBox(height: KvSpace.m),
        const Text(
          'Prove you saved them',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 22,
            height: 28 / 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: KvColor.ink,
          ),
        ),
        const SizedBox(height: KvSpace.s),
        const Text(
          'Tap word 4.',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 13,
            height: 19 / 13,
            color: KvColor.inkMeta,
          ),
        ),
        if (wrong) ...[
          const SizedBox(height: KvSpace.m),
          const _Notice('Not quite. Check your list and try again.'),
        ],
        const SizedBox(height: KvSpace.l),
        Wrap(
          spacing: KvSpace.s,
          runSpacing: KvSpace.s,
          children: [
            for (final w in _pool)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: KvSpace.m,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: KvColor.control,
                  borderRadius: BorderRadius.circular(KvRadius.control),
                  border: Border.all(
                    color: wrong && w == 'marble'
                        ? KvColor.warn
                        : KvColor.edgeHi,
                  ),
                ),
                child: Text(
                  w,
                  style: const TextStyle(
                    fontFamily: KvFont.mono,
                    fontSize: 13,
                    color: KvColor.ink,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: KvSpace.l),
      ],
    );
  }
}

/// The gate. Deliberately empty of everything, especially money — nothing
/// stale waits behind a lock (BG-13).
class _Gate extends StatelessWidget {
  const _Gate({required this.lockout});

  final bool lockout;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CustomPaint(
            size: Size(KvGlyph.grid, KvGlyph.grid),
            painter: _GlyphPainter(_Glyph.lock, tone: KvColor.inkNav),
          ),
          const SizedBox(height: KvSpace.m),
          const Text(
            'Vault locked',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 22,
              height: 28 / 22,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: KvColor.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            lockout
                ? 'Too many attempts. Wait a moment, then try again — your '
                      'funds are safe.'
                : 'Unlock to see your wallet.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 19 / 13,
              color: lockout ? KvColor.warn : KvColor.inkMeta,
            ),
          ),
          const SizedBox(height: KvSpace.l),
          if (lockout)
            const Text(
              '00:47',
              style: TextStyle(
                fontFamily: KvFont.mono,
                fontSize: 32,
                fontWeight: FontWeight.w500,
                color: KvColor.warn,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: _Action(
                label: 'Unlock vault',
                primary: true,
                onTap: () {},
              ),
            ),
          const SizedBox(height: KvSpace.m),
          const Text(
            'Use passphrase instead',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: KvColor.primaryMuted,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Network & connection.
//
// **The node picker half of this is SHIPPED** — `ui/node/node_screen.dart`,
// wired to the real seam and reachable from the network sheet (UX-1). What is
// still only drawn here is the rest of the surface: the explorer choice
// (D-192), the fiat rate's source (D-193), and the selectable ground when
// UX-3 adds it. Keep this until those land; it is the reference for them.
//
// A sovereignty statement wearing a diagnostic's precision: who serves you,
// how freshly, and the standing offer to serve yourself.
// ─────────────────────────────────────────────────────────────────────────────

class _NetworkPreview extends StatefulWidget {
  const _NetworkPreview();

  @override
  State<_NetworkPreview> createState() => _NetworkPreviewState();
}

class _NetworkPreviewState extends State<_NetworkPreview> {
  bool _ownNode = false;
  Explorer _explorer = Explorer.kaspaOrg;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            _DetailRail(
              onBack: () => Navigator.of(context).pop(),
              title: 'Node & connection',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
                children: [
                  const SizedBox(height: KvSpace.m),
                  const _RuledLabel('Serving you'),
                  const SizedBox(height: KvSpace.s),
                  Container(
                    padding: const EdgeInsets.all(KvSpace.m),
                    decoration: BoxDecoration(
                      color: KvColor.plate,
                      borderRadius: BorderRadius.circular(KvRadius.panel),
                      border: Border.all(color: KvColor.plateEdge),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const _Lamp(KvColor.ok),
                            const SizedBox(width: KvSpace.sm),
                            Expanded(
                              child: Text(
                                _ownNode
                                    ? '192.168.1.40:16110'
                                    : 'a public community node',
                                style: const TextStyle(
                                  fontFamily: KvFont.mono,
                                  fontSize: 13,
                                  height: 18 / 13,
                                  color: KvColor.ink,
                                ),
                              ),
                            ),
                            const _Cadence(running: true),
                          ],
                        ),
                        const SizedBox(height: KvSpace.sm),
                        const _RowRule(),
                        const _DetailRow('Latency', '84 ms', mono: true),
                        const _RowRule(),
                        const _DetailRow('DAA', '523,216,421', mono: true),
                      ],
                    ),
                  ),
                  const SizedBox(height: KvSpace.l),

                  // The node picker the sovereign-node session built the Rust,
                  // bridge and service layer for, with no way to reach it.
                  const _RuledLabel('Use my own node'),
                  const SizedBox(height: KvSpace.s),
                  KvToggle(
                    on: _ownNode,
                    title: 'Pin a node I run',
                    sub: _ownNode
                        ? 'A pinned node never silently falls back.'
                        : 'The wallet reaches Kaspa through public community '
                              'nodes.',
                    onChanged: (next) => setState(() => _ownNode = next),
                  ),
                  if (_ownNode) ...[
                    const SizedBox(height: KvSpace.sm),
                    const _AddressField(
                      address: '192.168.1.40:16110',
                      invalid: false,
                    ),
                  ],
                  const SizedBox(height: KvSpace.l),

                  const _RuledLabel('Explorer'),
                  const SizedBox(height: KvSpace.s),
                  Row(
                    children: [
                      for (final e in Explorer.values) ...[
                        _Pick(
                          label: e.label,
                          selected: e == _explorer,
                          onTap: () => setState(() => _explorer = e),
                        ),
                        const SizedBox(width: KvSpace.s),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Where “View in explorer” goes. It hands over the '
                    'transaction id and your network address.',
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 12,
                      height: 17 / 12,
                      color: KvColor.inkMeta,
                    ),
                  ),
                  const SizedBox(height: KvSpace.l),

                  const _RuledLabel('Rate'),
                  const SizedBox(height: KvSpace.s),
                  const KvToggle(
                    on: true,
                    title: 'Show a fiat value',
                    sub:
                        'api.kaspa.org · a price is the one thing here '
                        'consensus cannot check.',
                    onChanged: null,
                    disabledReason:
                        'The rate source is not built yet — this is a '
                        'drawing of where it lands.',
                  ),
                  const SizedBox(height: KvSpace.l),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pick extends StatelessWidget {
  const _Pick({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KvRadius.control),
        child: Container(
          height: KvSpace.touchTarget,
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.m),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? KvColor.keyPressed : KvColor.control,
            borderRadius: BorderRadius.circular(KvRadius.control),
            border: Border.all(
              color: selected ? KvColor.edgeHi : KvColor.hairline,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: KvFont.mono,
              fontSize: 12,
              color: selected ? KvColor.ink : KvColor.inkMeta,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The sweep: splash, the onboarding fork, and the stake surface.
//
// Copy from the shipped screens. The stake surface has no shipped copy — it is
// the extensibility proof, and it is marked as placeholder.
// ─────────────────────────────────────────────────────────────────────────────

enum SweepScreen { splash, fork }

extension on SweepScreen {
  String get label => switch (this) {
    SweepScreen.splash => 'splash',
    SweepScreen.fork => 'fork',
  };
}

class _SweepPreview extends StatefulWidget {
  const _SweepPreview();

  @override
  State<_SweepPreview> createState() => _SweepPreviewState();
}

class _SweepPreviewState extends State<_SweepPreview> {
  SweepScreen _screen = SweepScreen.fork;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KvColor.abyss,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: KvSpace.statusBarReserve),
            if (_screen != SweepScreen.splash)
              _DetailRail(
                onBack: () => Navigator.of(context).pop(),
                title: 'Your sovereign vault',
              ),
            Expanded(child: _body()),
            _Switcher(
              values: SweepScreen.values,
              value: _screen,
              label: (v) => v.label,
              onChanged: (v) => setState(() => _screen = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() => switch (_screen) {
    SweepScreen.splash => const _Splash(),
    SweepScreen.fork => const _Fork(),
  };
}

/// One breathing bar, no spinner. A splash that spins is telling the user
/// something is wrong before anything has happened.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'KaspaVerse',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 26,
              height: 32 / 26,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              color: KvColor.ink,
            ),
          ),
          SizedBox(height: KvSpace.s),
          Text(
            'Your sovereign vault',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 13,
              height: 18 / 13,
              color: KvColor.inkMeta,
            ),
          ),
          SizedBox(height: KvSpace.xl),
          _Cadence(running: true),
        ],
      ),
    );
  }
}

/// Two earned panels, weighted by likelihood. Most people arriving here are
/// creating, so create is the one that comes forward.
class _Fork extends StatelessWidget {
  const _Fork();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
      children: [
        const SizedBox(height: KvSpace.l),
        const Text(
          'Hold your own keys on Kaspa. Set up a new wallet, or restore one '
          'you already own.',
          style: TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 15,
            height: 22 / 15,
            color: KvColor.inkDim,
          ),
        ),
        const SizedBox(height: KvSpace.xl),
        const _ForkPanel(
          title: 'Create new wallet',
          sub: 'Twelve words, generated on this phone and shown once.',
          primary: true,
        ),
        const SizedBox(height: KvSpace.sm),
        const _ForkPanel(
          title: 'Restore existing wallet',
          sub: 'Type the words you already have.',
          primary: false,
        ),
        const SizedBox(height: KvSpace.xl),
        Row(
          children: [
            const _Lamp(KvColor.ok),
            const SizedBox(width: KvSpace.sm),
            const Expanded(
              child: Text(
                'Keys never leave this device, and never leave Rust.',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 12,
                  height: 17 / 12,
                  color: KvColor.inkMeta,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ForkPanel extends StatelessWidget {
  const _ForkPanel({
    required this.title,
    required this.sub,
    required this.primary,
  });

  final String title;
  final String sub;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {},
      borderRadius: BorderRadius.circular(KvRadius.panel),
      child: Container(
        padding: const EdgeInsets.all(KvSpace.m),
        decoration: BoxDecoration(
          color: primary ? KvColor.summoned : KvColor.plate,
          borderRadius: BorderRadius.circular(KvRadius.panel),
          border: Border.all(
            color: primary ? KvColor.summonedEdge : KvColor.plateEdge,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: primary ? 17 : 15,
                      height: 22 / 17,
                      fontWeight: FontWeight.w600,
                      color: KvColor.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: const TextStyle(
                      fontFamily: KvFont.ui,
                      fontSize: 12,
                      height: 17 / 12,
                      color: KvColor.inkMeta,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: KvSpace.sm),
            // The fork's single teal moment, on the path most people take.
            CustomPaint(
              size: const Size(20, 20),
              painter: _GlyphPainter(
                _Glyph.chevron,
                tone: primary ? KvColor.primary : KvColor.inkMeta,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
