import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/common_widgets/track_match_status_label.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/data/provisional_search_songs.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/utils/catalog_source.dart';

/// A ranked virtual playlist page: artwork, title, a meta line, Play,
/// Shuffle and Download, then numbered rows. The number is each track's
/// [ResolvedArtistTopTrack.rank] ("This Is" an artist's position, Trending's
/// chart position). Rows look like the ListenBrainz weekly playlists' rows:
/// a song still searched shows "Matching", one found nowhere is faded with
/// "Not on server" and a Search action, and a playable song (a library or a
/// remote one) opens the song menu, whose album and artist open their pages
/// (remote ones through the server).
///
/// "This Is" an artist and Home's Trending Now share it. [keyPrefix] names
/// the page's test keys (`<prefix>-desktop-header`, `<prefix>-desktop-fade`).
class RankedVirtualPlaylistContent extends ConsumerWidget {
  const new({
    required this.title,
    required this.meta,
    required this.artworkBuilder,
    required this.tracks,
    required this.keyPrefix,
    super.key,
  });

  final String title;

  /// The line under the title, such as "Artist • 50 songs".
  final String meta;

  /// The playlist's artwork at the given size, from the songs' cover ids.
  final Widget Function(List<String> coverArtIds, double size) artworkBuilder;
  final List<ResolvedArtistTopTrack> tracks;
  final String keyPrefix;

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
                  key: ValueKey<String>('$keyPrefix-desktop-header'),
                  color: colors.surfaceContainerHigh,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        artworkBuilder(coverArtIds, 260),
                        const SizedBox(width: 28),
                        Expanded(
                          child: _PlaylistHeaderText(
                            title: title,
                            meta: meta,
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
                        child: artworkBuilder(coverArtIds, 180),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: _PlaylistHeaderText(
                        title: title,
                        meta: meta,
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
              key: ValueKey<String>('$keyPrefix-desktop-fade'),
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
              actionExtent: 96,
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
    required this.title,
    required this.meta,
    required this.desktopMode,
    required this.onPlay,
    required this.onShuffle,
    required this.onDownload,
  });

  final String title;
  final String meta;
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
          title,
          style: desktopMode
              ? theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                )
              : theme.textTheme.headlineSmall,
        ),
        SizedBox(height: desktopMode ? 8 : 6),
        Text(
          meta,
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
    final matching = song == null && track.isMatching;
    final unavailable = song == null && !track.isMatching;
    final playbackState = song == null
        ? SongPlaybackIndicatorState.inactive
        : ref.watch(songPlaybackIndicatorStateProvider(song.id));
    final isSelected = playbackState.isSelected;
    final isRemote =
        !(song == null) &&
        isExternalCatalogSource(id: song.id, apiIsExternal: song.isExternal);

    final tile = AdaptiveTrackRow(
      title: song?.title ?? track.title,
      artist: song?.artist ?? track.artist,
      album: song?.album,
      duration: song?.duration,
      selected: isSelected,
      isRemote: isRemote,
      leadingExtent: 82,
      actionExtent: 96,
      titleBadge: song != null
          ? null
          : TrackMatchStatusLabel(
              kind: matching
                  ? TrackMatchLabelKind.matching
                  : TrackMatchLabelKind.unavailable,
            ),
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
      onLongPress: song == null
          ? null
          : () => unawaited(_showMenu(context, ref, song)),
      onSecondaryTapDown: song == null
          ? null
          : (details) => unawaited(
              _showMenu(context, ref, song, anchor: details.globalPosition),
            ),
      actions: song == null
          ? Align(
              alignment: AlignmentDirectional.centerEnd,
              child: IconButton(
                tooltip: matching
                    ? l10n.weeklyPlaylistMatching
                    : l10n.weeklyPlaylistSearchAction,
                onPressed: matching
                    ? null
                    : () => NavService.openSearch(
                        context,
                        ref,
                        '${track.title} ${track.artist}'.trim(),
                      ),
                icon: Icon(
                  matching
                      ? Icons.hourglass_empty_rounded
                      : Icons.search_rounded,
                ),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 48,
                  height: 48,
                  child: SongDownloadStatusIcon(
                    songId: song.id,
                    onDownload: () =>
                        unawaited(_downloadSong(context, ref, song.id)),
                  ),
                ),
                Builder(
                  builder: (buttonContext) => IconButton(
                    tooltip: MaterialLocalizations.of(buttonContext)
                        .showMenuTooltip,
                    icon: const Icon(Icons.more_vert),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () => unawaited(
                      _showMenu(
                        context,
                        ref,
                        song,
                        anchor: _menuAnchorFor(buttonContext),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
    return SongPlaybackSemantics(
      state: playbackState,
      child: Opacity(
        opacity: unavailable ? TrackMatchStatusLabel.unavailableOpacity : 1,
        child: tile,
      ),
    );
  }

  static Offset? _menuAnchorFor(BuildContext anchorContext) {
    if (!isDesktopRuntime) return null;
    final renderObject = anchorContext.findRenderObject();
    if (renderObject is! RenderBox) return null;
    return renderObject.localToGlobal(renderObject.size.center(Offset.zero));
  }

  /// The song menu. A song the library does not hold yet (a remote match)
  /// is stored first, as playing it would, so the menu's queue actions find
  /// it and its album and artist open their remote pages.
  Future<void> _showMenu(
    BuildContext context,
    WidgetRef ref,
    Song song, {
    Offset? anchor,
  }) async {
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    var row = await dao.getSongById(song.id);
    if (row == null) {
      await persistProvisionalSearchSongs(dao, <Song>[song]);
      row = await dao.getSongById(song.id) ?? provisionalSongTableData(song);
    }
    if (!context.mounted) return;
    await showSongContextMenu(context, ref, row, anchor: anchor);
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
