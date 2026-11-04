part of 'library_screen.dart';

// ---------------------------------------------------------------------------
// Genres tab embedded in the Library screen
// ---------------------------------------------------------------------------

/// One list item: a letter header (no genres) or a row of genre cards.
/// One genre per row on phones, one grid row of cards on wide panes.
typedef _GenreItem = ({String letter, List<GenreSummary> genres});

/// Height of a genre card at standard text size; it grows with text scale.
const double _kGenreCardHeight = 92;

/// The rail letter a genre sits under: its first Latin letter, else "#".
String _genreInitial(String name) {
  final first = name.isEmpty ? '#' : name.substring(0, 1).toUpperCase();
  return RegExp('[A-Z]').hasMatch(first) ? first : '#';
}

class _LibraryGenresTab extends ConsumerStatefulWidget {
  const new({
    required this.itemScrollController,
    this.typeFilterQuery = '',
    this.onClearTypeFilter,
    this.onRailScrubbing,
  });

  /// Lets the Library scroll this tab back to the top.
  final ItemScrollController itemScrollController;

  /// The Library type-to-filter query (desktop), used when the field is empty.
  final String typeFilterQuery;

  /// Clears the Library type-to-filter query.
  final VoidCallback? onClearTypeFilter;

  /// Reports a drag on the letter rail, which must not swipe the tab pager.
  final ValueChanged<bool>? onRailScrubbing;

  @override
  ConsumerState<_LibraryGenresTab> createState() => _LibraryGenresTabState();
}

