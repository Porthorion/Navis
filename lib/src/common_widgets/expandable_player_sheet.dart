import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:navis/src/theme/motion_policy.dart';

/// A Symfonium-style bottom-sheet player transition.
///
/// The [fullPlayer] is always pre-built at full screen height and positioned
/// off-screen below the viewport. Swiping up on the [miniPlayer] drives a
/// slide-up animation that translates the full player panel from `Offset(0,1)`
/// to `Offset(0,0)` — a GPU-composited transform with zero layout reflow.
/// The mini player fades out over the first 30 % of the gesture.
class ExpandablePlayerSheet extends StatefulWidget {
  const new({
    required this.miniPlayer,
    required this.fullPlayer,
    required this.isExpanded,
    required this.onExpand,
    required this.onCollapse,
    this.onProgressChanged,
    this.onSwipeUp,
    this.dragEnabled = true,
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
  final bool dragEnabled;

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

  /// The full player slides from just below the screen to its natural position.
  Offset get _slideOffset => Offset(0, 1 - _progress);

  /// Mini player fades out over the first 30 % of the expansion.
  double get _miniOpacity {
    final t = 1 - (_progress / 0.5).clamp(0.0, 1.0);
    return Curves.easeOutCubic.transform(t);
  }

  /// Keep the full player slightly faded near the end of collapse so the last
  /// few pixels don't visually "snap" as the mini player reappears.
  double get _fullOpacity {
    final t = (_progress / 0.92).clamp(0.0, 1.0);
    return Curves.easeOut.transform(t);
  }

  /// Mini player comes back with a subtle downward settle from above.
  double get _miniTranslateY {
    final t = (_progress / 0.45).clamp(0.0, 1.0);
    return -10 * Curves.easeOut.transform(t);
  }

  // -- Gesture handling -----------------------------------------------------

  void _handleDragStart(DragStartDetails details) {
    _dragStartedInQueueGuardZone = _didDragStartInQueueGuardZone(details);
  }

  bool _didDragStartInQueueGuardZone(DragStartDetails details) {
    final mq = MediaQuery.of(context);
    final guardHeight =
        _bottomQueueSwipeGuardHeight +
        mq.padding.bottom +
        mq.systemGestureInsets.bottom;
    return details.localPosition.dy >= mq.size.height - guardHeight;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    // Map finger delta to controller value. Screen height gives 1:1 tracking.
    final screenHeight = MediaQuery.of(context).size.height;
    if (screenHeight <= 0) return;
    final delta = details.primaryDelta ?? 0;
    final change = -delta / screenHeight;
    _controller.value = (_controller.value + change).clamp(0.0, 1.0);
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final absVelocity = velocity.abs();
    final screenHeight = MediaQuery.of(context).size.height;

    if (absVelocity > ExpandablePlayerSheet._flingThreshold) {
      if (velocity < 0) {
        // Swipe up — expand
        if (_controller.value >= 0.97 && widget.onSwipeUp != null) {
          if (!_dragStartedInQueueGuardZone) {
            widget.onSwipeUp!();
          }
        } else {
          final v = (absVelocity / screenHeight).clamp(1.0, 6.0);
          _settleTo(1, velocity: v);
          if (!widget.isExpanded) widget.onExpand();
        }
      } else {
        // Swipe down — collapse
        final v = (absVelocity / screenHeight).clamp(1.0, 6.0);
        _settleTo(0, velocity: v);
        if (widget.isExpanded) widget.onCollapse();
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
      if (!widget.isExpanded) widget.onExpand();
    } else {
      _settleTo(0, velocity: 2.5);
      if (widget.isExpanded) widget.onCollapse();
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final progress = _progress;

        return Stack(
          children: <Widget>[
            // ── Full player (slides in from below) ──────────────────────
            // The GestureDetector here is only active when progress >= 0.5
            // (expanding or fully expanded). When collapsed it is behind an
            // IgnorePointer so it never steals vertical scrolls from pages.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: progress < 0.5,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: widget.dragEnabled
                      ? _handleDragStart
                      : null,
                  onVerticalDragUpdate: widget.dragEnabled
                      ? _handleDragUpdate
                      : null,
                  onVerticalDragEnd: widget.dragEnabled ? _handleDragEnd : null,
                  onVerticalDragCancel: widget.dragEnabled
                      ? _handleDragCancel
                      : null,
                  // While fully collapsed the player stays mounted (so opening
                  // it is instant) but must not keep working: a disabled
                  // TickerMode stops its animations and pauses its provider
                  // listeners, such as the 5-10 Hz position stream.
                  child: TickerMode(
                    enabled: progress > 0,
                    child: Opacity(
                      opacity: _fullOpacity,
                      child: FractionalTranslation(
                        translation: _slideOffset,
                        child: widget.fullPlayer,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Mini player (fades out, anchored at bottom) ───────────
            // The GestureDetector here is only active when progress < 0.5
            // (collapsed or collapsing). It is scoped to the mini player
            // strip so it cannot intercept scrolls on content pages above.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: progress >= 0.5,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: widget.dragEnabled
                      ? _handleDragStart
                      : null,
                  onVerticalDragUpdate: widget.dragEnabled
                      ? _handleDragUpdate
                      : null,
                  onVerticalDragEnd: widget.dragEnabled ? _handleDragEnd : null,
                  onVerticalDragCancel: widget.dragEnabled
                      ? _handleDragCancel
                      : null,
                  child: Opacity(
                    opacity: _miniOpacity,
                    child: Transform.translate(
                      offset: Offset(0, _miniTranslateY),
                      child: widget.miniPlayer,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
