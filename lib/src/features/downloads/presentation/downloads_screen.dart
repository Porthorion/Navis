import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/format_utils.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final showSearch = _tabController.index != 2;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.downloadsTitle),
        bottom: TabBar(
          controller: _tabController,
          tabs: <Widget>[
            Tab(text: l10n.downloadsTabQueue),
            Tab(text: l10n.downloadsTabDownloaded),
            Tab(text: l10n.downloadsTabSettings),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          if (showSearch)
            _DownloadsSearchBar(
              controller: _searchController,
              hint: _tabController.index == 0
                  ? l10n.downloadsQueueSearchHint
                  : l10n.downloadsSearchHint,
              onChanged: (value) => setState(() => _query = value),
              onClear: () {
                _searchController.clear();
                setState(() => _query = '');
              },
            ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: <Widget>[
                _QueueTab(query: _query),
                _DownloadedTab(query: _query),
                const _DownloadSettingsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Queue tab — shows pending / active / failed downloads
// ---------------------------------------------------------------------------

class _QueueTab extends ConsumerWidget {
  const _QueueTab({required this.query});

  final String query;

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

        // Resolve song data for all items so we can filter by title/artist.
        final resolvedSongs = <int, SongsTableData?>{};
        for (final item in items) {
          if (item.songId != null) {
            resolvedSongs[item.id] = ref
                .watch(songByIdProvider(item.songId!))
                .asData
                ?.value;
          }
        }

        final filtered = query.isEmpty
            ? items
            : items
                  .where((item) {
                    final song = resolvedSongs[item.id];
                    final title = (song?.title ?? item.songId ?? '')
                        .toLowerCase();
                    final artist = (song?.artistName ?? '').toLowerCase();
                    final q = query.toLowerCase();
                    return title.contains(q) || artist.contains(q);
                  })
                  .toList(growable: false);

        final hasFailed = filtered.any(
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
            if (hasFailed || filtered.isNotEmpty)
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
            if (filtered.isEmpty && query.isNotEmpty)
              Expanded(
                child: EmptyState(
                  title: l10n.downloadsSearchNoResults(query),
                  icon: Icons.search_off,
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final item = filtered[index];
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
                isExternalSource: song.isExternal,
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
  const _DownloadedTab({required this.query});

  final String query;

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

        // Resolve song data so we can filter by title/artist.
        final resolvedSongs = <String, SongsTableData?>{};
        for (final track in tracks) {
          resolvedSongs[track.songId] = ref
              .watch(songByIdProvider(track.songId))
              .asData
              ?.value;
        }

        final filtered = query.isEmpty
            ? tracks
            : tracks
                  .where((track) {
                    final song = resolvedSongs[track.songId];
                    final title = (song?.title ?? track.songId).toLowerCase();
                    final artist = (song?.artistName ?? '').toLowerCase();
                    final q = query.toLowerCase();
                    return title.contains(q) || artist.contains(q);
                  })
                  .toList(growable: false);

        return Column(
          children: <Widget>[
            if (filtered.isEmpty && query.isNotEmpty)
              Expanded(
                child: EmptyState(
                  title: l10n.downloadsSearchNoResults(query),
                  icon: Icons.search_off,
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final track = filtered[index];
                    return _DownloadedTrackTile(
                      track: track,
                      allTracks: filtered,
                      trackIndex: index,
                    );
                  },
                ),
              ),
          ],
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
  const _DownloadedTrackTile({
    required this.track,
    required this.allTracks,
    required this.trackIndex,
  });

  final CachedTracksTableData track;
  final List<CachedTracksTableData> allTracks;
  final int trackIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final songAsync = ref.watch(songByIdProvider(track.songId));
    final song = songAsync.asData?.value;

    final title = song?.title ?? track.songId;
    final artist = song?.artistName ?? '';

    final tile = ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: song?.coverArt != null
            ? CoverArtImage(
                coverArtId: song!.coverArt,
                size: 48,
                borderRadius: BorderRadius.circular(6),
                isExternalSource: song.isExternal,
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
      onTap: () {
        final queue = allTracks.map((t) => t.songId).toList(growable: false);
        unawaited(
          ref
              .read(queueProvider.notifier)
              .replace(queue, startIndex: trackIndex, autoPlay: true),
        );
      },
      onLongPress: () => _showTrackMenu(context, ref, track, l10n),
    );
    if (!isDesktopRuntime) {
      return tile;
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) => unawaited(
        _showTrackMenu(
          context,
          ref,
          track,
          l10n,
          anchor: details.globalPosition,
        ),
      ),
      child: tile,
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
    await ref.read(downloadServiceProvider).removeDownloadedTrack(track.songId);
  }

  Future<void> _showTrackMenu(
    BuildContext context,
    WidgetRef ref,
    CachedTracksTableData track,
    AppLocalizations l10n, {
    Offset? anchor,
  }) async {
    if (anchor != null && isDesktopRuntime) {
      final action = await showDesktopContextMenu<_DownloadedTrackAction>(
        context: context,
        anchor: anchor,
        items: <PopupMenuEntry<_DownloadedTrackAction>>[
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.playNow,
            child: Text(l10n.librarySongMenuPlayNow),
          ),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.changeQuality,
            child: Text(l10n.downloadsChangeQuality),
          ),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.addQueue,
            child: Text(l10n.librarySongMenuAddToQueue),
          ),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.openFolder,
            child: Text(l10n.downloadsOpenFolderAction),
          ),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.removeDownload,
            child: Text(l10n.downloadsRemoveAction),
          ),
        ],
      );
      if (!context.mounted || action == null) {
        return;
      }
      await _handleTrackMenuAction(context, ref, track, l10n, action);
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.play_arrow_outlined),
                title: Text(l10n.librarySongMenuPlayNow),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.playNow,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.swap_vert),
                title: Text(l10n.downloadsChangeQuality),
                subtitle: Text(
                  l10n.downloadsChangeQualityCurrent(
                    track.bitRate == null
                        ? l10n.downloadQualityOriginal
                        : track.bitRate == 320
                        ? l10n.downloadQuality320
                        : track.bitRate == 192
                        ? l10n.downloadQuality192
                        : track.bitRate == 128
                        ? l10n.downloadQuality128
                        : '${track.bitRate} kbps ${track.format.toUpperCase()}',
                  ),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.changeQuality,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(l10n.librarySongMenuAddToQueue),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.addQueue,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(l10n.downloadsOpenFolderAction),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.openFolder,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(l10n.downloadsRemoveAction),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _handleTrackMenuAction(
                    context,
                    ref,
                    track,
                    l10n,
                    _DownloadedTrackAction.removeDownload,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleTrackMenuAction(
    BuildContext context,
    WidgetRef ref,
    CachedTracksTableData track,
    AppLocalizations l10n,
    _DownloadedTrackAction action,
  ) async {
    switch (action) {
      case _DownloadedTrackAction.playNow:
        final queue = allTracks.map((t) => t.songId).toList(growable: false);
        await ref
            .read(queueProvider.notifier)
            .replace(queue, startIndex: trackIndex, autoPlay: true);
        return;
      case _DownloadedTrackAction.changeQuality:
        final currentChoice = DownloadQualityChoice(
          quality: track.bitRate != null ? '${track.bitRate}' : null,
          format: track.bitRate != null ? track.format : null,
        );
        final choice = await showDownloadQualitySheet(
          context,
          initialChoice: currentChoice,
        );
        if (choice == null) return;
        final service = ref.read(downloadServiceProvider);
        await service.removeDownloadedTrack(track.songId);
        await service.enqueueSong(
          track.songId,
          forceRedownload: true,
          quality: choice.quality,
          format: choice.format,
        );
        if (context.mounted) {
          showAppNotice(
            context,
            message: l10n.downloadsRedownloadQueued,
            level: AppNoticeLevel.success,
          );
        }
        return;
      case _DownloadedTrackAction.addQueue:
        final song = ref.read(songByIdProvider(track.songId)).asData?.value;
        await ref.read(queueProvider.notifier).add(track.songId);
        if (context.mounted) {
          showAppNotice(
            context,
            message: l10n.librarySongAddedToQueue(song?.title ?? track.songId),
            level: AppNoticeLevel.success,
          );
        }
        return;
      case _DownloadedTrackAction.openFolder:
        final opened = await openDirectoryInFileManager(
          File(track.filePath).parent.path,
        );
        if (!opened && context.mounted) {
          showAppNotice(
            context,
            message: l10n.downloadsOpenFolderError,
            level: AppNoticeLevel.error,
          );
        }
        return;
      case _DownloadedTrackAction.removeDownload:
        await _confirmAndDelete(context, ref, track, l10n);
        return;
    }
  }
}

enum _DownloadedTrackAction {
  playNow,
  changeQuality,
  addQueue,
  openFolder,
  removeDownload,
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
  bool _updatingFolder = false;

  bool get _supportsCustomDownloadFolderSelection =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isWindows;

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
      final tracks = await ref
          .read(navisDatabaseProvider)
          .cacheDao
          .watchCachedTracksByType(CacheType.permanent)
          .first;
      await ref
          .read(downloadServiceProvider)
          .removeDownloadedTracks(tracks.map((t) => t.songId));
      if (mounted) {
        AppNoticeMessenger.of(context).clearSnackBars();
        showAppNotice(
          context,
          message: l10n.cacheSettingsClearSuccess,
          level: AppNoticeLevel.success,
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _toggleCustomDownloadFolder(bool enabled) async {
    if (enabled) {
      await _pickCustomDownloadFolder();
      return;
    }
    await _applyCustomDownloadFolder(enabled: false);
  }

  Future<void> _pickCustomDownloadFolder() async {
    final l10n = AppLocalizations.of(context)!;
    final selectedPath = await FilePicker.getDirectoryPath(
      dialogTitle: l10n.downloadsCustomFolderChooseAction,
    );
    if (!mounted || selectedPath == null) {
      return;
    }
    await _applyCustomDownloadFolder(enabled: true, path: selectedPath);
  }

  Future<void> _applyCustomDownloadFolder({
    required bool enabled,
    String? path,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _updatingFolder = true);
    try {
      await ref
          .read(downloadServiceProvider)
          .configureCustomDownloadFolder(
            enabled: enabled,
            path: path,
          );
      if (!mounted) {
        return;
      }
      AppNoticeMessenger.of(context).clearSnackBars();
      showAppNotice(
        context,
        message: enabled
            ? l10n.downloadsCustomFolderSaved
            : l10n.downloadsCustomFolderDisabled,
        level: AppNoticeLevel.success,
      );
    } on FileSystemException catch (error) {
      if (!mounted) {
        return;
      }
      AppNoticeMessenger.of(context).clearSnackBars();
      showAppNotice(
        context,
        message: l10n.downloadsCustomFolderError(error.message),
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) {
        setState(() => _updatingFolder = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final permanentStats = ref.watch(permanentCacheStatsProvider);
    final customFolderEnabled = ref.watch(customDownloadFolderEnabledProvider);
    final customFolderPath = ref.watch(customDownloadFolderPathProvider);

    if (_clearing || _updatingFolder) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _updatingFolder
                  ? l10n.downloadsCustomFolderUpdating
                  : l10n.cacheSettingsClearPermanent,
            ),
          ],
        ),
      );
    }

    return ListView(
      children: <Widget>[
        if (!isDesktopRuntime)
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
        SwitchListTile(
          title: Text(l10n.downloadsCustomFolderTitle),
          subtitle: Text(
            _supportsCustomDownloadFolderSelection
                ? customFolderEnabled && customFolderPath != null
                      ? customFolderPath
                      : l10n.downloadsCustomFolderSubtitle
                : l10n.downloadsCustomFolderUnsupported,
          ),
          value: customFolderEnabled,
          onChanged: _supportsCustomDownloadFolderSelection
              ? _toggleCustomDownloadFolder
              : null,
        ),
        if (_supportsCustomDownloadFolderSelection && customFolderEnabled)
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: Text(l10n.downloadsCustomFolderChooseAction),
            subtitle: Text(customFolderPath ?? ''),
            onTap: _pickCustomDownloadFolder,
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

// ---------------------------------------------------------------------------
// Shared search bar widget used by Queue and Downloaded tabs
// ---------------------------------------------------------------------------

class _DownloadsSearchBar extends StatelessWidget {
  const _DownloadsSearchBar({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                  onPressed: onClear,
                )
              : null,
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
        ),
      ),
    );
  }
}
