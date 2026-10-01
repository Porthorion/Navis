import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

class RatingWidget extends StatelessWidget {
  const new({
    required this.rating,
    required this.onChanged,
    super.key,
    this.maxRating = 5,
    this.iconSize = 18,
    this.compact = false,
  });

  final int? rating;
  final ValueChanged<int> onChanged;
  final int maxRating;
  final double iconSize;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final effectiveRating = rating ?? 0;
    final stars = <Widget>[];
    for (var i = 1; i <= maxRating; i++) {
      final filled = i <= effectiveRating;
      stars.add(
        InkResponse(
          onTap: () {
            unawaited(HapticFeedback.selectionClick());
            onChanged(i == effectiveRating ? 0 : i);
          },
          radius: compact ? 16 : 20,
          child: Icon(
            filled ? Icons.star : Icons.star_border,
            size: iconSize,
            color: filled
                ? Theme.of(context).colorScheme.secondary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: stars);
  }
}
