import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';

class SyncSettingsScreen extends ConsumerWidget {
  const SyncSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final syncState = ref.watch(librarySyncControllerProvider);
    final serverConfig = ref.watch(serverConfigStateProvider).asData?.value;
    final lastSynced = syncState.lastSyncedAt ?? serverConfig?.lastSynced;
    final isRunning = syncState.isRunning;
    final hasFailure = syncState.status == LibrarySyncStatus.failed;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.syncSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.syncSettingsStatusLabel,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _statusLabel(l10n, syncState),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (hasFailure &&
                      syncState.errorMessage != null &&
                      syncState.errorMessage!.trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      syncState.errorMessage!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              title: Text(l10n.syncSettingsLastSyncedLabel),
              subtitle: Text(
                lastSynced == null
                    ? l10n.syncSettingsNeverSynced
                    : MaterialLocalizations.of(context).formatFullDate(
                        lastSynced,
                      ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: isRunning
                ? null
                : () async {
                    await ref
                        .read(librarySyncControllerProvider.notifier)
                        .syncNow(forceFull: true);
                  },
            icon: const Icon(Icons.sync),
            label: Text(
              isRunning
                  ? l10n.serverSettingsForceFullSyncRunning
                  : l10n.serverSettingsForceFullSync,
            ),
          ),
          if (hasFailure) ...<Widget>[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: isRunning
                  ? null
                  : () async {
                      await ref
                          .read(librarySyncControllerProvider.notifier)
                          .syncNow();
                    },
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(AppLocalizations l10n, LibrarySyncState state) {
    return switch (state.status) {
      LibrarySyncStatus.running => l10n.librarySyncRunning,
      LibrarySyncStatus.succeeded => l10n.syncSettingsStatusSucceeded,
      LibrarySyncStatus.failed => l10n.syncSettingsStatusFailed,
      LibrarySyncStatus.skipped => l10n.syncSettingsStatusIdle,
      LibrarySyncStatus.idle => l10n.syncSettingsStatusIdle,
    };
  }
}
