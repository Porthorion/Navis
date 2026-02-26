import 'package:flutter/material.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';

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

  IconData _iconFor(ChangelogEntryType type) {
    switch (type) {
      case ChangelogEntryType.fix:
        return Icons.bug_report_outlined;
      case ChangelogEntryType.improvement:
        return Icons.auto_awesome_outlined;
      case ChangelogEntryType.newFeature:
        return Icons.new_releases_outlined;
    }
  }

  Color _colorFor(ChangelogEntryType type, ColorScheme scheme) {
    switch (type) {
      case ChangelogEntryType.fix:
        return scheme.error;
      case ChangelogEntryType.improvement:
        return scheme.primary;
      case ChangelogEntryType.newFeature:
        return scheme.tertiary;
    }
  }

  String _labelFor(ChangelogEntryType type) {
    switch (type) {
      case ChangelogEntryType.fix:
        return 'Fix';
      case ChangelogEntryType.improvement:
        return 'Improved';
      case ChangelogEntryType.newFeature:
        return 'New';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

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
              for (final entry in version.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 2),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: _colorFor(
                            entry.type,
                            colorScheme,
                          ).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          _iconFor(entry.type),
                          size: 16,
                          color: _colorFor(entry.type, colorScheme),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _labelFor(entry.type),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: _colorFor(entry.type, colorScheme),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              entry.text,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
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
