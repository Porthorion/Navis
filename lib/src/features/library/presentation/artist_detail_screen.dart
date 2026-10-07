import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/common_widgets/content_shelf.dart';
import 'package:navis/src/common_widgets/external_album_card.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/common_widgets/album_download_badge.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/common_widgets/external_artwork_image.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/integrations/presentation/deezer_release_labels.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/artist_header_image.dart';
import 'package:navis/src/features/library/presentation/artist_deezer_providers.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_section.dart';
import 'package:navis/src/features/library/presentation/artist_virtual_playlist_artwork.dart';
import 'package:navis/src/features/library/presentation/detail_load_states.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/similar_artists_section.dart';
import 'package:navis/src/common_widgets/artist_playback_action.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/theme/artwork_shape.dart';

/// The album count an artist page shows: the larger of the artist row's
/// [stored] count and the [listed] albums on the page. A server whose artist
/// list counts only its local albums (Octo-Fiesta) leaves the row short of
/// the remote albums that opening the page stores, and the page follows them
/// as they arrive. Null when neither gives a count.
int? artistPageAlbumCount({required int? stored, required int? listed}) {
  if (listed == null || listed == 0) return stored;
  return math.max(stored ?? 0, listed);
}

/// An artist's page. An artist the library does not hold yet, or a remote
/// (`ext-…`) artist without albums, is fetched from the server first: the page
/// shows "Loading Remote Artist…" until it has the artist's name and albums,
/// then fills in the rest as it arrives. When the server cannot provide it,
/// the page offers Retry and a search for [nameHint].
class ArtistDetailScreen extends ConsumerStatefulWidget {
  const new({required this.artistId, this.nameHint, super.key});

  final String artistId;

  /// The caller's name for the artist, shown and searched for until the
  /// library holds the artist.
  final String? nameHint;

