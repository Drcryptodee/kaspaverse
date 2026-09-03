import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/kv_window.dart';
import '../theme/tokens.dart';
import 'kv_glyph.dart';
import 'kv_address.dart';
import 'kv_mark.dart';
import 'kv_rows.dart';

/// One place the app can go, or one place it will be able to go.
///
/// **An unbuilt destination is not a disabled one** (§8). It renders with a
/// `chipLabel` tag saying so and takes no tap at all, because a control that
/// responds and does nothing teaches distrust of every other control on the
/// screen. [onTap] null *is* the unbuilt state — the two cannot drift apart
/// because they are one field.
@immutable
class KvDestination {
  const KvDestination({
    required this.mark,
    required this.label,
    this.onTap,
    this.tag,
  });

  final KvGlyph mark;
  final String label;

  /// Null ⇒ **not built yet**; [tag] is what the row says instead.
  final VoidCallback? onTap;

  /// The `chipLabel` a destination wears when it has nowhere to go.
  final String? tag;

  bool get built => onTap != null;
}

/// Where the navigation is, so a screen can stop drawing its own trigger.
///
/// [openDrawer] is null in every class where the drawer or the rail is already
/// standing: §3a.2 says the K avatar opens the drawer in `compact` and does
/// nothing anywhere else, **so the header drops it** rather than keeping a
/// control that is live in one window and inert in another.
class KvNavScope extends InheritedWidget {
  const KvNavScope({super.key, required this.openDrawer, required super.child});

  final VoidCallback? openDrawer;

  static KvNavScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KvNavScope>();

  @override
  bool updateShouldNotify(KvNavScope old) => old.openDrawer != openDrawer;
}

/// **The drawer, in three postures** (§4, §3a.2) — one widget, because a
/// second navigation surface is how two windows start disagreeing about where
/// the app can go.
///
///  * `compact` — the panel sits under the page and the page is **pushed**
///    296 dp right, rounded to [KvRadius.page], shadowed, scrimmed and blurred
///    (§1.8's five slices, and one of BG-31's exactly two blur call sites).
///    An edge swipe or the header's K avatar summons it, and it drag-follows
///    the finger unfiltered while touched, settling on `enter` (BG-9).
///  * `medium` — an 80 dp standing [KvRail]. No scrim, no push.
///  * `expanded`+ and tall — the standing drawer: the same panel, opaque on
///    [KvColor.shelf], with a [KvColor.hairline] on its right edge as its only
///    boundary.
///  * `expanded`+ and **short** — back to the rail: seven rows do not seat in
///    412 dp, and the class demotes rather than compressing them (row height
///    is fixed in every class, BG-33).
///
/// **It never survives a lock** (BG-13): the shell discards this whole subtree
/// at 0 ms, so the open state has nowhere to persist. That is by construction
/// rather than by a listener, which is the only way it stays true.
class KvNav extends StatefulWidget {
  const KvNav({
    super.key,
    required this.destinations,
    required this.footer,
    required this.selected,
    required this.child,
    this.header,
  });

  /// Wallet · Messages · Games · Finance · Identity (§4).
  final List<KvDestination> destinations;

  /// The wallet's identity block, at the head of the panel (D-260).
  final Widget? header;

  /// Settings and Lock, at the foot.
  final List<KvDestination> footer;

  /// Index into [destinations] of the page currently showing.
  final int selected;

  /// The page.
  final Widget child;

  /// The panel's width in every posture that shows it (§3a.3).
  static double get width => KvLayout.drawer;

  @override
  State<KvNav> createState() => _KvNavState();
}

class _KvNavState extends State<KvNav> with SingleTickerProviderStateMixin {
  /// **Built in `initState`, not `late final`.** A standing or rail posture
  /// never touches the controller, so a lazy field would first construct it
  /// inside `dispose()` — which reads `TickerMode` off an element that is
  /// already deactivated and throws while finalizing the tree.
  late final AnimationController _push;

