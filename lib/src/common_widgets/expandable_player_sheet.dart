import 'package:flutter/material.dart';

class ExpandablePlayerSheet extends StatefulWidget {
  const ExpandablePlayerSheet({
    required this.miniPlayer,
    required this.fullPlayer,
    required this.isExpanded,
    required this.onExpand,
    required this.onCollapse,
    required this.maxHeight,
    this.onSwipeUp,
    super.key,
  });

  final Widget miniPlayer;
  final Widget fullPlayer;
  final bool isExpanded;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final double maxHeight;

  /// Called when the user swipes up while the player is fully expanded.
  final VoidCallback? onSwipeUp;

  static const miniPlayerHeight = 64.0;

  @override
  State<ExpandablePlayerSheet> createState() => _ExpandablePlayerSheetState();
}

class _ExpandablePlayerSheetState extends State<ExpandablePlayerSheet>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _expandProgress;
  late Animation<double> _fullPlayerOpacity;
  late Animation<double> _miniPlayerOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 320),
      vsync: this,
    );

    _expandProgress = CurvedAnimation(
      parent: _controller,
      curve: Curves.fastEaseInToSlowEaseOut,
      reverseCurve: Curves.fastEaseInToSlowEaseOut.flipped,
    );

    _fullPlayerOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.1, 0.7, curve: Curves.easeIn),
      ),
    );

    _miniPlayerOpacity = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.25, curve: Curves.easeOut),
      ),
    );

    _controller.addStatusListener(_onAnimationStatusChanged);

    if (widget.isExpanded) {
      _controller.value = 1;
    }
  }

  void _onAnimationStatusChanged(AnimationStatus status) {
    if (!mounted) {
      return;
    }
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
      if (widget.isExpanded) {
        // Velocity of 2.5 gives a snappy but not jarring spring-style snap.
        _controller.fling(velocity: 2);
      } else {
        _controller.fling(velocity: -2);
      }
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onAnimationStatusChanged);
    _controller.dispose();
    super.dispose();
  }

  double get _maxHeight => widget.maxHeight;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _expandProgress.value;
        final height =
            ExpandablePlayerSheet.miniPlayerHeight +
            (_maxHeight - ExpandablePlayerSheet.miniPlayerHeight) * progress;

        return SizedBox(
          height: height,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: progress > 0.01 ? 8 : 0,
            child: GestureDetector(
              onVerticalDragUpdate: _handleDragUpdate,
              onVerticalDragEnd: _handleDragEnd,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: progress < 0.5,
                      child: Opacity(
                        opacity: _fullPlayerOpacity.value.clamp(0.0, 1.0),
                        child: widget.fullPlayer,
                      ),
                    ),
                  ),
                  if (progress < 0.7)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        ignoring: progress >= 0.5,
                        child: Opacity(
                          opacity: _miniPlayerOpacity.value.clamp(0.0, 1.0),
                          child: widget.miniPlayer,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    final change = -delta / _maxHeight;
    _controller.value = (_controller.value + change).clamp(0.0, 1.0);
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final absVelocity = velocity.abs();

    if (absVelocity > 150) {
      if (velocity < 0) {
        // Swipe up — expand
        if (_controller.value >= 0.99 && widget.onSwipeUp != null) {
          // Already fully expanded — trigger queue overlay.
          widget.onSwipeUp!();
        } else {
          // Clamp so very fast flicks don't overshoot spring simulation.
          final v = (absVelocity / _maxHeight).clamp(0.5, 8.0);
          _controller.fling(velocity: v);
          if (!widget.isExpanded) widget.onExpand();
        }
      } else {
        // Swipe down — collapse
        final v = (absVelocity / _maxHeight).clamp(0.5, 8.0);
        _controller.fling(velocity: -v);
        if (widget.isExpanded) widget.onCollapse();
      }
    } else {
      // Low velocity — snap to nearest half with moderate spring
      if (_controller.value > 0.5) {
        _controller.fling(velocity: 2);
        if (!widget.isExpanded) widget.onExpand();
      } else {
        _controller.fling(velocity: -2);
        if (widget.isExpanded) widget.onCollapse();
      }
    }
  }
}
