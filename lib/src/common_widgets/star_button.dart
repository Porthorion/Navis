import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/theme/motion_policy.dart';

class StarButton extends StatefulWidget {
  const new({
    required this.isStarred,
    super.key,
    this.onPressed,
    this.tooltip,
    this.label,
    this.starredLabel,
    this.compact = false,
  });

  final bool isStarred;
  final VoidCallback? onPressed;
  final String? tooltip;

  /// Label shown when [isStarred] is false (or always, if [starredLabel] is null).
  final String? label;

  /// Label shown when [isStarred] is true. Falls back to [label] if null.
  final String? starredLabel;
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
    if (widget.isStarred != oldWidget.isStarred &&
        !MotionPolicy.of(context).reduceMotion) {
      _controller.forward(from: 0);
    }
  }

  void _handlePress() {
    HapticFeedback.lightImpact();
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(
      widget.isStarred ? Icons.favorite : Icons.favorite_border,
    );
    final icon = MotionPolicy.of(context).reduceMotion
        ? glyph
        : ScaleTransition(
            key: const ValueKey<String>('starButtonFeedbackScale'),
            scale: _scale,
            child: glyph,
          );

    if (widget.compact) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: widget.tooltip,
        onPressed: widget.onPressed == null ? null : _handlePress,
        icon: icon,
      );
    }
    final effectiveLabel =
        (widget.isStarred ? widget.starredLabel : null) ?? widget.label ?? '';
    return OutlinedButton.icon(
      onPressed: widget.onPressed == null ? null : _handlePress,
      icon: icon,
      label: Text(effectiveLabel),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}
