import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/format_utils.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.downloadsTitle),
          bottom: TabBar(
            tabs: <Widget>[
              Tab(text: l10n.downloadsTabQueue),
              Tab(text: l10n.downloadsTabDownloaded),
              Tab(text: l10n.downloadsTabSettings),
            ],
          ),
        ),
        body: const TabBarView(
          children: <Widget>[
            _QueueTab(),
            _DownloadedTab(),
            _DownloadSettingsTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Queue tab — shows pending / active / failed downloads
// ---------------------------------------------------------------------------

class _QueueTab extends ConsumerWidget {
  const _QueueTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final queueAsync = ref.watch(downloadQueueProvider);

    return queueAsync.when(
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(
            title: l10n.downloadsQueueEmpty,
            subtitle: l10n.downloadsQueueEmptySubtitle,
            icon: Icons.download_outlined,
          );
        }

        final hasFailed = items.any(
          (i) => i.status == DownloadStatus.failed,
        );

        Future<void> clearQueue() async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(l10n.downloadsClearQueue),
              content: Text(l10n.downloadsClearQueueConfirm),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.cancelAction),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(l10n.downloadsClearQueue),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          final dao = ref.read(navisDatabaseProvider).downloadQueueDao;
          await dao.clearQueue();
        }

        return Column(
          children: <Widget>[
            if (hasFailed || items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: <Widget>[
                    if (hasFailed)
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: () {
                            final dao = ref
                                .read(navisDatabaseProvider)
                                .downloadQueueDao;
                            dao.retryAllFailed();
                          },
                          icon: const Icon(Icons.refresh),
                          label: Text(l10n.downloadsRetryAllFailed),
                        ),
                      ),
                    if (hasFailed) const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: clearQueue,
                        icon: const Icon(Icons.clear_all),
                        label: Text(l10n.downloadsClearQueue),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _QueueItemTile(item: item);
                },
              ),
            ),
          ],
        );
      },
      loading: () => const ShimmerListPage(count: 8),
      error: (error, _) => ErrorState(
        title: l10n.downloadsErrorLoadingQueue,
        message: error.toString(),
        onRetry: () => ref.invalidate(downloadQueueProvider),
      ),
    );
  }
}

class _QueueItemTile extends ConsumerWidget {
  const _QueueItemTile({required this.item});

  final DownloadQueueTableData item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songId = item.songId;
    final songAsync = songId != null
        ? ref.watch(songByIdProvider(songId))
        : null;
    final song = songAsync?.asData?.value;

    final title = song?.title ?? songId ?? '—';
    final artist = song?.artistName ?? '';
    final isActive = item.status == DownloadStatus.downloading;
    final isFailed = item.status == DownloadStatus.failed;

    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: song?.coverArt != null
            ? CoverArtImage(
                coverArtId: song!.coverArt,
                size: 48,
                borderRadius: BorderRadius.circular(6),
              )
            : Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.music_note),
              ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (artist.isNotEmpty) Text(artist, maxLines: 1),
          if (isActive)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: item.progress),
            ),
          if (isFailed)
            Text(
              l10n.downloadsStatusFailed,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
      trailing: IconButton(
        icon: Icon(isFailed ? Icons.refresh : Icons.close),
        tooltip: isFailed
            ? l10n.downloadsRetryFailed
            : l10n.downloadsCancelAction,
        onPressed: () {
          final dao = ref.read(navisDatabaseProvider).downloadQueueDao;
          if (isFailed) {
            dao.updateStatus(item.id, DownloadStatus.queued);
          } else {
            dao.remove(item.id);
          }
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Downloaded tab — shows permanently cached tracks (uses Riverpod)
// ---------------------------------------------------------------------------

class _DownloadedTab extends ConsumerWidget {
  const _DownloadedTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final tracksAsync = ref.watch(permanentCachedTracksProvider);

    return tracksAsync.when(
      data: (tracks) {
        if (tracks.isEmpty) {
          return EmptyState(
            title: l10n.downloadsDownloadedEmpty,
            subtitle: l10n.downloadsDownloadedEmptySubtitle,
            icon: Icons.download_done_outlined,
          );
        }

        return ListView.builder(
          itemCount: tracks.length,
          itemBuilder: (context, index) {
            final track = tracks[index];
            return _DownloadedTrackTile(track: track);
          },
        );
      },
      loading: () => const ShimmerListPage(count: 8),
      error: (_, _) => ErrorState(
        title: l10n.downloadsErrorLoadingQueue,
        onRetry: () => ref.invalidate(permanentCachedTracksProvider),
      ),
    );
  }
}

class _DownloadedTrackTile extends ConsumerWidget {
  const _DownloadedTrackTile({required this.track});

  final CachedTracksTableData track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songAsync = ref.watch(songByIdProvider(track.songId));
    final song = songAsync.asData?.value;

    final title = song?.title ?? track.songId;
    final artist = song?.artistName ?? '';

    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: song?.coverArt != null
            ? CoverArtImage(
                coverArtId: song!.coverArt,
                size: 48,
                borderRadius: BorderRadius.circular(6),
              )
            : Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.music_note),
              ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$artist · ${track.format.toUpperCase()} · ${formatBytes(track.fileSize)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: l10n.downloadsRemoveAction,
        onPressed: () => _confirmAndDelete(context, ref, track, l10n),
      ),
      onLongPress: () => _showTrackMenu(context, ref, track, l10n),
    );
  }

  Future<void> _confirmAndDelete(
    BuildContext context,
    WidgetRef ref,
    CachedTracksTableData track,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.downloadsRemoveConfirmTitle),
        content: Text(l10n.downloadsRemoveConfirmContent),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.downloadsRemoveAction),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await deleteFileWithSuffixes(track.filePath);
    await ref
        .read(navisDatabaseProvider)
        .cacheDao
        .removeCachedTrack(track.songId);
  }

  void _showTrackMenu(
    BuildContext context,
    WidgetRef ref,
    CachedTracksTableData track,
    AppLocalizations l10n,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.high_quality_outlined),
                title: Text(l10n.downloadsRedownloadOriginal),
                subtitle: Text(l10n.downloadsRedownloadOriginalSub),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  // Delete the existing permanent file first (async).
                  await deleteFileWithSuffixes(track.filePath);
                  await ref
                      .read(navisDatabaseProvider)
                      .cacheDao
                      .removeCachedTrack(track.songId);
                  // Re-enqueue in original quality (no transcode).
                  final service = ref.read(downloadServiceProvider);
                  await service.enqueueSong(
                    track.songId,
                    forceRedownload: true,
                  );
                  if (context.mounted) {
                    AppNoticeMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.downloadsRedownloadQueued),
                      ),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l10n.downloadsRemoveAction),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _confirmAndDelete(context, ref, track, l10n);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Download Settings tab