  /// True while a finger is on the page. The drawer follows it **unfiltered**
  /// (BG-9) — no curve, no easing — and only the settle is animated.
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _push = AnimationController(vsync: this, duration: KvMotion.enter);
  }

  @override
  void dispose() {
    _push.dispose();
    super.dispose();
  }

  void _open() => _push.animateTo(1, curve: KvMotion.curve);

  void _close() => _push.animateBack(0, curve: KvMotion.curve);

  void _dragStart(DragStartDetails _) => _dragging = true;

  void _dragUpdate(DragUpdateDetails d) {
    _push.value = (_push.value + d.primaryDelta! / KvNav.width).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails d) {
    _dragging = false;
    // A flick decides on its own; a slow drag decides on where it stopped.
    final v = d.primaryVelocity ?? 0;
    if (v.abs() > 300) {
      v > 0 ? _open() : _close();
    } else {
      _push.value > 0.5 ? _open() : _close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final metrics = KvWindow.of(context);
    if (metrics.hasRail) {
      return KvNavScope(
        openDrawer: null,
        child: Row(
          children: [
            KvRail(
              destinations: widget.destinations,
              footer: widget.footer,
              selected: widget.selected,
            ),
            Expanded(child: widget.child),
          ],
        ),
      );
    }
    if (metrics.hasStandingDrawer) {
      return KvNavScope(
        openDrawer: null,
        child: Row(
          children: [
            SizedBox(
              width: KvNav.width,
              child: KvDrawer(
                destinations: widget.destinations,
                footer: widget.footer,
                selected: widget.selected,
                header: widget.header,
                // Standing: no scrim, no shadow, and the hairline is the only
                // boundary it is allowed (§3a.2).
                standing: true,
              ),
            ),
            Expanded(child: widget.child),
          ],
        ),
      );
    }
    return KvNavScope(openDrawer: _open, child: _pushed(context));
  }

  Widget _pushed(BuildContext context) {
    final reducedTransparency =
        MediaQuery.maybeOf(context)?.highContrast ?? false;
    return Stack(
      children: [
        // **The drawer's ground runs the full width, behind everything**
        // (founder ruling D-260). The page rounds to 36 dp when it is pushed,
        // and at the top and bottom of the divide that radius leaves a notch
        // the page no longer covers — which showed the `Scaffold`'s own ground
        // through, a second dark reading as a pair of quarter-circle nicks.
        // Painting `shelf` across the whole stack puts the drawer's own colour
        // in them, so the page reads as a rounded card standing ON the drawer
        // rather than as a shape cut out of the dark.
        const Positioned.fill(child: ColoredBox(color: KvColor.shelf)),
        // The panel is *under* the page, on the ground it lives on. It is
        // built once and stays built: rebuilding a navigation panel every
        // frame of a drag is how a drag drops frames.
        //
        // **But its tickers stop while it is hidden.** The header orb breathes
        // on a 3.2 s repeating controller (BG-9's second ambient loop), and
        // behind a closed, opaque page that is a frame produced every 16 ms
        // for something nobody can see. `TickerMode` is the framework's own
        // answer — the same mechanism that mutes a route covered by another —
        // and the panel itself is passed through as `child`, so the rebuild is
        // one wrapper rather than a navigation panel.
        Positioned.fill(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: KvNav.width,
              child: AnimatedBuilder(
                animation: _push,
                builder: (context, panel) =>
                    TickerMode(enabled: _push.value > 0, child: panel!),
                child: KvDrawer(
                  destinations: widget.destinations,
                  footer: widget.footer,
                  selected: widget.selected,
                  header: widget.header,
                  standing: false,
                  onNavigate: _close,
                ),
              ),
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _push,
          builder: (context, page) {
            final t = _push.value;
            return Transform.translate(
              offset: Offset(KvNav.width * t, 0),
              child: _PushedPage(
                t: t,
                reducedTransparency: reducedTransparency,
                onDismiss: t > 0 ? _close : null,
                dragging: _dragging,
                onDragStart: _dragStart,
                onDragUpdate: _dragUpdate,
                onDragEnd: _dragEnd,
                child: page!,
              ),
            );
          },
          child: widget.child,
        ),
      ],
    );
  }
}

/// The page while the drawer is open: §1.8's five slices, in order.
class _PushedPage extends StatelessWidget {
  const _PushedPage({
    required this.t,
    required this.reducedTransparency,
    required this.onDismiss,
    required this.dragging,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.child,
  });

  final double t;
  final bool reducedTransparency;
  final VoidCallback? onDismiss;
  final bool dragging;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final Widget child;

