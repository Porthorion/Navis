import 'package:flutter/material.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_entry_tile.dart';

/// Full-page changelog screen listing all version changelogs, accessible from
/// the About section in Settings.
class ChangelogScreen extends StatelessWidget {
  const ChangelogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.changelogTitle)),
      body: changelogs.isEmpty
          ? Center(child: Text(l10n.changelogEmpty))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: changelogs.length,
              separatorBuilder: (_, __) => const Divider(height: 32),
              itemBuilder: (context, index) {
                final version = changelogs[index];
                return _VersionSection(version: version, theme: theme, l10n: l10n);
              },
            ),
    );
  }
}

class _VersionSection extends StatelessWidget {
  const _VersionSection({
    required this.version,
    required this.theme,
    required this.l10n,
  });

  final ChangelogVersion version;
  final ThemeData theme;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                l10n.changelogVersionLabel(version.version),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final entry in version.entries) ChangelogEntryTile(entry: entry),
      ],
    );
  }
}
