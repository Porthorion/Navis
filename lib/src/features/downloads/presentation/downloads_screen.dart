import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/format_utils.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.downloadsTitle),
          bottom: TabBar(
            tabs: <Widget>[
              Tab(text: l10n.downloadsTabQueue),
              Tab(text: l10n.downloadsTabDownloaded),
            ],
          ),
        ),
        body: const TabBarView(
          children: <Widget>[
            _QueueTab(),
            _DownloadedTab(),
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
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return _QueueItemTile(item: item);
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(
                l10n.downloadsErrorLoadingQueue,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
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
    final songAsync =
        songId != null ? ref.watch(songByIdProvider(songId)) : null;
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
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(
                l10n.downloadsErrorLoadingQueue,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
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
        onPressed: () async {
          // Delete files.
          _deleteFileWithSuffixes(track.filePath);
          await ref
              .read(navisDatabaseProvider)
              .cacheDao
              .removeCachedTrack(track.songId);
        },
      ),
    );
  }

  /// Best-effort file + sidecar deletion.
  void _deleteFileWithSuffixes(String filePath) {
    for (final suffix in <String>['', '.part', '.mime']) {
      try {
        final f = File('$filePath$suffix');
        if (f.existsSync()) f.deleteSync();
      } on FileSystemException {
        // best-effort
      }
    }
  }
}