  /// The band an edge swipe starts in. `compact` only (§3a.2).
  static const double edge = 20;

  @override
  Widget build(BuildContext context) {
    final radius = KvRadius.page * t;
    Widget page = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        children: [
          child,
          // **Slices 1 and 2, and one of BG-31's exactly two call sites.**
          // The filter blurs what is painted behind it in this clip — which
          // is the page — so the drawer beneath reads as the thing in focus.
          // Under reduced transparency the blur is off and the scrim rises to
          // 80% (§1.8), because a user who asked for less glass gets less
          // glass, not a lighter version of it.
          if (t > 0)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: t < 1,
                child: reducedTransparency
                    ? ColoredBox(
                        color: KvColor.shelf.withValues(
                          alpha: KvGlass.reducedScrimOpacity * t,
                        ),
                      )
                    : BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: KvGlass.blurSigma * t,
                          sigmaY: KvGlass.blurSigma * t,
                        ),
                        child: ColoredBox(
                          color: KvColor.drawerScrim.withValues(
                            alpha: (KvColor.drawerScrim.a) * t,
                          ),
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
    // **No shadow on the divide** (founder ruling 2026-09-04, D-260). §1.8's
    // slice 3 gave the pushed page a `layerShadow` falling to its left. On
    // glass it reads as a seam drawn between two panels rather than as a page
    // lifted off a ground — the drawer is not *under* the page in the way a
    // sheet is under a screen, it is beside it. The scrim and the blur already
    // say which one is in focus, and they say it about the whole page rather
    // than about a strip of its edge.
    //
    // The other four slices are untouched: scrim, blur, the 36 dp radius and
    // the surface all stand.
    final drag = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: onDragStart,
      onHorizontalDragUpdate: onDragUpdate,
      onHorizontalDragEnd: onDragEnd,
      // A tap anywhere on a pushed page puts it back — the gesture every
      // drawer on the platform answers to, and it costs nothing.
      onTap: onDismiss,
    );
    // **Closed, the gesture lives in a 20 dp band at the left edge; open, it
    // is the whole page.** A horizontal drag detector across a closed page
    // would claim every sideways gesture the app will ever add (a segmented
    // control, a carousel, a swipe on a row) and would not be an *edge* swipe
    // at all, which is the only thing §3a.2 grants.
    return Stack(
      children: [
        page,
        if (t == 0)
          Positioned(top: 0, bottom: 0, left: 0, width: edge, child: drag)
        else
          Positioned.fill(child: drag),
      ],
    );
  }
}

/// The 296 dp panel (§4, as corrected against the intake render `S2 · Drawer`).
/// The wallet's identity at the head, the destinations, Settings and Lock at
/// the foot.
class KvDrawer extends StatelessWidget {
  const KvDrawer({
    super.key,
    required this.destinations,
    required this.footer,
    required this.selected,
    required this.standing,
    this.onNavigate,
    this.header,
  });

  final List<KvDestination> destinations;
  final List<KvDestination> footer;
  final int selected;

  /// `expanded`+ tall: opaque, no scrim, a hairline right edge as its only
  /// boundary.
  final bool standing;

  /// Called after a destination is taken, so a pushed drawer closes behind it.
  final VoidCallback? onNavigate;

  /// **Who you are in, not what the app is called** (founder ruling
  /// 2026-09-04, D-260, from the intake render `S2 · Drawer`).
  ///
  /// §4 put an orb and the `KaspaVerse` wordmark here. The render puts the
  /// **wallet's own name and its address**, and the founder's reason is a
  /// product one rather than a visual one: **this seat becomes the place a
  /// user switches wallets.** The app will hold several accounts on one phone,
  /// and the header is where you see which one you are in and, later, change
  /// it. A wordmark answers a question nobody standing in their own wallet is
  /// asking.
  ///
  /// It is **not tappable yet**, and deliberately: there is no second wallet
  /// and no switch path, and §8 forbids a control that answers a tap and does
  /// nothing. The seat is built; the mechanism is not.
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return _NavGround(
      standing: standing,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: KvSpace.s),
            if (header != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  KvSpace.s20,
                  KvSpace.m,
                  KvSpace.s20,
                  KvSpace.l,
                ),
                child: header!,
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < destinations.length; i++)
                      _DestinationRow(
                        destination: destinations[i],
                        active: i == selected,
                        onNavigate: onNavigate,
                      ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: KvSpace.s20),
              child: SizedBox(
                height: 1,
                child: ColoredBox(color: KvColor.hairline),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: KvSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final f in footer)
                    _DestinationRow(
                      destination: f,
                      active: false,
                      onNavigate: onNavigate,
                    ),
                ],
              ),
            ),
            const SizedBox(height: KvSpace.s),
          ],
        ),
      ),
    );
  }
}

