import 'package:flutter/material.dart';

class ExpandablePlayerSheet extends StatefulWidget {
  const ExpandablePlayerSheet({
    required this.miniPlayer,
    required this.fullPlayer,
    required this.isExpanded,
    required this.onExpand,
    required this.onCollapse,
    this.onSwipeUpFullPlayer,
    super.key,
  });

  final Widget miniPlayer;
  final Widget fullPlayer;
  final bool isExpanded;
  final VoidCallback onExpand;
  final VoidCallback onCollapse;
  final VoidCallback? onSwipeUpFullPlayer;

  @override
  State<ExpandablePlayerSheet> createState() => _ExpandablePlayerSheetState();
}

class _ExpandablePlayerSheetState extends State<ExpandablePlayerSheet>
    with SingleTickerProviderStateMixin {
  static const _miniPlayerHeight = 64.0;

  late AnimationController _controller;
  late Animation<double> _expandProgress;
  late Animation<double> _fullPlayerOpacity;
  late Animation<double> _miniPlayerOpacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );

    _expandProgress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    _fullPlayerOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.3, 1, curve: Curves.easeIn),
      ),
    );

    _miniPlayerOpacity = Tween<double>(begin: 1, end: 0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.4, curve: Curves.easeOut),
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
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onAnimationStatusChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _expandProgress.value;
        final screenHeight = MediaQuery.of(context).size.height;
        final height =
            _miniPlayerHeight + (screenHeight - _miniPlayerHeight) * progress;

        return SizedBox(
          height: height,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: progress > 0.01 ? 8 : 0,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Full player (behind)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: progress < 0.5,
                    child: Opacity(
                      opacity: _fullPlayerOpacity.value.clamp(0.0, 1.0),
                      child: widget.fullPlayer,
                    ),
                  ),
                ),
                // Mini player (in front, fades out)
                if (progress < 0.7)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      ignoring: progress >= 0.5,
                      child: Opacity(
                        opacity: _miniPlayerOpacity.value.clamp(0.0, 1.0),
                        child: GestureDetector(
                          onVerticalDragUpdate: _handleDragUpdate,
                          onVerticalDragEnd: _handleDragEnd,
                          child: widget.miniPlayer,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    final screenHeight = MediaQuery.of(context).size.height;
    final change = -delta / screenHeight;

    _controller.value = (_controller.value + change).clamp(0.0, 1.0);
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;

    if (velocity.abs() > 300) {
      if (velocity < 0) {
        // Swiped up → expand
        _controller.forward();
      } else {
        // Swiped down → collapse
        _controller.reverse();
      }
    } else {
      if (_controller.value > 0.5) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }
}
