import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/album_download_badge.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/list_filter_field.dart';
import 'package:navis/src/common_widgets/responsive_content_grid.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/presentation/genre_providers.dart';
import 'package:navis/src/features/library/presentation/library_screen.dart'
    show LibrarySortFilterRow;
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/play_song_in_collection.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Songs per page of the Songs tab; the tab loads the next page on scroll.
const int _songPageSize = 100;

/// One genre: its albums as a grid and its songs as a list, each with its own
/// search, sort and downloaded-only filter, plus Play and Shuffle for all of
/// the genre's songs.
class GenreDetailScreen extends ConsumerStatefulWidget {
  const new({required this.genreKey, super.key});

  /// The genre's merge key (`genreKey`).
  final String genreKey;

  @override
  ConsumerState<GenreDetailScreen> createState() => _GenreDetailScreenState();
}

class _GenreDetailScreenState extends ConsumerState<GenreDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Queues every song of the genre (the downloaded ones while that filter
  /// is on), like the album and Liked Play and Shuffle.
  Future<void> _play({required bool shuffle}) async {
    final songs = await ref
        .read(navisDatabaseProvider)
        .libraryDao
        .getSongsByGenre(
          widget.genreKey,
          downloadedOnly: ref.read(downloadedOnlyFilterProvider),
        );
    if (songs.isEmpty || !mounted) return;
    final queued = List<SongsTableData>.of(songs);
    if (shuffle) queued.shuffle(Random());
    try {
      await ref
          .read(queueProvider.notifier)
          .replaceWithTableData(
            queued,
            originalOrder: shuffle
                ? songs.map((song) => song.id).toList()
                : null,
          );
    } on Object {
      if (!mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.playbackActionFailed,
        level: AppNoticeLevel.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final summary = ref.watch(genreSummaryProvider(widget.genreKey));
    final genre = summary.asData?.value;
    final body = summary.when(
      skipLoadingOnReload: true,
      loading: () => const ShimmerListPage(count: 8),
      error: (_, _) => ErrorState(
        title: l10n.genresLoadError,
        onRetry: () => ref.invalidate(genreSummaryProvider(widget.genreKey)),
        retryLabel: l10n.commonRetry,
      ),
      data: (genre) {
        if (genre == null) {
          return EmptyState(
            title: l10n.genreNotFound,
            icon: Icons.sell_outlined,
          );
        }
        return Column(
          children: <Widget>[
            LayoutBuilder(
              // The same inset as the search field and cards below.
              builder: (context, constraints) {
                final inset = ContentLayout.padding(constraints.maxWidth);
                return Padding(
                  padding: EdgeInsets.fromLTRB(inset, 8, inset, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${l10n.playlistsSongCount(genre.songCount)} • '
                          '${l10n.artistCardAlbumCount(genre.albumCount)}',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                      EntityActionBar(
                        compact: MediaQuery.sizeOf(context).width < 400,
                        playKey: const ValueKey<String>('genrePlayAction'),
                        shuffleKey: const ValueKey<String>(
                          'genreShuffleAction',
                        ),
                        onPlay: () => _play(shuffle: false),
                        onShuffle: () => _play(shuffle: true),
                      ),
                    ],
                  ),
                );
              },
            ),
            TabBar(
              controller: _tabs,
              tabs: <Widget>[
                Tab(text: l10n.libraryTabAlbums),
                Tab(text: l10n.searchSongsSection),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: <Widget>[
                  _GenreAlbumsTab(genreKey: widget.genreKey),
                  _GenreSongsTab(genreKey: widget.genreKey),
                ],
              ),
            ),
          ],
        );
      },
    );
    return Scaffold(
      appBar: AppBar(title: Text(genre?.name ?? '')),
      // A sync republish re-reads the summary; keep the page (tab, search,
      // scroll) on screen meanwhile.
      body: resolveAdaptiveContextFor(context).useDesktopShell
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

/// The typed search of a tab, applied to its list after a short pause like the
/// other searches that query the database (each keystroke would re-read the
/// whole genre).
mixin _DebouncedSearch<T extends StatefulWidget> on State<T> {
  final TextEditingController search = TextEditingController();
  Timer? _debounce;

  /// The search text the list currently follows.
  String query = '';

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => query = search.text.trim());
    });
    // Shows the clear button at once.
    setState(() {});
  }

  void _clearSearch() {
    _debounce?.cancel();
    search.clear();
    setState(() => query = '');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    search.dispose();
    super.dispose();
  }
}

