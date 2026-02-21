import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/providers/app_providers.dart';

class AlbumDetailScreen extends ConsumerStatefulWidget {
  const AlbumDetailScreen({required this.albumId, super.key});

  final String albumId;

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  bool _isStarred = false;
  bool _isStarring = false;

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
          final isStarred = _isStarred || details.starred != null;

          return CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                        child: CoverArtImage(
                          coverArtId: details.coverArt,
                          size: 640,
                          width: 180,
                          height: 180,
                          borderRadius: BorderRadius.circular(12),
                          placeholderIcon: Icons.album_outlined,
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
                          songs.length,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Wrap(
                        spacing: 8,
                        children: <Widget>[
                          FilledButton.tonalIcon(
                            onPressed: songs.isEmpty
                                ? null
                                : () => unawaited(
                                    _queueAlbum(songs, shuffle: false),
                                  ),
                            icon: const Icon(Icons.play_arrow_outlined),
                            label: Text(l10n.albumDetailPlayAction),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: songs.isEmpty
                                ? null
                                : () => unawaited(
                                    _queueAlbum(songs, shuffle: true),
                                  ),
                            icon: const Icon(Icons.shuffle_outlined),
                            label: Text(l10n.albumDetailShuffleAction),
                          ),
                          OutlinedButton.icon(
                            onPressed: _isStarring
                                ? null
                                : () => _toggleStar(isStarred: isStarred),
                            icon: Icon(
                              isStarred ? Icons.star : Icons.star_outline,
                            ),
                            label: Text(l10n.albumDetailStarAction),
                          ),
                          OutlinedButton.icon(
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    l10n.albumDetailDownloadActionQueued,
                                  ),
                                ),
                              );
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
              if (songs.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    title: l10n.albumDetailTracksEmptyTitle,
                    subtitle: l10n.albumDetailTracksEmptySubtitle,
                    icon: Icons.music_note_outlined,
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final song = songs[index];
                    return TrackListTile(
                      song: song,
                      onTap: () => unawaited(_playNow(song)),
                      onLongPress: () => unawaited(_showSongActions(song)),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        onPressed: () => unawaited(_showSongActions(song)),
                      ),
                    );
                  }, childCount: songs.length),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          title: l10n.albumDetailLoadErrorTitle,
          message: error.toString(),
          retryLabel: l10n.commonRetry,
        ),
      ),
    );
  }

  Future<void> _queueAlbum(
    List<SongsTableData> songs, {
    required bool shuffle,
  }) async {
    if (songs.isEmpty) {
      return;
    }

    final queue = songs.map((song) => song.id).toList(growable: false);
    if (shuffle) {
      queue.shuffle(Random());
    }
    try {
      await ref.read(queueProvider.notifier).replace(queue);
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
      return;
    }
    if (!mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          shuffle
              ? l10n.albumDetailShuffleActionQueued
              : l10n.albumDetailPlayActionQueued,
        ),
      ),
    );
  }

  Future<void> _playNow(SongsTableData song) async {
    try {
      await ref.read(queueProvider.notifier).replace(<String>[song.id]);
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
      return;
    }
    if (!mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(content: Text(l10n.librarySongPlayNowQueued(song.title))),
    );
  }

  Future<void> _playNext(SongsTableData song) async {
    try {
      await ref.read(queueProvider.notifier).playNext(song.id);
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
      return;
    }
    if (!mounted) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(content: Text(l10n.librarySongPlayNextQueued(song.title))),
    );
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
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            localizations.librarySongAddedToQueue(song.title),
                          ),
                        ),
                      );
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

  Future<void> _toggleStar({required bool isStarred}) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) {
      return;
    }

    setState(() => _isStarring = true);
    try {
      if (isStarred) {
        await api.unstar(widget.albumId);
      } else {
        await api.star(widget.albumId);
      }
      if (!mounted) {
        return;
      }
      setState(() => _isStarred = !isStarred);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isStarred
                ? l10n.albumDetailUnstarSuccess
                : l10n.albumDetailStarSuccess,
          ),
        ),
      );
    } on Object {
      if (!mounted) {
        return;
      }
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
