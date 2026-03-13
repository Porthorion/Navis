import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/cover_art_viewer.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/domain/set_rating.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:url_launcher/url_launcher.dart';

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
  bool _isUpdatingRating = false;
  bool _isQueueActionInFlight = false;
  late bool _showLikedOnly = widget.likedOnly;
  bool _showDownloadedOnly = false;

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
    final downloadedSongIds = _showDownloadedOnly
        ? ref.watch(downloadedSongIdsProvider).asData?.value ?? const <String>{}
        : const <String>{};

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.albumDetailTitle),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.commonRetry,
            onPressed: () => ref.invalidate(albumInfoProvider(widget.albumId)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
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
          final filteredSongs = songs
              .where((song) {
                if (_showLikedOnly && song.starred == null) {
                  return false;
                }
                if (_showDownloadedOnly &&
                    !downloadedSongIds.contains(song.id)) {
                  return false;
                }
                return true;
              })
              .toList(growable: false);
          final isStarred = _isStarred || details.starred != null;
          final albumInfoAsync = ref.watch(albumInfoProvider(widget.albumId));
          final albumRating =
              ref.watch(albumRatingProvider(widget.albumId)).asData?.value ??
              details.userRating;
          final coverArtHeroTag = buildCoverArtHeroTag(
            coverArtId: details.coverArt,
            context: 'album',
            entityId: widget.albumId,
          );
          // ── Build render items with disc headers for multi-disc ──
          final renderItems = _buildRenderItems(filteredSongs);
          final tracksSliver = renderItems.isEmpty
              ? SliverFillRemaining(
                  hasScrollBody: false,
                  child: _showDownloadedOnly
                      ? EmptyState(
                          title: l10n.libraryDownloadedOnlyEmpty,
                          subtitle: l10n.libraryDownloadedOnlyEmptySubtitle,
                          icon: Icons.download_done_outlined,
                        )
                      : _showLikedOnly
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
                    final item = renderItems[index];
                    return switch (item) {
                      _DiscHeader(:final discNumber, :final isFirst) =>
                        _buildDiscHeader(context, l10n, discNumber, isFirst),
                      _SongItem(:final song) => TrackListTile(
                        song: song,
                        onTap: _isQueueActionInFlight
                            ? null
                            : () => unawaited(_playNow(song)),
                        onLongPress: _isQueueActionInFlight
                            ? null
                            : () => unawaited(_showSongActions(song)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            SongDownloadStatusIcon(
                              songId: song.id,
                              onDownload: _isQueueActionInFlight
                                  ? null
                                  : () => unawaited(_downloadSong(song)),
                            ),
                            IconButton(
                              icon: const Icon(Icons.more_vert),
                              onPressed: _isQueueActionInFlight
                                  ? null
                                  : () => unawaited(_showSongActions(song)),
                            ),
                          ],
                        ),
                      ),
                    };
                  }, childCount: renderItems.length),
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
                              previewSize: 200,
                            ),
                          ),
                          child: HeroCoverArt(
                            coverArtId: details.coverArt,
                            heroTag: coverArtHeroTag,
                            size: 200,
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
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: <Widget>[
                          if (details.artistId != null &&
                              details.artistId!.isNotEmpty)
                            InkWell(
                              onTap: () => context.go(
                                '/library/artists/${details.artistId}',
                              ),
                              child: Text(
                                details.artistName ??
                                    l10n.albumDetailUnknownArtist,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                              ),
                            )
                          else
                            Text(
                              details.artistName ??
                                  l10n.albumDetailUnknownArtist,
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          Text(
                            '• ${details.year?.toString() ?? '-'} • ${filteredSongs.length}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            isStarred ? Icons.favorite : Icons.favorite_border,
                            size: 16,
                            color: isStarred
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isStarred ? l10n.actionLiked : l10n.actionLike,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(width: 16),
                          Text(
                            l10n.ratingTitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(width: 8),
                          Opacity(
                            opacity: _isUpdatingRating ? 0.6 : 1,
                            child: RatingWidget(
                              rating: albumRating,
                              compact: true,
                              iconSize: 16,
                              onChanged: _isUpdatingRating
                                  ? (_) {}
                                  : (next) => unawaited(
                                      _updateAlbumRating(next),
                                    ),
                            ),
                          ),
                        ],
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
                            label: l10n.actionLike,
                            starredLabel: l10n.actionLiked,
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
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.filter_list,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            l10n.albumDetailFilterLabel,
                            style:
                                Theme.of(
                                  context,
                                ).textTheme.labelSmall?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Wrap(
                        spacing: 8,
                        children: <Widget>[
                          FilterChip(
                            label: Text(l10n.libraryLikedOnlyFilter),
                            avatar: Icon(
                              _showLikedOnly
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 18,
                            ),
                            selected: _showLikedOnly,
                            onSelected: (value) =>
                                setState(() => _showLikedOnly = value),
                          ),
                          FilterChip(
                            label: Text(l10n.libraryDownloadedOnlyFilter),
                            avatar: Icon(
                              _showDownloadedOnly
                                  ? Icons.download_done
                                  : Icons.download_outlined,
                              size: 18,
                            ),
                            selected: _showDownloadedOnly,
                            onSelected: (value) =>
                                setState(() => _showDownloadedOnly = value),
                          ),
                        ],
                      ),
                    ),
                    albumInfoAsync.when(
                      data: (info) {
                        if (info == null) {
                          return const SizedBox.shrink();
                        }
                        final notes = _stripHtml(info.notes ?? '');
                        final hasNotes = notes.trim().isNotEmpty;
                        final hasLinks =
                            (info.lastFmUrl ?? '').trim().isNotEmpty ||
                            (info.musicBrainzId ?? '').trim().isNotEmpty;
                        if (!hasNotes && !hasLinks) {
                          return const SizedBox.shrink();
                        }

                        return Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    l10n.albumDetailAboutSection,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  if (hasNotes) ...<Widget>[
                                    const SizedBox(height: 8),
                                    Text(
                                      notes,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                  if (hasLinks) ...<Widget>[
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: <Widget>[
                                        if ((info.lastFmUrl ?? '')
                                            .trim()
                                            .isNotEmpty)
                                          ActionChip(
                                            avatar: const Icon(
                                              Icons.open_in_new,
                                              size: 16,
                                            ),
                                            label: Text(l10n.albumDetailLastFm),
                                            onPressed: () => unawaited(
                                              _openExternalLink(
                                                info.lastFmUrl!,
                                              ),
                                            ),
                                          ),
                                        if ((info.musicBrainzId ?? '')
                                            .trim()
                                            .isNotEmpty)
                                          ActionChip(
                                            avatar: const Icon(
                                              Icons.album_outlined,
                                              size: 16,
                                            ),
                                            label: Text(
                                              l10n.albumDetailMusicBrainz,
                                            ),
                                            onPressed: () => unawaited(
                                              _openExternalLink(
                                                'https://musicbrainz.org/release-group/${info.musicBrainzId}',
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      loading: () => const SizedBox.shrink(),
                      error: (_, _) => const SizedBox.shrink(),
                    ),
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
      await ref.read(queueProvider.notifier).replace(<String>[
        song.id,
      ], autoPlay: true);
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
      isScrollControlled: true,
      builder: (context) {
        final l10n = AppLocalizations.of(this.context)!;
        final maxHeight = MediaQuery.of(context).size.height * 0.85;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
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
                          final localizations = AppLocalizations.of(
                            this.context,
                          )!;
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
                  Consumer(
                    builder: (_, likeRef, _) {
                      final isLiked =
                          likeRef
                              .watch(songStarredProvider(song.id))
                              .asData
                              ?.value ??
                          song.starred != null;
                      return ListTile(
                        leading: Icon(
                          isLiked ? Icons.favorite : Icons.favorite_border,
                        ),
                        title: Text(
                          isLiked ? l10n.actionLiked : l10n.actionLike,
                        ),
                        onTap: () {
                          unawaited(
                            toggleSongStar(song.id, ref).catchError((_) {
                              if (this.context.mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.albumDetailStarFailure),
                                  ),
                                );
                              }
                            }),
                          );
                        },
                      );
                    },
                  ),
                  Consumer(
                    builder: (_, ratingRef, _) {
                      final rating = ratingRef
                          .watch(songRatingProvider(song.id))
                          .asData
                          ?.value;
                      return ListTile(
                        leading: const Icon(Icons.star_outline),
                        title: Text(l10n.ratingTitle),
                        subtitle: Text(l10n.ratingHint),
                        trailing: RatingWidget(
                          rating: rating,
                          compact: true,
                          onChanged: (next) {
                            unawaited(
                              setSongRating(song.id, next, ref).catchError((_) {
                                if (this.context.mounted) {
                                  ScaffoldMessenger.of(
                                    this.context,
                                  ).showSnackBar(
                                    SnackBar(
                                      content: Text(l10n.ratingUpdateFailed),
                                    ),
                                  );
                                }
                              }),
                            );
                          },
                        ),
                      );
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
                            color: Theme.of(this.context).colorScheme.error,
                          ),
                          title: Text(
                            l10n.deleteDownloadAction,
                            style: TextStyle(
                              color: Theme.of(this.context).colorScheme.error,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_deleteDownload(song));
                          },
                        );
                      }
                      return ListTile(
                        leading: const Icon(Icons.download_outlined),
                        title: Text(l10n.downloadAction),
                        onTap: () {
                          Navigator.of(context).pop();
                          unawaited(_downloadSong(song));
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
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
    final cacheDao = ref.read(navisDatabaseProvider).cacheDao;
    final track = await cacheDao.getCachedTrack(song.id);
    if (track != null) {
      await deleteFileWithSuffixes(track.filePath);
    }
    await cacheDao.removeCachedTrack(song.id);
  }

  Future<void> _downloadSong(SongsTableData song) async {
    final choice = await showDownloadQualitySheet(context);
    if (choice == null || !mounted) return;

    final service = ref.read(downloadServiceProvider);
    // Fire-and-forget — the service handles errors internally.
    unawaited(
      service.enqueueSong(
        song.id,
        albumId: widget.albumId,
        quality: choice.quality,
        format: choice.format,
      ),
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

    // Optimistic local update — flip the icon immediately, block re-taps.
    setState(() {
      _isStarred = !isStarred;
      _isStarring = true;
    });

    // Optimistic DB update BEFORE the API call — fires Drift stream
    // immediately so library/home screens watching liked albums/songs update
    // without waiting ~300 ms for the server round-trip.
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    await dao.updateAlbumStarred(
      widget.albumId,
      isStarred ? null : DateTime.now(),
    );

    try {
      if (isStarred) {
        await api.unstar(widget.albumId);
      } else {
        await api.star(widget.albumId);
      }
      if (!mounted) {
        return;
      }
      // DB already updated above — nothing more to do on success.
    } on SubsonicConnectionException {
      // Offline — the optimistic DB state is kept; just queue for server sync.
      if (!mounted) return;
      await ref
          .read(navisDatabaseProvider)
          .starSyncDao
          .queueStarAction(
            itemId: widget.albumId,
            itemType: 'album',
            action: isStarred ? 'unstar' : 'star',
          );
    } on Object {
      // API error — rollback both the optimistic local and DB state.
      if (!mounted) {
        return;
      }
      await dao.updateAlbumStarred(
        widget.albumId,
        isStarred ? DateTime.now() : null,
      );
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

  Future<void> _updateAlbumRating(int rating) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isUpdatingRating = true);
    try {
      await setAlbumRating(widget.albumId, rating, ref);
    } on Object {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.ratingUpdateFailed)));
    } finally {
      if (mounted) {
        setState(() => _isUpdatingRating = false);
      }
    }
  }

  Future<void> _openExternalLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _stripHtml(String input) {
    return input
        .replaceAll(RegExp('<[^>]+>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Pre-processes [songs] into a flat list of render items.
  /// Inserts [_DiscHeader]s when there are multiple distinct disc numbers.
  List<_AlbumRenderItem> _buildRenderItems(List<SongsTableData> songs) {
    if (songs.isEmpty) return const <_AlbumRenderItem>[];

    final discNumbers = <int>{};
    for (final song in songs) {
      discNumbers.add(song.discNumber ?? 1);
    }
    final isMultiDisc = discNumbers.length > 1;

    if (!isMultiDisc) {
      return songs.map((s) => _SongItem(song: s)).toList(growable: false);
    }

    final items = <_AlbumRenderItem>[];
    int? currentDisc;
    var isFirst = true;
    for (final song in songs) {
      final disc = song.discNumber ?? 1;
      if (disc != currentDisc) {
        items.add(_DiscHeader(discNumber: disc, isFirst: isFirst));
        currentDisc = disc;
        isFirst = false;
      }
      items.add(_SongItem(song: song));
    }
    return items;
  }

  Widget _buildDiscHeader(
    BuildContext context,
    AppLocalizations l10n,
    int discNumber,
    bool isFirst,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!isFirst) const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            l10n.albumDetailDiscHeader(discNumber),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      ],
    );
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

// ── Render-item types for disc-grouped track lists ─────────────────────────

sealed class _AlbumRenderItem {
  const _AlbumRenderItem();
}

final class _DiscHeader extends _AlbumRenderItem {
  const _DiscHeader({required this.discNumber, required this.isFirst});
  final int discNumber;
  final bool isFirst;
}

final class _SongItem extends _AlbumRenderItem {
  const _SongItem({required this.song});
  final SongsTableData song;
}
