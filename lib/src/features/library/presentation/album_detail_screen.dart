import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/cover_art_viewer.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_cache_badge.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';

class AlbumDetailScreen extends ConsumerStatefulWidget {
  const AlbumDetailScreen({
    required this.albumId,
    this.likedOnly = false,
    super.key,
  });

  final String albumId;
  final bool likedOnly;

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  bool _isStarred = false;
  bool _isStarring = false;
  bool _isQueueActionInFlight = false;
  late bool _showLikedOnly = widget.likedOnly;

  @override
  void initState() {
    super.initState();
    ref
        .read(librarySyncControllerProvider.notifier)
        .registerAlbumInteraction(widget.albumId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final album = ref.watch(albumProvider(widget.albumId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.albumDetailTitle)),
      body: album.when(
        data: (data) {
          if (data == null) {
            return EmptyState(
              title: l10n.albumDetailNotFoundTitle,
              subtitle: l10n.albumDetailNotFoundSubtitle,
              icon: Icons.album_outlined,
            );
          }
          final details = data.album;
          final songs = data.songs;
          final filteredSongs = _showLikedOnly
              ? songs.where((song) => song.starred != null).toList()
              : songs;
          final isStarred = _isStarred || details.starred != null;
          final coverArtHeroTag = buildCoverArtHeroTag(
            coverArtId: details.coverArt,
            context: 'album',
          );
          final tracksSliver = filteredSongs.isEmpty
              ? SliverFillRemaining(
                  hasScrollBody: false,
                  child: _showLikedOnly && isStarred
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            EmptyState(
                              title: l10n.albumDetailLikedTracksEmptyTitle,
                              subtitle:
                                  l10n.albumDetailLikedTracksEmptySubtitle,
                              icon: Icons.favorite_border_outlined,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.tonal(
                              onPressed: () =>
                                  setState(() => _showLikedOnly = false),
                              child: Text(l10n.albumDetailShowAllTracksAction),
                            ),
                          ],
                        )
                      : EmptyState(
                          title: l10n.albumDetailTracksEmptyTitle,
                          subtitle: l10n.albumDetailTracksEmptySubtitle,
                          icon: Icons.music_note_outlined,
                        ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final song = filteredSongs[index];
                    return TrackListTile(
                      song: song,
                      badge: SongCacheBadge(songId: song.id),
                      onTap: _isQueueActionInFlight
                          ? null
                          : () => unawaited(_playNow(song)),
                      onLongPress: _isQueueActionInFlight
                          ? null
                          : () => unawaited(_showSongActions(song)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            icon: const Icon(Icons.more_vert),
                            onPressed: _isQueueActionInFlight
                                ? null
                                : () => unawaited(_showSongActions(song)),
                          ),
                        ],
                      ),
                    );
                  }, childCount: filteredSongs.length),
                );

