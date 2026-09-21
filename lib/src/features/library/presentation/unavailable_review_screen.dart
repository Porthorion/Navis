import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Review entries for items that identity recovery could not relink.
final unavailableReviewProvider = StreamProvider.autoDispose
    .family<List<LibraryRecoveryReviewTableData>, int>((ref, serverId) {
      return ref
          .watch(navisDatabaseProvider)
          .librarySyncDao
          .watchPendingRecoveryReview(serverId);
    });

final pendingUnavailableCountProvider = FutureProvider.autoDispose<int>((
  ref,
) async {
  final serverId = ref.watch(serverConfigStateProvider).asData?.value?.id;
  if (serverId == null) {
    return 0;
  }
  final count = await ref
      .watch(navisDatabaseProvider)
      .librarySyncDao
      .watchPendingRecoveryReviewCount(serverId)
      .first;
  return count;
});

class UnavailableReviewScreen extends ConsumerStatefulWidget {
  const UnavailableReviewScreen({super.key});

  @override
  ConsumerState<UnavailableReviewScreen> createState() =>
      _UnavailableReviewScreenState();
}

class _UnavailableReviewScreenState
    extends ConsumerState<UnavailableReviewScreen> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final serverId = ref.watch(serverConfigStateProvider).asData?.value?.id;
    final entries = serverId == null
        ? const AsyncValue<List<LibraryRecoveryReviewTableData>>.data([])
        : ref.watch(unavailableReviewProvider(serverId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.unavailableReviewTitle)),
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text(l10n.unavailableReviewLoadError)),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(child: Text(l10n.unavailableReviewEmpty));
          }
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) => _ReviewCard(
              entry: rows[index],
              onKeep: () => _setDisposition(rows[index], 'keptForLater'),
              onRemoveFromLiked: () => _removeFromLiked(rows[index]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _setDisposition(
    LibraryRecoveryReviewTableData entry,
    String disposition,
  ) async {
    final serverId = ref.read(serverConfigStateProvider).asData?.value?.id;
    if (serverId == null) {
      return;
    }
    await ref
        .read(navisDatabaseProvider)
        .librarySyncDao
        .setRecoveryReviewDisposition(id: entry.id, disposition: disposition);
  }

  Future<void> _removeFromLiked(
    LibraryRecoveryReviewTableData entry,
  ) async {
    final serverId = ref.read(serverConfigStateProvider).asData?.value?.id;
    if (serverId == null || entry.entityType != 'song') {
      return;
    }
    final database = ref.read(navisDatabaseProvider);
    final song = await database.libraryDao.getSongById(entry.oldId);
    if (song != null) {
      // Explicit user decision: unlike locally and on the server, without
      // deleting any downloaded file.
      await database.starSyncDao.setStarred(
        itemId: entry.oldId,
        itemType: 'song',
        liked: false,
      );
    }
    await database.librarySyncDao.setRecoveryReviewDisposition(
      id: entry.id,
      disposition: 'removedFromLiked',
    );
  }
}

class _ReviewCard extends ConsumerWidget {
  const _ReviewCard({
    required this.entry,
    required this.onKeep,
    required this.onRemoveFromLiked,
  });

  final LibraryRecoveryReviewTableData entry;
  final Future<void> Function() onKeep;
  final Future<void> Function() onRemoveFromLiked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = entry.savedSubtitle;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  entry.savedTitle ?? l10n.unavailableReviewUnknownTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 8),
                Text(
                  _typeLabel(l10n),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            if (subtitle != null && subtitle.isNotEmpty)
              Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              _reasonLabel(l10n),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                if (entry.entityType == 'song')
                  OutlinedButton(
                    onPressed: () => _findMatch(context, ref),
                    child: Text(l10n.unavailableReviewFindMatch),
                  ),
                TextButton(
                  onPressed: onKeep,
                  child: Text(l10n.unavailableReviewKeepForLater),
                ),
                if (entry.entityType == 'song')
                  TextButton(
                    onPressed: onRemoveFromLiked,
                    child: Text(l10n.unavailableReviewRemoveFromLiked),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _typeLabel(AppLocalizations l10n) {
    return switch (entry.entityType) {
      'album' => l10n.unavailableReviewTypeAlbum,
      'artist' => l10n.unavailableReviewTypeArtist,
      _ => l10n.unavailableReviewTypeSong,
    };
  }

  String _reasonLabel(AppLocalizations l10n) {
    return switch (entry.reason) {
      'ambiguousMatch' => l10n.unavailableReviewReasonAmbiguous,
      'conflictingMbid' => l10n.unavailableReviewReasonConflicting,
      _ => l10n.unavailableReviewReasonMissing,
    };
  }

  Future<void> _findMatch(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final database = ref.read(navisDatabaseProvider);
    final title = entry.savedTitle?.trim();
    if (title == null || title.isEmpty) {
      return;
    }
    final candidates = await database.libraryDao.searchSongsLocal(
      title,
      limit: 25,
    );
    if (candidates.isEmpty) {
      if (context.mounted) {
        showAppNotice(
          context,
          message: l10n.unavailableReviewNoMatchFound,
          level: AppNoticeLevel.info,
        );
      }
      return;
    }
    if (!context.mounted) {
      return;
    }
    final selected = await showModalBottomSheet<SongsTableData>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: candidates.length,
          itemBuilder: (sheetContext, index) {
            final candidate = candidates[index];
            return ListTile(
              title: Text(candidate.title),
              subtitle: Text(candidate.artistName ?? ''),
              onTap: () => Navigator.pop(sheetContext, candidate),
            );
          },
        ),
      ),
    );
    if (selected == null) {
      return;
    }
    final serverId = ref.read(serverConfigStateProvider).asData?.value?.id;
    if (serverId == null || selected.id == entry.oldId) {
      return;
    }
    try {
      await database.songIdentityDao.remapSongIdentity(
        oldSongId: entry.oldId,
        canonicalSongId: selected.id,
        matchReason: 'manualReview',
      );
      await database.librarySyncDao.setRecoveryReviewDisposition(
        id: entry.id,
        disposition: 'relinked',
      );
    } on Object catch (error) {
      AppLogger.warning('Manual relink failed for ${entry.oldId}: $error');
    }
  }
}
