import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/presentation/changelog_entry_tile.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Shows what changed in the current version of the app, accessible from
/// Settings > About > What's New.
class ChangelogScreen extends ConsumerWidget {
  const ChangelogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final packageInfo = ref.watch(packageInfoProvider).asData?.value;
    final currentVersion = packageInfo?.version;

    // Find the entry for the current installed version; fall back to newest.
    final version = currentVersion != null
        ? changelogs.where((c) => c.version == currentVersion).firstOrNull ??
            (changelogs.isNotEmpty ? changelogs.first : null)
        : (changelogs.isNotEmpty ? changelogs.first : null);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.whatsNewTitle)),
      body: version == null
          ? Center(child: Text(l10n.changelogEmpty))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.celebration_outlined,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Version ${version.version}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                for (final entry in version.entries)
                  ChangelogEntryTile(entry: entry),
              ],
            ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
