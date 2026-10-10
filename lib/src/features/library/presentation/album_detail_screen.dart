import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_viewer.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/desktop/desktop_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/domain/set_rating.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/features/library/presentation/detail_load_states.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/common_widgets/entity_meta_line.dart';
import 'package:navis/src/utils/external_url.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/theme/artwork_shape.dart';
import 'package:navis/src/theme/navis_shape_data.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// An album's page. An album the library does not hold yet, or a remote
/// (`ext-…`) album without tracks, is fetched from the server first: the page
/// shows "Loading Remote Album…" until it has the album's title and tracks.
/// When the server cannot provide it, the page offers Retry and a search for
/// [nameHint] (with [artistNameHint]).
class AlbumDetailScreen extends ConsumerStatefulWidget {
  const new({
    required this.albumId,
    this.likedOnly = false,
    this.openingHeroTag,
    this.nameHint,
    this.artistNameHint,
    super.key,
  });

  final String albumId;
  final bool likedOnly;
  final String? openingHeroTag;

  /// The caller's title and artist for the album, shown and searched for
  /// until the library holds the album.
  final String? nameHint;
  final String? artistNameHint;

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  bool _isStarred = false;
  bool _isStarring = false;
  bool _isUpdatingRating = false;
  bool _isRefreshingAlbum = false;

  /// The page's request for the album, which only matters while the page has
  /// nothing to show (see [_showsAlbum]).
  DetailHydrationPhase _hydration = DetailHydrationPhase.running;

  /// The current request; an older one's answer or timeout is ignored.
  int _hydrationGeneration = 0;
  Timer? _hydrationTimeout;
  late bool _showLikedOnly = widget.likedOnly;
  bool _showDownloadedOnly = false;

  // Tracks the current visible (filtered) song list so _playNow can queue
  // the full album when the "queue full album on track tap" setting is on.
  List<SongsTableData> _currentFilteredSongs = const [];

  // Scroll-driven animation for the mobile header.
  final ScrollController _scrollController = ScrollController();
  double _headerProgress = 0; // 0 = art fully visible, 1 = fully collapsed
  double _screenWidth = 0;

  @override
  void initState() {
    super.initState();
    unawaited(
      _hydrate(
        ref
            .read(librarySyncControllerProvider.notifier)
            .hydrateOpenedAlbum(widget.albumId),
      ),
    );
    _scrollController.addListener(_onScroll);
  }

  /// Waits for [request] and records what it left in the library: settled
  /// once the album is stored (a remote album with at least one track),
  /// failed otherwise, including when the request or the library read
  /// throws, or when it has not answered within [kDetailHydrationTimeout]
  /// (a late answer still fills the page). Returns whether the server did
  /// not answer.
  Future<bool> _hydrate(Future<LibrarySyncState?> request) async {
    final generation = ++_hydrationGeneration;
    _hydrationTimeout?.cancel();
    _hydrationTimeout = Timer(kDetailHydrationTimeout, () {
      if (mounted &&
          generation == _hydrationGeneration &&
          _hydration == DetailHydrationPhase.running) {
        setState(() {
          _hydration = DetailHydrationPhase.failed;
          // Retry must work again even while the request keeps running.
          _isRefreshingAlbum = false;
        });
      }
    });
    var requestFailed = false;
    var phase = DetailHydrationPhase.failed;
    try {
      final result = await request;
      requestFailed = detailHydrationFailed(result);
      if (!mounted) return requestFailed;
      final dao = ref.read(navisDatabaseProvider).libraryDao;
      final stored = await dao.getAlbumById(widget.albumId);
      final storedSongs = stored == null
          ? 0
          : await dao.countSongsByAlbum(widget.albumId);
      if (stored != null && (!_isRemote(stored) || storedSongs > 0)) {
        phase = DetailHydrationPhase.settled;
      }
      // The page's album stream must not miss rows the request stored.
      final albumStream = albumProvider(widget.albumId);
      final shown = mounted ? ref.read(albumStream).value : null;
      if (mounted &&
          stored != null &&
          (shown == null || shown.songs.length < storedSongs)) {
        ref.invalidate(albumStream);
      }
    } on Object {
      requestFailed = true;
    }
    if (generation == _hydrationGeneration) _hydrationTimeout?.cancel();
    if (mounted && generation == _hydrationGeneration) {
      setState(() => _hydration = phase);
    }
    return requestFailed;
  }

  /// An `ext-…` id is remote whatever its row says.
  bool _isRemote(AlbumsTableData? album) =>
      (album?.isExternal ?? false) ||
      isExternalCatalogSource(id: widget.albumId);

  /// Whether the page has enough to show the album: a stored library album,
  /// or a remote album with at least one track. A remote album without one
  /// cannot play, so it never shows as an empty album: it loads, then offers
  /// Retry and a search.
  bool _showsAlbum(AlbumWithSongs? data) {
    if (data == null) return false;
    return !_isRemote(data.album) || data.songs.isNotEmpty;
  }

