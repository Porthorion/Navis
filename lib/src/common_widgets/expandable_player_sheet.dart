import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/motion_policy.dart';

/// A Symfonium-style bottom-sheet player transition.
///
/// The [fullPlayer] is always pre-built at full sheet size and stays hidden
/// while collapsed. Dragging the [miniPlayer] up moves the panel from the mini
/// player's top edge to the top of the sheet, one pixel per pixel of finger
/// travel. The panel is an opaque, repaint-isolated layer that only changes
/// position (no page layout, no opacity layer). It is painted above the page,
/// so from its first pixel of travel it covers whatever sits below its top
/// edge, such as a bottom navigation bar.
///
/// The ends are soft: over the first [edgeFade] of the travel the mini player
/// rides on top of the panel's top edge and fades out, and when collapsing it
/// fades back in on the edge as the panel lands, so nothing pops in one frame.
///
/// [onExpand] and [onCollapse] report a user gesture at drag release, while
/// the settle animation is still running, so a back press during the settle
/// already sees the player as open or closed.
class ExpandablePlayerSheet extends StatefulWidget {
  const new({
    required this.miniPlayer,
    required this.fullPlayer,
    required this.isExpanded,
    required this.onExpand,
    required this.onCollapse,
    this.onProgressChanged,
    this.onSwipeUp,
    this.onDragStart,
    this.dragEnabled = true,
    this.bottomInset = 0,
    super.key,
  });

  final Widget miniPlayer;
  final Widget fullPlayer;
  final bool isExpanded;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final ValueChanged<double>? onProgressChanged;

  /// Called when the user swipes up while the player is fully expanded.
  final VoidCallback? onSwipeUp;

  /// Called when the user starts dragging the sheet, before it moves.
  final VoidCallback? onDragStart;
  final bool dragEnabled;

  /// Space kept free below the mini player, such as a bottom navigation bar
  /// the sheet is allowed to cover when expanded.
  final double bottomInset;

  static const miniPlayerHeight = 64.0;

  /// Share of the travel over which the mini player rides the panel edge and
  /// fades. The shell eases the bottom navigation bar over the same range.
  static const double edgeFade = 0.15;

  /// Velocity threshold (px / s) for a fling gesture.
  static const double _flingThreshold = 300;

  @override
  State<ExpandablePlayerSheet> createState() => _ExpandablePlayerSheetState();
}

