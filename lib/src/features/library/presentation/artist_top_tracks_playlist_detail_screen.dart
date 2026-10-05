import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/artist_playback_action.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/artist_virtual_playlist_artwork.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/theme/artwork_shape.dart';

class ArtistTopTracksPlaylistDetailScreen extends ConsumerWidget {
  const new({required this.artistId, super.key});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final artistAsync = ref.watch(artistByIdProvider(artistId));
    final artistInfoAsync = ref.watch(artistInfoProvider(artistId));
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final artist = artistAsync.asData?.value;
    final appBarTitle = artist == null
        ? l10n.playlistDetailTitle
        : l10n.artistTopTracksPlaylistTitle(artist.name);

    final body = artistAsync.when(
      data: (artist) {
        if (artist == null) {
          return EmptyState(
            title: l10n.artistDetailNotFoundTitle,
            subtitle: l10n.artistDetailNotFoundSubtitle,
            icon: Icons.person_off_outlined,
          );
        }
        final key = (artistId: artist.id, name: artist.name);
        final tracksAsync = ref.watch(artistTopTracksPlaylistProvider(key));
        return tracksAsync.when(
          skipLoadingOnReload: true,
          data: (tracks) {
            // No source allowed, or none had songs: offer what the artist
            // page offers instead of "This Is".
            if (tracks.isEmpty) {
              return EmptyState(
                title: l10n.artistTopTracksPlaylistEmptyTitle,
                subtitle: l10n.artistTopTracksPlaylistEmptySubtitle,
                icon: Icons.queue_music_outlined,
                action: FilledButton.tonalIcon(
                  key: const ValueKey<String>(
                    'artist-top-tracks-shuffle-everything',
                  ),
                  onPressed: () => unawaited(
                    startArtistPlayback(
                      ProviderScope.containerOf(context, listen: false),
                      artist.id,
                      ArtistPlaybackAction.shuffle,
                    ),
                  ),
                  icon: const Icon(Icons.shuffle_rounded),
                  label: Text(l10n.artistShuffleEverythingAction),
                ),
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
            onRetry: () => ref.invalidate(
              artistTopTracksPlaylistProvider((
                artistId: artist.id,
                name: artist.name,
              )),
            ),
          ),
        );
      },
      loading: () => const ShimmerListPage(count: 8),
      error: (error, _) => ErrorState(
        title: l10n.artistDetailLoadErrorTitle,
        onRetry: () => ref.invalidate(artistByIdProvider(artistId)),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(appBarTitle)),
      body: desktopMode
          ? DesktopFrame(
              layoutClass: resolveDesktopLayoutClass(
                MediaQuery.sizeOf(context).width,
              ),
              padding: EdgeInsets.zero,
              child: body,
            )
          : body,
    );
  }
}

class _ArtistTopTracksPlaylistContent extends ConsumerWidget {
  const new({
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
    const desktopTrackPadding = EdgeInsets.symmetric(horizontal: 24);
    final colors = Theme.of(context).colorScheme;

    return CustomScrollView(
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: desktopMode
              ? ColoredBox(
                  key: const ValueKey<String>(
                    'artist-top-tracks-desktop-header',
                  ),
                  color: colors.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        ArtistVirtualPlaylistArtwork(
                          coverArtIds: coverArtIds,
                          imageUrl: imageUrl,
                          size: 260,
                        ),
                        const SizedBox(width: 28),
                        Expanded(
                          child: _PlaylistHeaderText(
                            artistName: artistName,
                            trackCount: tracks.length,
                            desktopMode: true,
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
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: _PlaylistHeaderText(
                        artistName: artistName,
                        trackCount: tracks.length,
                        desktopMode: false,
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
        if (desktopMode)
          SliverToBoxAdapter(
            child: Container(
              key: const ValueKey<String>('artist-top-tracks-desktop-fade'),
              height: 28,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[colors.surfaceContainerHigh, colors.surface],
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: desktopMode ? desktopTrackPadding : EdgeInsets.zero,
            child: const AdaptiveTrackHeader(
              numberColumnExtent: 30,
              leadingExtent: 82,
              actionExtent: 48,
            ),
          ),
        ),
        SliverPadding(
          padding: desktopMode ? desktopTrackPadding : EdgeInsets.zero,
          sliver: SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return _RankedTopTrackRow(track: track);
            },
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }

  void _queueSongs(WidgetRef ref, List<Song> songs, {bool shuffle = false}) {
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
    final choice = await requestDownloadQuality(context, ref);
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
      message: downloadQueuedNotice(
        AppLocalizations.of(context)!,
        AppLocalizations.of(context)!.downloadPlaylistQueued(songs.length),
        choice,
      ),
      level: AppNoticeLevel.success,
    );
  }
}

class _PlaylistHeaderText extends StatelessWidget {
  const new({
    required this.artistName,
    required this.trackCount,
    required this.desktopMode,
    required this.onPlay,
    required this.onShuffle,
    required this.onDownload,
  });

  final String artistName;
  final int trackCount;
  final bool desktopMode;
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          l10n.artistTopTracksPlaylistTitle(artistName),
          style: desktopMode
              ? theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                )
              : theme.textTheme.headlineSmall,
        ),
        SizedBox(height: desktopMode ? 8 : 6),
        Text(
          l10n.playlistDetailMeta(artistName, trackCount),
          style: desktopMode
              ? theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                )
              : null,
        ),
        SizedBox(height: desktopMode ? 20 : 16),
        EntityActionBar(
          onPlay: onPlay,
          onShuffle: onShuffle,
          secondary: <Widget>[
            EntitySecondaryAction(
              icon: const Icon(Icons.download_outlined),
              label: l10n.downloadAction,
              onPressed: onDownload,
            ),
          ],
        ),
      ],
    );
  }
}

class _RankedTopTrackRow extends ConsumerWidget {
  const new({required this.track});

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
    final isRemote =
        !(song == null) &&
        isExternalCatalogSource(id: song.id, apiIsExternal: song.isExternal);

    final tile = AdaptiveTrackRow(
      title: track.title,
      artist: track.artist,
      album: song?.album,
      duration: song?.duration,
      selected: isSelected,
      isRemote: isRemote,
      leadingExtent: 82,
      actionExtent: 48,
      badge: unavailable
          ? Text(
              l10n.artistTopTracksPlaylistUnavailable,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            )
          : null,
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
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            CoverArtImage(
              coverArtId: song?.coverArt,
              size: 80,
              width: 44,
              height: 44,
              shape: ArtworkShapeRole.cover,
              placeholderIcon: Icons.music_note_outlined,
              isExternalSource: isRemote,
              remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
            ),
          ],
        ),
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
      actions: song == null
          ? IconButton(
              tooltip: l10n.artistTopTracksPlaylistSearchAction,
              onPressed: () => NavService.openSearch(
                context,
                ref,
                '${track.title} ${track.artist}'.trim(),
              ),
              icon: const Icon(Icons.search_outlined),
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
    final choice = await requestDownloadQuality(context, ref);
    if (choice == null || !context.mounted) return;
    await ref
        .read(downloadServiceProvider)
        .enqueueSong(songId, quality: choice.quality, format: choice.format);
    if (!context.mounted) return;
    showAppNotice(
      context,
      message: downloadQueuedNotice(
        AppLocalizations.of(context)!,
        AppLocalizations.of(context)!.downloadSongQueued,
        choice,
      ),
      level: AppNoticeLevel.success,
    );
  }
}
