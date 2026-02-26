import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class StarButton extends StatefulWidget {
  const StarButton({
    required this.isStarred,
    super.key,
    this.onPressed,
    this.tooltip,
    this.label,
    this.compact = false,
  });

  final bool isStarred;
  final VoidCallback? onPressed;
  final String? tooltip;
  final String? label;
  final bool compact;

  @override
  State<StarButton> createState() => _StarButtonState();
}

class _StarButtonState extends State<StarButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 1.40,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 40,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.40,
          end: 1,
        ).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 60,
      ),
    ]).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(StarButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isStarred != oldWidget.isStarred) {
      _controller.forward(from: 0);
    }
  }

  void _handlePress() {
    HapticFeedback.lightImpact();
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final icon = ScaleTransition(
      scale: _scale,
      child: Icon(
        widget.isStarred ? Icons.favorite : Icons.favorite_border,
      ),
    );

    if (widget.compact) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: widget.tooltip,
        onPressed: widget.onPressed == null ? null : _handlePress,
        icon: icon,
      );
    }
    return OutlinedButton.icon(
      onPressed: widget.onPressed == null ? null : _handlePress,
      icon: icon,
      label: Text(widget.label ?? ''),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}