  /// "Loading Remote Album…" while the album is fetched, or Retry and a
  /// search when the server could not provide it or the library could not
  /// be read ([libraryFailed]).
  Widget _buildPendingBody(
    BuildContext context,
    AlbumsTableData? album, {
    bool libraryFailed = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final isRemote = _isRemote(album);
    final name = album?.name ?? _nonBlank(widget.nameHint);
    final artistName = album?.artistName ?? _nonBlank(widget.artistNameHint);
    final artwork = CoverArtImage(
      coverArtId: album?.coverArt,
      revision: album?.coverArtRevision ?? 0,
      width: kDetailStateArtworkExtent,
      height: kDetailStateArtworkExtent,
      shape: ArtworkShapeRole.cover,
      placeholderIcon: Icons.album_outlined,
      isExternalSource: isRemote,
      remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
    );
    final Widget body;
    if (libraryFailed || _hydration == DetailHydrationPhase.failed) {
      body = DetailLoadFailedView(
        title: l10n.albumDetailLoadFailedTitle,
        artwork: artwork,
        name: name,
        isRemote: isRemote,
        onRetry: () => unawaited(_refreshAlbum()),
        onSearch: name == null
            ? null
            : () => NavService.openSearch(
                context,
                ref,
                <String>[name, ?artistName].join(' '),
                filter: SearchResultType.albums,
              ),
      );
    } else {
      body = DetailLoadingView(
        status: isRemote
            ? l10n.albumDetailLoadingRemote
            : l10n.albumDetailLoadingServer,
        artwork: artwork,
        name: name,
        isRemote: isRemote,
        content: const DetailTrackListOutline(),
      );
    }
    if (!resolveAdaptiveContextFor(context).useDesktopShell) return body;
    return DesktopFrame(
      layoutClass: resolveDesktopLayoutClass(MediaQuery.sizeOf(context).width),
      child: body,
    );
  }

  @override
  void dispose() {
    _hydrationTimeout?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final maxScroll = max(1, _screenWidth - kToolbarHeight);
    final newProgress = (_scrollController.offset / maxScroll).clamp(0.0, 1.0);
    if ((newProgress - _headerProgress).abs() > 0.001) {
      setState(() => _headerProgress = newProgress);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final album = ref.watch(albumProvider(widget.albumId));
    final downloadedSongIds = _showDownloadedOnly
        ? ref.watch(downloadedSongIdsProvider).asData?.value ?? const <String>{}
        : const <String>{};
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = artworkBorderRadius(
      coverShape,
      extent: double.infinity,
    );
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final desktopMode = adaptiveContext.useDesktopShell;
    final compactWideMode = adaptiveContext.useCompactWideLandscape;
    final showsAlbum = _showsAlbum(album.value);

    return Scaffold(
      // AppBar is only shown on desktop or until the album can show.
      // The mobile data state uses a custom SliverAppBar with overlay nav buttons.
      appBar: (desktopMode || !showsAlbum)
          ? AppBar(
              // The page always offers a way back, even when it was opened
              // without history while the album loads.
              leading: showsAlbum
                  ? null
                  : BackButton(
                      onPressed: () =>
                          NavService.back(context, fallback: AppRoutes.library),
                    ),
              // Once loaded, the header's large album title names the page.
              title: showsAlbum
                  ? null
                  : Text(
                      album.value?.album.name ??
                          _nonBlank(widget.nameHint) ??
                          l10n.albumDetailTitle,
                    ),
              backgroundColor: desktopMode
                  ? Theme.of(context).colorScheme.surfaceContainerHigh
                  : null,
              actions: <Widget>[
                IconButton(
                  tooltip: l10n.detailRefreshAction,
                  onPressed: _isRefreshingAlbum ? null : _refreshAlbum,
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _isRefreshingAlbum
                        ? const SizedBox(
                            key: ValueKey<String>('album-refresh-loading'),
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : const Icon(
                            Icons.refresh,
                            key: ValueKey<String>('album-refresh-idle'),
                          ),
                  ),
                ),
              ],
            )
          : null,
      body: Stack(
        children: <Widget>[
          album.when(
            data: (data) {
              if (data == null || !showsAlbum) {
                return _buildPendingBody(context, data?.album);
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
              _currentFilteredSongs = filteredSongs;
              final isStarred = _isStarred || details.starred != null;
              final albumInfoAsync = ref.watch(
                albumInfoProvider(widget.albumId),
              );
              final albumRating =
                  ref
                      .watch(albumRatingProvider(widget.albumId))
                      .asData
                      ?.value ??
                  details.userRating;
              final coverArtHeroTag =
                  widget.openingHeroTag?.trim().isNotEmpty == true
                  ? widget.openingHeroTag!.trim()
                  : buildCoverArtHeroTag(
                      coverArtId: details.coverArt,
                      // Keep desktop detail/viewer artwork distinct from the
                      // Library card even when no opening Hero was supplied.
                      context: desktopMode ? 'album_detail' : 'album',
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
                                  child: Text(
                                    l10n.albumDetailShowAllTracksAction,
                                  ),
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
                        if (index == 0) {
                          return AdaptiveTrackHeader(
                            showAlbumColumn: false,
                            numberColumnExtent: 32,
                            leadingExtent: 32,
                            leadingGap: 6,
                            actionExtent: desktopMode ? null : 96,
                            padding: compactWideMode
                                ? const EdgeInsetsDirectional.only(
                                    start: 8,
                                    end: 4,
                                  )
                                : const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                          );
                        }
                        final item = renderItems[index - 1];
                        return switch (item) {
                          _DiscHeader(:final discNumber, :final isFirst) =>
                            _buildDiscHeader(
                              context,
                              l10n,
                              discNumber,
                              isFirst,
                            ),
                          _SongItem(:final song) => TrackListTile(
                            song: song,
                            showAlbumColumn: false,
                            actionExtent: desktopMode ? null : 96,
                            contentPadding: compactWideMode
                                ? const EdgeInsetsDirectional.only(
                                    start: 8,
                                    end: 4,
                                  )
                                : null,
                            horizontalTitleGap: 6,
                            onTap: () => _playNow(song),
                            onLongPress: () =>
                                unawaited(_showSongActions(song)),
                            onSecondaryTapDown: (details) => unawaited(
                              _showSongActions(
                                song,
                                anchor: details.globalPosition,
                              ),
                            ),
                            trailing: desktopMode
                                ? DesktopSongActions(
                                    song: song,
                                    keyPrefix: 'album-song',
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: song.isExternal
                                            ? null
                                            : SongDownloadStatusIcon(
                                                songId: song.id,
                                                onDownload: () => unawaited(
                                                  _downloadSong(song),
                                                ),
                                              ),
                                      ),
                                      _AlbumSongMoreButton(
                                        onPressed: (anchor) => unawaited(
                                          _showSongActions(
                                            song,
                                            anchor: anchor,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        };
                      }, childCount: renderItems.length + 1),
                    );

              // ── Desktop layout: horizontal header + scrollable track panel ──
              if (desktopMode) {
                final desktopLayoutClass = resolveDesktopLayoutClass(
                  MediaQuery.sizeOf(context).width,
                );
                final compactDesktop =
                    desktopLayoutClass == DesktopLayoutClass.compactDesktop;
                final artSize = compactDesktop ? 208.0 : 260.0;
                final colors = Theme.of(context).colorScheme;
                final textTheme = Theme.of(context).textTheme;
                final albumInfoWidget = albumInfoAsync.when(
                  data: (info) {
                    if (info == null) return const SizedBox.shrink();
                    final notes = _stripHtml(info.notes ?? '');
                    final hasNotes = notes.trim().isNotEmpty;
                    final hasLinks =
                        (info.lastFmUrl ?? '').trim().isNotEmpty ||
                        isMusicBrainzUuid(info.musicBrainzId);
                    if (!hasNotes && !hasLinks) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Divider(height: 1),
                          const SizedBox(height: 14),
                          Text(
                            l10n.albumDetailAboutSection,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (hasNotes) ...<Widget>[
                            const SizedBox(height: 8),
                            Text(
                              notes,
                              style: textTheme.bodyMedium?.copyWith(
                                height: 1.6,
                                color: colors.onSurface.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                          if (hasLinks) ...<Widget>[
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: <Widget>[
                                if ((info.lastFmUrl ?? '').trim().isNotEmpty)
                                  ActionChip(
                                    avatar: const Icon(
                                      Icons.open_in_new,
                                      size: 16,
                                    ),
                                    label: Text(l10n.albumDetailLastFm),
                                    onPressed: () => unawaited(
                                      _openExternalLink(info.lastFmUrl!),
                                    ),
                                  ),
                                if (isMusicBrainzUuid(info.musicBrainzId))
                                  ActionChip(
                                    avatar: const Icon(
                                      Icons.album_outlined,
                                      size: 16,
                                    ),
                                    label: Text(l10n.albumDetailMusicBrainz),
                                    onPressed: () => unawaited(
                                      _openExternalLink(
                                        'https://musicbrainz.org/release-group/${info.musicBrainzId}',
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 12),
                        ],
                      ),
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                );
                return SafeArea(
                  bottom: false,
                  child: DesktopFrame(
                    layoutClass: desktopLayoutClass,
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // ── Spotify-style header: tinted background ──
                        ColoredBox(
                          key: const ValueKey<String>(
                            'albumDetailDesktopHeader',
                          ),
                          color: colors.surfaceContainerHigh,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              compactDesktop ? 20 : 24,
                              compactDesktop ? 16 : 24,
                              compactDesktop ? 20 : 24,
                              compactDesktop ? 14 : 20,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: <Widget>[
                                InkWell(
                                  borderRadius: coverRadius,
                                  onTap: () => unawaited(
                                    showCoverArtViewer(
                                      context,
                                      coverArtId: details.coverArt,
                                      revision: details.coverArtRevision ?? 0,
                                      heroTag: coverArtHeroTag,
                                      previewSize: 300,
                                      isExternalSource: details.isExternal,
                                    ),
                                  ),
                                  child: HeroCoverArt(
                                    coverArtId: details.coverArt,
                                    revision: details.coverArtRevision ?? 0,
                                    heroTag: coverArtHeroTag,
                                    // Keep the same cache key as album cards
                                    // after the Hero lands. The logical layout
                                    // is still [artSize]; requesting a smaller
                                    // image here can otherwise swap in a cold
                                    // 300 px placeholder at the end of flight.
                                    size: kCoverArtStandardSize,
                                    width: artSize,
                                    height: artSize,
                                    isExternalSource: details.isExternal,
                                    remoteSourceIndicatorPolicy:
                                        RemoteSourceIndicatorPolicy.hidden,
                                    borderRadius: coverRadius,
                                    placeholderIcon: Icons.album_outlined,
                                    loadPriority: CoverArtLoadPriority.critical,
                                  ),
                                ),
                                SizedBox(width: compactDesktop ? 20 : 28),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      // Album title — large
                                      Text(
                                        details.name,
                                        style:
                                            (compactDesktop
                                                    ? textTheme.headlineLarge
                                                    : textTheme.displaySmall)
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: -0.5,
                                                  height: 1.1,
                                                ),
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      SizedBox(height: compactDesktop ? 8 : 10),
                                      // Artist, then Year · Count · Duration
                                      Wrap(
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        runSpacing: 4,
                                        children: <Widget>[
                                          ..._buildArtistChips(
                                            context: context,
                                            artists: _resolveArtists(details),
                                            textStyle: textTheme.titleMedium
                                                ?.copyWith(
                                                  color: colors.primary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                            dimStyle: textTheme.titleMedium
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                          if (details.isExternal) ...<Widget>[
                                            const SizedBox(width: 8),
                                            const RemoteSourceIndicator(
                                              variant:
                                                  RemoteSourceIndicatorVariant
                                                      .chip,
                                            ),
                                          ],
                                        ],
                                      ),
                                      // The summary gets its own line so a
                                      // wrapped artist list never leaves a
                                      // line starting with a separator.
                                      const SizedBox(height: 2),
                                      Text(
                                        entityCollectionSummary(
                                          l10n,
                                          year: details.year,
                                          songCount: songs.length,
                                          totalSeconds: _totalDurationSeconds(
                                            songs,
                                          ),
                                        ),
                                        style: textTheme.bodyMedium?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                      SizedBox(
                                        height: compactDesktop ? 16 : 20,
                                      ),
                                      EntityActionBar(
                                        onPlay: filteredSongs.isEmpty
                                            ? null
                                            : () => _queueAlbum(
                                                filteredSongs,
                                                shuffle: false,
                                              ),
                                        onShuffle: filteredSongs.isEmpty
                                            ? null
                                            : () => _queueAlbum(
                                                filteredSongs,
                                                shuffle: true,
                                              ),
                                        secondary: <Widget>[
                                          if (!details.isExternal)
                                            StarButton(
                                              isStarred: isStarred,
                                              onPressed: _isStarring
                                                  ? null
                                                  : () => _toggleStar(
                                                      isStarred: isStarred,
                                                    ),
                                              label: l10n.actionLike,
                                              starredLabel: l10n.actionLiked,
                                            ),
                                          if (!details.isExternal)
                                            EntitySecondaryAction(
                                              compact: compactDesktop,
                                              icon: const Icon(
                                                Icons.download_outlined,
                                              ),
                                              label: l10n
                                                  .albumDetailDownloadAction,
                                              onPressed: () => unawaited(
                                                _downloadAlbumSongs(context),
                                              ),
                                            ),
                                          _RatingButton(
                                            rating: albumRating,
                                            loading: _isUpdatingRating,
                                            onChanged: (next) => unawaited(
                                              _updateAlbumRating(next),
                                            ),
                                          ),
                                          _albumFilterButton(),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // ── Gradient fade from header into track list ──
                        Container(
                          height: 28,
                          // Flat: a hard step to the solid end colour.
                          decoration: NavisColorStyleData.of(context).flat
                              ? BoxDecoration(color: colors.surface)
                              : BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: <Color>[
                                      colors.surfaceContainerHigh,
                                      colors.surface,
                                    ],
                                  ),
                                ),
                        ),
                        // ── Track list — flat, no card ──
                        Expanded(
                          child: CustomScrollView(
                            slivers: <Widget>[
                              SliverToBoxAdapter(child: albumInfoWidget),
                              tracksSliver,
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 16),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              if (compactWideMode) {
                final colors = Theme.of(context).colorScheme;
                final textTheme = Theme.of(context).textTheme;
                final albumInfoSliver = albumInfoAsync.when<Widget>(
                  data: (info) {
                    if (info == null) return const SliverToBoxAdapter();
                    final notes = _stripHtml(info.notes ?? '');
                    final hasNotes = notes.trim().isNotEmpty;
                    final hasLinks =
                        (info.lastFmUrl ?? '').trim().isNotEmpty ||
                        isMusicBrainzUuid(info.musicBrainzId);
                    if (!hasNotes && !hasLinks) {
                      return const SliverToBoxAdapter();
                    }

                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Divider(height: 1),
                            const SizedBox(height: 12),
                            Text(
                              l10n.albumDetailAboutSection,
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (hasNotes) ...<Widget>[
                              const SizedBox(height: 8),
                              Text(
                                notes,
                                style: textTheme.bodyMedium?.copyWith(
                                  height: 1.5,
                                  color: colors.onSurface.withValues(
                                    alpha: 0.82,
                                  ),
                                ),
                              ),
                            ],
                            if (hasLinks) ...<Widget>[
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: <Widget>[
                                  if ((info.lastFmUrl ?? '').trim().isNotEmpty)
                                    ActionChip(
                                      avatar: const Icon(
                                        Icons.open_in_new,
                                        size: 16,
                                      ),
                                      label: Text(l10n.albumDetailLastFm),
                                      onPressed: () => unawaited(
                                        _openExternalLink(info.lastFmUrl!),
                                      ),
                                    ),
                                  if (isMusicBrainzUuid(info.musicBrainzId))
                                    ActionChip(
                                      avatar: const Icon(
                                        Icons.album_outlined,
                                        size: 16,
                                      ),
                                      label: Text(l10n.albumDetailMusicBrainz),
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
                    );
                  },
                  loading: () => const SliverToBoxAdapter(),
                  error: (_, _) => const SliverToBoxAdapter(),
                );
                final toolbarSliver = SliverToBoxAdapter(
                  child: Material(
                    key: const ValueKey<String>(
                      'albumDetailCompactWideToolbar',
                    ),
                    color: colors.surface,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 8, 2),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          EntityActionBar(
                            compact: true,
                            onPlay: filteredSongs.isEmpty
                                ? null
                                : () => _queueAlbum(
                                    filteredSongs,
                                    shuffle: false,
                                  ),
                            onShuffle: filteredSongs.isEmpty
                                ? null
                                : () =>
                                      _queueAlbum(filteredSongs, shuffle: true),
                          ),
                          _RatingButton(
                            rating: albumRating,
                            loading: _isUpdatingRating,
                            onChanged: (next) =>
                                unawaited(_updateAlbumRating(next)),
                          ),
                          IconButton(
                            tooltip: isStarred
                                ? l10n.actionLiked
                                : l10n.actionLike,
                            icon: Icon(
                              isStarred
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                            ),
                            color: isStarred ? colors.primary : null,
                            onPressed: _isStarring
                                ? null
                                : () => _toggleStar(isStarred: isStarred),
                          ),
                          _albumFilterButton(outlined: false),
                          IconButton(
                            tooltip: MaterialLocalizations.of(context)
                                .showMenuTooltip,
                            icon: const Icon(Icons.more_vert),
                            onPressed: () => unawaited(
                              _showMobileAlbumContextMenu(
                                details,
                                filteredSongs,
                                albumRating,
                                coverArtHeroTag,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                return SafeArea(
                  left: false,
                  right: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final panelWidthValue = (constraints.maxWidth * 0.28)
                          .clamp(208, 256);
                      final panelWidth = panelWidthValue.toDouble();
                      final artSize = min<double>(
                        168,
                        max<double>(148, panelWidth - 56),
                      );

                      return Row(
                        key: const ValueKey<String>(
                          'albumDetailCompactWideSplitPane',
                        ),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(
                            width: panelWidth,
                            child: Material(
                              color: colors.surfaceContainerHigh,
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  8,
                                  10,
                                  12,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Row(
                                      children: <Widget>[
                                        IconButton(
                                          tooltip: MaterialLocalizations.of(
                                            context,
                                          ).backButtonTooltip,
                                          onPressed: () => NavService.back(
                                            context,
                                            fallback: AppRoutes.library,
                                          ),
                                          icon: const Icon(Icons.arrow_back),
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          tooltip: l10n.detailRefreshAction,
                                          onPressed: _isRefreshingAlbum
                                              ? null
                                              : _refreshAlbum,
                                          icon: AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            child: _isRefreshingAlbum
                                                ? const SizedBox(
                                                    key: ValueKey<String>(
                                                      'album-refresh-loading',
                                                    ),
                                                    width: 20,
                                                    height: 20,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2.2,
                                                        ),
                                                  )
                                                : const Icon(
                                                    Icons.refresh,
                                                    key: ValueKey<String>(
                                                      'album-refresh-idle',
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Center(
                                      child: InkWell(
                                        borderRadius: coverRadius,
                                        onTap: () => unawaited(
                                          showCoverArtViewer(
                                            context,
                                            coverArtId: details.coverArt,
                                            revision:
                                                details.coverArtRevision ?? 0,
                                            heroTag: coverArtHeroTag,
                                            previewSize: 160,
                                            isExternalSource:
                                                details.isExternal,
                                          ),
                                        ),
                                        child: HeroCoverArt(
                                          coverArtId: details.coverArt,
                                          revision:
                                              details.coverArtRevision ?? 0,
                                          heroTag: coverArtHeroTag,
                                          size: kCoverArtStandardSize,
                                          width: artSize,
                                          height: artSize,
                                          isExternalSource: details.isExternal,
                                          remoteSourceIndicatorPolicy:
                                              RemoteSourceIndicatorPolicy
                                                  .hidden,
                                          borderRadius: coverRadius,
                                          placeholderIcon: Icons.album_outlined,
                                          loadPriority:
                                              CoverArtLoadPriority.critical,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      details.name,
                                      style: textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        height: 1.15,
                                      ),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      runSpacing: 2,
                                      children: <Widget>[
                                        ..._buildArtistChips(
                                          context: context,
                                          artists: _resolveArtists(details),
                                          textStyle: textTheme.bodyMedium
                                              ?.copyWith(
                                                color: colors.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                          dimStyle: textTheme.bodyMedium
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                              ),
                                        ),
                                        if (details.isExternal) ...<Widget>[
                                          const SizedBox(width: 8),
                                          const RemoteSourceIndicator(
                                            variant:
                                                RemoteSourceIndicatorVariant
                                                    .chip,
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      entityCollectionSummary(
                                        l10n,
                                        year: details.year,
                                        songCount: songs.length,
                                        totalSeconds: _totalDurationSeconds(
                                          songs,
                                        ),
                                      ),
                                      style: textTheme.bodySmall?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: colors.outlineVariant,
                          ),
                          Expanded(
                            child: CustomScrollView(
                              slivers: <Widget>[
                                toolbarSliver,
                                tracksSliver,
                                albumInfoSliver,
                                const SliverToBoxAdapter(
                                  child: SizedBox(height: 16),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              }

              final screenWidth = MediaQuery.of(context).size.width;
              final theme = Theme.of(context);
              final mobileColors = theme.colorScheme;
              final mobileTextTheme = theme.textTheme;
              final isLightTheme = theme.brightness == Brightness.light;
              // Keep _screenWidth in sync so the scroll listener can compute progress.
              _screenWidth = screenWidth;

              // Album name opacity fades out as the header collapses (gone by 90% scroll).
              final gradientScrollFade = ((0.9 - _headerProgress) / 0.3).clamp(
                0.0,
                1.0,
              );
              // Toolbar title fades in during the last 20% of the collapse.
              final toolbarTitleOpacity = ((_headerProgress - 0.8) / 0.2).clamp(
                0.0,
                1.0,
              );

              return CustomScrollView(
                controller: _scrollController,
                slivers: <Widget>[
                  // Full-bleed album art with scroll-driven collapsed toolbar.
                  SliverAppBar(
                    key: const ValueKey<String>(
                      'albumDetailMobileExpandedArtAppBar',
                    ),
                    automaticallyImplyLeading: false,
                    pinned: true,
                    toolbarHeight: kToolbarHeight,
                    expandedHeight: screenWidth,
                    backgroundColor: Color.lerp(
                      Colors.transparent,
                      mobileColors.surfaceContainerHighest,
                      _headerProgress,
                    ),
                    systemOverlayStyle: SystemUiOverlayStyle.light,
                    leading: _buildAnimatedNavButton(
                      icon: Icons.arrow_back,
                      tooltip: MaterialLocalizations.of(context)
                          .backButtonTooltip,
                      onPressed: () =>
                          NavService.back(context, fallback: AppRoutes.library),
                    ),
                    actions: <Widget>[
                      _buildAnimatedNavButton(
                        icon: Icons.refresh,
                        tooltip: l10n.detailRefreshAction,
                        isLoading: _isRefreshingAlbum,
                        onPressed: _isRefreshingAlbum ? null : _refreshAlbum,
                      ),
                    ],
                    title: Opacity(
                      opacity: toolbarTitleOpacity,
                      child: Text(
                        details.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    flexibleSpace: FlexibleSpaceBar(
                      collapseMode: CollapseMode.pin,
                      background: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          // Phone album pages deliberately render the artwork
                          // as ordinary, already-composed content. Keeping a
                          // matching Hero here would still launch an artwork
                          // flight independently of the fade-only route.
                          CoverArtImage(
                            coverArtId: details.coverArt,
                            revision: details.coverArtRevision ?? 0,
                            size: kCoverArtStandardSize,
                            width: double.infinity,
                            height: double.infinity,
                            isExternalSource: details.isExternal,
                            remoteSourceIndicatorPolicy:
                                RemoteSourceIndicatorPolicy.hidden,
                            fit: BoxFit.cover,
                            fadeInDuration: Duration.zero,
                          ),
                          if (NavisColorStyleData.of(context).flat)
                            // Flat: a hard-edged solid block under the title
                            // instead of the fade into the page.
                            Positioned.fill(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  heightFactor: 0.4,
                                  widthFactor: 1,
                                  child: ColoredBox(
                                    color: Theme.of(context)
                                        .scaffoldBackgroundColor,
                                  ),
                                ),
                              ),
                            )
                          else
                            Positioned.fill(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: <Color>[
                                      Colors.transparent,
                                      Colors.transparent,
                                      Theme.of(context).scaffoldBackgroundColor,
                                    ],
                                    stops: const <double>[0, 0.60, 0.85],
                                  ),
                                ),
                              ),
                            ),
                          // The title scrolls out with the lower gradient.
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Opacity(
                              opacity: gradientScrollFade,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  16,
                                ),
                                child: _buildMobileAlbumTitle(
                                  title: details.name,
                                  style: mobileTextTheme.displayMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: isLightTheme
                                            ? mobileColors.onSurface
                                            : Colors.white,
                                        shadows:
                                            isLightTheme ||
                                                NavisColorStyleData.of(context)
                                                    .flat
                                            ? null
                                            : <Shadow>[
                                                Shadow(
                                                  color:
                                                      NavisColorStyleData.of(
                                                        context,
                                                      ).artworkScrim.withValues(
                                                        alpha: 0.55,
                                                      ),
                                                  blurRadius: 12,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ],
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // Artist names (each individually clickable)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            runSpacing: 2,
                            children: <Widget>[
                              ..._buildArtistChips(
                                context: context,
                                artists: _resolveArtists(details),
                                textStyle: mobileTextTheme.bodyLarge?.copyWith(
                                  color: mobileColors.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                                dimStyle: mobileTextTheme.bodyLarge?.copyWith(
                                  color: mobileColors.onSurfaceVariant,
                                ),
                              ),
                              if (details.isExternal) ...<Widget>[
                                const SizedBox(width: 8),
                                const RemoteSourceIndicator(
                                  variant: RemoteSourceIndicatorVariant.chip,
                                ),
                              ],
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Text(
                            entityCollectionSummary(
                              l10n,
                              year: details.year,
                              songCount: songs.length,
                              totalSeconds: _totalDurationSeconds(songs),
                            ),
                            style: mobileTextTheme.bodyMedium?.copyWith(
                              color: mobileColors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        // Action buttons:
                        //   Left  — play (icon), shuffle (icon), Rate (text)
                        //   Right — like (icon), 3-dot context menu
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              EntityActionBar(
                                compact: true,
                                onPlay: filteredSongs.isEmpty
                                    ? null
                                    : () => _queueAlbum(
                                        filteredSongs,
                                        shuffle: false,
                                      ),
                                onShuffle: filteredSongs.isEmpty
                                    ? null
                                    : () => _queueAlbum(
                                        filteredSongs,
                                        shuffle: true,
                                      ),
                              ),
                              const SizedBox(width: 4),
                              _RatingButton(
                                rating: albumRating,
                                loading: _isUpdatingRating,
                                onChanged: (next) =>
                                    unawaited(_updateAlbumRating(next)),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: isStarred
                                    ? l10n.actionLiked
                                    : l10n.albumDetailStarAction,
                                icon: Icon(
                                  isStarred
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                ),
                                color: isStarred ? mobileColors.primary : null,
                                onPressed: _isStarring
                                    ? null
                                    : () => _toggleStar(isStarred: isStarred),
                              ),
                              _albumFilterButton(outlined: false),
                              IconButton(
                                tooltip: MaterialLocalizations.of(context)
                                    .showMenuTooltip,
                                icon: const Icon(Icons.more_vert),
                                onPressed: () => unawaited(
                                  _showMobileAlbumContextMenu(
                                    details,
                                    filteredSongs,
                                    albumRating,
                                    coverArtHeroTag,
                                  ),
                                ),
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
                                isMusicBrainzUuid(info.musicBrainzId);
                            if (!hasNotes && !hasLinks) {
                              return const SizedBox.shrink();
                            }

                            return Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        l10n.albumDetailAboutSection,
                                        style: mobileTextTheme.titleSmall,
                                      ),
                                      if (hasNotes) ...<Widget>[
                                        const SizedBox(height: 8),
                                        Text(
                                          notes,
                                          style: mobileTextTheme.bodyMedium,
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
                                                label: Text(
                                                  l10n.albumDetailLastFm,
                                                ),
                                                onPressed: () => unawaited(
                                                  _openExternalLink(
                                                    info.lastFmUrl!,
                                                  ),
                                                ),
                                              ),
                                            if (isMusicBrainzUuid(
                                              info.musicBrainzId,
                                            ))
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
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],
              );
            },
            // A remote album is fetched before it is stored, so its page says
            // so from the start.
            loading: () => _isRemote(null)
                ? _buildPendingBody(context, null)
                : const ShimmerListPage(count: 8, leadingSize: 56),
            error: (error, _) =>
                _buildPendingBody(context, null, libraryFailed: true),
          ),
          // Marks the page as showing the album, for diagnostics.
          if (showsAlbum) const SizedBox.shrink(key: detailPageShownKey),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: _isRefreshingAlbum ? 1 : 0,
              child: const LinearProgressIndicator(minHeight: 2),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshAlbum() async {
    if (_isRefreshingAlbum) {
      return;
    }
    await HapticFeedback.lightImpact();
    // An album stream that failed is read again.
    final albumStream = albumProvider(widget.albumId);
    if (ref.read(albumStream).hasError) ref.invalidate(albumStream);
    setState(() {
      _isRefreshingAlbum = true;
      _hydration = DetailHydrationPhase.running;
    });
    final request = _hydrate(
      ref
          .read(librarySyncControllerProvider.notifier)
          .requestTarget(LibrarySyncTarget.album(widget.albumId)),
    );
    // A later refresh (Retry after a timeout) owns the guard and the notice.
    final generation = _hydrationGeneration;
    try {
      final requestFailed = await request;
      if (!mounted || generation != _hydrationGeneration) {
        return;
      }
      ref.invalidate(albumInfoProvider(widget.albumId));
      // A page without the album shows the failure itself.
      if (!requestFailed ||
          !_showsAlbum(ref.read(albumProvider(widget.albumId)).value)) {
        return;
      }
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.albumDetailRefreshError,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted && generation == _hydrationGeneration) {
        setState(() => _isRefreshingAlbum = false);
      }
    }
  }

  static int _totalDurationSeconds(List<SongsTableData> songs) =>
      songs.fold<int>(0, (total, song) => total + (song.duration ?? 0));

  Widget _albumFilterButton({bool outlined = true}) {
    return _AlbumFilterButton(
      outlined: outlined,
      likedOnly: _showLikedOnly,
      downloadedOnly: _showDownloadedOnly,
      onLikedOnlyChanged: (value) => setState(() => _showLikedOnly = value),
      onDownloadedOnlyChanged: (value) =>
          setState(() => _showDownloadedOnly = value),
    );
  }

  void _queueAlbum(List<SongsTableData> songs, {required bool shuffle}) {
    if (songs.isEmpty) {
      return;
    }

    final songsToQueue = List<SongsTableData>.of(songs);
    if (shuffle) {
      songsToQueue.shuffle(Random());
    }
    ref
        .read(queueProvider.notifier)
        .fireAndForget(
          () => ref
              .read(queueProvider.notifier)
              .replaceWithTableData(
                songsToQueue,
                originalOrder: shuffle
                    ? songs.map((song) => song.id).toList()
                    : null,
              ),
          label: 'replace',
        );
  }

  void _playNow(SongsTableData song) {
    final queueFullAlbum = ref.read(albumQueueEnabledProvider);
    if (queueFullAlbum && _currentFilteredSongs.length > 1) {
      final startIndex = _currentFilteredSongs.indexWhere(
        (s) => s.id == song.id,
      );
      final effectiveIndex = startIndex < 0 ? 0 : startIndex;
      ref
          .read(queueProvider.notifier)
          .fireAndForget(
            () => ref
                .read(queueProvider.notifier)
                .replaceWithTableData(
                  _currentFilteredSongs,
                  startIndex: effectiveIndex,
                  autoPlay: true,
                ),
            label: 'playNow',
          );
    } else {
      ref
          .read(queueProvider.notifier)
          .fireAndForget(
            () => ref.read(queueProvider.notifier).replaceWithTableData(
              <SongsTableData>[song],
              autoPlay: true,
            ),
            label: 'playNow',
          );
    }
  }

  void _playNext(SongsTableData song) {
    final l10n = AppLocalizations.of(context)!;
    ref
        .read(queueProvider.notifier)
        .fireAndForget(
          () => ref.read(queueProvider.notifier).playNext(song.id),
          label: 'playNext',
        );
    // Optimistic success feedback — the action is non-blocking now.
    showAppNotice(
      context,
      message: l10n.librarySongPlayNextQueued(song.title),
      level: AppNoticeLevel.success,
    );
  }

  Future<void> _showSongActions(SongsTableData song, {Offset? anchor}) async {
    if (anchor != null && isDesktopRuntime) {
      await _showDesktopSongActions(song, anchor: anchor);
      return;
    }
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
                      _playNow(song);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.queue_music_outlined),
                    title: Text(l10n.librarySongMenuAddToQueue),
                    onTap: () {
                      Navigator.of(context).pop();
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
                      Navigator.of(context).pop();
                      _playNext(song);
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
                              if (mounted) {
                                showAppNotice(
                                  this.context,
                                  message: l10n.albumDetailStarFailure,
                                  level: AppNoticeLevel.error,
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
                                if (mounted) {
                                  showAppNotice(
                                    this.context,
                                    message: l10n.ratingUpdateFailed,
                                    level: AppNoticeLevel.error,
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
                        NavService.openArtistDetail(
                          this.context,
                          ref,
                          song.artistId!,
                          name: song.artistName,
                        );
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: Text(l10n.librarySongMenuAddToPlaylist),
                    onTap: () {
                      Navigator.of(context).pop();
                      unawaited(
                        showAddToPlaylistSheet(this.context, ref, [song.id]),
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

  Future<void> _showDesktopSongActions(
    SongsTableData song, {
    required Offset anchor,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final isLiked =
        ref.read(songStarredProvider(song.id)).asData?.value ??
        song.starred != null;
    final isDownloaded =
        ref.read(songDownloadStateProvider(song.id)).status ==
        SongDownloadStatus.downloaded;
    final action = await showDesktopContextMenu<_AlbumSongContextAction>(
      context: context,
      anchor: anchor,
      items: <PopupMenuEntry<_AlbumSongContextAction>>[
        PopupMenuItem<_AlbumSongContextAction>(
          value: _AlbumSongContextAction.playNow,
          child: Text(l10n.librarySongMenuPlayNow),
        ),
        PopupMenuItem<_AlbumSongContextAction>(
          value: _AlbumSongContextAction.addQueue,
          child: Text(l10n.librarySongMenuAddToQueue),
        ),
        PopupMenuItem<_AlbumSongContextAction>(
          value: _AlbumSongContextAction.playNext,
          child: Text(l10n.librarySongMenuPlayNext),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<_AlbumSongContextAction>(
          value: _AlbumSongContextAction.toggleLike,
          child: Text(isLiked ? l10n.actionLiked : l10n.actionLike),
        ),
        PopupMenuItem<_AlbumSongContextAction>(
          value: _AlbumSongContextAction.rate,
          child: Text(l10n.ratingTitle),
        ),
        if (song.artistId != null && song.artistId!.isNotEmpty)
          PopupMenuItem<_AlbumSongContextAction>(
            value: _AlbumSongContextAction.openArtist,
            child: Text(l10n.librarySongMenuOpenArtist),
          ),
        PopupMenuItem<_AlbumSongContextAction>(
          value: _AlbumSongContextAction.addToPlaylist,
          child: Text(l10n.librarySongMenuAddToPlaylist),
        ),
        if (isDownloaded) const PopupMenuDivider(),
        PopupMenuItem<_AlbumSongContextAction>(
          value: isDownloaded
              ? _AlbumSongContextAction.deleteDownload
              : _AlbumSongContextAction.download,
          textStyle: isDownloaded
              ? TextStyle(color: Theme.of(context).colorScheme.error)
              : null,
          child: Text(
            isDownloaded ? l10n.deleteDownloadAction : l10n.downloadAction,
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _AlbumSongContextAction.playNow:
        _playNow(song);
        return;
      case _AlbumSongContextAction.addQueue:
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
      case _AlbumSongContextAction.playNext:
        _playNext(song);
        return;
      case _AlbumSongContextAction.toggleLike:
        try {
          await toggleSongStar(song.id, ref);
        } on Object {
          if (mounted) {
            showAppNotice(
              context,
              message: l10n.albumDetailStarFailure,
              level: AppNoticeLevel.error,
            );
          }
        }
        return;
      case _AlbumSongContextAction.rate:
        await _showSongRatingDialog(song);
        return;
      case _AlbumSongContextAction.openArtist:
        NavService.openArtistDetail(
          context,
          ref,
          song.artistId!,
          name: song.artistName,
        );
        return;
      case _AlbumSongContextAction.addToPlaylist:
        await showAddToPlaylistSheet(context, ref, <String>[song.id]);
        return;
      case _AlbumSongContextAction.download:
        await _downloadSong(song);
        return;
      case _AlbumSongContextAction.deleteDownload:
        await _deleteDownload(song);
        return;
    }
  }

  Future<void> _showSongRatingDialog(SongsTableData song) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.ratingTitle),
        content: Consumer(
          builder: (_, ratingRef, _) {
            final rating = ratingRef
                .watch(songRatingProvider(song.id))
                .asData
                ?.value;
            return RatingWidget(
              rating: rating,
              onChanged: (next) {
                unawaited(
                  setSongRating(song.id, next, ref)
                      .then((_) {
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      })
                      .catchError((_) {
                        if (mounted) {
                          showAppNotice(
                            context,
                            message: l10n.ratingUpdateFailed,
                            level: AppNoticeLevel.error,
                          );
                        }
                      }),
                );
              },
            );
          },
        ),
      ),
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
    final choice = await requestDownloadQuality(context, ref);
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
    showAppNotice(
      context,
      message: downloadQueuedNotice(l10n, l10n.downloadSongQueued, choice),
      level: AppNoticeLevel.success,
    );
  }

  Future<void> _toggleStar({required bool isStarred}) async {
    setState(() {
      _isStarred = !isStarred;
      _isStarring = true;
    });
    try {
      await ref
          .read(navisDatabaseProvider)
          .starSyncDao
          .setStarred(
            itemId: widget.albumId,
            itemType: 'album',
            liked: !isStarred,
          );
    } on Object {
      // A local persistence failure means the intent was not saved.
      if (!mounted) return;
      setState(() => _isStarred = isStarred);
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.albumDetailStarFailure,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) setState(() => _isStarring = false);
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
      showAppNotice(
        context,
        message: l10n.ratingUpdateFailed,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isUpdatingRating = false);
      }
    }
  }

  Future<void> _openExternalLink(String url) async {
    await launchExternalHttpUrl(url);
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

  /// Returns the authoritative artist list for [details].
  ///
  /// Prefers the OpenSubsonic `artists` list (populated after a full sync on
  /// servers that support the extension). Falls back to splitting the legacy
  /// `artistName` string (e.g. "Artist A & Artist B, Artist C") into individual
  /// entries, all linked to `artistId`. As a last resort returns a single entry.
  List<ArtistRef> _resolveArtists(AlbumsTableData details) {
    if (details.artists.isNotEmpty) return details.artists;
    final id = details.artistId;
    final name = details.artistName;
    if (id == null || id.isEmpty || name == null || name.isEmpty) {
      return const [];
    }
    // Try to split compound names ("Artist A & Artist B", "Artist A feat. B").
    final segments = _parseArtistSegments(name);
    final nameSegments = segments
        .where((s) => !s.$2)
        .map((s) => ArtistRef(id: id, name: s.$1))
        .toList(growable: false);
    return nameSegments.isNotEmpty
        ? nameSegments
        : [ArtistRef(id: id, name: name)];
  }

  /// Splits [name] into alternating (text, isDelimiter) pairs so each artist
  /// name segment can be rendered as its own tappable widget.
  ///
  /// Recognised separators: `,`, ` & `, ` feat.`, ` ft.`, ` with `.
  static List<(String text, bool isDelimiter)> _parseArtistSegments(
    String name,
  ) {
    final result = <(String, bool)>[];
    final sep = RegExp(
      r'\s*(?:,\s*|&|feat\.?|ft\.?|with)\s*',
      caseSensitive: false,
    );
    var last = 0;
    for (final match in sep.allMatches(name)) {
      if (match.start > last) {
        final seg = name.substring(last, match.start).trim();
        if (seg.isNotEmpty) result.add((seg, false));
      }
      result.add((match.group(0)!, true));
      last = match.end;
    }
    if (last < name.length) {
      final seg = name.substring(last).trim();
      if (seg.isNotEmpty) result.add((seg, false));
    }
    return result;
  }

  /// Builds [Widget]s for a [Wrap] where each artist is individually tappable.
  ///
  /// Separators (`' & '`) are rendered in [dimStyle] between artists.
  /// When [artists] is empty a plain "Unknown artist" label is returned.
  List<Widget> _buildArtistChips({
    required BuildContext context,
    required List<ArtistRef> artists,
    required TextStyle? textStyle,
    required TextStyle? dimStyle,
  }) {
    if (artists.isEmpty) {
      final fallbackLabel = AppLocalizations.of(context)!
          .albumDetailUnknownArtist;
      return [Text(fallbackLabel, style: dimStyle)];
    }
    final widgets = <Widget>[];
    for (var i = 0; i < artists.length; i++) {
      if (i > 0) {
        widgets.add(Text(' & ', style: dimStyle));
      }
      final artist = artists[i];
      widgets.add(
        InkWell(
          onTap: () => NavService.openArtistDetail(
            context,
            ref,
            artist.id,
            name: artist.name,
          ),
          onLongPress: () =>
              unawaited(showArtistContextMenu(context, ref, artist.id)),
          onSecondaryTapDown: (details) => unawaited(
            showArtistContextMenu(
              context,
              ref,
              artist.id,
              anchor: details.globalPosition,
            ),
          ),
          child: Text(artist.name, style: textStyle),
        ),
      );
    }
    return widgets;
  }

  /// Keeps the original prominent title treatment, but steps it down only
  /// when that lets a long album name fit cleanly within two lines. Titles
  /// that still cannot fit at the smallest intentional display size retain
  /// the established ellipsis rather than making the header visually noisy.
  Widget _buildMobileAlbumTitle({
    required String title,
    required TextStyle? style,
  }) {
    final baseStyle = style ?? const TextStyle(fontSize: 32);
    return LayoutBuilder(
      builder: (context, constraints) {
        final baseFontSize = baseStyle.fontSize ?? 32;
        final minimumFontSize = max<double>(22, baseFontSize * 0.48);
        final textScaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        final maxWidth = constraints.hasBoundedWidth && constraints.maxWidth > 0
            ? constraints.maxWidth
            : max<double>(0, MediaQuery.sizeOf(context).width - 32);

        bool fitsAt(double fontSize) {
          final painter = TextPainter(
            text: TextSpan(
              text: title,
              style: baseStyle.copyWith(fontSize: fontSize),
            ),
            textDirection: direction,
            textScaler: textScaler,
          )..layout(maxWidth: maxWidth);
          final fits = painter.computeLineMetrics().length <= 2;
          painter.dispose();
          return fits;
        }

        var resolvedFontSize = baseFontSize;
        final fitsBase = fitsAt(baseFontSize);
        final fitsMinimum = fitsAt(minimumFontSize);
        if (!fitsBase && fitsMinimum) {
          for (
            var candidate = baseFontSize - 1;
            candidate >= minimumFontSize;
            candidate -= 1
          ) {
            if (fitsAt(candidate)) {
              resolvedFontSize = candidate;
              break;
            }
          }
        }

        return Text(
          title,
          key: const ValueKey<String>('albumDetailMobileHeaderTitle'),
          style: baseStyle.copyWith(fontSize: resolvedFontSize),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
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

  /// A circular nav button used in the mobile SliverAppBar leading/actions slots.
  /// Colors animate with scroll: white over art (expanded) → onSurface over
  /// surface (collapsed), controlled by [_headerProgress].
  Widget _buildAnimatedNavButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool isLoading = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final iconColor = Color.lerp(
      Colors.white,
      colorScheme.onSurface,
      _headerProgress,
    );
    final circleAlpha = 0.35 * (1.0 - _headerProgress);
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: circleAlpha),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          tooltip: tooltip,
          icon: isLoading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: iconColor,
                  ),
                )
              : Icon(icon, color: iconColor),
          onPressed: onPressed,
        ),
      ),
    );
  }

  /// Bottom-sheet context menu for the mobile album detail screen (3-dot button).
  Future<void> _showMobileAlbumContextMenu(
    AlbumsTableData details,
    List<SongsTableData> songs,
    int? albumRating,
    String coverArtHeroTag,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final l10n = AppLocalizations.of(context)!;
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.85;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // Show album art
                  ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: Text(l10n.albumDetailMenuShowAlbumArt),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(
                        showCoverArtViewer(
                          context,
                          coverArtId: details.coverArt,
                          revision: details.coverArtRevision ?? 0,
                          heroTag: coverArtHeroTag,
                          previewSize: 200,
                          isExternalSource: details.isExternal,
                        ),
                      );
                    },
                  ),
                  // Go to artist (only when artist is known)
                  if (details.artistId != null && details.artistId!.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(l10n.librarySongMenuOpenArtist),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        NavService.openArtistDetail(
                          context,
                          ref,
                          details.artistId!,
                          name: details.artistName,
                        );
                      },
                    ),
                  // Remote catalog records cannot be modified or downloaded.
                  if (!details.isExternal) ...<Widget>[
                    // Add to favorites (toggle star)
                    Consumer(
                      builder: (_, favRef, _) {
                        final currentlyStarred =
                            favRef
                                .watch(albumProvider(widget.albumId))
                                .asData
                                ?.value
                                ?.album
                                .starred !=
                            null;
                        return ListTile(
                          leading: Icon(
                            currentlyStarred
                                ? Icons.favorite
                                : Icons.favorite_border,
                          ),
                          title: Text(
                            currentlyStarred
                                ? l10n.actionLiked
                                : l10n.actionLike,
                          ),
                          onTap: () {
                            unawaited(_toggleStar(isStarred: currentlyStarred));
                          },
                        );
                      },
                    ),
                    // Rating
                    Consumer(
                      builder: (_, ratingRef, _) {
                        final currentRating =
                            ratingRef
                                .watch(albumRatingProvider(widget.albumId))
                                .asData
                                ?.value ??
                            albumRating;
                        return ListTile(
                          leading: const Icon(Icons.star_outline),
                          title: Text(l10n.ratingTitle),
                          subtitle: Text(l10n.ratingHint),
                          trailing: RatingWidget(
                            rating: currentRating,
                            compact: true,
                            onChanged: (next) {
                              unawaited(_updateAlbumRating(next));
                            },
                          ),
                        );
                      },
                    ),
                    // Add to playlist
                    ListTile(
                      leading: const Icon(Icons.playlist_add),
                      title: Text(l10n.librarySongMenuAddToPlaylist),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          showAddToPlaylistSheet(
                            context,
                            ref,
                            songs.map((s) => s.id).toList(growable: false),
                          ),
                        );
                      },
                    ),
                    // Download album
                    Consumer(
                      builder: (_, dlRef, _) {
                        final isFullyDownloaded =
                            songs.isNotEmpty &&
                            songs.every(
                              (s) =>
                                  dlRef
                                      .watch(songDownloadStateProvider(s.id))
                                      .status ==
                                  SongDownloadStatus.downloaded,
                            );
                        if (isFullyDownloaded) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Divider(height: 1),
                              ListTile(
                                leading: Icon(
                                  Icons.delete_outlined,
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
                                  unawaited(
                                    _deleteAllAlbumDownloads(context, songs),
                                  );
                                },
                              ),
                            ],
                          );
                        }
                        return ListTile(
                          leading: const Icon(Icons.download_outlined),
                          title: Text(l10n.albumDetailDownloadAction),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(_downloadAlbumSongs(context));
                          },
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Downloads all tracks in the current album (same logic as the old inline
  /// download button).
  Future<void> _downloadAlbumSongs(BuildContext ctx) async {
    final choice = await requestDownloadQuality(ctx, ref);
    if (choice == null || !ctx.mounted) return;
    final service = ref.read(downloadServiceProvider);
    final count = await service.enqueueAlbum(
      widget.albumId,
      quality: choice.quality,
      format: choice.format,
    );
    if (!ctx.mounted) return;
    final l10n = AppLocalizations.of(ctx)!;
    showAppNotice(
      ctx,
      message: downloadQueuedNotice(
        l10n,
        l10n.downloadAlbumQueued(count),
        choice,
      ),
      level: AppNoticeLevel.success,
    );
  }

  /// Shows a confirmation dialog and removes all downloaded tracks in [songs].
  Future<void> _deleteAllAlbumDownloads(
    BuildContext ctx,
    List<SongsTableData> songs,
  ) async {
    if (!ctx.mounted) return;
    final l10n = AppLocalizations.of(ctx)!;
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l10n.downloadsRemoveConfirmTitle),
        content: Text(l10n.downloadsRemoveConfirmContent),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
              foregroundColor: Theme.of(dialogCtx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(l10n.downloadsRemoveAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(downloadServiceProvider)
        .removeDownloadedTracks(songs.map((song) => song.id));
  }

  Widget _buildDiscHeader(
    BuildContext context,
    AppLocalizations l10n,
    int discNumber,
    bool isFirst,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!isFirst) const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.album_outlined,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                l10n.albumDetailDiscHeader(discNumber),
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}

// ── Rating button ───────────────────────────────────────────────────────────

/// Collapsed: an outlined button showing a star icon with "Rate" or "n/5".
/// Expanded: an inline row of 5 tappable stars with hover-fill on desktop.
/// Filters the album's track list to liked and/or downloaded songs.
///
/// A single button replaces an always-visible filter row; a badge shows how
/// many filters are active so a shortened track list is never unexplained.
class _AlbumFilterButton extends StatelessWidget {
  const new({
    required this.likedOnly,
    required this.downloadedOnly,
    required this.onLikedOnlyChanged,
    required this.onDownloadedOnlyChanged,
    this.outlined = true,
  });

  static const Key buttonKey = ValueKey<String>('album-filter-button');
  static const Key likedKey = ValueKey<String>('album-filter-liked');
  static const Key downloadedKey = ValueKey<String>('album-filter-downloaded');

  final bool likedOnly;
  final bool downloadedOnly;
  final ValueChanged<bool> onLikedOnlyChanged;
  final ValueChanged<bool> onDownloadedOnlyChanged;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final activeCount = (likedOnly ? 1 : 0) + (downloadedOnly ? 1 : 0);
    return MenuAnchor(
      menuChildren: <Widget>[
        CheckboxMenuButton(
          key: likedKey,
          value: likedOnly,
          closeOnActivate: false,
          onChanged: (value) => onLikedOnlyChanged(value ?? false),
          child: Text(l10n.libraryLikedOnlyFilter),
        ),
        CheckboxMenuButton(
          key: downloadedKey,
          value: downloadedOnly,
          closeOnActivate: false,
          onChanged: (value) => onDownloadedOnlyChanged(value ?? false),
          child: Text(l10n.libraryDownloadedOnlyFilter),
        ),
      ],
      builder: (context, controller, _) {
        void toggle() =>
            controller.isOpen ? controller.close() : controller.open();
        final icon = Badge(
          isLabelVisible: activeCount > 0,
          label: Text('$activeCount'),
          child: const Icon(Icons.filter_list),
        );
        final tooltip = l10n.albumDetailFilterLabel;
        return outlined
            ? IconButton.outlined(
                key: buttonKey,
                tooltip: tooltip,
                isSelected: activeCount > 0,
                onPressed: toggle,
                icon: icon,
              )
            : IconButton(
                key: buttonKey,
                tooltip: tooltip,
                isSelected: activeCount > 0,
                onPressed: toggle,
                icon: icon,
              );
      },
    );
  }
}

/// Matches the Material button height used by the surrounding actions.
const double _kRatingHeight = 40;

class _RatingButton extends StatefulWidget {
  const new({
    required this.rating,
    required this.onChanged,
    this.loading = false,
  });

  final int? rating;
  final ValueChanged<int> onChanged;
  final bool loading;

  @override
  State<_RatingButton> createState() => _RatingButtonState();
}

class _RatingButtonState extends State<_RatingButton>
    with SingleTickerProviderStateMixin {
  int _hovered = 0;
  late AnimationController _ctrl;
  late Animation<double> _anim;

  // Approximate pill widths (px). Collapsed fits star icon + "Rate"/"3/5".
  static const double _kCollapsedWidth = 92;
  static const double _kIconOnlyWidth = 48;
  // 5 stars × 30px + close (28px) + horizontal padding (2×12) = 202px.
  static const double _kExpandedWidth = 202;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _expand() {
    _ctrl.forward();
  }

  void _collapse() {
    unawaited(
      _ctrl.reverse().then((_) {
        if (mounted) {
          setState(() {
            _hovered = 0;
          });
        }
      }),
    );
  }

  void _confirm(int value) {
    // Tapping the current rating deselects it (sets to 0).
    final next = value == (widget.rating ?? 0) ? 0 : value;
    widget.onChanged(next);
    _collapse();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    // The pill follows Corner Style: a stadium in Rounded, a rounded
    // rectangle in Soft and Square.
    final pillRadius = min(
      NavisShapeData.of(context).control,
      _kRatingHeight / 2,
    );
    final pillInnerRadius = pillRadius - 1;
    final hasRating = (widget.rating ?? 0) > 0;
    final effective = widget.rating ?? 0;
    // The collapsed label is helpful at ordinary text sizes, but forcing it
    // into the fixed touch target makes the action overflow at large text
    // scales. The star retains the action, while its tooltip and semantics
    // preserve its name for discovery.
    final showCollapsedLabel =
        MediaQuery.textScalerOf(context).scale(13) <= 16.9;
    final collapsedWidth = showCollapsedLabel
        ? _kCollapsedWidth
        : _kIconOnlyWidth;

    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final t = _anim.value;
        final w = collapsedWidth + (_kExpandedWidth - collapsedWidth) * t;

        // Collapsed label fades out in the first 40% of the expansion.
        final labelOpacity = (1.0 - t / 0.4).clamp(0.0, 1.0);
        // Stars fade in starting at 30% of the expansion.
        final starsOpacity = ((t - 0.3) / 0.7).clamp(0.0, 1.0);

        final borderColor = hasRating
            ? cs.secondary.withValues(alpha: 0.45)
            : cs.outlineVariant;

        return SizedBox(
          width: w,
          height: _kRatingHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(pillRadius),
              border: Border.all(color: borderColor),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(pillInnerRadius),
              child: Material(
                color: Colors.transparent,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // ── Expanded: stars + close ───────────────────────────
                    if (t > 0)
                      Opacity(
                        opacity: starsOpacity,
                        child: OverflowBox(
                          maxWidth: _kExpandedWidth,
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 1; i <= 5; i++)
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  onEnter: (_) => setState(() => _hovered = i),
                                  onExit: (_) => setState(() => _hovered = 0),
                                  child: GestureDetector(
                                    onTap: widget.loading
                                        ? null
                                        : () => _confirm(i),
                                    child: SizedBox(
                                      width: 30,
                                      height: _kRatingHeight,
                                      child: Center(
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 120,
                                          ),
                                          transitionBuilder: (child, anim) =>
                                              ScaleTransition(
                                                scale: anim,
                                                child: child,
                                              ),
                                          child: Icon(
                                            (_hovered > 0
                                                    ? i <= _hovered
                                                    : i <= effective)
                                                ? Icons.star_rounded
                                                : Icons.star_border_rounded,
                                            key: ValueKey(
                                              _hovered > 0
                                                  ? i <= _hovered
                                                  : i <= effective,
                                            ),
                                            size: 20,
                                            color:
                                                (_hovered > 0
                                                    ? i <= _hovered
                                                    : i <= effective)
                                                ? cs.secondary
                                                : cs.onSurfaceVariant
                                                      .withValues(alpha: 0.4),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 2),
                              if (widget.loading)
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: cs.secondary,
                                  ),
                                )
                              else
                                InkResponse(
                                  onTap: _collapse,
                                  radius: 14,
                                  child: Icon(
                                    Icons.close,
                                    size: 14,
                                    color: cs.onSurfaceVariant.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ), // OverflowBox
                      ),
                    // ── Collapsed: label ─────────────────────────────────
                    if (t < 1.0)
                      Opacity(
                        opacity: labelOpacity,
                        child: Semantics(
                          button: true,
                          label: l10n.ratingTitle,
                          child: Tooltip(
                            message: l10n.ratingTitle,
                            child: InkWell(
                              onTap: widget.loading ? null : _expand,
                              borderRadius: BorderRadius.circular(
                                pillInnerRadius,
                              ),
                              child: SizedBox(
                                width: collapsedWidth,
                                height: _kRatingHeight,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      hasRating
                                          ? Icons.star_rounded
                                          : Icons.star_border_rounded,
                                      size: 16,
                                      color: hasRating
                                          ? cs.secondary
                                          : cs.onSurfaceVariant,
                                    ),
                                    if (showCollapsedLabel) ...<Widget>[
                                      const SizedBox(width: 6),
                                      Text(
                                        hasRating
                                            ? l10n.ratingValueShort(
                                                widget.rating!,
                                              )
                                            : l10n.ratingActionLabel,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: hasRating
                                              ? cs.secondary
                                              : cs.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Render-item types for disc-grouped track lists ─────────────────────────

enum _AlbumSongContextAction {
  playNow,
  addQueue,
  playNext,
  toggleLike,
  rate,
  openArtist,
  addToPlaylist,
  download,
  deleteDownload,
}

class _AlbumSongMoreButton extends StatefulWidget {
  const new({required this.onPressed});

  final ValueChanged<Offset?> onPressed;

  @override
  State<_AlbumSongMoreButton> createState() => _AlbumSongMoreButtonState();
}

class _AlbumSongMoreButtonState extends State<_AlbumSongMoreButton> {
  Offset? _anchor() {
    if (!isDesktopRuntime) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return null;
    return renderObject.localToGlobal(renderObject.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      icon: const Icon(Icons.more_vert),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      onPressed: () => widget.onPressed(_anchor()),
    );
  }
}

sealed class _AlbumRenderItem {
  const new();
}

final class _DiscHeader extends _AlbumRenderItem {
  const new({required this.discNumber, required this.isFirst});
  final int discNumber;
  final bool isFirst;
}

final class _SongItem extends _AlbumRenderItem {
  const new({required this.song});
  final SongsTableData song;
}

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
