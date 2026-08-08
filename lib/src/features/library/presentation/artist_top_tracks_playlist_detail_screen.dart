import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/artist_virtual_playlist_artwork.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';

class ArtistTopTracksPlaylistDetailScreen extends ConsumerWidget {
  const ArtistTopTracksPlaylistDetailScreen({
    required this.artistId,
    super.key,
  });

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final artistAsync = ref.watch(artistByIdProvider(artistId));
    final artistInfoAsync = ref.watch(artistInfoProvider(artistId));
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    final body = artistAsync.when(
      data: (artist) {
        if (artist == null) {
          return EmptyState(
            title: l10n.artistDetailNotFoundTitle,
            subtitle: l10n.artistDetailNotFoundSubtitle,
            icon: Icons.person_off_outlined,
          );
        }
        final tracksAsync = ref.watch(
          artistTopTracksPlaylistProvider(artist.name),
        );
        return tracksAsync.when(
          skipLoadingOnReload: true,
          data: (tracks) {
            if (tracks.isEmpty) {
              return EmptyState(
                title: l10n.artistTopTracksPlaylistEmptyTitle,
                subtitle: l10n.artistTopTracksPlaylistEmptySubtitle,
                icon: Icons.queue_music_outlined,
              );
            }
            final imageUrl =
                artistInfoAsync.asData?.value?.largeImageUrl ??
                artistInfoAsync.asData?.value?.mediumImageUrl;
            return _ArtistTopTracksPlaylistContent(
              artistName: artist.name,
              imageUrl: imageUrl,
              tracks: tracks,
            );
          },
          loading: () => const ShimmerListPage(count: 8),
          error: (error, _) => ErrorState(
            title: l10n.artistTopTracksPlaylistErrorTitle,
            message: error.toString(),
            onRetry: () => ref.invalidate(
              artistTopTracksPlaylistProvider(artist.name),
            ),
          ),
        );
      },
      loading: () => const ShimmerListPage(count: 8),
      error: (error, _) => ErrorState(
        title: l10n.artistDetailLoadErrorTitle,
        message: error.toString(),
        onRetry: () => ref.invalidate(artistByIdProvider(artistId)),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.playlistDetailTitle)),
      body: desktopMode
          ? DesktopFrame(
              layoutClass: resolveDesktopLayoutClass(
                MediaQuery.sizeOf(context).width,
              ),
              child: body,
            )
          : body,
    );
  }
}

class _ArtistTopTracksPlaylistContent extends ConsumerWidget {
  const _ArtistTopTracksPlaylistContent({
    required this.artistName,
    required this.imageUrl,
    required this.tracks,
  });

  final String artistName;
  final String? imageUrl;
  final List<ResolvedArtistTopTrack> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolvedSongs = tracks
        .map((track) => track.resolvedSong)
        .nonNulls
        .toList(growable: false);
    final coverArtIds = resolvedSongs
        .map((song) => song.coverArt)
        .nonNulls
        .toList(growable: false);
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: desktopMode
              ? DesktopPanel(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ArtistVirtualPlaylistArtwork(
                        coverArtIds: coverArtIds,
                        imageUrl: imageUrl,
                        size: 220,
                        borderRadius: 12,
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: _PlaylistHeaderText(
                          artistName: artistName,
                          onPlay: resolvedSongs.isEmpty
                              ? null
                              : () => _queueSongs(ref, resolvedSongs),
                          onShuffle: resolvedSongs.isEmpty
                              ? null
                              : () => _queueSongs(
                                  ref,
                                  resolvedSongs,
                                  shuffle: true,
                                ),
                          onDownload: resolvedSongs.isEmpty
                              ? null
                              : () => unawaited(
                                  _downloadSongs(context, ref, resolvedSongs),
                                ),
                        ),
                      ),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                        child: ArtistVirtualPlaylistArtwork(
                          coverArtIds: coverArtIds,
                          imageUrl: imageUrl,
                          size: 180,
                          borderRadius: 12,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: _PlaylistHeaderText(
                        artistName: artistName,
                        onPlay: resolvedSongs.isEmpty
                            ? null
                            : () => _queueSongs(ref, resolvedSongs),
                        onShuffle: resolvedSongs.isEmpty
                            ? null
                            : () => _queueSongs(
                                ref,
                                resolvedSongs,
                                shuffle: true,
                              ),
                        onDownload: resolvedSongs.isEmpty
                            ? null
                            : () => unawaited(
                                _downloadSongs(context, ref, resolvedSongs),
                              ),
                      ),
                    ),
                  ],
                ),
        ),
        SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (context, index) {
            final track = tracks[index];
            return _RankedTopTrackRow(track: track);
          },
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }

  void _queueSongs(
    WidgetRef ref,
    List<Song> songs, {
    bool shuffle = false,
  }) {
    if (songs.isEmpty) return;
    final queueSongs = List<Song>.of(songs);
    if (shuffle) queueSongs.shuffle(Random());
    ref
        .read(queueProvider.notifier)
        .fireAndForget(
          () => ref.read(queueProvider.notifier).replaceWithSongs(queueSongs),
          label: 'replace',
        );
  }

  Future<void> _downloadSongs(
    BuildContext context,
    WidgetRef ref,
    List<Song> songs,
  ) async {
    final choice = await showDownloadQualitySheet(context);
    if (choice == null || !context.mounted) return;
    final service = ref.read(downloadServiceProvider);
    for (final song in songs) {
      await service.enqueueSong(
        song.id,
        quality: choice.quality,
        format: choice.format,
      );
    }
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.downloadPlaylistQueued(
        songs.length,
      ),
      level: AppNoticeLevel.success,
    );
  }
}

