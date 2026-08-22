import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
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

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final showSearch = _tabController.index != 2;
    return Scaffold(
      appBar: desktopMode
          ? null
          : AppBar(
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
          if (desktopMode)
            _DownloadsDesktopCommandStrip(
              controller: _tabController,
              searchController: _searchController,
              showSearch: showSearch,
              searchHint: _tabController.index == 0
                  ? l10n.downloadsQueueSearchHint
                  : l10n.downloadsSearchHint,
              onSearchChanged: (value) => setState(() => _query = value),
              onClearSearch: _clearSearch,
            )
          else if (showSearch)
            _DownloadsSearchBar(
              controller: _searchController,
              hint: _tabController.index == 0
                  ? l10n.downloadsQueueSearchHint
                  : l10n.downloadsSearchHint,
              onChanged: (value) => setState(() => _query = value),
              onClear: _clearSearch,
            ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: <Widget>[
                _QueueTab(query: _query, onClearQuery: _clearSearch),
                _DownloadedTab(query: _query, onClearQuery: _clearSearch),
                const _DownloadSettingsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadsDesktopCommandStrip extends StatelessWidget {
  const _DownloadsDesktopCommandStrip({
    required this.controller,
    required this.searchController,
    required this.showSearch,
    required this.searchHint,
    required this.onSearchChanged,
    required this.onClearSearch,
  });

  final TabController controller;
  final TextEditingController searchController;
  final bool showSearch;
  final String searchHint;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey<String>('downloadsDesktopCommandStrip'),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 12),
        child: Row(
          children: <Widget>[
            IconButton(
              key: const ValueKey<String>('desktopDownloadsBackButton'),
              icon: const Icon(Icons.arrow_back),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(Navigator.of(context).maybePop()),
            ),
            const SizedBox(width: 4),
            Text(
              l10n.downloadsTitle,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TabBar(
                  controller: controller,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                  tabs: <Widget>[
                    Tab(text: l10n.downloadsTabQueue),
                    Tab(text: l10n.downloadsTabDownloaded),
                    Tab(text: l10n.downloadsTabSettings),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerRight,
              child: showSearch
                  ? SizedBox(
                      width: 304,
                      child: _DownloadsSearchBar(
                        controller: searchController,
                        hint: searchHint,
                        onChanged: onSearchChanged,
                        onClear: onClearSearch,
                        dense: true,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
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
  const _QueueTab({required this.query, required this.onClearQuery});

  final String query;
  final VoidCallback onClearQuery;

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
                  action: FilledButton.tonalIcon(
                    onPressed: onClearQuery,
                    icon: const Icon(Icons.clear_all_outlined),
                    label: Text(l10n.searchShowAll),
                  ),
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
    final playbackState = songId == null
        ? SongPlaybackIndicatorState.inactive
        : ref.watch(songPlaybackIndicatorStateProvider(songId));
    final isSelected = playbackState.isSelected;

    final tile = ListTile(
      selected: isSelected,
      selectedColor: Theme.of(context).colorScheme.primary,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.08),
      leading: ArtworkPlaybackMarker(
        state: playbackState,
        child: SizedBox(
          width: 48,
          height: 48,
          child: song?.coverArt != null
              ? CoverArtImage(
                  coverArtId: song!.coverArt,
                  size: 48,
                  borderRadius: BorderRadius.circular(6),
                  isExternalSource: song.isExternal,
                  remoteSourceIndicatorPolicy:
                      RemoteSourceIndicatorPolicy.hidden,
                )
              : Container(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.music_note),
                ),
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isSelected
            ? TextStyle(color: Theme.of(context).colorScheme.primary)
            : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (artist.isNotEmpty || (song?.isExternal ?? false))
            RemoteSourceMetadataLine(
              metadata: Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              isRemote: song?.isExternal ?? false,
              spacing: artist.isEmpty ? 0 : 6,
            ),
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
    return SongPlaybackSemantics(state: playbackState, child: tile);
  }
}

// ---------------------------------------------------------------------------
// Downloaded tab — shows permanently cached tracks (uses Riverpod)
// ---------------------------------------------------------------------------

class _DownloadedTab extends ConsumerWidget {
  const _DownloadedTab({required this.query, required this.onClearQuery});

  final String query;
  final VoidCallback onClearQuery;

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
                  action: FilledButton.tonalIcon(
                    onPressed: onClearQuery,
                    icon: const Icon(Icons.clear_all_outlined),
                    label: Text(l10n.searchShowAll),
                  ),
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
    final playbackState = ref.watch(
      songPlaybackIndicatorStateProvider(track.songId),
    );
    final isSelected = playbackState.isSelected;

    final tile = ListTile(
      selected: isSelected,
      selectedColor: Theme.of(context).colorScheme.primary,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.08),
      leading: ArtworkPlaybackMarker(
        state: playbackState,
        child: SizedBox(
          width: 48,
          height: 48,
          child: song?.coverArt != null
              ? CoverArtImage(
                  coverArtId: song!.coverArt,
                  size: 48,
                  borderRadius: BorderRadius.circular(6),
                  isExternalSource: song.isExternal,
                  remoteSourceIndicatorPolicy:
                      RemoteSourceIndicatorPolicy.hidden,
                )
              : Container(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.music_note),
                ),
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isSelected
            ? TextStyle(color: Theme.of(context).colorScheme.primary)
            : null,
      ),
      subtitle: RemoteSourceMetadataLine(
        metadata: Text(
          '$artist · ${track.format.toUpperCase()} · ${formatBytes(track.fileSize)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        isRemote: song?.isExternal ?? false,
        spacing: 8,
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
    final interactiveTile = !isDesktopRuntime
        ? tile
        : GestureDetector(
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
    return SongPlaybackSemantics(
      state: playbackState,
      child: interactiveTile,
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
          const PopupMenuDivider(),
          PopupMenuItem<_DownloadedTrackAction>(
            value: _DownloadedTrackAction.removeDownload,
            textStyle: TextStyle(color: Theme.of(context).colorScheme.error),
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
              const Divider(height: 1),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  l10n.downloadsRemoveAction,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
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
      androidSafOptions: Platform.isAndroid
          ? const AndroidSAFOptions(
              grant: AndroidSAFGrant.lifetime,
              accessMode: AndroidSAFAccessMode.readWrite,
              persistGrant: true,
            )
          : null,
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
      final service = ref.read(downloadServiceProvider);
      PermanentDownloadImportPreview? preview;
      if (enabled && path != null) {
        preview = await service.previewCustomDownloadFolder(path);
        if (!mounted) return;
        final manualSongIds = await _reviewFolderImport(preview);
        if (manualSongIds == null || !mounted) return;
        await service.configureCustomDownloadFolder(
          enabled: enabled,
          path: path,
        );
        await service.importCustomDownloadFolder(
          preview,
          manualSongIds: manualSongIds,
        );
      } else {
        await service.configureCustomDownloadFolder(
          enabled: enabled,
          path: path,
        );
      }
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

  Future<Map<String, String>?> _reviewFolderImport(
    PermanentDownloadImportPreview preview,
  ) async {
    final manualSongIds = <String, String>{};
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Import Existing Downloads?'),
          content: SizedBox(
            width: 460,
            child: Semantics(
              liveRegion: true,
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  Text(
                    '${preview.recognizedCount} track(s) can be imported. '
                    '${preview.uncertainCount} need review and '
                    '${preview.skippedCount} will be left untouched.',
                  ),
                  if (preview.profileMismatchCount > 0)
                    Text(
                      '${preview.profileMismatchCount} track(s) belong to a different Navis profile and cannot be imported here.',
                    ),
                  if (preview.unmatchedCount > 0)
                    Text(
                      '${preview.unmatchedCount} track(s) could not be matched to the synced local library.',
                    ),
                  if (preview.inaccessibleCount > 0)
                    Text(
                      '${preview.inaccessibleCount} track(s) could not be read and will be left untouched.',
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Navis will never remove files it cannot identify in this folder.',
                  ),
                  for (final item in preview.items.where(
                    (item) =>
                        item.disposition ==
                            PermanentDownloadImportDisposition.ambiguous ||
                        item.disposition ==
                            PermanentDownloadImportDisposition.unmatched,
                  ))
                    ListTile(
                      dense: true,
                      title: Text(item.relativePath),
                      subtitle: Text(
                        manualSongIds.containsKey(item.relativePath)
                            ? 'Song selected'
                            : 'Choose a local library song',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final song = await _pickLocalSong(item);
                        if (song == null || !context.mounted) return;
                        setDialogState(
                          () => manualSongIds[item.relativePath] = song.id,
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, manualSongIds),
              child: const Text('Import & Use Folder'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<SongsTableData?> _pickLocalSong(
    PermanentDownloadImportItem item,
  ) async {
    final controller = TextEditingController(
      text: item.relativePath.split('/').last.split('.').first,
    );
    var query = controller.text;
    return showDialog<SongsTableData>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Choose Library Song'),
          content: SizedBox(
            width: 460,
            height: 360,
            child: Column(
              children: <Widget>[
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Search Your Local Library',
                  ),
                  onChanged: (value) => setDialogState(() => query = value),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: FutureBuilder<List<SongsTableData>>(
                    future: ref
                        .read(navisDatabaseProvider)
                        .libraryDao
                        .searchSongsLocal(query),
                    builder: (context, snapshot) {
                      final songs = snapshot.data ?? const <SongsTableData>[];
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (songs.isEmpty)
                        return const Center(
                          child: Text('No Local Library Songs Found.'),
                        );
                      return ListView.builder(
                        itemCount: songs.length,
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          return ListTile(
                            title: Text(song.title),
                            subtitle: Text(
                              song.artistName ?? song.albumName ?? '',
                            ),
                            onTap: () => Navigator.pop(dialogContext, song),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ).whenComplete(controller.dispose);
  }

  Future<void> _rescanCustomDownloadFolder() async {
    final path = ref.read(customDownloadFolderPathProvider);
    if (path == null || path.trim().isEmpty) return;
    setState(() => _updatingFolder = true);
    try {
      final service = ref.read(downloadServiceProvider);
      final preview = await service.previewCustomDownloadFolder(path);
      final manualSongIds = await _reviewFolderImport(preview);
      if (!mounted || manualSongIds == null) return;
      final result = await service.importCustomDownloadFolder(
        preview,
        manualSongIds: manualSongIds,
      );
      if (mounted) {
        showAppNotice(
          context,
          message: '${result.importedCount} existing download(s) imported.',
          level: AppNoticeLevel.success,
        );
      }
    } on FileSystemException catch (error) {
      if (mounted) {
        showAppNotice(
          context,
          message: 'Could not scan downloads: ${error.message}',
          level: AppNoticeLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _updatingFolder = false);
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
          subtitle:
              _supportsCustomDownloadFolderSelection &&
                  customFolderEnabled &&
                  customFolderPath != null
              ? _CustomFolderLabel(path: customFolderPath)
              : Text(
                  _supportsCustomDownloadFolderSelection
                      ? l10n.downloadsCustomFolderSubtitle
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
            subtitle: _CustomFolderLabel(path: customFolderPath),
            onTap: _pickCustomDownloadFolder,
          ),
        if (_supportsCustomDownloadFolderSelection && customFolderEnabled)
          ListTile(
            leading: const Icon(Icons.manage_search_outlined),
            title: const Text('Rescan Existing Downloads'),
            subtitle: const Text('Import tracks already in this folder'),
            onTap: _rescanCustomDownloadFolder,
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

/// A tree URI is intentionally opaque. Android users see the provider's
/// folder name, while desktop platforms retain the useful filesystem path.
class _CustomFolderLabel extends StatelessWidget {
  const _CustomFolderLabel({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final value = path;
    if (!Platform.isAndroid ||
        value == null ||
        !value.startsWith('content://')) {
      return Text(value ?? '');
    }
    return FutureBuilder<AndroidSafTree>(
      future: const AndroidSafStorage().inspectTree(value),
      builder: (context, snapshot) => Text(
        snapshot.data?.displayName ?? 'Selected folder',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
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
    this.dense = false,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: dense
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(12, 8, 12, 4),
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
          contentPadding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: dense ? 10 : 14,
          ),
        ),
      ),
    );
  }
}
