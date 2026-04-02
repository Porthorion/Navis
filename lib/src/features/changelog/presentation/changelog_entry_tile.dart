import 'package:flutter/material.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';

/// A single row in a changelog list, displaying the entry type badge,
/// label, and description text.
///
/// Used by both the "What's New" dialog and the full Changelog screen.
class ChangelogEntryTile extends StatelessWidget {
  const ChangelogEntryTile({super.key, required this.entry});

  final ChangelogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final color = entryColor(entry.type, colorScheme);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              entryIcon(entry.type),
              size: 16,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entryLabel(entry.type),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(entry.text, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData entryIcon(ChangelogEntryType type) {
  switch (type) {
    case ChangelogEntryType.fix:
      return Icons.bug_report_outlined;
    case ChangelogEntryType.improvement:
      return Icons.auto_awesome_outlined;
    case ChangelogEntryType.newFeature:
      return Icons.new_releases_outlined;
  }
}

Color entryColor(ChangelogEntryType type, ColorScheme scheme) {
  switch (type) {
    case ChangelogEntryType.fix:
      return scheme.error;
    case ChangelogEntryType.improvement:
      return scheme.primary;
    case ChangelogEntryType.newFeature:
      return scheme.tertiary;
  }
}

String entryLabel(ChangelogEntryType type) {
  switch (type) {
    case ChangelogEntryType.fix:
      return 'Fix';
    case ChangelogEntryType.improvement:
      return 'Improved';
    case ChangelogEntryType.newFeature:
      return 'New';
  }
}