class _PlaylistHeaderText extends StatelessWidget {
  const _PlaylistHeaderText({
    required this.artistName,
    required this.onPlay,
    required this.onShuffle,
    required this.onDownload,
  });

  final String artistName;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          l10n.artistTopTracksPlaylistTitle(artistName),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.tonalIcon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_outlined),
              label: Text(l10n.playlistDetailPlayAction),
            ),
            FilledButton.tonalIcon(
              onPressed: onShuffle,
              icon: const Icon(Icons.shuffle_outlined),
              label: Text(l10n.playlistDetailShuffleAction),
            ),
            FilledButton.tonalIcon(
              onPressed: onDownload,
              icon: const Icon(Icons.download_outlined),
              label: Text(l10n.downloadAction),
            ),
          ],
        ),
      ],
    );
  }
}

class _RankedTopTrackRow extends ConsumerWidget {
  const _RankedTopTrackRow({required this.track});

  final ResolvedArtistTopTrack track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final song = track.resolvedSong;
    final colorScheme = Theme.of(context).colorScheme;
    final unavailable = song == null;
    final playbackState = song == null
        ? SongPlaybackIndicatorState.inactive
        : ref.watch(songPlaybackIndicatorStateProvider(song.id));
    final isSelected = playbackState.isSelected;

    final tile = ListTile(
      selected: isSelected,
      selectedColor: colorScheme.primary,
      selectedTileColor: colorScheme.primary.withValues(alpha: 0.08),
      enabled: !unavailable,
      minLeadingWidth: 76,
      leading: SizedBox(
        height: 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 30,
              child: isSelected
                  ? SongPlaybackMarker(state: playbackState)
                  : Text(
                      '${track.rank}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.65,
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            CoverArtImage(
              coverArtId: song?.coverArt,
              size: 80,
              width: 44,
              height: 44,
              borderRadius: BorderRadius.circular(4),
              placeholderIcon: Icons.music_note_outlined,
              isExternalSource: song?.isExternal ?? false,
            ),
          ],
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isSelected ? TextStyle(color: colorScheme.primary) : null,
      ),
      subtitle: Text(
        unavailable ? l10n.artistTopTracksPlaylistUnavailable : track.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: song == null
          ? null
          : () => ref
                .read(queueProvider.notifier)
                .fireAndForget(
                  () => ref.read(queueProvider.notifier).replaceWithSongs([
                    song,
                  ], autoPlay: true),
                  label: 'playNow',
                ),
      trailing: song == null
          ? TextButton.icon(
              onPressed: () => NavService.openSearch(
                context,
                ref,
                '${track.title} ${track.artist}'.trim(),
              ),
              icon: const Icon(Icons.search_outlined, size: 18),
              label: Text(l10n.artistTopTracksPlaylistSearchAction),
            )
          : SongDownloadStatusIcon(
              songId: song.id,
              onDownload: () => unawaited(_downloadSong(context, ref, song.id)),
            ),
    );
    return SongPlaybackSemantics(state: playbackState, child: tile);
  }

  Future<void> _downloadSong(
    BuildContext context,
    WidgetRef ref,
    String songId,
  ) async {
    final choice = await showDownloadQualitySheet(context);
    if (choice == null || !context.mounted) return;
    await ref
        .read(downloadServiceProvider)
        .enqueueSong(
          songId,
          quality: choice.quality,
          format: choice.format,
        );
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.downloadSongQueued,
      level: AppNoticeLevel.success,
    );
  }
}
