import 'dart:async';

import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/changelog/presentation/changelog_entry_tile.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_tokens.dart';

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
    builder: (dialogContext) => _ChangelogDialog(
      version: version,
      onViewFullChangelog: () {
        unawaited(markChangelogSeen(version.version));
        Navigator.of(dialogContext).pop();
        if (context.mounted) {
          NavService.openAboutChangelog(context);
        }
      },
    ),
  );
}

class _ChangelogDialog extends StatelessWidget {
  const _ChangelogDialog({
    required this.version,
    required this.onViewFullChangelog,
  });

  final ChangelogVersion version;
  final VoidCallback onViewFullChangelog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final highlights = version.entries
        .where((e) => e.type != ChangelogEntryType.fix)
        .toList();
    final hasHighlights = highlights.isNotEmpty;
    final hasFixes = version.entries.any(
      (e) => e.type == ChangelogEntryType.fix,
    );
    final titleText = !hasHighlights && hasFixes
        ? l10n.changelogDialogBugFixesTitle
        : l10n.whatsNewTitle;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: NavisRadius.xlAll),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      title: Row(
        children: [
          Icon(
            !hasHighlights && hasFixes
                ? Icons.build_circle_outlined
                : Icons.celebration_outlined,
            color: colorScheme.primary,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titleText,
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
        child: SizedBox(
          width: double.infinity,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          hasHighlights
                              ? l10n.changelogDialogOtherBugFixes
                              : l10n.changelogDialogBugFixesTitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (version.specialThanks.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    l10n.changelogSpecialThanks,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final thankYou in version.specialThanks)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(thankYou, style: theme.textTheme.bodyMedium),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: onViewFullChangelog,
          child: Text(l10n.changelogDialogViewAll),
        ),
        FilledButton(
          onPressed: () {
            unawaited(markChangelogSeen(version.version));
            Navigator.of(context).pop();
          },
          child: Text(l10n.changelogDialogGotIt),
        ),
      ],
    );
  }
}