/// The ground the drawer and the rail stand on — **and the text default they
/// would otherwise not have**.
///
/// `KvNav` sits above every `Scaffold` in the app, which is deliberate (it
/// wraps the page), but it means the panel inherits `WidgetsApp`'s fallback
/// `DefaultTextStyle` — the deliberately ugly one, carrying
/// `TextDecoration.underline`. Every `Kv*` style sets family, size, weight and
/// colour and leaves `decoration` alone, so the underline came through on
/// every destination label. Caught by looking at the contact sheet, which is
/// what the sheet is for.
class _NavGround extends StatelessWidget {
  const _NavGround({required this.standing, required this.child});

  final bool standing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle(
      style: const TextStyle(
        fontFamily: KvFont.ui,
        color: KvColor.ink,
        decoration: TextDecoration.none,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: KvColor.shelf,
          border: standing
              ? const Border(right: BorderSide(color: KvColor.hairline))
              : null,
        ),
        child: child,
      ),
    );
  }
}

class _DestinationRow extends StatelessWidget {
  const _DestinationRow({
    required this.destination,
    required this.active,
    required this.onNavigate,
  });

  final KvDestination destination;
  final bool active;
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final tap = destination.onTap;
    return KvRow(
      leading: active
          ? KvRowDisc.ours(mark: destination.mark, ring: KvColor.tealTintEdge)
          : KvRowDisc.neutral(mark: destination.mark),
      title: destination.label,
      trailing: destination.built ? null : _Tag(destination.tag ?? 'Next'),
      onTap: tap == null
          ? null
          : () {
              onNavigate?.call();
              tap();
            },
    );
  }
}

/// **The wallet you are standing in** — the drawer's header (D-260).
///
/// The K avatar is *ours* (§4): [KvColor.tealTint] with a
/// [KvColor.primaryMuted] initial, never [KvColor.primary]. The name sits over
/// the address in its compact form, through [KvAddress] — the one widget for
/// an address on every surface (BG-15), so the truncation counts payload
/// entropy here exactly as it does on Receive.
class KvWalletIdentity extends StatelessWidget {
  const KvWalletIdentity({super.key, required this.name, this.address});

  final String name;

  /// Null while the vault has not answered yet. The row renders the name
  /// alone rather than a placeholder — a line that appears one frame after
  /// launch is better than one that appears and then leaves (BG-8).
  final String? address;

  @override
  Widget build(BuildContext context) {
    final addr = address;
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: KvColor.tealTint,
            shape: BoxShape.circle,
          ),
          child: const Text(
            'K',
            style: TextStyle(
              fontFamily: KvFont.ui,
              fontSize: 17,
              height: 1,
              fontWeight: FontWeight.w700,
              fontVariations: KvWeight.w700,
              color: KvColor.primaryMuted,
            ),
          ),
        ),
        const SizedBox(width: KvSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
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
              if (addr != null) ...[
                const SizedBox(height: 2),
                KvAddress(addr, fontSize: 12),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A `chipLabel` tag on a destination that has nowhere to go yet (§4, §8).
/// [KvColor.inkDim] on [KvColor.chip] — `inkMeta` fails AA there (§1.4).
class _Tag extends StatelessWidget {
  const _Tag(this.words);

  final String words;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: KvSpace.s10,
      vertical: KvSpace.xs,
    ),
    decoration: BoxDecoration(
      color: KvColor.chip,
      borderRadius: BorderRadius.circular(KvRadius.control),
    ),
    child: Text(
      words,
      style: const TextStyle(
        fontFamily: KvFont.ui,
        fontSize: 11,
        height: 16 / 11,
        fontWeight: FontWeight.w600,
        fontVariations: KvWeight.w600,
        color: KvColor.inkDim,
      ),
    ),
  );
}