class _ExpandablePlayerSheetState extends State<ExpandablePlayerSheet>
    with SingleTickerProviderStateMixin {
  static const double _bottomQueueSwipeGuardHeight = 120;

  late AnimationController _controller;
  final _geometry = _SheetGeometry();
  bool _dragStartedInQueueGuardZone = false;

  /// Last state reported through [ExpandablePlayerSheet.onExpand] or
  /// [ExpandablePlayerSheet.onCollapse], or received as `isExpanded`. The
  /// widget's own `isExpanded` lags a frame behind a report, so completion of
  /// an instant (reduced-motion) settle would otherwise report it twice.
  late bool _reportedExpanded = widget.isExpanded;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 280),
      vsync: this,
    );

    _controller.addStatusListener(_onAnimationStatusChanged);
    _controller.addListener(_notifyProgressChanged);

    if (widget.isExpanded) {
      _controller.value = 1;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _notifyProgressChanged();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final duration = MotionPolicy.of(context).surface;
    _controller
      ..duration = duration
      ..reverseDuration = duration;
  }

  void _onAnimationStatusChanged(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed) {
      _report(expanded: true);
    } else if (status == AnimationStatus.dismissed) {
      _report(expanded: false);
    }
  }

  void _report({required bool expanded}) {
    if (_reportedExpanded == expanded) return;
    _reportedExpanded = expanded;
    if (expanded) {
      widget.onExpand();
    } else {
      widget.onCollapse();
    }
  }

  @override
  void didUpdateWidget(ExpandablePlayerSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded != oldWidget.isExpanded) {
      _reportedExpanded = widget.isExpanded;
      // A release already started this settle (and reported it, which is what
      // flipped `isExpanded`); restarting would cut a fast fling short.
      final status = widget.isExpanded
          ? AnimationStatus.forward
          : AnimationStatus.reverse;
      if (_controller.isAnimating && _controller.status == status) return;
      _settleTo(widget.isExpanded ? 1 : 0, velocity: 2.5);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_notifyProgressChanged);
    _controller.removeStatusListener(_onAnimationStatusChanged);
    _controller.dispose();
    super.dispose();
  }

  void _notifyProgressChanged() {
    widget.onProgressChanged?.call(_controller.value);
  }

  // -- Derived animations ---------------------------------------------------

  /// 0 = collapsed (mini player visible), 1 = expanded (full player visible).
  double get _progress => _controller.value;

  /// Mini player fades out over the first [ExpandablePlayerSheet.edgeFade] of
  /// the travel, riding the panel edge (see [_SheetLayout]).
  double get _miniOpacity =>
      1 - (_progress / ExpandablePlayerSheet.edgeFade).clamp(0.0, 1.0);

  // -- Gesture handling -----------------------------------------------------

  void _handleDragStart(DragStartDetails details) {
    _dragStartedInQueueGuardZone = _didDragStartInQueueGuardZone(details);
    widget.onDragStart?.call();
  }

  bool _didDragStartInQueueGuardZone(DragStartDetails details) {
    // The shell removes the bottom padding (and view padding) from this
    // subtree, so the system inset is read from the view itself, as Now
    // Playing does for its own bottom padding.
    final view = View.of(context);
    final guardHeight =
        _bottomQueueSwipeGuardHeight +
        view.viewPadding.bottom / view.devicePixelRatio +
        MediaQuery.systemGestureInsetsOf(context).bottom;
    return details.globalPosition.dy >=
        MediaQuery.sizeOf(context).height - guardHeight;
  }

  /// Distance the panel travels between collapsed and expanded; a finger delta
  /// of this many pixels moves the sheet from one edge to the other.
  // ponytail: the 1 px floor only guards a divide-by-zero; `collapsedTop` is
  // always the mini player's top (tens of px) on real layouts, so it is
  // unreachable today. Revisit if the sheet can ever be shorter than its mini
  // player.
  double get _travel => math.max(_geometry.collapsedTop, 1);

  void _handleDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    _controller.value = (_controller.value - delta / _travel).clamp(0.0, 1.0);
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final absVelocity = velocity.abs();

    if (absVelocity > ExpandablePlayerSheet._flingThreshold) {
      if (velocity < 0) {
        // Swipe up — expand
        if (_controller.value >= 0.97 && widget.onSwipeUp != null) {
          if (!_dragStartedInQueueGuardZone) {
            widget.onSwipeUp!();
          }
        } else {
          _settleTo(1, velocity: (absVelocity / _travel).clamp(1.0, 6.0));
          _report(expanded: true);
        }
      } else {
        // Swipe down — collapse
        _settleTo(0, velocity: (absVelocity / _travel).clamp(1.0, 6.0));
        _report(expanded: false);
      }
    } else {
      // Low velocity — snap to nearest edge.
      _snapToEdge();
    }

    _dragStartedInQueueGuardZone = false;
  }

  void _handleDragCancel() {
    // Gesture was cancelled (e.g. the system gesture recognizer claimed the
    // pointer, or a competing recognizer won the arena during a slow drag).
    // Snap to the nearest edge so the sheet never stays stuck.
    _dragStartedInQueueGuardZone = false;
    _snapToEdge();
  }

  /// Snap the sheet to the nearest edge (expanded or collapsed).
  void _snapToEdge() {
    if (_controller.value > 0.4) {
      _settleTo(1, velocity: 2.5);
      _report(expanded: true);
    } else {
      _settleTo(0, velocity: 2.5);
      _report(expanded: false);
    }
  }

  void _settleTo(double target, {required double velocity}) {
    if (MotionPolicy.of(context).reduceMotion) {
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _controller.value = target;
          }
        });
      } else {
        _controller.value = target;
      }
      return;
    }
    _controller.fling(velocity: target == 1 ? velocity : -velocity);
  }

  // -- Build ----------------------------------------------------------------

  /// Detector for one of the two drag surfaces (panel or mini player).
  Widget _dragSurface({
    required HitTestBehavior behavior,
    required Widget child,
  }) {
    final enabled = widget.dragEnabled;
    return GestureDetector(
      behavior: behavior,
      // Start tracking where the finger lands, so the first update carries the
      // touch slop and the panel edge stays under the finger.
      dragStartBehavior: DragStartBehavior.down,
      onVerticalDragStart: enabled ? _handleDragStart : null,
      onVerticalDragUpdate: enabled ? _handleDragUpdate : null,
      onVerticalDragEnd: enabled ? _handleDragEnd : null,
      onVerticalDragCancel: enabled ? _handleDragCancel : null,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomMultiChildLayout(
        delegate: _SheetLayout(
          progress: _controller,
          bottomInset: widget.bottomInset,
          geometry: _geometry,
        ),
        children: <Widget>[
          // ── Full player (rises from the mini player's top edge) ───────
          // Covers the page below its top edge and takes its hits. It stays mounted
          // (so opening it is instant) but hidden while collapsed, and a
          // disabled TickerMode stops its animations and pauses its provider
          // listeners, such as the 5-10 Hz position stream.
          LayoutId(
            id: _SheetSlot.panel,
            child: AnimatedBuilder(
              animation: _controller,
              child: _dragSurface(
                behavior: HitTestBehavior.opaque,
                child: RepaintBoundary(child: widget.fullPlayer),
              ),
              builder: (context, panel) {
                final progress = _controller.value;
                return Offstage(
                  offstage: progress == 0,
                  child: TickerMode(enabled: progress > 0, child: panel!),
                );
              },
            ),
          ),
          // ── Mini player (rides the panel edge, fades out) ─────────────
          // Painted above the panel, positioned on its top edge by
          // [_SheetLayout]. Only reachable while it is visible, so it cannot
          // intercept scrolls on content pages above, and the panel takes the
          // touches once it has faded.
          LayoutId(
            id: _SheetSlot.mini,
            child: AnimatedBuilder(
              animation: _controller,
              child: RepaintBoundary(child: widget.miniPlayer),
              builder: (context, mini) => IgnorePointer(
                ignoring: _progress >= ExpandablePlayerSheet.edgeFade,
                child: _dragSurface(
                  behavior: HitTestBehavior.translucent,
                  child: Opacity(opacity: _miniOpacity, child: mini),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _SheetSlot { panel, mini }

/// Where the sheet's collapsed edge is, measured by [_SheetLayout] so the drag
/// maths follows the real mini player height instead of a constant.
class _SheetGeometry {
  /// Distance from the sheet's top to the mini player's top.
  double collapsedTop = 0;
}

/// Places the mini player above [bottomInset] and slides the full player from
/// the mini player's top edge to the sheet's top, with the mini player riding
/// on the panel's top edge. Relayouts on every
/// animation tick, but only repositions the panel: its constraints never
/// change, so nothing inside the panel or the page behind the sheet is laid
/// out again.
class _SheetLayout extends MultiChildLayoutDelegate {
  new({
    required this.progress,
    required this.bottomInset,
    required this.geometry,
  }) : super(relayout: progress);

  final Animation<double> progress;
  final double bottomInset;
  final _SheetGeometry geometry;

  @override
  void performLayout(Size size) {
    final mini = layoutChild(
      _SheetSlot.mini,
      BoxConstraints(
        minWidth: size.width,
        maxWidth: size.width,
        maxHeight: size.height,
      ),
    );
    final miniTop = math.max<double>(
      0,
      size.height - bottomInset - mini.height,
    );

    layoutChild(_SheetSlot.panel, BoxConstraints.tight(size));
    geometry.collapsedTop = miniTop;
    final edge = Offset(0, miniTop * (1 - progress.value));
    positionChild(_SheetSlot.panel, edge);
    positionChild(_SheetSlot.mini, edge);
  }

  @override
  bool shouldRelayout(_SheetLayout oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.bottomInset != bottomInset;
}
