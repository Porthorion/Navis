import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';

class PlaylistDetailScreen extends ConsumerStatefulWidget {
  const PlaylistDetailScreen({required this.playlistId, super.key});

  final String playlistId;

  @override
  ConsumerState<PlaylistDetailScreen> createState() =>
      _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends ConsumerState<PlaylistDetailScreen> {
  bool _isQueueActionInFlight = false;

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
    // Keep sync alive
    ref.watch(playlistDetailSyncProvider(widget.playlistId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.playlistDetailTitle)),
      body: playlistAsync.when(
        data: (playlist) {
          if (playlist == null) {
            return EmptyState(
              title: l10n.playlistDetailNotFound,
              subtitle: l10n.playlistDetailNotFoundSubtitle,
              icon: Icons.queue_music_outlined,
            );
          }

          return songsAsync.when(
            data: (songs) => _buildContent(context, playlist, songs),
            loading: () => _buildContent(context, playlist, const []),
            error: (error, _) => ErrorState(
              title: l10n.playlistDetailLoadError,
              message: error.toString(),
              retryLabel: 'Retry',
              onRetry: () => ref.invalidate(
                playlistDetailSyncProvider(widget.playlistId),
              ),
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          title: l10n.playlistDetailLoadError,
          message: error.toString(),
          retryLabel: 'Retry',
          onRetry: () => ref.invalidate(
            playlistDetailSyncProvider(widget.playlistId),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    PlaylistsTableData playlist,
    List<SongsTableData> songs,
  ) {
    final l10n = AppLocalizations.of(context)!;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(playlistDetailSyncProvider(widget.playlistId));
        await ref.read(playlistDetailSyncProvider(widget.playlistId).future);
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                    child: CoverArtImage(
                      coverArtId: playlist.coverArt,
                      size: 640,
                      width: 180,
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
                      songs.length,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: songs.isEmpty || _isQueueActionInFlight
                            ? null
                            : () => unawaited(
                                _queuePlaylist(songs, shuffle: false),
                              ),
                        icon: const Icon(Icons.play_arrow_outlined),
                        label: Text(l10n.playlistDetailPlayAction),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: songs.isEmpty || _isQueueActionInFlight
                            ? null
                            : () => unawaited(
                                _queuePlaylist(songs, shuffle: true),
                              ),
                        icon: const Icon(Icons.shuffle_outlined),
                        label: Text(l10n.playlistDetailShuffleAction),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
          if (songs.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                title: l10n.playlistDetailEmptyTitle,
                subtitle: l10n.playlistDetailEmptySubtitle,
                icon: Icons.music_note_outlined,
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final song = songs[index];
                  return Dismissible(
                    key: ValueKey('${widget.playlistId}-${song.id}-$index'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Theme.of(context).colorScheme.errorContainer,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 16),
                      child: Icon(
                        Icons.delete_outline,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    confirmDismiss: (_) async {
                      await _removeTrack(index);
                      return false;
                    },
                    child: TrackListTile(
                      song: song,
                      onTap: _isQueueActionInFlight
                          ? null
                          : () => unawaited(_playNow(songs, index)),
                      onLongPress: _isQueueActionInFlight
                          ? null
                          : () => _showSongActions(song, index),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: _isQueueActionInFlight
                            ? null
                            : () => _showSongActions(song, index),
                      ),
                    ),
                  );
                },
                childCount: songs.length,
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
        ],
      ),
    );
  }

  Future<void> _queuePlaylist(
    List<SongsTableData> songs, {
    required bool shuffle,
  }) async {
    if (songs.isEmpty || _isQueueActionInFlight) return;

    final queue = songs.map((s) => s.id).toList(growable: false);
    if (shuffle) queue.shuffle(Random());
    await _runQueueAction(() async {
      await ref.read(queueProvider.notifier).replace(queue);
    });
  }

  Future<void> _playNow(List<SongsTableData> songs, int index) async {
    if (_isQueueActionInFlight) return;

    final queue = songs.map((s) => s.id).toList(growable: false);
    await _runQueueAction(() async {
      await ref
          .read(queueProvider.notifier)
          .replace(queue, startIndex: index, autoPlay: true);
    });
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.playlistDetailTrackRemoved)),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.playlistDetailTrackRemoveFailed)),
      );
    }
  }

  void _showSongActions(SongsTableData song, int songIndex) {
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
                final songs =
                    ref
                        .read(playlistSongsProvider(widget.playlistId))
                        .asData
                        ?.value ??
                    [];
                unawaited(
                  _playNow(songs, songIndex),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_outlined),
              title: Text(l10n.librarySongMenuAddToQueue),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  _runQueueAction(() async {
                    await ref.read(queueProvider.notifier).add(song.id);
                  }),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_outlined),
              title: Text(l10n.librarySongMenuPlayNext),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  _runQueueAction(() async {
                    await ref.read(queueProvider.notifier).playNext(song.id);
                  }),
                );
              },
            ),
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
            if (song.artistId != null && song.artistId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(l10n.librarySongMenuOpenArtist),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NavService.goToArtist(context, ref, song.artistId!);
                },
              ),
            if (song.albumId != null && song.albumId!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.album_outlined),
                title: Text(l10n.nowPlayingGoToAlbum),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  NavService.goToAlbum(context, ref, song.albumId!);
                },
              ),
          ],
        ),
      ),
    );
  }

  String _playbackErrorMessage(AppLocalizations l10n, Object error) {
    if (error is PlaybackUnavailableException) {
      return switch (error.reason) {
        PlaybackUnavailableReason.initializing =>
          l10n.playbackUnavailableInitializing,
        PlaybackUnavailableReason.startupFailed =>
          l10n.playbackUnavailableStartupFailed,
        PlaybackUnavailableReason.unavailable =>
          l10n.playbackUnavailableGeneric,
      };
    }
    if (error is PlaybackSourceUnavailableException) {
      return l10n.playbackUnavailableSource;
    }
    return l10n.playbackActionFailed;
  }

  Future<void> _runQueueAction(Future<void> Function() action) async {
    if (_isQueueActionInFlight) return;

    setState(() => _isQueueActionInFlight = true);
    try {
      await action();
    } on Object catch (error) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_playbackErrorMessage(l10n, error))),
      );
    } finally {
      if (mounted) {
        setState(() => _isQueueActionInFlight = false);
      }
    }
  }
}
