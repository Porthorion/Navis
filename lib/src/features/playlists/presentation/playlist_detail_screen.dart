import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({required this.playlistId, super.key});

  final String playlistId;

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

enum _PlaylistSongContextAction {
  playNow,
  addToQueue,
  playNext,
  openArtist,
  openAlbum,
  addToPlaylist,
  download,
  deleteDownload,
  removeFromPlaylist,
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  @override
  void initState() {
    super.initState();
    // Trigger server sync for this playlist's songs
    Future.microtask(
      () => ref.invalidate(playlistDetailSyncProvider(widget.playlistId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playlistAsync = ref.watch(playlistByIdProvider(widget.playlistId));
    final songsAsync = ref.watch(playlistSongsProvider(widget.playlistId));
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final downloadedSongIds = downloadedOnly
        ? ref.watch(downloadedSongIdsProvider).asData?.value ?? const <String>{}
        : const <String>{};
    // Keep sync alive
    ref.watch(playlistDetailSyncProvider(widget.playlistId));

    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final playlistBody = playlistAsync.when(
      data: (playlist) {
        if (playlist == null) {
          return EmptyState(
            title: l10n.playlistDetailNotFound,
            subtitle: l10n.playlistDetailNotFoundSubtitle,
            icon: Icons.queue_music_outlined,
            action: OutlinedButton.icon(
              key: const ValueKey<String>('playlist-detail-back-to-library'),
              onPressed: () => NavService.returnToLibrary(context, ref),
              icon: const Icon(Icons.library_music_outlined),
              label: Text(l10n.detailUnavailableBackToLibrary),
            ),
          );
        }

        return songsAsync.when(
          data: (songs) => _buildContent(
            context,
            playlist,
            songs,
            downloadedOnly: downloadedOnly,
            downloadedSongIds: downloadedSongIds,
          ),
          loading: () => _buildContent(
            context,
            playlist,
            const [],
            isLoading: true,
            downloadedOnly: downloadedOnly,
            downloadedSongIds: downloadedSongIds,
          ),
          error: (error, _) => ErrorState(
            title: l10n.playlistDetailLoadError,
            onRetry: () => ref.invalidate(
              playlistDetailSyncProvider(widget.playlistId),
            ),
          ),
        );
      },
      loading: () => const ShimmerListPage(count: 8),
      error: (error, _) => ErrorState(
        title: l10n.playlistDetailLoadError,
        onRetry: () => ref.invalidate(
          playlistDetailSyncProvider(widget.playlistId),
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.playlistDetailTitle),
        actions: <Widget>[],
      ),
      body: desktopMode
          ? DesktopFrame(
              layoutClass: resolveDesktopLayoutClass(
                MediaQuery.sizeOf(context).width,
              ),
              padding: EdgeInsets.zero,
              child: playlistBody,
            )
          : playlistBody,
    );
  }

  Widget _buildContent(
    BuildContext context,
    PlaylistsTableData playlist,
    List<SongsTableData> songs, {
    bool isLoading = false,
    required bool downloadedOnly,
    required Set<String> downloadedSongIds,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final visibleEntries = songs.indexed
        .where(
          (entry) => !downloadedOnly || downloadedSongIds.contains(entry.$2.id),
        )
        .map((entry) => (song: entry.$2, playlistIndex: entry.$1))
        .toList(growable: false);
    final visibleSongs = visibleEntries
        .map((entry) => entry.song)
        .toList(growable: false);
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    const desktopTrackPadding = EdgeInsets.fromLTRB(24, 0, 24, 0);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(playlistDetailSyncProvider(widget.playlistId));
        await ref.read(playlistDetailSyncProvider(widget.playlistId).future);
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: desktopMode
                ? ColoredBox(
                    key: const ValueKey<String>(
                      'playlist-detail-desktop-header',
                    ),
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          CoverArtImage(
                            coverArtId: playlist.coverArt,
                            size: kCoverArtStandardSize,
                            height: 220,
                            borderRadius: BorderRadius.circular(16),
                            placeholderIcon: Icons.queue_music,
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  playlist.name,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.headlineMedium,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  l10n.playlistDetailMeta(
                                    playlist.owner ?? '',
                                    visibleSongs.length,
                                  ),
                                ),
                                if (downloadedOnly) ...<Widget>[
                                  const SizedBox(height: 8),
                                  Chip(
                                    label: Text(
                                      l10n.libraryDownloadedOnlyFilter,
                                    ),
                                    avatar: const Icon(
                                      Icons.download_done,
                                      size: 18,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: <Widget>[
                                    // Play is the one primary entity action;
                                    // Shuffle and Download remain supporting
                                    // actions, matching album and artist detail.
                                    FilledButton.icon(
                                      onPressed: visibleSongs.isEmpty
                                          ? null
                                          : () => _queuePlaylist(
                                              visibleSongs,
                                              shuffle: false,
                                            ),
                                      icon: const Icon(Icons.play_arrow),
                                      label: Text(
                                        l10n.playlistDetailPlayAction,
                                      ),
                                    ),
                                    FilledButton.tonalIcon(
                                      onPressed: visibleSongs.isEmpty
                                          ? null
                                          : () => _queuePlaylist(
                                              visibleSongs,
                                              shuffle: true,
                                            ),
                                      icon: const Icon(
                                        Icons.shuffle_outlined,
                                      ),
                                      label: Text(
                                        l10n.playlistDetailShuffleAction,
                                      ),
                                    ),
                                    FilledButton.tonalIcon(
                                      onPressed: visibleSongs.isEmpty
                                          ? null
                                          : () => unawaited(
                                              _downloadPlaylist(
                                                playlist,
                                                visibleSongs,
                                              ),
                                            ),
                                      icon: const Icon(
                                        Icons.download_outlined,
                                      ),
                                      label: Text(l10n.downloadAction),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                          child: CoverArtImage(
                            coverArtId: playlist.coverArt,
                            size: kCoverArtStandardSize,
                            height: 180,
                            borderRadius: BorderRadius.circular(12),
                            placeholderIcon: Icons.queue_music,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                        child: Text(
                          playlist.name,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Text(
                          l10n.playlistDetailMeta(
                            playlist.owner ?? '',
                            visibleSongs.length,
                          ),
                        ),
                      ),
                      if (downloadedOnly)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Chip(
                              label: Text(l10n.libraryDownloadedOnlyFilter),
                              avatar: const Icon(Icons.download_done, size: 18),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            // Keep the phone hierarchy identical to desktop:
                            // one filled Play action, then tonal supporting
                            // actions.
                            FilledButton.icon(
                              onPressed: visibleSongs.isEmpty
                                  ? null
                                  : () => _queuePlaylist(
                                      visibleSongs,
                                      shuffle: false,
                                    ),
                              icon: const Icon(Icons.play_arrow),
                              label: Text(l10n.playlistDetailPlayAction),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: visibleSongs.isEmpty
                                  ? null
                                  : () => _queuePlaylist(
                                      visibleSongs,
                                      shuffle: true,
                                    ),
                              icon: const Icon(Icons.shuffle_outlined),
                              label: Text(l10n.playlistDetailShuffleAction),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: visibleSongs.isEmpty
                                  ? null
                                  : () => unawaited(
                                      _downloadPlaylist(playlist, visibleSongs),
                                    ),
                              icon: const Icon(Icons.download_outlined),
                              label: Text(l10n.downloadAction),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
          ),
          if (visibleSongs.isEmpty)
            SliverPadding(
              padding: desktopMode ? desktopTrackPadding : EdgeInsets.zero,
              sliver: SliverFillRemaining(
                hasScrollBody: false,
                child: isLoading
                    ? const ShimmerListPage()
                    : downloadedOnly
                    ? EmptyState(
                        title: l10n.libraryDownloadedOnlyEmpty,
                        subtitle: l10n.libraryDownloadedOnlyEmptySubtitle,
                        icon: Icons.download_done_outlined,
                      )
                    : EmptyState(
                        title: l10n.playlistDetailEmptyTitle,
                        subtitle: l10n.playlistDetailEmptySubtitle,
                        icon: Icons.music_note_outlined,
                      ),
              ),
            )
          else if (downloadedOnly)
            SliverPadding(
              padding: desktopMode ? desktopTrackPadding : EdgeInsets.zero,
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final entry = visibleEntries[index];
                  final song = entry.song;
                  return Material(
                    type: MaterialType.transparency,
                    child: TrackListTile(
                      song: song,
                      onTap: () => _playNow(visibleSongs, index),
                      onLongPress: () =>
                          _showSongActions(song, entry.playlistIndex),
                      onSecondaryTapDown: (details) => _showSongActions(
                        song,
                        entry.playlistIndex,
                        anchor: details.globalPosition,
                      ),
                      trailing: desktopMode
                          ? DesktopSongActions(
                              song: song,
                              keyPrefix: 'playlist-song',
                              onMore: (anchor) => _showSongActions(
                                song,
                                entry.playlistIndex,
                                anchor: anchor,
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                SongDownloadStatusIcon(
                                  songId: song.id,
                                  onDownload: () =>
                                      unawaited(_downloadSong(song)),
                                ),
                                _songActionsButton(song, entry.playlistIndex),
                              ],
                            ),
                    ),
                  );
                }, childCount: visibleEntries.length),
              ),
            )
          else
            SliverPadding(
              padding: desktopMode ? desktopTrackPadding : EdgeInsets.zero,
              sliver: SliverReorderableList(
                onReorder: (oldIndex, newIndex) =>
                    unawaited(_reorderTrack(songs, oldIndex, newIndex)),
                itemCount: songs.length,
                itemBuilder: (context, index) {
                  final song = songs[index];
                  return Material(
                    key: ValueKey('${widget.playlistId}-${song.id}-$index'),
                    type: MaterialType.transparency,
                    child: TrackListTile(
                      song: song,
                      onTap: () => _playNow(songs, index),
                      onLongPress: () => _showSongActions(song, index),
                      onSecondaryTapDown: (details) => _showSongActions(
                        song,
                        index,
                        anchor: details.globalPosition,
                      ),
                      trailing: desktopMode
                          ? DesktopSongActions(
                              song: song,
                              keyPrefix: 'playlist-song',
                              onMore: (anchor) => _showSongActions(
                                song,
                                index,
                                anchor: anchor,
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                SongDownloadStatusIcon(
                                  songId: song.id,
                                  onDownload: () =>
                                      unawaited(_downloadSong(song)),
                                ),
                                _songActionsButton(song, index),
                                ReorderableDragStartListener(
                                  index: index,
                                  child: const Icon(Icons.drag_handle),
                                ),
                              ],
                            ),
                    ),
                  );
                },
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
        ],
      ),
    );
  }

  void _queuePlaylist(
    List<SongsTableData> songs, {
    required bool shuffle,
  }) {
    if (songs.isEmpty) return;

    final songsToQueue = List<SongsTableData>.of(songs);
    if (shuffle) songsToQueue.shuffle(Random());
    ref
        .read(queueProvider.notifier)
        .fireAndForget(
          () => ref
              .read(queueProvider.notifier)
              .replaceWithTableData(songsToQueue),
          label: 'replace',
        );
  }

  void _playNow(List<SongsTableData> songs, int index) {
    ref
        .read(queueProvider.notifier)
        .fireAndForget(
          () => ref
              .read(queueProvider.notifier)
              .replaceWithTableData(songs, startIndex: index, autoPlay: true),
          label: 'playNow',
        );
  }

  Future<void> _removeTrack(int songIndex) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    try {
      await api.updatePlaylist(
        id: widget.playlistId,
        songIndexesToRemove: [songIndex],
      );
      ref.invalidate(playlistDetailSyncProvider(widget.playlistId));
      if (!mounted) return;
      showAppNotice(
        context,
        message: l10n.playlistDetailTrackRemoved,
        level: AppNoticeLevel.success,
      );
    } on Object {
      if (!mounted) return;
      showAppNotice(
        context,
        message: l10n.playlistDetailTrackRemoveFailed,
        level: AppNoticeLevel.error,
      );
    }
  }

  /// Reorder a track within the playlist via the Subsonic API.
  ///
  /// Uses `createPlaylist.view?playlistId=…&songId=…` to atomically replace
  /// the playlist's song list in a single call, avoiding the brittle
  /// remove-all + re-add pattern that could leave the playlist empty if the
  /// second request fails.
  Future<void> _reorderTrack(
    List<SongsTableData> songs,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex == newIndex) return;

    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    // Build the desired order locally.
    final reordered = songs.map((s) => s.id).toList();
    final songId = reordered.removeAt(oldIndex);
    final insertAt = newIndex > oldIndex ? newIndex - 1 : newIndex;
    reordered.insert(insertAt, songId);

    try {
      await api.replacePlaylistSongs(
        playlistId: widget.playlistId,
        songIds: reordered,
      );

      ref.invalidate(playlistDetailSyncProvider(widget.playlistId));
    } on Object {
      // Revert UI by re-syncing.
      ref.invalidate(playlistDetailSyncProvider(widget.playlistId));
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showAppNotice(
        context,
        message: l10n.playlistDetailTrackRemoveFailed,
        level: AppNoticeLevel.error,
      );
    }
  }

  Widget _songActionsButton(SongsTableData song, int songIndex) {
    final l10n = AppLocalizations.of(context)!;
    final buttonKey = GlobalKey();
    return IconButton(
      key: buttonKey,
      icon: const Icon(Icons.more_vert),
      tooltip: l10n.nowPlayingMore,
      onPressed: () => _showSongActions(
        song,
        songIndex,
        anchor: _menuAnchorFor(buttonKey.currentContext),
      ),
    );
  }

  Offset? _menuAnchorFor(BuildContext? anchorContext) {
    if (!isDesktopRuntime) return null;
    if (anchorContext == null) return null;
    final renderObject = anchorContext.findRenderObject();
    if (renderObject is! RenderBox) return null;
    return renderObject.localToGlobal(renderObject.size.center(Offset.zero));
  }

  void _showSongActions(
    SongsTableData song,
    int songIndex, {
    Offset? anchor,
  }) {
    if (anchor != null && isDesktopRuntime) {
      unawaited(
        _showDesktopSongActions(song, songIndex, anchor: anchor),
      );
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_arrow_outlined),
              title: Text(l10n.librarySongMenuPlayNow),
              onTap: () {
                Navigator.of(sheetContext).pop();
                final downloadedOnly = ref.read(downloadedOnlyFilterProvider);
                final downloadedSongIds = downloadedOnly
                    ? ref.read(downloadedSongIdsProvider).asData?.value ??
                          const <String>{}
                    : const <String>{};
                final songs =
                    ref
                        .read(playlistSongsProvider(widget.playlistId))
                        .asData
                        ?.value ??
                    const <SongsTableData>[];
                final playableEntries = songs.indexed
                    .where(
                      (entry) =>
                          !downloadedOnly ||
                          downloadedSongIds.contains(entry.$2.id),
                    )
                    .toList(growable: false);
                final playableSongs = playableEntries
                    .map((entry) => entry.$2)
                    .toList(growable: false);
                final visibleIndex = playableEntries.indexWhere(
                  (entry) => entry.$1 == songIndex,
                );
                if (visibleIndex < 0) {
                  return;
                }
                _playNow(playableSongs, visibleIndex);
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_outlined),
              title: Text(l10n.librarySongMenuAddToQueue),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref
                    .read(queueProvider.notifier)
                    .fireAndForget(
                      () => ref.read(queueProvider.notifier).add(song.id),
                      label: 'addToQueue',
                    );
                // Optimistic success feedback.
                showAppNotice(
                  this.context,
                  message: l10n.librarySongAddedToQueue(song.title),
                  level: AppNoticeLevel.success,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_outlined),
              title: Text(l10n.librarySongMenuPlayNext),
              onTap: () {
                Navigator.of(sheetContext).pop();
                ref
                    .read(queueProvider.notifier)
                    .fireAndForget(
                      () => ref.read(queueProvider.notifier).playNext(song.id),
                      label: 'playNext',
                    );
                // Optimistic success feedback.
                showAppNotice(
                  this.context,
                  message: l10n.librarySongPlayNextQueued(song.title),
                  level: AppNoticeLevel.success,
                );
              },
            ),
            const Divider(height: 1),
            if (song.artistId != null && song.artistId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(l10n.librarySongMenuOpenArtist),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NavService.openArtistDetail(context, ref, song.artistId!);
                },
              ),
            if (song.albumId != null && song.albumId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.album_outlined),
                title: Text(l10n.nowPlayingGoToAlbum),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NavService.openAlbumDetail(context, ref, song.albumId!);
                },
              ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: Text(l10n.librarySongMenuAddToPlaylist),
              onTap: () {
                Navigator.of(sheetContext).pop();
                showAddToPlaylistSheet(context, ref, [song.id]);
              },
            ),
            Consumer(
              builder: (_, menuRef, _) {
                final downloadState = menuRef.watch(
                  songDownloadStateProvider(song.id),
                );
                final isDownloaded =
                    downloadState.status == SongDownloadStatus.downloaded;
                if (isDownloaded) {
                  return ListTile(
                    leading: Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      l10n.deleteDownloadAction,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(_deleteDownload(song));
                    },
                  );
                }
                return ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: Text(l10n.downloadAction),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_downloadSong(song));
                  },
                );
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                Icons.remove_circle_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                l10n.playlistDetailRemoveTrack,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_removeTrack(songIndex));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDesktopSongActions(
    SongsTableData song,
    int songIndex, {
    required Offset anchor,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final downloadState = ref.read(songDownloadStateProvider(song.id));
    final isDownloaded = downloadState.status == SongDownloadStatus.downloaded;
    final colors = Theme.of(context).colorScheme;
    final action = await showDesktopContextMenu<_PlaylistSongContextAction>(
      context: context,
      anchor: anchor,
      items: <PopupMenuEntry<_PlaylistSongContextAction>>[
        PopupMenuItem<_PlaylistSongContextAction>(
          value: _PlaylistSongContextAction.playNow,
          child: Text(l10n.librarySongMenuPlayNow),
        ),
        PopupMenuItem<_PlaylistSongContextAction>(
          value: _PlaylistSongContextAction.addToQueue,
          child: Text(l10n.librarySongMenuAddToQueue),
        ),
        PopupMenuItem<_PlaylistSongContextAction>(
          value: _PlaylistSongContextAction.playNext,
          child: Text(l10n.librarySongMenuPlayNext),
        ),
        const PopupMenuDivider(),
        if (song.artistId != null && song.artistId!.isNotEmpty)
          PopupMenuItem<_PlaylistSongContextAction>(
            value: _PlaylistSongContextAction.openArtist,
            child: Text(l10n.librarySongMenuOpenArtist),
          ),
        if (song.albumId != null && song.albumId!.isNotEmpty)
          PopupMenuItem<_PlaylistSongContextAction>(
            value: _PlaylistSongContextAction.openAlbum,
            child: Text(l10n.nowPlayingGoToAlbum),
          ),
        PopupMenuItem<_PlaylistSongContextAction>(
          value: _PlaylistSongContextAction.addToPlaylist,
          child: Text(l10n.librarySongMenuAddToPlaylist),
        ),
        PopupMenuItem<_PlaylistSongContextAction>(
          value: isDownloaded
              ? _PlaylistSongContextAction.deleteDownload
              : _PlaylistSongContextAction.download,
          textStyle: isDownloaded ? TextStyle(color: colors.error) : null,
          child: Text(
            isDownloaded ? l10n.deleteDownloadAction : l10n.downloadAction,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<_PlaylistSongContextAction>(
          value: _PlaylistSongContextAction.removeFromPlaylist,
          textStyle: TextStyle(color: colors.error),
          child: Text(l10n.playlistDetailRemoveTrack),
        ),
      ],
    );
    if (!mounted || action == null) return;

    switch (action) {
      case _PlaylistSongContextAction.playNow:
        _playSongFromMenu(song, songIndex);
        return;
      case _PlaylistSongContextAction.addToQueue:
        ref
            .read(queueProvider.notifier)
            .fireAndForget(
              () => ref.read(queueProvider.notifier).add(song.id),
              label: 'addToQueue',
            );
        showAppNotice(
          context,
          message: l10n.librarySongAddedToQueue(song.title),
          level: AppNoticeLevel.success,
        );
        return;
      case _PlaylistSongContextAction.playNext:
        ref
            .read(queueProvider.notifier)
            .fireAndForget(
              () => ref.read(queueProvider.notifier).playNext(song.id),
              label: 'playNext',
            );
        showAppNotice(
          context,
          message: l10n.librarySongPlayNextQueued(song.title),
          level: AppNoticeLevel.success,
        );
        return;
      case _PlaylistSongContextAction.openArtist:
        if (song.artistId != null && song.artistId!.isNotEmpty) {
          NavService.openArtistDetail(context, ref, song.artistId!);
        }
        return;
      case _PlaylistSongContextAction.openAlbum:
        if (song.albumId != null && song.albumId!.isNotEmpty) {
          NavService.openAlbumDetail(context, ref, song.albumId!);
        }
        return;
      case _PlaylistSongContextAction.addToPlaylist:
        unawaited(showAddToPlaylistSheet(context, ref, [song.id]));
        return;
      case _PlaylistSongContextAction.download:
        unawaited(_downloadSong(song));
        return;
      case _PlaylistSongContextAction.deleteDownload:
        unawaited(_deleteDownload(song));
        return;
      case _PlaylistSongContextAction.removeFromPlaylist:
        unawaited(_removeTrack(songIndex));
        return;
    }
  }

  void _playSongFromMenu(SongsTableData song, int songIndex) {
    final downloadedOnly = ref.read(downloadedOnlyFilterProvider);
    final downloadedSongIds = downloadedOnly
        ? ref.read(downloadedSongIdsProvider).asData?.value ?? const <String>{}
        : const <String>{};
    final songs =
        ref.read(playlistSongsProvider(widget.playlistId)).asData?.value ??
        const <SongsTableData>[];
    final playableEntries = songs.indexed
        .where(
          (entry) => !downloadedOnly || downloadedSongIds.contains(entry.$2.id),
        )
        .toList(growable: false);
    final playableSongs = playableEntries
        .map((entry) => entry.$2)
        .toList(growable: false);
    final visibleIndex = playableEntries.indexWhere(
      (entry) => entry.$1 == songIndex,
    );
    if (visibleIndex >= 0) {
      _playNow(playableSongs, visibleIndex);
    }
  }

  Future<void> _downloadPlaylist(
    PlaylistsTableData playlist,
    List<SongsTableData> songs,
  ) async {
    final choice = await showDownloadQualitySheet(context);
    if (choice == null || !mounted) return;

    final service = ref.read(downloadServiceProvider);
    final songIds = songs.map((s) => s.id).toList(growable: false);
    final count = await service.enqueuePlaylist(
      playlist.id,
      songIds,
      quality: choice.quality,
      format: choice.format,
    );
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showAppNotice(
      context,
      message: l10n.downloadPlaylistQueued(count),
      level: AppNoticeLevel.success,
    );
  }

  Future<void> _deleteDownload(SongsTableData song) async {
    final l10n = AppLocalizations.of(context)!;
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
    if (confirmed != true || !mounted) return;
    await ref.read(downloadServiceProvider).removeDownloadedTrack(song.id);
  }

  Future<void> _downloadSong(SongsTableData song) async {
    final choice = await showDownloadQualitySheet(context);
    if (choice == null || !mounted) return;

    final service = ref.read(downloadServiceProvider);
    await service.enqueueSong(
      song.id,
      quality: choice.quality,
      format: choice.format,
    );
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showAppNotice(
      context,
      message: l10n.downloadSongQueued,
      level: AppNoticeLevel.success,
    );
  }
}
