import 'package:flutter/material.dart';

class ExpandablePlayerSheet extends StatefulWidget {
  const ExpandablePlayerSheet({
    required this.miniPlayer,
    required this.fullPlayer,
    required this.isExpanded,
    required this.onToggleExpanded,
    super.key,
  });

  final Widget miniPlayer;
  final Widget fullPlayer;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;

  @override
  State<ExpandablePlayerSheet> createState() => _ExpandablePlayerSheetState();
}

class _ExpandablePlayerSheetState extends State<ExpandablePlayerSheet>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _heightFactor;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _heightFactor = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    _opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 1, curve: Curves.easeIn),
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
      widget.onToggleExpanded();
    } else if (status == AnimationStatus.dismissed && widget.isExpanded) {
      widget.onToggleExpanded();
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
        final isCollapsed = _heightFactor.value < 0.5;

        return GestureDetector(
          onTap: isCollapsed ? widget.onToggleExpanded : null,
          onVerticalDragUpdate: _handleDragUpdate,
          onVerticalDragEnd: _handleDragEnd,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 8,
            child: SizedBox(
              height: _calculateHeight(context),
              child: Stack(
                children: [
                  if (!isCollapsed)
                    Positioned.fill(
                      child: FadeTransition(
                        opacity: _opacity,
                        child: widget.fullPlayer,
                      ),
                    ),
                  if (isCollapsed)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: widget.miniPlayer,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  double _calculateHeight(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final miniPlayerHeight = 64.0;
    final fullPlayerHeight = screenHeight;

    return miniPlayerHeight +
        (fullPlayerHeight - miniPlayerHeight) * _heightFactor.value;
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    final screenHeight = MediaQuery.of(context).size.height;
    final change = -delta / screenHeight;

    _controller.value = (_controller.value + change).clamp(0.0, 1.0);
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;

    if (velocity.abs() > 500) {
      if (velocity < 0) {
        _controller.forward();
      } else {
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