class _LibraryGenresTabState extends ConsumerState<_LibraryGenresTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _filterController = TextEditingController();
  final ItemPositionsListener _positionsListener =
      ItemPositionsListener.create();
  GenreSortOrder _sort = GenreSortOrder.songs;
  List<GenreSummary>? _lastGenres;
  List<GenreSummary>? _itemsSource;
  int _itemsColumns = 1;
  List<_GenreItem> _items = const <_GenreItem>[];
  Map<String, int> _letterStart = const <String, int>{};
  String? _activeLetter;
  bool _scrubbing = false;

  /// The active filter: the typed field, else the Library's type-to-filter.
  String get _query =>
      (_filterController.text.isNotEmpty
              ? _filterController.text
              : widget.typeFilterQuery)
          .trim();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _positionsListener.itemPositions.addListener(_onViewportChanged);
  }

  @override
  void dispose() {
    _positionsListener.itemPositions.removeListener(_onViewportChanged);
    _filterController.dispose();
    super.dispose();
  }

  void _clearQuery() {
    _filterController.clear();
    widget.onClearTypeFilter?.call();
    setState(() {});
  }

  void _setDownloadedOnly(bool value) {
    if (ref.read(downloadedOnlyFilterProvider) == value) return;
    ref.read(downloadedOnlyFilterProvider.notifier).enabled = value;
  }

  void _setSort(GenreSortOrder? sort) {
    if (sort == null || sort == _sort) return;
    setState(() => _sort = sort);
  }

  void _setScrubbing(bool value) {
    if (_scrubbing == value) return;
    setState(() => _scrubbing = value);
    widget.onRailScrubbing?.call(value);
  }

  /// Rows of [columns] genres, grouped under letter headers (A-Z order) when
  /// sorted by name.
  void _rebuildItems(List<GenreSummary> genres, int columns) {
    if (identical(genres, _itemsSource) && columns == _itemsColumns) return;
    _itemsSource = genres;
    _itemsColumns = columns;
    List<_GenreItem> rows(String letter, List<GenreSummary> group) => [
      for (var i = 0; i < group.length; i += columns)
        (
          letter: letter,
          genres: group.sublist(i, math.min(i + columns, group.length)),
        ),
    ];
    if (_sort != GenreSortOrder.name) {
      _items = rows('', genres);
      _letterStart = const <String, int>{};
      _activeLetter = null;
      return;
    }
    final grouped = <String, List<GenreSummary>>{};
    for (final genre in genres) {
      grouped
          .putIfAbsent(_genreInitial(genre.name), () => <GenreSummary>[])
          .add(genre);
    }
    final letters = grouped.keys.toList()..sort();
    final items = <_GenreItem>[];
    final starts = <String, int>{};
    for (final letter in letters) {
      starts[letter] = items.length;
      items.add((letter: letter, genres: const <GenreSummary>[]));
      items.addAll(rows(letter, grouped[letter]!));
    }
    _items = items;
    _letterStart = starts;
    if (_activeLetter == null || !starts.containsKey(_activeLetter)) {
      _activeLetter = starts.keys.firstOrNull;
    }
  }

  void _onViewportChanged() {
    if (_letterStart.isEmpty || _scrubbing || !mounted) return;
    final visible = _positionsListener.itemPositions.value
        .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
        .toList(growable: false);
    if (visible.isEmpty) return;
    final first = visible.reduce(
      (a, b) => a.itemLeadingEdge <= b.itemLeadingEdge ? a : b,
    );
    final letter = _items[first.index].letter;
    if (letter != _activeLetter) setState(() => _activeLetter = letter);
  }

  void _scrollToLetter(String letter, {required bool animate}) {
    if (_activeLetter != letter) setState(() => _activeLetter = letter);
    final index = _letterStart[letter];
    if (index == null || !widget.itemScrollController.isAttached) return;
    widget.itemScrollController.jumpTo(index: index);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final l10n = AppLocalizations.of(context)!;
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final query = _query;
    final async = ref.watch(
      genreListProvider((
        query: query,
        sort: _sort,
        downloadedOnly: downloadedOnly,
      )),
    );
    // Keep showing the previous list while a changed query loads.
    final genres = async.asData?.value ?? _lastGenres;
    _lastGenres = genres;

    return Column(
      children: <Widget>[
        ListFilterField(
          controller: _filterController,
          alignWithContent: true,
          hint: l10n.genresSearchHint,
          onChanged: (_) => setState(() {}),
          onClear: _clearQuery,
        ),
        LibrarySortFilterRow<GenreSortOrder>(
          sortKey: const ValueKey<String>('genresSortControl'),
          sortLabel: l10n.genresSortLabel,
          sortValue: _sort,
          sortItems: <DropdownMenuItem<GenreSortOrder>>[
            DropdownMenuItem(
              value: GenreSortOrder.songs,
              child: Text(l10n.genresSortSongs),
            ),
            DropdownMenuItem(
              value: GenreSortOrder.albums,
              child: Text(l10n.genresSortAlbums),
            ),
            DropdownMenuItem(
              value: GenreSortOrder.name,
              child: Text(l10n.genresSortName),
            ),
          ],
          onSortChanged: _setSort,
          downloadedOnly: downloadedOnly,
          onDownloadedOnlyChanged: _setDownloadedOnly,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => triggerLibrarySyncFromPull(ref),
            child: genres == null
                ? (async.hasError
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: <Widget>[
                            ErrorState(
                              title: l10n.genresLoadError,
                              onRetry: () => ref.invalidate(genreListProvider),
                              retryLabel: l10n.commonRetry,
                            ),
                          ],
                        )
                      : const ShimmerListPage(count: 8))
                : genres.isEmpty
                ? _buildEmpty(
                    l10n,
                    query: query,
                    downloadedOnly: downloadedOnly,
                  )
                : _buildList(l10n, genres),
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty(
    AppLocalizations l10n, {
    required String query,
    required bool downloadedOnly,
  }) {
    final filtered = query.isNotEmpty || downloadedOnly;
    // Before the first genre-reading sync an empty list means "not yet".
    final syncing =
        !filtered &&
        (ref.watch(genresPendingSyncProvider).asData?.value ?? false);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: <Widget>[
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.5,
          child: EmptyState(
            title: query.isNotEmpty
                ? l10n.libraryFilterNoResults(query)
                : downloadedOnly
                ? l10n.libraryDownloadedOnlyEmpty
                : syncing
                ? l10n.genresSyncingTitle
                : l10n.genresEmptyTitle,
            subtitle: query.isNotEmpty
                ? l10n.libraryFilterNoResultsSubtitle
                : downloadedOnly
                ? l10n.libraryDownloadedOnlyEmptySubtitle
                : syncing
                ? l10n.genresSyncingSubtitle
                : l10n.genresEmptySubtitle,
            icon: query.isNotEmpty
                ? Icons.search_off
                : downloadedOnly
                ? Icons.download_done_outlined
                : syncing
                ? Icons.sync
                : Icons.sell_outlined,
            action: filtered
                ? FilledButton.tonalIcon(
                    style: NavisColorStyleData.tonalStyleOf(context),
                    key: const ValueKey<String>('genresClearFiltersAction'),
                    onPressed: () {
                      _clearQuery();
                      _setDownloadedOnly(false);
                    },
                    icon: const Icon(Icons.filter_alt_off_outlined),
                    label: Text(l10n.libraryClearFiltersAction),
                  )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildList(AppLocalizations l10n, List<GenreSummary> genres) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Wide panes show uniform cards in the same grid geometry as the
        // album and artist grids; phones keep the list.
        final inset = ContentLayout.padding(constraints.maxWidth);
        final railInset = _sort == GenreSortOrder.name ? 28.0 : 0.0;
        final wide = constraints.maxWidth >= kAdaptiveMediumWidth;
        final grid = wide
            ? ContentLayout.genres(
                math.max(0, constraints.maxWidth - inset * 2 - railInset),
              )
            : null;
        _rebuildItems(genres, grid?.columns ?? 1);
        // Centre a short grid like `ResponsiveContentSliverGrid`.
        final side = grid == null
            ? 16.0
            : inset +
                  (constraints.maxWidth -
                          inset * 2 -
                          railInset -
                          grid.occupiedWidth) /
                      2;
        final cardHeight =
            _kGenreCardHeight *
            math.max(1.0, MediaQuery.textScalerOf(context).scale(14) / 14);
        return Stack(
          children: <Widget>[
            ScrollablePositionedList.builder(
              itemCount: _items.length,
              itemScrollController: widget.itemScrollController,
              itemPositionsListener: _positionsListener,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.only(
                bottom: 16,
                right: _letterStart.isEmpty ? 0 : 28,
              ),
              itemBuilder: (context, index) {
                final item = _items[index];
                if (item.genres.isEmpty) {
                  return Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(side, 12, 16, 4),
                    child: Text(
                      item.letter,
                      style: theme.textTheme.titleMedium,
                    ),
                  );
                }
                if (grid == null) {
                  return _buildGenreRow(l10n, item.genres.single);
                }
                return Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: side,
                    bottom: grid.gap,
                  ),
                  child: Row(
                    children: <Widget>[
                      for (var i = 0; i < item.genres.length; i++) ...<Widget>[
                        if (i > 0) SizedBox(width: grid.gap),
                        SizedBox(
                          width: grid.extent,
                          height: cardHeight,
                          child: _GenreCard(
                            genre: item.genres[i],
                            subtitle: _genreCounts(l10n, item.genres[i]),
                            onTap: () => NavService.openGenreDetail(
                              context,
                              ref,
                              item.genres[i].key,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
            if (_letterStart.isNotEmpty) ...<Widget>[
              Positioned(
                right: 0,
                top: 8,
                bottom: 8,
                child: _SectionRail(
                  railKey: const Key('genreAlphabetRail'),
                  activeLabelKey: const Key('genreRailActiveLetter'),
                  labels: _letterStart.keys.toList(growable: false),
                  activeLabel: _activeLetter,
                  onLabelSelected: _scrollToLetter,
                  onInteractionStart: () => _setScrubbing(true),
                  onInteractionEnd: () => _setScrubbing(false),
                ),
              ),
              if (_scrubbing && _activeLetter != null)
                _RailOverlay(
                  overlayKey: const Key('genreAlphabetOverlay'),
                  label: _activeLetter!,
                ),
            ],
          ],
        );
      },
    );
  }

  String _genreCounts(AppLocalizations l10n, GenreSummary genre) =>
      '${l10n.playlistsSongCount(genre.songCount)} • '
      '${l10n.artistCardAlbumCount(genre.albumCount)}';

  Widget _buildGenreRow(AppLocalizations l10n, GenreSummary genre) {
    return ListTile(
      key: ValueKey<String>('genre-row-${genre.key}'),
      leading: const Icon(Icons.sell_outlined),
      title: Text(genre.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_genreCounts(l10n, genre)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => NavService.openGenreDetail(context, ref, genre.key),
    );
  }
}

/// A uniform genre tile for wide panes: name and counts on a themed card.
class _GenreCard extends StatelessWidget {
  const new({required this.genre, required this.subtitle, required this.onTap});

  final GenreSummary genre;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      key: ValueKey<String>('genre-row-${genre.key}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: colors.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: NavisSpace.md,
            end: NavisSpace.sm,
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.sell_outlined, color: colors.onSurfaceVariant),
              const SizedBox(width: NavisSpace.sm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      genre.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: NavisSpace.xxs),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
