import 'package:flutter/material.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/changelog/presentation/changelog_entry_tile.dart';

/// Shows a dismissable changelog dialog for the given [version].
///
/// When the user taps "Got it", the version is marked as seen so the dialog
/// won't appear again until the next update.
Future<void> showChangelogDialog(
  BuildContext context,
  ChangelogVersion version,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _ChangelogDialog(version: version),
  );
}

class _ChangelogDialog extends StatelessWidget {
  const _ChangelogDialog({required this.version});

  final ChangelogVersion version;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final highlights = version.entries
        .where((e) => e.type != ChangelogEntryType.fix)
        .toList();
    final hasFixes = version.entries.any((e) => e.type == ChangelogEntryType.fix);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      title: Row(
        children: [
          Icon(
            Icons.celebration_outlined,
            color: colorScheme.primary,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "What's New",
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'Version ${version.version}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 400),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 4),
              for (final entry in highlights)
                ChangelogEntryTile(entry: entry),
              if (hasFixes)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.build_circle_outlined,
                        size: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '& Other Bug Fixes',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            markChangelogSeen(version.version);
            Navigator.of(context).pop();
          },
          child: const Text('Got it'),
        ),
      ],
    );
  }
}
