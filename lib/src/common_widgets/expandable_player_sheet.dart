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
/// position (no page layout, no opacity layer); the mini player fades out over
/// the first half of the gesture on top of it.
///
/// [onExpand] and [onCollapse] report a user gesture once the animation has
/// finished, so the state change never rebuilds the shell mid-animation.
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
    if (status == AnimationStatus.completed && !widget.isExpanded) {
      widget.onExpand();
    } else if (status == AnimationStatus.dismissed && widget.isExpanded) {
      widget.onCollapse();
    }
  }

  @override
  void didUpdateWidget(ExpandablePlayerSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded != oldWidget.isExpanded) {
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

  /// Mini player fades out over the first 30 % of the expansion.
  double get _miniOpacity {
    final t = 1 - (_progress / 0.5).clamp(0.0, 1.0);
    return Curves.easeOutCubic.transform(t);
  }

  /// Mini player comes back with a subtle downward settle from above.
  double get _miniTranslateY {
    final t = (_progress / 0.45).clamp(0.0, 1.0);
    return -10 * Curves.easeOut.transform(t);
  }

  // -- Gesture handling -----------------------------------------------------

  void _handleDragStart(DragStartDetails details) {
    _dragStartedInQueueGuardZone = _didDragStartInQueueGuardZone(details);
    widget.onDragStart?.call();
  }

  bool _didDragStartInQueueGuardZone(DragStartDetails details) {
    final guardHeight =
        _bottomQueueSwipeGuardHeight +
        MediaQuery.paddingOf(context).bottom +
        MediaQuery.systemGestureInsetsOf(context).bottom;
    return details.globalPosition.dy >=
        MediaQuery.sizeOf(context).height - guardHeight;
  }

  /// Distance the panel travels between collapsed and expanded; a finger delta
  /// of this many pixels moves the sheet from one edge to the other.
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
        }
      } else {
        // Swipe down — collapse
        _settleTo(0, velocity: (absVelocity / _travel).clamp(1.0, 6.0));
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
    _settleTo(_controller.value > 0.4 ? 1 : 0, velocity: 2.5);
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
          // Only reachable from progress >= 0.5 (expanding or expanded); when
          // collapsed it is behind an IgnorePointer so it never steals
          // vertical scrolls from pages. It stays mounted (so opening it is
          // instant) but hidden, and a disabled TickerMode stops its
          // animations and pauses its provider listeners, such as the
          // 5-10 Hz position stream.
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
                  child: IgnorePointer(
                    ignoring: progress < 0.5,
                    child: TickerMode(enabled: progress > 0, child: panel!),
                  ),
                );
              },
            ),
          ),

          // ── Mini player (fades out, anchored above the bottom inset) ──
          // Only reachable while progress < 0.5 (collapsed or collapsing).
          // It is scoped to the mini player strip so it cannot intercept
          // scrolls on content pages above.
          LayoutId(
            id: _SheetSlot.mini,
            child: AnimatedBuilder(
              animation: _controller,
              child: _dragSurface(
                behavior: HitTestBehavior.translucent,
                child: AnimatedBuilder(
                  animation: _controller,
                  child: RepaintBoundary(child: widget.miniPlayer),
                  builder: (context, mini) => Opacity(
                    opacity: _miniOpacity,
                    child: Transform.translate(
                      offset: Offset(0, _miniTranslateY),
                      child: mini,
                    ),
                  ),
                ),
              ),
              builder: (context, mini) =>
                  IgnorePointer(ignoring: _progress >= 0.5, child: mini),
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
/// the mini player's top edge to the sheet's top. Relayouts on every
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
    positionChild(_SheetSlot.mini, Offset(0, miniTop));

    layoutChild(_SheetSlot.panel, BoxConstraints.tight(size));
    geometry.collapsedTop = miniTop;
    positionChild(_SheetSlot.panel, Offset(0, miniTop * (1 - progress.value)));
  }

  @override
  bool shouldRelayout(_SheetLayout oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.bottomInset != bottomInset;
}