/// **The 80 dp standing rail** (§3a.1) — `medium` at any height, and
/// `expanded`+ when the window is too short to seat the drawer's rows.
///
/// The orb, five sockets with their names beneath, and Settings and Lock at
/// the foot. **The labels are Jakarta, not mono**: §3a.2 asks for
/// `metaMono`-*size* labels, and BG-30 says a word is set in Jakarta whatever
/// its size — mono never carries a word.
class KvRail extends StatelessWidget {
  const KvRail({
    super.key,
    required this.destinations,
    required this.footer,
    required this.selected,
  });

  final List<KvDestination> destinations;
  final List<KvDestination> footer;
  final int selected;

  @override
  Widget build(BuildContext context) {
    return _NavGround(
      standing: true,
      child: SizedBox(
        width: KvLayout.rail,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: KvSpace.m),
              const KvMark(size: 40),
              const SizedBox(height: KvSpace.m),
              // **The scroll region ends BETWEEN sockets, never through one.**
              //
              // Seven rows do not seat in 412 dp — which is why the class
              // demotes to a rail at all — so at `expanded short` the list
              // genuinely scrolls. Left to its own height it cut the third
              // socket through the middle of its disc, and a half-drawn glyph
              // reads as a paint fault rather than as *there is more*
              // (`ux-auditor`, UX-R1). A gradient fade is not available to fix
              // it: BG-4 forbids one anywhere.
              //
              // So the viewport is rounded DOWN to a whole number of sockets.
              // This measures the height this widget was given — it does not
              // choose a layout from a width, which is what BG-33 forbids.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final whole =
                        (box.maxHeight / _RailSocket.height).floor() *
                        _RailSocket.height;
                    // **`Align` is load-bearing, and its absence made the fix
                    // inert.** `Expanded` hands its child a *tight* height, so
                    // a bare `SizedBox(height: whole)` is discarded and the
                    // viewport stayed 180 dp — 2.368 sockets — which cut the
                    // third disc through its middle, exactly what this code
                    // exists to prevent. It shipped that way and unproven,
                    // which is why `ux_r1_shell_test.dart` now asserts the
                    // viewport is an integer multiple of the socket.
                    return Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        height: whole > 0 ? whole : box.maxHeight,
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              for (var i = 0; i < destinations.length; i++)
                                _RailSocket(
                                  destination: destinations[i],
                                  active: i == selected,
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              for (final f in footer)
                _RailSocket(destination: f, active: false),
              const SizedBox(height: KvSpace.s),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailSocket extends StatelessWidget {
  const _RailSocket({required this.destination, required this.active});

  final KvDestination destination;
  final bool active;

  /// **A socket's whole height, stated so the rail can end a scroll on one.**
  /// 8 + 40 disc + 4 + 16 label + 8. It is fixed, like every other height in
  /// the system (BG-33), and the label does not wrap — a destination's name is
  /// one or two words by construction.
  static const double height =
      KvSpace.s + KvSpace.rowDisc + KvSpace.xs + 16 + KvSpace.s;

  @override
  Widget build(BuildContext context) {
    final body = SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: KvSpace.s),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            active
                ? KvRowDisc.ours(
                    mark: destination.mark,
                    ring: KvColor.tealTintEdge,
                  )
                : KvRowDisc.neutral(mark: destination.mark),
            const SizedBox(height: KvSpace.xs),
            Text(
              destination.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: KvFont.ui,
                fontSize: 11,
                height: 16 / 11,
                fontWeight: FontWeight.w600,
                fontVariations: KvWeight.w600,
                // An unbuilt destination is quieter than a built one, and there
                // is no room out here for the tag the drawer's row carries.
                color: destination.built ? KvColor.inkDim : KvColor.inkMeta,
              ),
            ),
          ],
        ),
      ),
    );
    final tap = destination.onTap;
    if (tap == null) {
      return Semantics(
        label: '${destination.label}. ${destination.tag ?? 'Not built yet'}',
        child: ExcludeSemantics(child: body),
      );
    }
    return Semantics(
      button: true,
      selected: active,
      label: destination.label,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: tap,
          child: body,
        ),
      ),
    );
  }
}