  @override
  ConsumerState<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends ConsumerState<ArtistDetailScreen> {
  bool _isStarred = false;
  bool _isStarring = false;

  /// Bumped by a refresh, which gives the header a fresh state.
  int _headerGeneration = 0;

  /// The page's request for the artist, which only matters while the page
  /// has nothing to show (see [_showsArtist]).
  DetailHydrationPhase _hydration = DetailHydrationPhase.running;

  /// A successful hydration found the remote artist without albums: the
  /// only case where the page shows a remote artist with none.
  bool _confirmedNoAlbums = false;

  /// The artist's stored albums when the request last ended: the page shows
  /// once they are stored, even before the album list has read them.
  int _storedAlbumCount = 0;
  bool _refreshing = false;

  /// The current request; an older one's answer or timeout is ignored.
  int _hydrationGeneration = 0;
  Timer? _hydrationTimeout;

  @override
  void dispose() {
    _hydrationTimeout?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(
      _hydrate(
        ref
            .read(librarySyncControllerProvider.notifier)
            .hydrateOpenedArtist(widget.artistId),
      ),
    );
  }

  /// Waits for [request] and records what it left in the library: settled
  /// once the artist is stored with albums, or with none and a successful
  /// hydration confirming it; failed otherwise, including when the request
  /// or the library read throws. Returns whether the server did not answer.
  Future<bool> _hydrate(Future<LibrarySyncState?> request) async {
    final generation = ++_hydrationGeneration;
    _hydrationTimeout?.cancel();
    // Loading never lasts forever: after the timeout the page offers Retry
    // and a search, and a late answer still fills it.
    _hydrationTimeout = Timer(kDetailHydrationTimeout, () {
      if (mounted &&
          generation == _hydrationGeneration &&
          _hydration == DetailHydrationPhase.running) {
        setState(() {
          _hydration = DetailHydrationPhase.failed;
          // Retry must work again even while the request keeps running.
          _refreshing = false;
        });
      }
    });
    var requestFailed = false;
    var phase = DetailHydrationPhase.failed;
    bool? confirmedNoAlbums;
    var storedAlbums = 0;
    try {
      final result = await request;
      requestFailed = detailHydrationFailed(result);
      if (!mounted) return requestFailed;
      final dao = ref.read(navisDatabaseProvider).libraryDao;
      final stored = await dao.getArtistById(widget.artistId);
      final albums = await dao.watchAlbumsByArtist(widget.artistId).first;
      storedAlbums = albums.length;
      // This request, or an earlier successful one this server session,
      // confirms what the server holds; no request alone confirms nothing.
      final confirmed =
          detailHydrationConfirmed(result) ||
          (result == null &&
              ref
                  .read(librarySyncControllerProvider.notifier)
                  .artistConfirmedWithoutAlbums(widget.artistId));
      if (confirmed) confirmedNoAlbums = albums.isEmpty;
      if (stored != null &&
          (!_isRemote(stored) || albums.isNotEmpty || confirmed)) {
        phase = DetailHydrationPhase.settled;
      }
      // The page's artist stream must not miss a row the request stored.
      final artistStream = artistByIdProvider(widget.artistId);
      if (stored != null && ref.read(artistStream).value == null) {
        ref.invalidate(artistStream);
      }
    } on Object {
      requestFailed = true;
    }
    if (generation == _hydrationGeneration) _hydrationTimeout?.cancel();
    if (mounted && generation == _hydrationGeneration) {
      setState(() {
        _hydration = phase;
        _storedAlbumCount = storedAlbums;
        _confirmedNoAlbums = confirmedNoAlbums ?? _confirmedNoAlbums;
      });
    }
    return requestFailed;
  }

  /// Fetches the artist again (Refresh, Retry and pull to refresh). A page
  /// that already shows the artist keeps it and reports a failure.
  Future<void> _refresh() async {
    if (_refreshing) return;
    // A library stream that failed is read again.
    final artistProvider = artistByIdProvider(widget.artistId);
    if (ref.read(artistProvider).hasError) ref.invalidate(artistProvider);
    final albumsProvider = artistAlbumSectionsProvider(widget.artistId);
    if (ref.read(albumsProvider).hasError) ref.invalidate(albumsProvider);
    setState(() {
      _refreshing = true;
      _hydration = DetailHydrationPhase.running;
      // A refresh also tries photos that failed to load again.
      _headerGeneration++;
    });
    final request = _hydrate(
      ref
          .read(librarySyncControllerProvider.notifier)
          .refreshArtist(widget.artistId),
    );
    // A later refresh (Retry after a timeout) owns the guard and the notice.
    final generation = _hydrationGeneration;
    try {
      final requestFailed = await request;
      if (!mounted || !requestFailed || generation != _hydrationGeneration) {
        return;
      }
      final shown = _showsArtist(
        ref.read(artistByIdProvider(widget.artistId)).value,
        ref.read(artistAlbumSectionsProvider(widget.artistId)),
      );
      if (shown) {
        showAppNotice(
          context,
          message: AppLocalizations.of(context)!.artistDetailRefreshError,
          level: AppNoticeLevel.error,
        );
      }
    } finally {
      if (mounted && generation == _hydrationGeneration) {
        setState(() => _refreshing = false);
      }
    }
  }

  /// An `ext-…` id is remote whatever its row says.
  bool _isRemote(ArtistsTableData? artist) =>
      (artist?.isExternal ?? false) ||
      isExternalCatalogSource(id: widget.artistId);

  /// Whether the page has enough to show the artist: a stored library
  /// artist, or a remote artist with albums (or one the server confirmed has
  /// none).
  bool _showsArtist(
    ArtistsTableData? artist,
    AsyncValue<ArtistAlbumSections> sections,
  ) {
    if (artist == null) return false;
    if (!_isRemote(artist)) return true;
    final listed = sections.value;
    // An album list that cannot be read shows the failure state instead.
    if (sections.hasError && listed == null) return false;
    // Albums the request stored are enough; the album list may still be
    // reading them while the library is busy.
    if (_storedAlbumCount > 0 || _confirmedNoAlbums) return true;
    return listed != null && !listed.isEmpty;
  }

  /// "Loading Remote Artist…" while the artist is fetched, or Retry and a
  /// search when the server could not provide it or the library could not
  /// be read ([libraryFailed]).
  Widget _buildPendingBody(
    BuildContext context,
    ArtistsTableData? artist, {
    bool libraryFailed = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final isRemote = _isRemote(artist);
    final name = artist?.name ?? _nonBlank(widget.nameHint);
    final artwork = CoverArtImage(
      coverArtId: artist?.coverArt,
      width: kDetailStateArtworkExtent,
      height: kDetailStateArtworkExtent,
      shape: ArtworkShapeRole.artist,
      placeholderIcon: Icons.person_outline,
      isExternalSource: isRemote,
      remoteSourceIndicatorPolicy: RemoteSourceIndicatorPolicy.hidden,
    );
    if (libraryFailed || _hydration == DetailHydrationPhase.failed) {
      return DetailLoadFailedView(
        title: l10n.artistDetailLoadFailedTitle,
        artwork: artwork,
        name: name,
        isRemote: isRemote,
        onRetry: () => unawaited(_refresh()),
        onSearch: name == null
            ? null
            : () => NavService.openSearch(
                context,
                ref,
                name,
                filter: SearchResultType.artists,
              ),
      );
    }
    return DetailLoadingView(
      status: isRemote
          ? l10n.artistDetailLoadingRemote
          : l10n.artistDetailLoadingServer,
      artwork: artwork,
      name: name,
      isRemote: isRemote,
      content: const DetailAlbumGridOutline(),
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
            itemId: widget.artistId,
            itemType: 'artist',
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artist = ref.watch(artistByIdProvider(widget.artistId));
    final albumSections = ref.watch(
      artistAlbumSectionsProvider(widget.artistId),
    );
    final artistInfo = ref.watch(artistInfoProvider(widget.artistId));
    final currentArtist = artist.value;
    final showsArtist = _showsArtist(currentArtist, albumSections);

    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final artistBody = artist.when(
      data: (artistData) {
        if (artistData == null || !showsArtist) {
          return _buildPendingBody(
            context,
            artistData,
            // Albums that cannot be read leave nothing to wait for once the
            // request has ended.
            libraryFailed:
                albumSections.hasError &&
                !albumSections.hasValue &&
                _hydration != DetailHydrationPhase.running,
          );
        }

        final isStarred = _isStarred || artistData.starred != null;
        final artistKey = (artistId: artistData.id, name: artistData.name);
        final deezerArtist = ref
            .watch(artistDeezerDetailsProvider(artistKey))
            .value;
        final policy = ref.watch(integrationPolicyProvider);
        final serverHost = ref.watch(serverHostProvider);
        // Server photo first, then Deezer's; placeholders and refused URLs
        // are left out (see artistHeaderImageUrls).
        final headerImageUrls =
            artistHeaderImageUrls(
                  serverLargeImageUrl: artistInfo.value?.largeImageUrl,
                  serverMediumImageUrl: artistInfo.value?.mediumImageUrl,
                  deezerPictureUrl: deezerArtist?.pictureXl,
                )
                .where((url) {
                  final uri = Uri.tryParse(url);
                  return uri != null &&
                      ref
                          .read(artworkCallRecorderProvider)
                          .checkAllowed(
                            uri,
                            allowed: integrationAllowsArtworkUri(
                              policy,
                              uri,
                              serverHost: serverHost,
                            ),
                          );
                })
                .toList(growable: false);
        final fanCount = deezerArtist?.fanCount ?? 0;
        final albumCount = artistPageAlbumCount(
          stored: artistData.albumCount,
          listed: albumSections.asData?.value.albums.length,
        );
        final headerSummary = <String>[
          if (albumCount != null) l10n.artistCardAlbumCount(albumCount),
          if (fanCount > 0) l10n.artistDetailFanCount(fanCount),
        ].join(' • ');

        return RefreshIndicator(
          onRefresh: _refresh,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverList.list(
                children: [
                  // ── Artist image header with name + heart overlaid ──────────
                  _ArtistHeader(
                    key: ValueKey<int>(_headerGeneration),
                    artist: artistData,
                    imageUrls: headerImageUrls,
                    summary: headerSummary,
                    // The server's photo may still arrive; until then the
                    // plain header stands in and the heart waits.
                    waitingForServerPhoto:
                        artistInfo.isLoading && !artistInfo.hasValue,
                    isStarred: isStarred,
                    isStarring: _isStarring,
                    onStarToggle: _isStarring
                        ? null
                        : () => _toggleStar(isStarred: isStarred),
                    starTooltip: l10n.albumDetailStarAction,
                  ),
                  // ── Bio ─────────────────────────────────────────────────────
                  artistInfo.when(
                    data: (info) {
                      if (info == null) {
                        return const SizedBox.shrink();
                      }
                      return _ArtistInfoSection(
                        info: info,
                        albumCount: albumCount,
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                    error: (_, _) => const SizedBox.shrink(),
                  ),
                  // ── Play / Shuffle buttons ────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: EntityActionBar(
                      playKey: const ValueKey('artist-play'),
                      shuffleKey: const ValueKey('artist-shuffle'),
                      onPlay: () => unawaited(
                        startArtistPlayback(
                          ProviderScope.containerOf(context, listen: false),
                          widget.artistId,
                          ArtistPlaybackAction.play,
                        ),
                      ),
                      onShuffle: () => unawaited(
                        startArtistPlayback(
                          ProviderScope.containerOf(context, listen: false),
                          widget.artistId,
                          ArtistPlaybackAction.shuffle,
                        ),
                      ),
                      secondary: <Widget>[
                        // Repeats the app-bar menu within thumb reach on
                        // phones.
                        EntitySecondaryAction(
                          icon: const Icon(Icons.more_horiz),
                          label: l10n.actionMore,
                          onPressed: () => unawaited(
                            showArtistContextMenu(context, ref, artistData.id),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ArtistPlaybackProgressIndicator(artistId: widget.artistId),
                  // ── Top Tracks (Deezer, else Last.fm; hidden without either) ──
                  if (ref.watch(artistTopSongsAllowedProvider))
                    ArtistTopTracksSection(
                      artistId: artistData.id,
                      artistName: artistData.name,
                    ),
                  _ArtistTopTracksPlaylistCard(
                    artistId: artistData.id,
                    artistName: artistData.name,
                    imageUrl: headerImageUrls.firstOrNull,
                  ),
                ],
              ),
              albumSections.when(
                data: (sections) {
                  if (sections.isEmpty) {
                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: EmptyState(
                          title: l10n.artistDetailAlbumsEmptyTitle,
                          subtitle: l10n.artistDetailAlbumsEmptySubtitle,
                          icon: Icons.album_outlined,
                        ),
                      ),
                    );
                  }

                  return SliverMainAxisGroup(
                    slivers: <Widget>[
                      if (sections.albums.isNotEmpty)
                        _ArtistAlbumSection(
                          title: l10n.artistDetailAlbumsSection,
                          albums: sections.albums,
                        ),
                      if (sections.featuredIn.isNotEmpty)
                        _ArtistAlbumSection(
                          title: l10n.artistDetailFeaturedSection,
                          albums: sections.featuredIn,
                        ),
                    ],
                  );
                },
                loading: () => const SliverToBoxAdapter(
                  child: ShimmerListPage(count: 4, leadingSize: 56),
                ),
                error: (error, _) => SliverToBoxAdapter(
                  child: ErrorState(
                    title: l10n.artistDetailAlbumsErrorTitle,
                    onRetry: () => ref.invalidate(
                      artistAlbumSectionsProvider(widget.artistId),
                    ),
                  ),
                ),
              ),
              // ── Missing albums (Deezer releases the server lacks) ───────
              _MissingAlbumsSection(
                artistKey: artistKey,
                artistName: artistData.name,
              ),
              SliverList.list(
                children: [
                  // ── Fans also like / Similar Artists (below albums) ─────────
                  _RelatedArtistsSection(
                    artistKey: artistKey,
                    artistInfo: artistInfo,
                  ),
                  if (ref.watch(audioMuseAvailableProvider))
                    _AudioMuseSimilarArtists(artistId: widget.artistId),
                  const SizedBox(height: 12),
                ],
              ),
            ],
          ),
        );
      },
      // A remote artist is fetched before it is stored, so its page says so
      // from the start; a library artist shows the page's silhouette.
      loading: () => _isRemote(null)
          ? _buildPendingBody(context, null)
          : const _ArtistDetailLoadingState(),
      error: (error, _) =>
          _buildPendingBody(context, null, libraryFailed: true),
    );
    return Scaffold(
      appBar: AppBar(
        // The page always offers a way back, even when it was opened without
        // history while the artist loads.
        leading: showsArtist
            ? null
            : BackButton(
                onPressed: () =>
                    NavService.back(context, fallback: AppRoutes.library),
              ),
        title: Text(
          currentArtist?.name ??
              _nonBlank(widget.nameHint) ??
              l10n.artistDetailTitle,
        ),
        actions: <Widget>[
          DetailRefreshButton(
            refreshing: _refreshing,
            onRefresh: () => unawaited(_refresh()),
          ),
          if (currentArtist != null && showsArtist)
            Builder(
              builder: (buttonContext) => IconButton(
                icon: const Icon(Icons.more_horiz),
                tooltip: MaterialLocalizations.of(buttonContext)
                    .showMenuTooltip,
                onPressed: () {
                  final renderObject = buttonContext.findRenderObject();
                  if (renderObject is! RenderBox) return;
                  unawaited(
                    showArtistContextMenu(
                      context,
                      ref,
                      currentArtist.id,
                      anchor: renderObject.localToGlobal(
                        renderObject.size.center(Offset.zero),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
      body: KeyedSubtree(
        key: showsArtist ? detailPageShownKey : null,
        child: desktopMode
            ? DesktopFrame(
                layoutClass: resolveDesktopLayoutClass(
                  MediaQuery.sizeOf(context).width,
                ),
                child: artistBody,
              )
            : artistBody,
      ),
    );
  }
}

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// The initial detail query has no artist identity to preserve yet. Keep the
/// page's eventual silhouette visible so a cold deep link never reads as an
/// empty page while the local library stream is connecting.
class _ArtistDetailLoadingState extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final headerHeight = (availableWidth * (desktopMode ? 0.32 : 0.43))
            .clamp(260.0, desktopMode ? 420.0 : 560.0);

        return Semantics(
          label: l10n.artistDetailLoadingLabel,
          child: ExcludeSemantics(
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: <Widget>[
                SizedBox(
                  height: headerHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          colorScheme.surfaceContainerHighest,
                          colorScheme.surfaceContainerHigh,
                          colorScheme.surface,
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const <Widget>[
                            _ArtistDetailLoadingPlaceholder(
                              height: 44,
                              width: 240,
                            ),
                            SizedBox(height: 10),
                            _ArtistDetailLoadingPlaceholder(
                              height: 16,
                              width: 96,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: <Widget>[
                      _ArtistDetailLoadingPlaceholder(height: 40, width: 88),
                      SizedBox(width: 10),
                      _ArtistDetailLoadingPlaceholder(height: 40, width: 104),
                      SizedBox(width: 10),
                      _ArtistDetailLoadingPlaceholder(height: 40, width: 88),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 28, 16, 12),
                  child: _ArtistDetailLoadingPlaceholder(height: 24, width: 92),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: <Widget>[
                      _ArtistDetailLoadingAlbumRow(),
                      SizedBox(height: 12),
                      _ArtistDetailLoadingAlbumRow(),
                      SizedBox(height: 12),
                      _ArtistDetailLoadingAlbumRow(),
                      SizedBox(height: 12),
                      _ArtistDetailLoadingAlbumRow(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ArtistDetailLoadingAlbumRow extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        _ArtistDetailLoadingPlaceholder(height: 88, width: 88),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _ArtistDetailLoadingPlaceholder(height: 16),
              SizedBox(height: 8),
              _ArtistDetailLoadingPlaceholder(height: 12, width: 128),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArtistDetailLoadingPlaceholder extends StatelessWidget {
  const new({required this.height, this.width = double.infinity});

  final double height;
  final double width;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12),
        borderRadius: NavisRadius.smAll,
      ),
      child: SizedBox(height: height, width: width),
    );
  }
}

/// The artist page header: the first photo of [imageUrls] that loads, under
/// the name, the summary line and the heart, or the plain name header when
/// none does. A photo that fails to load hands over to the next one, so a
/// broken server photo shows Deezer's and a broken Deezer photo the name
/// header, never a blank box.
class _ArtistHeader extends StatefulWidget {
  const new({
    required this.artist,
    required this.imageUrls,
    required this.summary,
    required this.waitingForServerPhoto,
    required this.isStarred,
    required this.isStarring,
    required this.onStarToggle,
    required this.starTooltip,
    super.key,
  });

  final ArtistsTableData artist;
  final List<String> imageUrls;

  /// "12 albums • 4.1M fans"; empty to show no line.
  final String summary;
  final bool waitingForServerPhoto;
  final bool isStarred;
  final bool isStarring;
  final VoidCallback? onStarToggle;
  final String starTooltip;

  @override
  State<_ArtistHeader> createState() => _ArtistHeaderState();
}

class _ArtistHeaderState extends State<_ArtistHeader> {
  final Set<String> _failedUrls = <String>{};

  @override
  void didUpdateWidget(covariant _ArtistHeader oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Forget failures of photos the page no longer offers; a refresh replaces
    // this state and forgets them all.
    _failedUrls.retainWhere(widget.imageUrls.contains);
  }

  /// Called while the failed image builds its fallback, so the switch to the
  /// next photo waits for the end of the frame.
  void _imageFailed(String url) {
    if (!_failedUrls.add(url)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    final imageUrl = widget.waitingForServerPhoto
        ? null
        : widget.imageUrls
              .where((url) => !_failedUrls.contains(url))
              .firstOrNull;
    if (imageUrl != null) {
      return _ArtistImageHeader(
        key: ValueKey<String>('artist-header-image:$imageUrl'),
        imageUrl: imageUrl,
        onImageFailed: () => _imageFailed(imageUrl),
        artistName: artist.name,
        summary: widget.summary,
        isStarred: widget.isStarred,
        isStarring: widget.isStarring,
        onStarToggle: widget.onStarToggle,
        starTooltip: widget.starTooltip,
        isExternalSource: artist.isExternal,
      );
    }
    return _ArtistNameHeader(
      key: const ValueKey<String>('artist-name-header'),
      name: artist.name,
      summary: widget.summary,
      isExternalSource: artist.isExternal,
      isStarred: widget.isStarred,
      isStarring: widget.isStarring,
      onStarToggle: widget.waitingForServerPhoto ? null : widget.onStarToggle,
      starTooltip: widget.starTooltip,
    );
  }
}

/// Full-width header image shown at the top of the artist detail page when
/// the artist has a photo (the server's, else Deezer's). Overlays the artist
/// name, the summary line and the heart at the bottom of the image.
class _ArtistImageHeader extends StatelessWidget {
  const new({
    required this.imageUrl,
    required this.onImageFailed,
    required this.artistName,
    required this.summary,
    required this.isStarred,
    required this.isStarring,
    required this.onStarToggle,
    required this.starTooltip,
    required this.isExternalSource,
    super.key,
  });

  final String imageUrl;
  final VoidCallback onImageFailed;
  final String artistName;
  final String summary;
  final bool isStarred;
  final bool isStarring;
  final VoidCallback? onStarToggle;
  final String starTooltip;
  final bool isExternalSource;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
        final headerHeight = (availableWidth * (desktopMode ? 0.32 : 0.43))
            .clamp(260.0, desktopMode ? 420.0 : 560.0);

        // Gradually shift the vertical anchor from top (portrait/narrow screens
        // where topCenter works well for portrait artist shots) toward center
        // (wide/cinematic displays where topCenter cuts off the face).
        // The transition spans aspect‑ratios 1.5 → 2.5:
        //   ≤ 1.5  → Alignment(0, −1)  = topCenter
        //   ≥ 2.5  → Alignment(0,  0)  = center
        final displayRatio = availableWidth / headerHeight;
        final alignY = ((displayRatio - 1.5) / 1.0).clamp(0.0, 1.0) - 1.0;
        final imageAlignment = Alignment(0, alignY);

        return SizedBox(
          height: headerHeight,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ExternalArtworkImage(
                url: imageUrl,
                fit: BoxFit.cover,
                alignment: imageAlignment,
                fallbackBuilder: (_) {
                  onImageFailed();
                  return const SizedBox.shrink();
                },
              ),
              // Dual gradient: slight top vignette + heavy bottom scrim
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x55000000),
                      Color(0x00000000),
                      Color(0xF2000000),
                    ],
                    stops: <double>[0, 0.35, 1],
                  ),
                ),
              ),
              // Artist name (bottom-left) + heart (bottom-right) overlaid
              Positioned(
                left: 20,
                right: 8,
                bottom: 20,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.bottomLeft,
                            child: Text(
                              artistName,
                              style: Theme.of(context).textTheme.displayLarge
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -1,
                                    height: 1.05,
                                    fontSize: 64,
                                    shadows: const <Shadow>[
                                      Shadow(
                                        blurRadius: 4,
                                        color: Color(0xCC000000),
                                      ),
                                      Shadow(
                                        blurRadius: 24,
                                        color: Color(0xAA000000),
                                      ),
                                    ],
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                          if (summary.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 6),
                            Text(
                              summary,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.82),
                                    shadows: const <Shadow>[
                                      Shadow(
                                        blurRadius: 8,
                                        color: Color(0xCC000000),
                                      ),
                                    ],
                                  ),
                            ),
                          ],
                          if (isExternalSource) ...<Widget>[
                            const SizedBox(height: 8),
                            const RemoteSourceIndicator(
                              variant: RemoteSourceIndicatorVariant.chip,
                            ),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        isStarred ? Icons.favorite : Icons.favorite_border,
                        // The heart sits on the darkened artist image in
                        // every theme; fill, not colour, shows the state.
                        color: isStarred
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.8),
                        size: 26,
                      ),
                      tooltip: isDesktopRuntime ? starTooltip : null,
                      onPressed: onStarToggle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Fallback header shown when there is no artist photo.
class _ArtistNameHeader extends ConsumerWidget {
  const new({
    required this.name,
    required this.summary,
    required this.isStarred,
    required this.isStarring,
    required this.onStarToggle,
    required this.starTooltip,
    required this.isExternalSource,
    super.key,
  });

  final String name;
  final String summary;
  final bool isStarred;
  final bool isStarring;
  final VoidCallback? onStarToggle;
  final String starTooltip;
  final bool isExternalSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final artistShape = ref.watch(artistCardShapeProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 32, 12, 24),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // Stands in for the artist photo, so it takes Artist Card Shape.
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              shape: artistShape == 'circle'
                  ? BoxShape.circle
                  : BoxShape.rectangle,
              borderRadius: artistShape == 'circle'
                  ? null
                  : artworkBorderRadius(artistShape, extent: 72),
            ),
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    name,
                    style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      fontSize: 56,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  ),
                ),
                if (summary.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(summary),
                ],
                if (isExternalSource) ...<Widget>[
                  const SizedBox(height: 8),
                  const RemoteSourceIndicator(
                    variant: RemoteSourceIndicatorVariant.chip,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              isStarred ? Icons.favorite : Icons.favorite_border,
              color: isStarred
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
              size: 26,
            ),
            tooltip: isDesktopRuntime ? starTooltip : null,
            onPressed: onStarToggle,
          ),
        ],
      ),
    );
  }
}

class _ArtistInfoSection extends StatelessWidget {
  const new({required this.info, this.albumCount});

  final ArtistInfo info;
  final int? albumCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (info.biography == null || info.biography!.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final bioTitle = albumCount != null && albumCount! > 0
        ? '${l10n.artistDetailBioSection} · ${l10n.artistDetailAlbumCount(albumCount!)}'
        : l10n.artistDetailBioSection;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (info.biography != null &&
              info.biography!.trim().isNotEmpty) ...<Widget>[
            NavisSectionHeader(title: bioTitle),
            const SizedBox(height: 10),
            Text(
              info.biography!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.65,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}

/// "This Is" the artist, opening the top songs page, while a top-songs source
/// is allowed and some of the first ten songs are in the library. Otherwise
/// nothing: the page's own Shuffle button covers shuffling the artist.
///
/// It watches the section's ten songs, never the 50-song playlist, so the
/// artist page does not resolve all 50.
class _ArtistTopTracksPlaylistCard extends ConsumerWidget {
  const new({
    required this.artistId,
    required this.artistName,
    required this.imageUrl,
  });

  final String artistId;
  final String artistName;
  final String? imageUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(artistTopSongsAllowedProvider)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final tracks = ref.watch(
      artistTopTracksProvider((artistId: artistId, name: artistName)),
    );
    return tracks.when(
      skipLoadingOnReload: true,
      data: (sectionTracks) {
        final resolved = sectionTracks
            .map((track) => track.resolvedSong)
            .nonNulls
            .toList(growable: false);
        if (resolved.isEmpty) return const SizedBox.shrink();
        return _ArtistVirtualPlaylistCard(
          key: const ValueKey<String>('artist-this-is-card'),
          title: l10n.artistTopTracksPlaylistTitle(artistName),
          artwork: ArtistVirtualPlaylistArtwork(
            coverArtIds: resolved
                .map((song) => song.coverArt)
                .nonNulls
                .toList(growable: false),
            imageUrl: imageUrl,
            size: 64,
          ),
          onTap: () =>
              NavService.openArtistTopTracksPlaylist(context, ref, artistId),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _ArtistVirtualPlaylistCard extends StatelessWidget {
  const new({
    required this.title,
    required this.artwork,
    required this.onTap,
    super.key,
  });

  final String title;
  final Widget artwork;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Material(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: NavisRadius.smAll,
        child: InkWell(
          borderRadius: NavisRadius.smAll,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: <Widget>[
                artwork,
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistAlbumSection extends ConsumerWidget {
  const new({required this.title, required this.albums});

  final String title;
  final List<AlbumsTableData> albums;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: NavisSectionHeader(title: title),
          ),
        ),
        ResponsiveContentSliverGrid(
          itemCount: albums.length,
          itemBuilder: (context, index) {
            final album = albums[index];
            final heroTag = buildCoverArtHeroTag(
              coverArtId: album.coverArt,
              context: 'artist_album',
              entityId: album.id,
            );
            return RepaintBoundary(
              child: AlbumCard(
                album: album,
                size: AlbumCardSize.library,
                heroTag: heroTag,
                badge: AlbumDownloadBadge(albumId: album.id),
                onTap: () => NavService.openAlbumDetail(
                  context,
                  ref,
                  album.id,
                  heroTag: heroTag,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// How long the artist page waits for Deezer's "Fans Also Like" before it
/// shows the server's Similar Artists instead.
const Duration kFansAlsoLikeServerFallbackDelay = Duration(milliseconds: 2500);

/// Deezer's "Fans Also Like" when it has artists for this artist, otherwise
/// the server's Similar Artists.
///
/// The server's list shows as soon as Deezer has nothing, fails, or has not
/// answered within [kFansAlsoLikeServerFallbackDelay]. Whichever list shows
/// first stays: a late Deezer answer never replaces the server's list.
class _RelatedArtistsSection extends ConsumerStatefulWidget {
  const new({required this.artistKey, required this.artistInfo});

  final ArtistPageKey artistKey;
  final AsyncValue<ArtistInfo?> artistInfo;

  @override
  ConsumerState<_RelatedArtistsSection> createState() =>
      _RelatedArtistsSectionState();
}

enum _RelatedArtistsSource { deezer, server }

class _RelatedArtistsSectionState
    extends ConsumerState<_RelatedArtistsSection> {
  Timer? _deezerWait;
  bool _waitedForDeezer = false;

  /// The list on screen, kept once it has shown artists.
  _RelatedArtistsSource? _shown;

  @override
  void initState() {
    super.initState();
    _deezerWait = Timer(kFansAlsoLikeServerFallbackDelay, () {
      if (mounted) setState(() => _waitedForDeezer = true);
    });
  }

  @override
  void dispose() {
    _deezerWait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final deezer = ref.watch(artistFansAlsoLikeProvider(widget.artistKey));
    final deezerEntries = deezer.value ?? const <SimilarArtistEntry>[];
    final serverEntries = _serverSimilarArtists();

    final source = switch (_shown) {
      _RelatedArtistsSource.deezer when deezerEntries.isNotEmpty =>
        _RelatedArtistsSource.deezer,
      _RelatedArtistsSource.server when serverEntries.isNotEmpty =>
        _RelatedArtistsSource.server,
      _ when deezerEntries.isNotEmpty => _RelatedArtistsSource.deezer,
      _
          when serverEntries.isNotEmpty &&
              (deezer.hasValue || deezer.hasError || _waitedForDeezer) =>
        _RelatedArtistsSource.server,
      _ => null,
    };
    // A memo of what is on screen, not state that needs a rebuild.
    _shown = source ?? _shown;
    return switch (source) {
      _RelatedArtistsSource.deezer => SimilarArtistsSection(
        key: const ValueKey<String>('artist-fans-also-like'),
        title: l10n.artistDetailFansAlsoLikeSection,
        artists: deezerEntries,
      ),
      _RelatedArtistsSource.server => SimilarArtistsSection(
        key: const ValueKey<String>('artist-server-similar'),
        title: l10n.artistDetailSimilarSection,
        artists: serverEntries,
      ),
      null => const SizedBox.shrink(),
    };
  }

  /// The server's similar artists; empty while its artist info loads or
  /// failed.
  List<SimilarArtistEntry> _serverSimilarArtists() {
    final currentArtistId = widget.artistKey.artistId.trim();
    return (widget.artistInfo.value?.similarArtists ?? const <Artist>[])
        .where((artist) {
          final candidateId = artist.id.trim();
          return candidateId.isNotEmpty && candidateId != currentArtistId;
        })
        .map(
          (artist) => SimilarArtistEntry(
            name: artist.name,
            libraryArtistId: artist.id,
            coverArt: artist.coverArt,
          ),
        )
        .toList(growable: false);
  }
}

/// Deezer albums and EPs of the artist that the server lacks, as a shelf
/// below the album grids. Hidden while there are none (including while
/// anything loads, and whenever the server has any remote album for the
/// artist). A card opens the server's remote album `ext-deezer-album-<id>`.
class _MissingAlbumsSection extends ConsumerWidget {
  const new({required this.artistKey, required this.artistName});

  final ArtistPageKey artistKey;
  final String artistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(artistMissingAlbumsProvider(artistKey));
    if (albums.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final l10n = AppLocalizations.of(context)!;
    return SliverToBoxAdapter(
      child: Column(
        key: const ValueKey<String>('artist-missing-albums'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NavisSpace.md,
              NavisSpace.xl,
              NavisSpace.md,
              NavisSpace.xs,
            ),
            child: NavisSectionHeader(
              title: l10n.artistDetailMissingAlbumsSection,
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final padding = ContentLayout.padding(width);
              // Home's album shelf size, so this shelf and Home's release
              // shelves share one card. Home's compact density is a Home
              // setting, so the artist page keeps the comfortable size.
              final extent = ContentLayout.shelfCardExtent(width);
              return Padding(
                // The album grids' insets, bottom included.
                padding: EdgeInsets.fromLTRB(padding, 0, padding, padding),
                child: ContentShelf(
                  height: extent,
                  extent: extent,
                  gap: ContentLayout.gap(width - padding * 2),
                  itemCount: albums.length,
                  itemBuilder: (context, index) {
                    final album = albums[index];
                    return ExternalAlbumCard(
                      key: ValueKey<String>('missing-album-${album.id}'),
                      title: album.title,
                      subtitle: deezerReleaseSummary(l10n, album),
                      coverUrl: deezerReleaseCoverUrl(album),
                      feature: IntegrationFeature.deezerMissingAlbums,
                      extent: extent,
                      // The server's remote album, which plays like any
                      // album; its page searches when the server lacks it.
                      onTap: () => NavService.openAlbumDetail(
                        context,
                        ref,
                        remoteDeezerAlbumId(album.id),
                        name: album.title,
                        artistName: artistName,
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// AI-powered similar artists section, gated behind
/// [audioMuseAvailableProvider]. Hidden when no recommendations are returned.
class _AudioMuseSimilarArtists extends ConsumerWidget {
  const new({required this.artistId});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final asyncRecs = ref.watch(audioMuseSimilarArtistsProvider(artistId));

    return asyncRecs.when(
      data: (recs) {
        final currentArtistId = artistId.trim();
        final filteredRecs = recs
            .where((rec) {
              final candidateId = rec.id.trim();
              return candidateId.isNotEmpty && candidateId != currentArtistId;
            })
            .toList(growable: false);
        if (filteredRecs.isEmpty) return const SizedBox.shrink();
        return SimilarArtistsSection(
          title: l10n.audioMuseSimilarArtists,
          artists: filteredRecs
              .map(
                (rec) => SimilarArtistEntry(
                  name: rec.title,
                  libraryArtistId: rec.id,
                ),
              )
              .toList(growable: false),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}