// ---------------------------------------------------------------------------

class _DownloadSettingsTab extends ConsumerStatefulWidget {
  const _DownloadSettingsTab();

  @override
  ConsumerState<_DownloadSettingsTab> createState() =>
      _DownloadSettingsTabState();
}

class _DownloadSettingsTabState extends ConsumerState<_DownloadSettingsTab> {
  bool _clearing = false;

  Future<bool> _confirmCellularAutoDownload() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.cacheSettingsAutoDownloadCellularWarningTitle),
        content: Text(l10n.cacheSettingsAutoDownloadCellularWarning),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.cacheSettingsAutoDownloadCellularWarningContinue),
          ),
        ],
      ),
    );
    return confirm == true;
  }

  Future<void> _updateWifiOnlyDownloads(bool enabled) async {
    if (!enabled && ref.read(autoDownloadStarredOnWifiProvider)) {
      final confirmed = await _confirmCellularAutoDownload();
      if (!confirmed || !mounted) {
        return;
      }
    }
    await ref
        .read(navisDatabaseProvider)
        .appSettingsDao
        .updateWifiOnlyDownloads(enabled: enabled);
  }

  Future<void> _updateAutoDownloadLiked(bool enabled) async {
    if (enabled && !ref.read(wifiOnlyDownloadsProvider)) {
      final confirmed = await _confirmCellularAutoDownload();
      if (!confirmed || !mounted) {
        return;
      }
    }
    await ref
        .read(navisDatabaseProvider)
        .appSettingsDao
        .updateAutoDownloadStarredOnWifi(enabled: enabled);
  }

  Future<void> _clearDownloads() async {
    final l10n = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.cacheSettingsClearPermanent),
        content: Text(l10n.cacheSettingsClearPermanentConfirm),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.cacheSettingsClearPermanent),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _clearing = true);
    try {
      final db = ref.read(navisDatabaseProvider);
      final tracks = await db.cacheDao
          .watchCachedTracksByType(CacheType.permanent)
          .first;
      for (final track in tracks) {
        await deleteFileWithSuffixes(track.filePath);
      }
      if (tracks.isNotEmpty) {
        await db.cacheDao.deleteCachedTracksBySongIds(
          tracks.map((t) => t.songId),
        );
      }
      if (mounted) {
        AppNoticeMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(l10n.cacheSettingsClearSuccess)),
          );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final permanentStats = ref.watch(permanentCacheStatsProvider);

    if (_clearing) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      children: <Widget>[
        SwitchListTile(
          title: Text(l10n.cacheSettingsWifiOnlyDownloads),
          subtitle: Text(l10n.cacheSettingsWifiOnlyDownloadsSub),
          value: ref.watch(wifiOnlyDownloadsProvider),
          onChanged: _updateWifiOnlyDownloads,
        ),
        SwitchListTile(
          title: Text(l10n.cacheSettingsAutoDownloadStarred),
          subtitle: Text(l10n.cacheSettingsAutoDownloadStarredSub),
          value: ref.watch(autoDownloadStarredOnWifiProvider),
          onChanged: _updateAutoDownloadLiked,
        ),
        const Divider(),
        permanentStats.when(
          data: (stats) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  formatBytes(stats.totalBytes),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.cacheSettingsPermanentTrackCount(stats.trackCount),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const SizedBox.shrink(),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(l10n.cacheSettingsClearPermanent),
          onTap: _clearDownloads,
        ),
      ],
    );
  }
}
