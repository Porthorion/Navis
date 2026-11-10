import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

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
    final l10n = AppLocalizations.of(context)!;
    final effectiveRating = rating ?? 0;
    final stars = <Widget>[];
    for (var i = 1; i <= maxRating; i++) {
      final filled = i <= effectiveRating;
      void onTap() {
        NavisHaptics.tick(HapticCategory.likesAndAlerts);
        onChanged(i == effectiveRating ? 0 : i);
      }

      stars.add(
        Semantics(
          button: true,
          selected: filled,
          label: l10n.ratingStarLabel(i),
          excludeSemantics: true,
          onTap: onTap,
          child: InkResponse(
            onTap: onTap,
            radius: compact ? 16 : 20,
            child: SizedBox(
              // The icon stays small; the hit area is a full 48 px tall.
              // Compact rows (list-tile trailing) cannot take 5 x 48 px, so
              // their stars are narrower.
              width: compact ? 28 : kMinInteractiveDimension,
              height: kMinInteractiveDimension,
              child: Icon(
                filled ? Icons.star : Icons.star_border,
                size: iconSize,
                color: filled
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: stars);
  }
}
