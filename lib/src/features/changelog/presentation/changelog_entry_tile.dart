import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// One changelog entry as a plain paragraph. Entries sit under a heading
/// that names their type or, for other platforms, their platforms, so the
/// row itself usually carries no label or marker.
///
/// An entry that is not for everyone names its platforms in a small line
/// above it ([platformLabel]); [muted] quiets entries for other platforms.
class ChangelogEntryTile extends StatelessWidget {
  const new({
    required this.entry,
    this.platformLabel,
    this.muted = false,
    super.key,
  });

  final ChangelogEntry entry;
  final String? platformLabel;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.colorScheme.onSurfaceVariant;
    final label = platformLabel;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NavisSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (label != null)
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: quiet),
            ),
          Text(
            entry.text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: muted ? quiet : null,
            ),
          ),
        ],
      ),
    );
  }
}
