import 'package:flutter/material.dart';

class StarButton extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final icon = Icon(isStarred ? Icons.favorite : Icons.favorite_border);
    if (compact) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: icon,
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: Text(label ?? ''),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}
