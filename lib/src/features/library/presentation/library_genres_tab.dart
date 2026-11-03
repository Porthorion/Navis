part of 'library_screen.dart';

// ---------------------------------------------------------------------------
// Genres tab embedded in the Library screen
// ---------------------------------------------------------------------------

typedef _GenreItem = ({String letter, GenreSummary? genre});

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

  /// Rows grouped under letter headers (A-Z order) when sorted by name.
  void _rebuildItems(List<GenreSummary> genres) {
    if (identical(genres, _itemsSource)) return;
    _itemsSource = genres;
    if (_sort != GenreSortOrder.name) {
      _items = <_GenreItem>[
        for (final genre in genres) (letter: '', genre: genre),
      ];
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
      items.add((letter: letter, genre: null));
      items.addAll(<_GenreItem>[
        for (final genre in grouped[letter]!) (letter: letter, genre: genre),
      ]);
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
    _rebuildItems(genres);
    final theme = Theme.of(context);
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
            final genre = item.genre;
            if (genre == null) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(item.letter, style: theme.textTheme.titleMedium),
              );
            }
            return ListTile(
              key: ValueKey<String>('genre-row-${genre.key}'),
              leading: const Icon(Icons.sell_outlined),
              title: Text(
                genre.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${l10n.playlistsSongCount(genre.songCount)} • '
                '${l10n.artistCardAlbumCount(genre.albumCount)}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => NavService.openGenreDetail(context, ref, genre.key),
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
  }
}