/// Search field, sort and downloaded-only chip shared by both tabs.
Widget _filters({
  required TextEditingController controller,
  required String hint,
  required ValueChanged<String> onChanged,
  required VoidCallback onClear,
  required Widget sortRow,
  bool alignWithGrid = true,
}) => Column(
  children: <Widget>[
    ListFilterField(
      controller: controller,
      alignWithContent: alignWithGrid,
      hint: hint,
      onChanged: onChanged,
      onClear: onClear,
    ),
    sortRow,
  ],
);

/// Whether the list is near its end and the last page came back full, so the
/// next page should be requested: a large genre is read a page at a time.
bool _wantsNextPage(
  ScrollController controller, {
  required int loaded,
  required int limit,
}) {
  if (!controller.hasClients || loaded < limit) return false;
  final metrics = controller.position;
  return metrics.hasContentDimensions &&
      metrics.extentAfter < metrics.viewportDimension;
}

class _GenreAlbumsTab extends ConsumerStatefulWidget {
  const new({required this.genreKey});

  final String genreKey;

  @override
  ConsumerState<_GenreAlbumsTab> createState() => _GenreAlbumsTabState();
}

class _GenreAlbumsTabState extends ConsumerState<_GenreAlbumsTab>
    with AutomaticKeepAliveClientMixin, _DebouncedSearch {
  final ScrollController _scroll = ScrollController();
  AlbumSortOrder _sort = AlbumSortOrder.name;
  int _pages = 1;
  Object? _pagedFor;
  List<AlbumsTableData>? _last;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final limit = ref.read(albumPageSizeProvider) * _pages;
    if (_wantsNextPage(_scroll, loaded: _last?.length ?? 0, limit: limit)) {
      setState(() => _pages++);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    // A different search, sort or filter starts again from the first page.
    final pagedFor = (query, _sort, downloadedOnly);
    if (_pagedFor != pagedFor) {
      _pagedFor = pagedFor;
      _pages = 1;
    }
    final async = ref.watch(
      genreAlbumsProvider((
        key: widget.genreKey,
        sort: _sort,
        downloadedOnly: downloadedOnly,
        query: query,
        limit: ref.watch(albumPageSizeProvider) * _pages,
      )),
    );
    final albums = async.asData?.value ?? _last;
    _last = albums;

    return CustomScrollView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: _filters(
            controller: search,
            hint: l10n.genreAlbumsSearchHint,
            onChanged: _onSearchChanged,
            onClear: _clearSearch,
            sortRow: LibrarySortFilterRow<AlbumSortOrder>(
              sortKey: const ValueKey<String>('genreAlbumsSortControl'),
              sortLabel: l10n.libraryAlbumsSortLabel,
              sortValue: _sort,
              sortItems: <DropdownMenuItem<AlbumSortOrder>>[
                DropdownMenuItem(
                  value: AlbumSortOrder.name,
                  child: Text(l10n.librarySortName),
                ),
                DropdownMenuItem(
                  value: AlbumSortOrder.artist,
                  child: Text(l10n.librarySortArtist),
                ),
                DropdownMenuItem(
                  value: AlbumSortOrder.newest,
                  child: Text(l10n.librarySortNewest),
                ),
                DropdownMenuItem(
                  value: AlbumSortOrder.recentlyAdded,
                  child: Text(l10n.librarySortRecentlyAdded),
                ),
              ],
              onSortChanged: (value) {
                if (value != null) setState(() => _sort = value);
              },
              downloadedOnly: downloadedOnly,
              onDownloadedOnlyChanged: (value) =>
                  ref.read(downloadedOnlyFilterProvider.notifier).enabled =
                      value,
            ),
          ),
        ),
        if (albums == null && async.hasError)
          SliverToBoxAdapter(
            child: ErrorState(
              title: l10n.libraryAlbumsErrorTitle,
              onRetry: () => ref.invalidate(genreAlbumsProvider),
              retryLabel: l10n.commonRetry,
            ),
          )
        else if (albums == null)
          const SliverToBoxAdapter(child: ShimmerListPage(count: 6))
        else if (albums.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyResults(
              query: query,
              downloadedOnly: downloadedOnly,
              emptyTitle: l10n.libraryAlbumsEmptyTitle,
            ),
          )
        else
          ResponsiveContentSliverGrid(
            itemCount: albums.length,
            itemBuilder: (context, index) {
              final album = albums[index];
              final heroTag = buildCoverArtHeroTag(
                coverArtId: album.coverArt,
                context: 'genre_album',
                entityId: album.id,
              );
              return RepaintBoundary(
                child: AlbumCard(
                  key: ValueKey('genre-album-${album.id}'),
                  album: album,
                  size: AlbumCardSize.library,
                  heroTag: heroTag,
                  badge: AlbumDownloadBadge(albumId: album.id),
                  onTap: () {
                    ref
                        .read(librarySyncControllerProvider.notifier)
                        .registerAlbumInteraction(album.id);
                    NavService.openAlbumDetail(
                      context,
                      ref,
                      album.id,
                      heroTag: heroTag,
                    );
                  },
                  onLongPress: () =>
                      showAlbumContextMenu(context, ref, album.id),
                  onSecondaryTapDown: (details) => showAlbumContextMenu(
                    context,
                    ref,
                    album.id,
                    anchor: details.globalPosition,
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _GenreSongsTab extends ConsumerStatefulWidget {
  const new({required this.genreKey});

  final String genreKey;

  @override
  ConsumerState<_GenreSongsTab> createState() => _GenreSongsTabState();
}

class _GenreSongsTabState extends ConsumerState<_GenreSongsTab>
    with AutomaticKeepAliveClientMixin, _DebouncedSearch {
  final ScrollController _scroll = ScrollController();
  GenreSongSort _sort = GenreSongSort.title;
  int _pages = 1;
  Object? _pagedFor;
  List<SongsTableData>? _last;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_wantsNextPage(
      _scroll,
      loaded: _last?.length ?? 0,
      limit: _songPageSize * _pages,
    )) {
      setState(() => _pages++);
    }
  }

  /// Plays [index] of the loaded [songs]. While more of the genre remains
  /// unloaded, the whole genre in the current order is queued instead, so a
  /// tap in a large genre does not stop after the loaded pages (like Play).
  Future<void> _playFrom(List<SongsTableData> songs, int index) async {
    var queued = songs;
    var start = index;
    if (ref.read(albumQueueEnabledProvider) &&
        songs.length >= _songPageSize * _pages) {
      final all = await ref
          .read(navisDatabaseProvider)
          .libraryDao
          .getSongsByGenre(
            widget.genreKey,
            sort: _sort,
            downloadedOnly: ref.read(downloadedOnlyFilterProvider),
            query: query,
          );
      final at = all.indexWhere((song) => song.id == songs[index].id);
      if (at >= 0) {
        queued = all;
        start = at;
      }
    }
    if (mounted) playTableSongInCollection(ref, queued, start);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context)!;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    // A different search, sort or filter starts again from the first page.
    final pagedFor = (query, _sort, downloadedOnly);
    if (_pagedFor != pagedFor) {
      _pagedFor = pagedFor;
      _pages = 1;
    }
    final async = ref.watch(
      genreSongsProvider((
        key: widget.genreKey,
        sort: _sort,
        downloadedOnly: downloadedOnly,
        query: query,
        limit: _songPageSize * _pages,
      )),
    );
    final songs = async.asData?.value ?? _last;
    _last = songs;

    return CustomScrollView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: _filters(
            controller: search,
            hint: l10n.matchFlowSearchHint,
            onChanged: _onSearchChanged,
            onClear: _clearSearch,
            alignWithGrid: false,
            sortRow: LibrarySortFilterRow<GenreSongSort>(
              alignWithGrid: false,
              sortKey: const ValueKey<String>('genreSongsSortControl'),
              sortLabel: l10n.genreSongsSortLabel,
              sortValue: _sort,
              sortItems: <DropdownMenuItem<GenreSongSort>>[
                DropdownMenuItem(
                  value: GenreSongSort.title,
                  child: Text(l10n.genreSongsSortTitle),
                ),
                DropdownMenuItem(
                  value: GenreSongSort.artist,
                  child: Text(l10n.librarySortArtist),
                ),
                DropdownMenuItem(
                  value: GenreSongSort.album,
                  child: Text(l10n.genreSongsSortAlbum),
                ),
              ],
              onSortChanged: (value) {
                if (value != null) setState(() => _sort = value);
              },
              downloadedOnly: downloadedOnly,
              onDownloadedOnlyChanged: (value) =>
                  ref.read(downloadedOnlyFilterProvider.notifier).enabled =
                      value,
            ),
          ),
        ),
        if (songs == null && async.hasError)
          SliverToBoxAdapter(
            child: ErrorState(
              title: l10n.genresLoadError,
              onRetry: () => ref.invalidate(genreSongsProvider),
              retryLabel: l10n.commonRetry,
            ),
          )
        else if (songs == null)
          const SliverToBoxAdapter(child: ShimmerListPage(count: 6))
        else if (songs.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyResults(
              query: query,
              downloadedOnly: downloadedOnly,
              emptyTitle: l10n.genreSongsEmpty,
            ),
          )
        else ...<Widget>[
          SliverToBoxAdapter(
            child: AdaptiveTrackHeader(actionExtent: desktopMode ? null : 48),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final song = songs[index];
              return TrackListTile(
                key: ValueKey<String>('genre-song-${song.id}'),
                song: song,
                actionExtent: desktopMode ? null : 48,
                trailing: desktopMode
                    ? DesktopSongActions(song: song, keyPrefix: 'genre-song')
                    : IconButton(
                        tooltip: MaterialLocalizations.of(context)
                            .showMenuTooltip,
                        icon: const Icon(Icons.more_vert),
                        onPressed: () =>
                            showSongContextMenu(context, ref, song),
                      ),
                onTap: () => unawaited(_playFrom(songs, index)),
                onLongPress: () => showSongContextMenu(context, ref, song),
              );
            }, childCount: songs.length),
          ),
        ],
      ],
    );
  }
}