          return CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => unawaited(
                            showCoverArtViewer(
                              context,
                              coverArtId: details.coverArt,
                              heroTag: coverArtHeroTag,
                            ),
                          ),
                          child: HeroCoverArt(
                            coverArtId: details.coverArt,
                            heroTag: coverArtHeroTag,
                            size: 640,
                            width: 180,
                            height: 180,
                            borderRadius: BorderRadius.circular(12),
                            placeholderIcon: Icons.album_outlined,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Text(
                        details.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Text(
                        l10n.albumDetailMeta(
                          details.artistName ?? l10n.albumDetailUnknownArtist,
                          details.year?.toString() ?? '-',
                          filteredSongs.length,
                        ),
                      ),
                    ),
                    if (_showLikedOnly)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ActionChip(
                            label: Text(l10n.libraryLikedOnlyFilter),
                            avatar: const Icon(Icons.favorite, size: 18),
                            onPressed: filteredSongs.isEmpty && isStarred
                                ? () => setState(() => _showLikedOnly = false)
                                : null,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Wrap(
                        spacing: 8,
                        children: <Widget>[
                          FilledButton.tonalIcon(
                            onPressed:
                                filteredSongs.isEmpty || _isQueueActionInFlight
                                ? null
                                : () => unawaited(
                                    _queueAlbum(
                                      filteredSongs,
                                      shuffle: false,
                                    ),
                                  ),
                            icon: const Icon(Icons.play_arrow_outlined),
                            label: Text(l10n.albumDetailPlayAction),
                          ),
                          FilledButton.tonalIcon(
                            onPressed:
                                filteredSongs.isEmpty || _isQueueActionInFlight
                                ? null
                                : () => unawaited(
                                    _queueAlbum(filteredSongs, shuffle: true),
                                  ),
                            icon: const Icon(Icons.shuffle_outlined),
                            label: Text(l10n.albumDetailShuffleAction),
                          ),
                          StarButton(
                            isStarred: isStarred,
                            onPressed: _isStarring
                                ? null
                                : () => _toggleStar(isStarred: isStarred),
                            label: l10n.albumDetailStarAction,
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final choice = await showDownloadQualitySheet(
                                context,
                              );
                              if (choice == null || !context.mounted) return;
                              final service = ref.read(downloadServiceProvider);
                              final count = await service.enqueueAlbum(
                                widget.albumId,
                                quality: choice.quality,
                                format: choice.format,
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      l10n.downloadAlbumQueued(count),
                                    ),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.download_outlined),
                            label: Text(l10n.albumDetailDownloadAction),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
              tracksSliver,
              if (ref.watch(audioMuseAvailableProvider))
                SliverToBoxAdapter(
                  child: _AudioMuseSimilarAlbums(
                    albumId: widget.albumId,
                  ),
                ),
            ],
          );
        },
        loading: () => const ShimmerListPage(count: 8, leadingSize: 56),
        error: (error, _) => ErrorState(
          title: l10n.albumDetailLoadErrorTitle,
          message: error.toString(),
          onRetry: () => ref.invalidate(albumProvider(widget.albumId)),
        ),
      ),
    );
  }

  Future<void> _queueAlbum(
    List<SongsTableData> songs, {
    required bool shuffle,
  }) async {
    if (songs.isEmpty || _isQueueActionInFlight) {
      return;
    }

    final queue = songs.map((song) => song.id).toList(growable: false);
    if (shuffle) {
      queue.shuffle(Random());
    }
    await _runQueueAction(() async {
      await ref.read(queueProvider.notifier).replace(queue);
    });
  }

  Future<void> _playNow(SongsTableData song) async {
    if (_isQueueActionInFlight) {
      return;
    }

    await _runQueueAction(() async {
      await ref
          .read(queueProvider.notifier)
          .replace(<String>[song.id], startIndex: 0, autoPlay: true);
    });
  }

  Future<void> _playNext(SongsTableData song) async {
    if (_isQueueActionInFlight) {
      return;
    }

    await _runQueueAction(() async {
      await ref.read(queueProvider.notifier).playNext(song.id);
    });
  }

  Future<void> _showSongActions(SongsTableData song) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final l10n = AppLocalizations.of(this.context)!;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.play_arrow_outlined),
                title: Text(l10n.librarySongMenuPlayNow),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_playNow(song));
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music_outlined),
                title: Text(l10n.librarySongMenuAddToQueue),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(
                    () async {
                      final messenger = ScaffoldMessenger.of(this.context);
                      final localizations = AppLocalizations.of(this.context)!;
                      try {
                        await ref.read(queueProvider.notifier).add(song.id);
                      } on Object catch (error) {
                        if (!mounted) {
                          return;
                        }
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              _playbackErrorMessage(localizations, error),
                            ),
                          ),
                        );
                        return;
                      }
                      if (!mounted) {
                        return;
                      }
                    }(),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add_outlined),
                title: Text(l10n.librarySongMenuPlayNext),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_playNext(song));
                },
              ),
              if (song.artistId != null && song.artistId!.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(l10n.librarySongMenuOpenArtist),
                  onTap: () {
                    Navigator.of(context).pop();
                    this.context.go('/library/artists/${song.artistId}');
                  },
                ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: Text(l10n.librarySongMenuAddToPlaylist),
                onTap: () {
                  Navigator.of(context).pop();
                  showAddToPlaylistSheet(
                    this.context,
                    ref,
                    [song.id],
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(l10n.downloadAction),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_downloadSong(song));
                },
              ),
            ],
          ),
        );
      },
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.downloadSongQueued)),
    );
  }

  Future<void> _runQueueAction(Future<void> Function() action) async {
    if (_isQueueActionInFlight) {
      return;
    }

    setState(() => _isQueueActionInFlight = true);
    try {
      await action();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(content: Text(_playbackErrorMessage(l10n, error))),
      );
    } finally {
      if (mounted) {
        setState(() => _isQueueActionInFlight = false);
      }
    }
  }

  Future<void> _toggleStar({required bool isStarred}) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) {
      return;
    }

    // Optimistic update — flip the icon immediately, block re-taps in flight.
    setState(() {
      _isStarred = !isStarred;
      _isStarring = true;
    });
    try {
      if (isStarred) {
        await api.unstar(widget.albumId);
      } else {
        await api.star(widget.albumId);
      }
      if (!mounted) {
        return;
      }
      // Persist star change to local DB so library views update reactively.
      final dao = ref.read(navisDatabaseProvider).libraryDao;
      await dao.updateAlbumStarred(
        widget.albumId,
        isStarred ? null : DateTime.now(),
      );
    } on SubsonicConnectionException {
      // Offline — queue for retry and keep the optimistic UI.
      if (!mounted) return;
      final dao = ref.read(navisDatabaseProvider);
      await dao.starSyncDao.queueStarAction(
        itemId: widget.albumId,
        itemType: 'album',
        action: isStarred ? 'unstar' : 'star',
      );
      await dao.libraryDao.updateAlbumStarred(
        widget.albumId,
        isStarred ? null : DateTime.now(),
      );
    } on Object {
      // Rollback the optimistic update on failure.
      if (!mounted) {
        return;
      }
      setState(() => _isStarred = isStarred);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.albumDetailStarFailure)));
    } finally {
      if (mounted) {
        setState(() => _isStarring = false);
      }
    }
  }
}

class _AudioMuseSimilarAlbums extends ConsumerWidget {
  const _AudioMuseSimilarAlbums({required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncAlbums = ref.watch(audioMuseSimilarAlbumsProvider(albumId));
    return asyncAlbums.when(
      data: (albums) {
        if (albums.isEmpty) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context)!;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    l10n.audioMuseSimilarAlbums,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: albums.map((rec) {
                  return ActionChip(
                    avatar: const Icon(Icons.album, size: 18),
                    label: Text(
                      rec.artist != null
                          ? '${rec.title} — ${rec.artist}'
                          : rec.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () => context.go('/library/albums/${rec.id}'),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}
