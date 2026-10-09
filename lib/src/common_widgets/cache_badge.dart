import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/theme/navis_shape_data.dart';

/// Visual variants for the cache badge.
enum CacheBadgeType {
  /// Permanently downloaded track.
  downloaded,

  /// Temporarily cached (rolling cache) track.
  cached,
}

class CacheBadge extends StatelessWidget {
  const new({super.key, this.type = CacheBadgeType.downloaded});

  final CacheBadgeType type;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    final (icon, label, bgColor, fgColor) = switch (type) {
      CacheBadgeType.downloaded => (
        Icons.download_done_outlined,
        l10n.cacheBadgeDownloaded,
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      CacheBadgeType.cached => (
        Icons.schedule_outlined,
        l10n.cacheBadgeCached,
        theme.colorScheme.tertiaryContainer,
        theme.colorScheme.onTertiaryContainer,
      ),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: NavisShapeData.of(context).controlAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 12, color: fgColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: fgColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