/// A tab with nothing to show: no match for the search, nothing downloaded,
/// or (rarely) nothing in the genre.
class _EmptyResults extends ConsumerWidget {
  const new({
    required this.query,
    required this.downloadedOnly,
    required this.emptyTitle,
  });

  final String emptyTitle;
  final String query;
  final bool downloadedOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return EmptyState(
      title: query.isNotEmpty
          ? l10n.libraryFilterNoResults(query)
          : downloadedOnly
          ? l10n.libraryDownloadedOnlyEmpty
          : emptyTitle,
      subtitle: query.isNotEmpty
          ? l10n.libraryFilterNoResultsSubtitle
          : downloadedOnly
          ? l10n.libraryDownloadedOnlyEmptySubtitle
          : null,
      icon: query.isNotEmpty
          ? Icons.search_off
          : downloadedOnly
          ? Icons.download_done_outlined
          : Icons.sell_outlined,
      action: downloadedOnly
          ? FilledButton.tonalIcon(
              style: NavisColorStyleData.tonalStyleOf(context),
              onPressed: () =>
                  ref.read(downloadedOnlyFilterProvider.notifier).enabled =
                      false,
              icon: const Icon(Icons.filter_alt_off_outlined),
              label: Text(l10n.libraryClearFiltersAction),
            )
          : null,
    );
  }
}
