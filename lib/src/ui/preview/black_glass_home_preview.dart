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

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

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
              const _NetworkChip(),
            ],
          ),
          const SizedBox(height: KvSpace.sm),
          _Figure(integer: integer, fraction: fraction),
          const SizedBox(height: KvSpace.s),
          _ValueLine(
            empty: integer == '0',
            rate: 0.0752,
            ageLabel: 'rate 2 m ago',
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
          child: CustomPaint(painter: _DatumPainter()),
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
  const _NetworkChip();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Mainnet. Open network and node settings',
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(KvRadius.pill),
        child: Container(
          constraints: const BoxConstraints(minHeight: KvSpace.xl),
          padding: const EdgeInsets.symmetric(
            horizontal: KvSpace.sm,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: KvColor.chip,
            borderRadius: BorderRadius.circular(KvRadius.pill),
            border: Border.all(color: KvColor.edgeHi),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _Lamp(KvColor.ok),
              const SizedBox(width: 7),
              const Text(
                'Mainnet',
                style: TextStyle(
                  fontFamily: KvFont.ui,
                  fontSize: 12,
                  height: 16 / 12,
                  fontWeight: FontWeight.w500,
                  color: KvColor.inkDim,
                ),
              ),
              const SizedBox(width: 5),
              CustomPaint(
                size: const Size(12, 12),
                painter: const _GlyphPainter(
                  _Glyph.chevron,
                  tone: KvColor.inkMeta,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the balance is worth, in fiat.
///
/// **Founder call, 2026-08-26 (D-186): fiat exists.** The rate comes from
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
        const SizedBox(width: KvSpace.s),
        Text(
          r == null ? 'no rate yet' : ageLabel,
          style: const TextStyle(
            fontFamily: KvFont.ui,
            fontSize: 11,
            height: 15 / 11,
            color: KvColor.etch,
          ),
        ),
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

/// The graduated datum. Long risers mark the ends, a taller notch marks the
/// decimal, and short graduations run between — a gauge's zero mark, at the
/// one place in the app a number needs to read as an instrument reading.
class _DatumPainter extends CustomPainter {
  const _DatumPainter({this.graduated = true});

  /// A graduated datum reads as a measuring scale. Ungraduated, it is simply
  /// the rule the figure stands on — which is what a balance actually wants.
  final bool graduated;

  @override
  void paint(Canvas canvas, Size size) {
    final rule = Paint()
      ..color = KvColor.datum
      ..strokeWidth = 1
      ..isAntiAlias = false;
    canvas.drawLine(Offset(0, 0.5), Offset(size.width, 0.5), rule);

    if (!graduated) {
      final stop = Paint()
        ..color = KvColor.primaryMuted
        ..strokeWidth = 1
        ..isAntiAlias = false;
      canvas.drawLine(const Offset(0.5, 0), const Offset(0.5, 5), stop);
      canvas.drawLine(
        Offset(size.width - 0.5, 0),
        Offset(size.width - 0.5, 5),
        stop,
      );
      return;
    }

    // Graduations every 12dp, taller every fifth — the rhythm of a scale.
    final tick = Paint()
      ..color = KvColor.datum
      ..strokeWidth = 1
      ..isAntiAlias = false;
    var i = 0;
    for (double x = 0; x <= size.width; x += 12, i++) {
      final h = i % 5 == 0 ? 4.0 : 2.0;
      canvas.drawLine(Offset(x + 0.5, 1), Offset(x + 0.5, 1 + h), tick);
    }

    // The end stops, in ambient teal: a calibration mark, structural rather
    // than decorative, and the brand sitting on the instrument itself.
    final stop = Paint()
      ..color = KvColor.primaryMuted
      ..strokeWidth = 1
      ..isAntiAlias = false;
    canvas.drawLine(const Offset(0.5, 0), const Offset(0.5, 7), stop);
    canvas.drawLine(
      Offset(size.width - 0.5, 0),
      Offset(size.width - 0.5, 7),
      stop,
    );
  }

  @override
  bool shouldRepaint(_DatumPainter old) => old.graduated != graduated;
}

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

/// The cadence — five bars breathing at block rhythm. It is the app's ONE
/// loading indicator and its liveness signal at once, and it **freezes** the
/// instant the link dies, which is what makes "live" a felt thing rather than
/// a claimed one (BG-8).
class _Cadence extends StatefulWidget {
  const _Cadence({required this.running});

  final bool running;

  @override
  State<_Cadence> createState() => _CadenceState();
}

class _CadenceState extends State<_Cadence>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: KvMotion.breath,
  );

  static const _heights = <double>[6, 10, 14, 10, 6];

  @override
  void initState() {
    super.initState();
    if (widget.running) _c.repeat();
  }

  @override
  void didUpdateWidget(_Cadence old) {
    super.didUpdateWidget(old);
    if (widget.running && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.running && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stagger =
        KvMotion.cadenceStagger.inMilliseconds / KvMotion.breath.inMilliseconds;
    return ExcludeSemantics(
      child: SizedBox(
        height: 14,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < _heights.length; i++) ...[
                if (i > 0) const SizedBox(width: 3),
                Container(
                  width: 3,
                  height: _heights[i],
                  color: KvColor.primary.withValues(
                    alpha: widget.running
                        ? 0.15 +
                              0.85 *
                                  (0.5 -
                                          0.5 *
                                              math.cos(
                                                2 *
                                                    math.pi *
                                                    ((_c.value - i * stagger) %
                                                        1.0),
                                              ))
                                      .clamp(0.0, 1.0)
                        : KvFreshness.opacityStale,
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
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
                if (variant.instrumentRegister)
                  const _MicroLabel('COMPLETE TO 14:02', tone: KvColor.warn)
                else
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
        ),
        const SizedBox(height: KvSpace.m),
        for (final e in _entries) _Row(entry: e, stale: state.stale),
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
                      overflow: TextOverflow.ellipsis,
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
            child: _Action(label: 'Receive', primary: empty, onTap: () {}),
          ),
          const SizedBox(width: KvSpace.sm),
          Expanded(
            child: _Action(
              label: 'Send',
              primary: !empty,
              // BG-12: a disabled control always says why, in words.
              disabledReason: empty ? 'Nothing to send yet' : null,
              onTap: () {},
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
            borderRadius: BorderRadius.circular(KvRadius.panel),
            child: Container(
              height: KvSpace.control,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // Teal fills exactly one thing on this screen: the single
                // primary action (BG-2).
                color: primary && !disabled ? KvColor.primary : KvColor.chip,
                borderRadius: BorderRadius.circular(KvRadius.panel),
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

enum _Glyph {
  arrowIn,
  arrowOut,
  selfSend,
  navDots,
  diamond,
  chevron,
  money,
  chat,
  games,
  contracts,
  finance,
  assets,
  settings,
  lock,
}

/// Every glyph is 1–3 strokes on a 24dp grid at 1.75dp with square caps — the
/// icon set is drawn, not imported, which is a supply-chain decision (INV-7)
/// as much as a visual one. This is also where most of the machined character
/// actually lives, so the stroke discipline is not negotiable.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, {this.tone = KvColor.inkMeta});

  final _Glyph glyph;
  final Color tone;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / KvGlyph.grid;
    final p = Paint()
      ..color = tone
      ..style = PaintingStyle.stroke
      ..strokeWidth = KvGlyph.stroke * s
      ..strokeCap = KvGlyph.cap
      ..strokeJoin = StrokeJoin.miter;

    Path path(List<List<double>> pts) {
      final path = Path();
      for (final seg in pts) {
        path.moveTo(seg[0] * s, seg[1] * s);
        for (var i = 2; i < seg.length; i += 2) {
          path.lineTo(seg[i] * s, seg[i + 1] * s);
        }
      }
      return path;
    }

    switch (glyph) {
      case _Glyph.arrowIn:
        canvas.drawPath(
          path([
            [12, 4, 12, 15],
            [7, 10, 12, 15, 17, 10],
            [5, 20, 19, 20],
          ]),
          p,
        );
      case _Glyph.arrowOut:
        canvas.drawPath(
          path([
            [12, 20, 12, 9],
            [7, 14, 12, 9, 17, 14],
            [5, 4, 19, 4],
          ]),
          p,
        );
      case _Glyph.selfSend:
        canvas.drawPath(
          path([
            [5, 8, 16, 8],
            [13, 5, 16, 8, 13, 11],
            [19, 16, 8, 16],
            [11, 19, 8, 16, 11, 13],
          ]),
          p,
        );
      case _Glyph.navDots:
        final dot = Paint()..color = KvColor.ink;
        for (final c in const [
          Offset(7.5, 7.5),
          Offset(16.5, 7.5),
          Offset(7.5, 16.5),
          Offset(16.5, 16.5),
        ]) {
          canvas.drawCircle(Offset(c.dx * s, c.dy * s), 2.5 * s, dot);
        }
      case _Glyph.money:
        // A note, not a coin: a circle with strokes through it reads as a
        // symbol to be decoded, and a glyph you decode has already failed.
        canvas.drawPath(
          path([
            [3.5, 6.5, 20.5, 6.5, 20.5, 17.5, 3.5, 17.5, 3.5, 6.5],
          ]),
          p,
        );
        canvas.drawCircle(Offset(12 * s, 12 * s), 2.6 * s, p);
      case _Glyph.chat:
        canvas.drawPath(
          path([
            [4.5, 5.5, 19.5, 5.5, 19.5, 15.5, 9.5, 15.5, 5.5, 19.5, 5.5, 5.5],
          ]),
          p,
        );
      case _Glyph.games:
        canvas.drawPath(
          path([
            [5, 5, 19, 5, 19, 19, 5, 19, 5, 5],
          ]),
          p,
        );
        final dot = Paint()..color = tone;
        for (final c in const [
          Offset(9, 9),
          Offset(15, 9),
          Offset(9, 15),
          Offset(15, 15),
        ]) {
          canvas.drawCircle(Offset(c.dx * s, c.dy * s), 1.4 * s, dot);
        }
      case _Glyph.contracts:
        canvas.drawPath(
          path([
            [7, 4, 17, 4, 17, 20, 7, 20, 7, 4],
            [10, 9, 14, 9],
            [10, 13, 14, 13],
          ]),
          p,
        );
      case _Glyph.finance:
        // A trend on a baseline. The export's three-bar mark read as "++".
        canvas.drawPath(
          path([
            [4, 19, 20, 19],
            [5, 15, 9.5, 10.5, 13.5, 13.5, 19, 7],
            [15, 7, 19, 7, 19, 11],
          ]),
          p,
        );
      case _Glyph.assets:
        canvas.drawPath(
          path([
            [12, 4, 20, 8.5, 20, 15.5, 12, 20, 4, 15.5, 4, 8.5, 12, 4],
          ]),
          p,
        );
      case _Glyph.settings:
        // Sliders. A cross-haired dot is a target, not a setting.
        canvas.drawPath(
          path([
            [4, 7, 20, 7],
            [4, 12, 20, 12],
            [4, 17, 20, 17],
          ]),
          p,
        );
        final knob = Paint()..color = tone;
        for (final c in const [Offset(9, 7), Offset(15, 12), Offset(11, 17)]) {
          canvas.drawCircle(Offset(c.dx * s, c.dy * s), 2.1 * s, knob);
        }
      case _Glyph.lock:
        canvas.drawPath(
          path([
            [6, 11, 18, 11, 18, 20, 6, 20, 6, 11],
          ]),
          p,
        );
        final shackle = Path()
          ..addArc(
            Rect.fromCircle(center: Offset(12 * s, 11 * s), radius: 4 * s),
            math.pi,
            math.pi,
          );
        canvas.drawPath(shackle, p);
      case _Glyph.chevron:
        canvas.drawPath(
          path([
            [9, 5, 16, 12, 9, 19],
          ]),
          p,
        );
      case _Glyph.diamond:
        canvas.drawPath(
          path([
            [12, 4, 20, 12, 12, 20, 4, 12, 12, 4],
          ]),
          p,
        );
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.tone != tone;
}

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
                  const _DetailRow(
                    'From',
                    'kaspa:qz0k4vnr…s8fjm2wa',
                    mono: true,
                  ),
                  const _DetailRow('Fee', '0.00001000 KAS', mono: true),
                  const _DetailRow('Accepted', '14:02:41 · 26 Aug 2026'),
                  const _DetailRow('DAA', '523,216,421', mono: true),
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
  const _DetailRail({required this.onBack});

  final VoidCallback onBack;

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
          const Text(
            'Transaction',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: KvColor.inkDim,
            ),
          ),
          const Spacer(),
          const SizedBox(width: KvSpace.touchTarget),
        ],
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
            _DestinationPlate(_built[1], terse: style.terse),

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
            _PanelAction(_Glyph.settings, 'Settings', onTap: () {}, wide: true),
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
  });

  final _Destination dest;
  final bool tall;
  final bool current;
  final bool terse;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: current,
      child: InkWell(
        onTap: () {},
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
