import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_entry_tile.dart';

/// Shows every app changelog entry, accessible from Settings > About.
class ChangelogScreen extends StatelessWidget {
  const ChangelogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutChangelog)),
      body: changelogs.isEmpty
          ? Center(child: Text(l10n.changelogEmpty))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                for (var i = 0; i < changelogs.length; i++) ...[
                  Row(
                    children: [
                      Icon(
                        i == 0
                            ? Icons.celebration_outlined
                            : Icons.history_rounded,
                        color: theme.colorScheme.primary,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Version ${changelogs[i].version}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  for (final entry in changelogs[i].entries)
                    ChangelogEntryTile(entry: entry),
                  if (changelogs[i].specialThanks.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      l10n.changelogSpecialThanks,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final thankYou in changelogs[i].specialThanks)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          thankYou,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                  ],
                  if (i != changelogs.length - 1)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Divider(height: 1),
                    ),
                ],
              ],
            ),
    );
  }
}
