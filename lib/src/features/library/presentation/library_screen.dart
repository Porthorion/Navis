import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/radio_screen.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

enum _AlbumSort { recentlyAdded, newest, name, artist }

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with TickerProviderStateMixin {
  _AlbumSort _albumSort = _AlbumSort.recentlyAdded;
  bool _downloadedOnly = false;
  final ScrollController _albumsScrollController = ScrollController();
  final ScrollController _playlistsScrollController = ScrollController();
  final ScrollController _radioScrollController = ScrollController();
  final ItemScrollController _artistsItemScrollController =
      ItemScrollController();
  final ItemPositionsListener _artistsItemPositionsListener =
      ItemPositionsListener.create();
  List<ArtistsTableData>? _cachedArtists;
  List<_ArtistListItem> _artistListItems = const <_ArtistListItem>[];
  Map<String, int> _artistLetterStartIndex = const <String, int>{};
  String? _activeArtistLetter;
  bool _isArtistRailScrubbing = false;
  int _loadedAlbumPages = 1;
  String _lastVisibleAlbumSignature = '';
  List<AlbumsTableData>? _cachedAlbums;
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    _albumsScrollController.addListener(_onAlbumsScroll);
    _artistsItemPositionsListener.itemPositions.addListener(
      _onArtistsViewportChanged,
    );
  }

  @override
  void dispose() {
    _tabController?.dispose();
    _albumsScrollController
      ..removeListener(_onAlbumsScroll)
      ..dispose();
    _playlistsScrollController.dispose();
    _radioScrollController.dispose();
    _artistsItemPositionsListener.itemPositions.removeListener(
      _onArtistsViewportChanged,
    );
    super.dispose();
  }

  Future<void> _refreshLibrary() {
    return ref.read(librarySyncControllerProvider.notifier).syncNow();
  }

  /// Scrolls whichever tab is currently selected back to the top.
  void _scrollCurrentTabToTop() {
    final tab = _tabController?.index ?? 0;

    if (tab == 0) {
      // Albums
      if (_albumsScrollController.hasClients) {
        _albumsScrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }

    var offset = 1;

    if (ref.read(showArtistsPageProvider)) {
      if (tab == offset) {
        // Artists
        if (_artistsItemScrollController.isAttached) {
          unawaited(
            _artistsItemScrollController.scrollTo(
              index: 0,
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
            ),
          );
        }
        return;
      }
      offset++;
    }

    if (ref.read(showPlaylistsPageProvider)) {
      if (tab == offset) {
        // Playlists
        if (_playlistsScrollController.hasClients) {
          _playlistsScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
          );
        }
        return;
      }
      offset++;
    }

    if (ref.read(showRadioPageProvider)) {
      if (tab == offset) {
        // Radio
        if (_radioScrollController.hasClients) {
          _radioScrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final syncState = ref.watch(librarySyncControllerProvider);
    final showRadioTab = ref.watch(showRadioPageProvider);
    final showArtistsTab = ref.watch(showArtistsPageProvider);
    final showPlaylistsTab = ref.watch(showPlaylistsPageProvider);
    final tabCount = 1 +
        (showArtistsTab ? 1 : 0) +
        (showPlaylistsTab ? 1 : 0) +
        (showRadioTab ? 1 : 0);
    final tabController = _ensureTabController(tabCount);

    // Scroll the active tab to top when the Library nav icon is re-tapped.
    ref.listen<int>(libraryScrollToTopRequestProvider, (prev, next) {
      if (!mounted) return;
      _scrollCurrentTabToTop();
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.libraryTitle),
        bottom: TabBar(
          controller: tabController,
          tabs: <Widget>[
            Tab(text: l10n.libraryTabAlbums),
            if (showArtistsTab) Tab(text: l10n.libraryTabArtists),
            if (showPlaylistsTab) Tab(text: l10n.navPlaylists),
            if (showRadioTab) Tab(text: l10n.navRadio),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          _SyncStatusBanner(syncState: syncState, onRetry: _refreshLibrary),
          Expanded(
            child: TabBarView(
              controller: tabController,
              physics: _isArtistRailScrubbing
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              children: <Widget>[
                _buildAlbumsTab(context),
                if (showArtistsTab) _buildArtistsTab(context),
                if (showPlaylistsTab)
                  _LibraryPlaylistsTab(
                    scrollController: _playlistsScrollController,
                  ),
                if (showRadioTab)
                  RadioTabContent(scrollController: _radioScrollController),
              ],
            ),
          ),
        ],
      ),
    );
  }

  TabController _ensureTabController(int tabCount) {
    final existing = _tabController;
    if (existing == null) {
      final created = TabController(length: tabCount, vsync: this);
      _tabController = created;
      return created;
    }
    if (existing.length == tabCount) {
      return existing;
    }
    final nextIndex = existing.index.clamp(0, tabCount - 1);
    existing.dispose();
    final replaced = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: nextIndex,
    );
    _tabController = replaced;
    return replaced;
  }

  Widget _buildArtistsTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artists = ref.watch(artistsProvider);
    // Watch downloaded content IDs so filter updates reactively.
    if (_downloadedOnly) {
      ref.watch(downloadedContentIdsProvider);
    }

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: artists.when(
        data: (items) {
          final filteredItems = _downloadedOnly
              ? _filterDownloadedArtists(items)
              : items;
          if (filteredItems.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                EmptyState(
                  title: _downloadedOnly
                      ? l10n.libraryDownloadedOnlyEmpty
                      : l10n.libraryArtistsEmptyTitle,
                  subtitle: _downloadedOnly
                      ? l10n.libraryDownloadedOnlyEmptySubtitle
                      : l10n.libraryArtistsEmptySubtitle,
                  icon: _downloadedOnly
                      ? Icons.download_done_outlined
                      : Icons.person_outline,
                ),
              ],
            );
          }

          _ensureArtistListCache(filteredItems);
          final letters = _artistLetterStartIndex.keys.toList(growable: false);

          return Stack(
            children: <Widget>[
              ScrollablePositionedList.builder(
                itemCount: _artistListItems.length,
                itemScrollController: _artistsItemScrollController,
                itemPositionsListener: _artistsItemPositionsListener,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 16, right: 28),
                itemBuilder: (context, index) {
                  final item = _artistListItems[index];
                  if (item.artist == null) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        item.letter,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    );
                  }
                  final artist = item.artist!;
                  return RepaintBoundary(
                    child: ArtistCard(
                      artist: artist,
                      onTap: () => context.go('/library/artists/${artist.id}'),
                      onLongPress: () => _showArtistMenu(context, artist),
                      onStarToggled: () => _toggleArtistStar(artist),
                    ),
                  );
                },
              ),
              Positioned(
                right: 0,
                top: 8,
                bottom: 8,
                child: _ArtistAlphabetRail(
                  letters: letters,
                  activeLetter: _activeArtistLetter,
                  onLetterSelected: _scrollToArtistLetter,
                  onInteractionStart: () {
                    if (_isArtistRailScrubbing) {
                      return;
                    }
                    setState(() => _isArtistRailScrubbing = true);
                  },
                  onInteractionEnd: () {
                    if (!_isArtistRailScrubbing) {
                      return;
                    }
                    setState(() => _isArtistRailScrubbing = false);
                  },
                ),
              ),
              if (_isArtistRailScrubbing && _activeArtistLetter != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Center(
                      child: DecoratedBox(
                        key: const Key('artistAlphabetOverlay'),
                        decoration: BoxDecoration(
                          color:
                              Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHigh.withValues(
                                alpha: 0.92,
                              ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                          child: Text(
                            _activeArtistLetter!,
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const <Widget>[
            _LoadingListPlaceholder(),
            _LoadingListPlaceholder(),
            _LoadingListPlaceholder(),
          ],
        ),
        error: (error, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            ErrorState(
              title: l10n.libraryArtistsErrorTitle,
              message: error.toString(),
              onRetry: _refreshLibrary,
              retryLabel: l10n.commonRetry,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumsTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pageSize = ref.watch(albumPageSizeProvider);
    final totalAlbumsAsync = ref.watch(albumCountProvider);
    final limit = pageSize * _loadedAlbumPages;
    // Watch downloaded content IDs so filter updates reactively.
    if (_downloadedOnly) {
      ref.watch(downloadedContentIdsProvider);
    }
    final albumsAsync = ref.watch(
      pagedAlbumsProvider(
        (
          sort: _toAlbumSortOrder(_albumSort),
          limit: limit,
        ),
      ),
    );

    // Preserve previous album data while loading a new page to avoid
    // destroying the scroll position (provider key change → AsyncLoading).
    final items = albumsAsync.asData?.value ?? _cachedAlbums;
    if (albumsAsync.asData != null) {
      _cachedAlbums = albumsAsync.asData!.value;
    }

    if (items == null) {
      // First load — no cached data yet.
      return RefreshIndicator(
        onRefresh: _refreshLibrary,
        child: albumsAsync.when(
          data: (_) => const SizedBox.shrink(), // handled above
          loading: () => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const <Widget>[
              _LoadingListPlaceholder(),
              _LoadingListPlaceholder(),
              _LoadingListPlaceholder(),
            ],
          ),
          error: (error, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: <Widget>[
              ErrorState(
                title: l10n.libraryAlbumsErrorTitle,
                message: error.toString(),
                onRetry: _refreshLibrary,
                retryLabel: l10n.commonRetry,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: Builder(
        builder: (context) {
          // Apply "Downloaded Only" filter if active.
          final filteredItems = _downloadedOnly
              ? _filterDownloadedAlbums(items)
              : items;
          _reportVisibleAlbumPriority(filteredItems);
          final totalAlbums = _downloadedOnly
              ? filteredItems.length
              : (totalAlbumsAsync.asData?.value ?? items.length);
          final hasMore = !_downloadedOnly && items.length < totalAlbums;
          return Scrollbar(
            controller: _albumsScrollController,
            thumbVisibility: false,
            interactive: true,
            child: CustomScrollView(
            controller: _albumsScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _SortFilterRow<_AlbumSort>(
                  sortLabel: l10n.libraryAlbumsSortLabel,
                  sortValue: _albumSort,
                  sortItems: <DropdownMenuItem<_AlbumSort>>[
                    DropdownMenuItem(
                      value: _AlbumSort.recentlyAdded,
                      child: Text(l10n.librarySortRecentlyAdded),
                    ),
                    DropdownMenuItem(
                      value: _AlbumSort.newest,
                      child: Text(l10n.librarySortNewest),
                    ),
                    DropdownMenuItem(
                      value: _AlbumSort.name,
                      child: Text(l10n.librarySortName),
                    ),
                    DropdownMenuItem(
                      value: _AlbumSort.artist,
                      child: Text(l10n.librarySortArtist),
                    ),
                  ],
                  onSortChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _albumSort = value;
                        _loadedAlbumPages = 1;
                        _cachedAlbums = null;
                      });
                      if (_albumsScrollController.hasClients) {
                        _albumsScrollController.jumpTo(0);
                      }
                    }
                  },
                  downloadedOnly: _downloadedOnly,
                  onDownloadedOnlyChanged: (value) {
                    setState(() => _downloadedOnly = value);
                  },
                ),
              ),
              if (filteredItems.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    title: _downloadedOnly
                        ? l10n.libraryDownloadedOnlyEmpty
                        : l10n.libraryAlbumsEmptyTitle,
                    subtitle: _downloadedOnly
                        ? l10n.libraryDownloadedOnlyEmptySubtitle
                        : l10n.libraryAlbumsEmptySubtitle,
                    icon: _downloadedOnly
                        ? Icons.download_done_outlined
                        : Icons.album_outlined,
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 1,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final album = filteredItems[index];
                      return RepaintBoundary(
                        child: AlbumCard(
                          key: ValueKey(album.id),
                          album: album,
                          size: AlbumCardSize.library,
                          heroTag: buildCoverArtHeroTag(
                            coverArtId: album.coverArt,
                            context: 'album',
                          ),
                          onTap: () {
                            ref
                                .read(librarySyncControllerProvider.notifier)
                                .registerAlbumInteraction(album.id);
                            context.go('/library/albums/${album.id}');
                          },
                          onLongPress: () => _showAlbumMenu(context, album),
                        ),
                      );
                    }, childCount: filteredItems.length),
                  ),
                ),
              if (hasMore)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    child: Text(
                      l10n.libraryAlbumsPagingProgress(
                        items.length,
                        totalAlbums,
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
            ),
          );
        },
      ),
    );
  }

  void _onAlbumsScroll() {
    if (!_albumsScrollController.hasClients) {
      return;
    }

    final metrics = _albumsScrollController.position;
    if (!metrics.hasContentDimensions || metrics.maxScrollExtent <= 0) {
      return;
    }

    final threshold = metrics.maxScrollExtent * 0.7;
    if (metrics.pixels < threshold) {
      return;
    }

    final totalAlbums = ref.read(albumCountProvider).asData?.value;
    final pageSize = ref.read(albumPageSizeProvider);
    if (totalAlbums == null) {
      return;
    }
    if (pageSize * _loadedAlbumPages >= totalAlbums) {
      return;
    }
    setState(() => _loadedAlbumPages += 1);
  }

  void _reportVisibleAlbumPriority(List<AlbumsTableData> albums) {
    if (albums.isEmpty) {
      return;
    }
    final ids = albums
        .take(24)
        .map((album) => album.id)
        .where((id) => id.trim().isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    final signature = ids.join('|');
    if (signature == _lastVisibleAlbumSignature) {
      return;
    }
    _lastVisibleAlbumSignature = signature;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(librarySyncControllerProvider.notifier).setVisibleAlbumIds(ids);
    });
  }

  AlbumSortOrder _toAlbumSortOrder(_AlbumSort sort) {
    return switch (sort) {
      _AlbumSort.recentlyAdded => AlbumSortOrder.recentlyAdded,
      _AlbumSort.newest => AlbumSortOrder.newest,
      _AlbumSort.name => AlbumSortOrder.name,
      _AlbumSort.artist => AlbumSortOrder.artist,
    };
  }

  List<AlbumsTableData> _filterDownloadedAlbums(List<AlbumsTableData> albums) {
    final contentIds = ref.read(downloadedContentIdsProvider).asData?.value;
    if (contentIds == null) return const [];
    return albums
        .where((album) => contentIds.albumIds.contains(album.id))
        .toList();
  }

  List<ArtistsTableData> _filterDownloadedArtists(
    List<ArtistsTableData> artists,
  ) {
    final contentIds = ref.read(downloadedContentIdsProvider).asData?.value;
    if (contentIds == null) return const [];
    return artists
        .where((artist) => contentIds.artistIds.contains(artist.id))
        .toList();
  }

  Map<String, List<ArtistsTableData>> _groupArtistsByInitial(
    List<ArtistsTableData> artists,
  ) {
    final grouped = <String, List<ArtistsTableData>>{};
    for (final artist in artists) {
      final first = artist.name.isEmpty ? '#' : artist.name.substring(0, 1);
      final initial = RegExp('[A-Za-z]').hasMatch(first.toUpperCase())
          ? first.toUpperCase()
          : '#';
      grouped.putIfAbsent(initial, () => <ArtistsTableData>[]).add(artist);
    }
    for (final entry in grouped.entries) {
      entry.value.sort((a, b) => a.name.compareTo(b.name));
    }
    return grouped;
  }

  List<_ArtistListItem> _buildArtistListItems(
    Map<String, List<ArtistsTableData>> grouped,
    List<String> letters,
  ) {
    final items = <_ArtistListItem>[];
    for (final letter in letters) {
      items.add(_ArtistListItem.header(letter));
      for (final artist in grouped[letter] ?? const <ArtistsTableData>[]) {
        items.add(_ArtistListItem.artist(letter, artist));
      }
    }
    return items;
  }

  Map<String, int> _buildArtistLetterStartIndex(List<_ArtistListItem> items) {
    final indexByLetter = <String, int>{};
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.artist == null) {
        indexByLetter[item.letter] ??= i;
      }
    }
    return indexByLetter;
  }

  void _ensureArtistListCache(List<ArtistsTableData> artists) {
    if (identical(_cachedArtists, artists) && _artistListItems.isNotEmpty) {
      return;
    }
    final grouped = _groupArtistsByInitial(artists);
    final letters = grouped.keys.toList(growable: false)..sort();
    _artistListItems = _buildArtistListItems(grouped, letters);
    _artistLetterStartIndex = _buildArtistLetterStartIndex(_artistListItems);
    if (_artistLetterStartIndex.isEmpty) {
      _activeArtistLetter = null;
    } else if (_activeArtistLetter == null ||
        !_artistLetterStartIndex.containsKey(_activeArtistLetter)) {
      _activeArtistLetter = _artistLetterStartIndex.keys.first;
    }
    _cachedArtists = artists;
  }

  void _onArtistsViewportChanged() {
    if (_artistListItems.isEmpty || _isArtistRailScrubbing) {
      return;
    }
    final positions = _artistsItemPositionsListener.itemPositions.value;
    if (positions.isEmpty) {
      return;
    }
    final visible = positions
        .where(
          (position) =>
              position.itemTrailingEdge > 0 && position.itemLeadingEdge < 1,
        )
        .toList(growable: false);
    if (visible.isEmpty) {
      return;
    }
    final candidates = visible
        .where((position) => position.itemLeadingEdge >= 0)
        .toList(growable: false);
    final targetSet = candidates.isEmpty ? visible : candidates;
    targetSet.sort((a, b) {
      final byEdge = a.itemLeadingEdge.compareTo(b.itemLeadingEdge);
      if (byEdge != 0) {
        return byEdge;
      }
      return a.index.compareTo(b.index);
    });
    final topIndex = targetSet.first.index.clamp(
      0,
      _artistListItems.length - 1,
    );
    final topLetter = _artistListItems[topIndex].letter;
    if (topLetter == _activeArtistLetter || !mounted) {
      return;
    }
    setState(() => _activeArtistLetter = topLetter);
  }

  void _scrollToArtistLetter(
    String letter, {
    required bool animate,
  }) {
    if (_activeArtistLetter == letter) {
      return;
    }
    if (mounted) {
      setState(() => _activeArtistLetter = letter);
    }
    final sectionIndex = _artistLetterStartIndex[letter];
    if (sectionIndex == null || !_artistsItemScrollController.isAttached) {
      return;
    }
    if (animate) {
      unawaited(
        _artistsItemScrollController.scrollTo(
          index: sectionIndex,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        ),
      );
      return;
    }
    _artistsItemScrollController.jumpTo(index: sectionIndex);
  }

  // Kept for future star action in album context menu.
  // ignore: unused_element
  Future<void> _toggleAlbumStar(AlbumsTableData album) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    final isStarred = album.starred != null;
    try {
      if (isStarred) {
        await api.unstar(album.id);
      } else {
        await api.star(album.id);
      }
      final dao = ref.read(navisDatabaseProvider).libraryDao;
      await dao.updateAlbumStarred(
        album.id,
        isStarred ? null : DateTime.now(),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.albumDetailStarFailure)),
      );
    }
  }

  Future<void> _toggleArtistStar(ArtistsTableData artist) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    final isStarred = artist.starred != null;
    try {
      if (isStarred) {
        await api.unstar(artist.id);
      } else {
        await api.star(artist.id);
      }
      final dao = ref.read(navisDatabaseProvider).libraryDao;
      await dao.updateArtistStarred(
        artist.id,
        isStarred ? null : DateTime.now(),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.albumDetailStarFailure)),
      );
    }
  }

  Future<void> _showAlbumMenu(
    BuildContext context,
    AlbumsTableData album,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.open_in_new_outlined),
                title: Text(l10n.libraryAlbumMenuOpen),
                onTap: () {
                  Navigator.of(context).pop();
                  ref
                      .read(librarySyncControllerProvider.notifier)
                      .registerAlbumInteraction(album.id);
                  this.context.go('/library/albums/${album.id}');
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showArtistMenu(
    BuildContext context,
    ArtistsTableData artist,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.open_in_new_outlined),
                title: Text(l10n.libraryArtistMenuOpen),
                onTap: () {
                  Navigator.of(context).pop();
                  this.context.go('/library/artists/${artist.id}');
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SyncStatusBanner extends StatelessWidget {
  const _SyncStatusBanner({required this.syncState, required this.onRetry});

  final LibrarySyncState syncState;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (syncState.status == LibrarySyncStatus.failed) {
      return Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  syncState.errorMessage ?? l10n.librarySyncFailureFallback,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onRetry,
                child: Text(l10n.commonRetry),
              ),
            ],
          ),
        ),
      );
    }

    if (!syncState.isRunning && syncState.lastSyncedAt == null) {
      return const SizedBox.shrink();
    }

    if (syncState.isRunning) {
      final total = syncState.total;
      final processed = syncState.processed ?? 0;
      final progress = total == null || total == 0
          ? null
          : processed / total.clamp(1, total);
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(value: progress),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                _runningLabel(l10n, total, processed),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  String _runningLabel(
    AppLocalizations l10n,
    int? total,
    int processed,
  ) {
    final pending = syncState.pendingHydrationCount ?? 0;
    if (syncState.metadataReady &&
        syncState.stage == LibrarySyncStage.fetchingSongs) {
      if (total == null || total == 0) {
        return l10n.librarySyncHydratingUnknown;
      }
      final throughput = syncState.hydrationThroughputAlbumsPerSecond;
      if (throughput != null && throughput > 0) {
        return l10n.librarySyncHydratingProgressWithRate(
          processed,
          total,
          pending,
          throughput.toStringAsFixed(1),
        );
      }
      return l10n.librarySyncHydratingProgress(processed, total, pending);
    }

    if (total == null) {
      return l10n.librarySyncRunningStage(_stageLabel(syncState.stage, l10n));
    }
    return l10n.librarySyncRunningWithProgress(processed, total);
  }

  String _stageLabel(LibrarySyncStage stage, AppLocalizations l10n) {
    return switch (stage) {
      LibrarySyncStage.preparing => l10n.librarySyncStagePreparing,
      LibrarySyncStage.fetchingArtists => l10n.librarySyncStageArtists,
      LibrarySyncStage.fetchingAlbums => l10n.librarySyncStageAlbums,
      LibrarySyncStage.persistingMetadata => l10n.librarySyncStagePersisting,
      LibrarySyncStage.fetchingSongs => l10n.librarySyncStageSongs,
      LibrarySyncStage.fetchingGenres => l10n.librarySyncStageGenres,
      LibrarySyncStage.fetchingPlaylists => l10n.librarySyncStagePlaylists,
      LibrarySyncStage.finalizing => l10n.librarySyncStageFinalizing,
      _ => l10n.librarySyncRunning,
    };
  }
}

class _ArtistAlphabetRail extends StatelessWidget {
  const _ArtistAlphabetRail({
    required this.letters,
    required this.activeLetter,
    required this.onLetterSelected,
    required this.onInteractionStart,
    required this.onInteractionEnd,
  });

  final List<String> letters;
  final String? activeLetter;
  final void Function(String letter, {required bool animate}) onLetterSelected;
  final VoidCallback onInteractionStart;
  final VoidCallback onInteractionEnd;

  @override
  Widget build(BuildContext context) {
    if (letters.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      key: const Key('artistAlphabetRail'),
      width: 36,
      child: LayoutBuilder(
        builder: (context, constraints) {
          void selectAtDy(double dy) {
            if (constraints.maxHeight <= 0) {
              return;
            }
            final normalized = ((dy / constraints.maxHeight) * letters.length)
                .clamp(0, letters.length - 0.0001);
            final index = normalized.floor().clamp(
              0,
              letters.length - 1,
            );
            onLetterSelected(
              letters[index],
              animate: false,
            );
          }

          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (details) {
              onInteractionStart();
              selectAtDy(details.localPosition.dy);
            },
            onPointerMove: (details) => selectAtDy(details.localPosition.dy),
            onPointerUp: (details) {
              selectAtDy(details.localPosition.dy);
              onInteractionEnd();
            },
            onPointerCancel: (_) => onInteractionEnd(),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: letters
                    .map(
                      (letter) => Expanded(
                        child: Center(
                          child: Text(
                            letter,
                            key: letter == activeLetter
                                ? const Key('artistRailActiveLetter')
                                : null,
                            style:
                                Theme.of(
                                  context,
                                ).textTheme.labelSmall?.copyWith(
                                  color: letter == activeLetter
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                  fontWeight: letter == activeLetter
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          );
        },
      ),
    );
  }
}

@immutable
class _ArtistListItem {
  const _ArtistListItem._({required this.letter, this.artist});

  const _ArtistListItem.header(String letter) : this._(letter: letter);

  const _ArtistListItem.artist(String letter, ArtistsTableData artist)
    : this._(letter: letter, artist: artist);

  final String letter;
  final ArtistsTableData? artist;
}

class _SortFilterRow<T> extends StatelessWidget {
  const _SortFilterRow({
    required this.sortLabel,
    required this.sortValue,
    required this.sortItems,
    required this.onSortChanged,
    required this.downloadedOnly,
    required this.onDownloadedOnlyChanged,
  });

  final String sortLabel;
  final T sortValue;
  final List<DropdownMenuItem<T>> sortItems;
  final ValueChanged<T?> onSortChanged;
  final bool downloadedOnly;
  final ValueChanged<bool> onDownloadedOnlyChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: <Widget>[
          FilterChip(
            label: Text(l10n.libraryDownloadedOnlyFilter),
            selected: downloadedOnly,
            onSelected: onDownloadedOnlyChanged,
            avatar: Icon(
              downloadedOnly ? Icons.download_done : Icons.download_outlined,
              size: 18,
            ),
          ),
          const Spacer(),
          DropdownButton<T>(
            value: sortValue,
            items: sortItems,
            onChanged: onSortChanged,
          ),
        ],
      ),
    );
  }
}

class _LoadingListPlaceholder extends StatelessWidget {
  const _LoadingListPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ShimmerPlaceholder(height: 18, width: 180),
          SizedBox(height: 8),
          ShimmerPlaceholder(height: 14, width: 120),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Playlists tab embedded in the Library screen
// ---------------------------------------------------------------------------

class _LibraryPlaylistsTab extends ConsumerStatefulWidget {
  const _LibraryPlaylistsTab({this.scrollController});

  /// Optional external [ScrollController] for scroll-to-top support.
  final ScrollController? scrollController;

  @override
  ConsumerState<_LibraryPlaylistsTab> createState() =>
      _LibraryPlaylistsTabState();
}

class _LibraryPlaylistsTabState
    extends ConsumerState<_LibraryPlaylistsTab> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.invalidate(playlistSyncProvider));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playlistsAsync = ref.watch(playlistListProvider);
    ref.watch(playlistSyncProvider);

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(playlistSyncProvider);
            await ref.read(playlistSyncProvider.future);
          },
          child: playlistsAsync.when(
            data: (playlists) {
              if (playlists.isEmpty) {
                return ListView(
                  children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: EmptyState(
                        title: l10n.playlistsEmpty,
                        subtitle: l10n.playlistsEmptySubtitle,
                        icon: Icons.queue_music_outlined,
                      ),
                    ),
                  ],
                );
              }

              return ListView.builder(
                controller: widget.scrollController,
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: playlists.length,
                itemBuilder: (context, index) {
                  final playlist = playlists[index];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CoverArtImage(
                        coverArtId: playlist.coverArt,
                        size: 48,
                        semanticLabel: playlist.name,
                      ),
                    ),
                    title: Text(playlist.name),
                    subtitle: playlist.songCount != null
                        ? Text(l10n.playlistsSongCount(playlist.songCount!))
                        : null,
                    onTap: () => context.push(
                      '/library/playlists/${playlist.id}',
                    ),
                    onLongPress: () =>
                        _showPlaylistActions(context, playlist),
                  );
                },
              );
            },
            loading: () => const ShimmerListPage(count: 8),
            error: (error, _) => ErrorState(
              title: l10n.playlistsLoadError,
              message: error.toString(),
              onRetry: () => ref.invalidate(playlistSyncProvider),
            ),
          ),
        ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton(
            heroTag: 'library_playlists_fab',
            onPressed: () => _showCreatePlaylistDialog(context),
            tooltip: l10n.playlistsCreateAction,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsCreateTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration:
              InputDecoration(labelText: l10n.playlistsCreateNameLabel),
          onSubmitted: (_) =>
              _createPlaylist(dialogContext, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () =>
                _createPlaylist(dialogContext, controller.text.trim()),
            child: Text(l10n.playlistsCreateAction),
          ),
        ],
      ),
    );
  }

  void _createPlaylist(BuildContext dialogContext, String name) {
    if (name.isEmpty) return;
    Navigator.of(dialogContext).pop();

    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;

    unawaited(
      api
          .createPlaylist(name)
          .then((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsCreateSuccess)),
            );
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.playlistsCreateFailed)),
            );
          }),
    );
  }

  void _showPlaylistActions(
    BuildContext context,
    PlaylistsTableData playlist,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.playlistsRenameTitle),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showRenameDialog(context, playlist);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                l10n.playlistsDeleteConfirmTitle,
                style:
                    TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmDelete(context, playlist);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, PlaylistsTableData playlist) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: playlist.name);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsRenameTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration:
              InputDecoration(labelText: l10n.playlistsCreateNameLabel),
          onSubmitted: (_) =>
              _renamePlaylist(dialogContext, playlist, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () =>
                _renamePlaylist(dialogContext, playlist, controller.text.trim()),
            child: Text(l10n.playlistsRenameTitle),
          ),
        ],
      ),
    );
  }

  void _renamePlaylist(
    BuildContext dialogContext,
    PlaylistsTableData playlist,
    String newName,
  ) {
    if (newName.isEmpty) return;
    Navigator.of(dialogContext).pop();
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    unawaited(
      api
          .updatePlaylist(id: playlist.id, name: newName)
          .then((_) {
            if (!mounted) return;
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {}),
    );
  }

  void _confirmDelete(
    BuildContext context,
    PlaylistsTableData playlist,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsDeleteConfirmTitle),
        content: Text(l10n.playlistsDeleteConfirmMessage(playlist.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _deletePlaylist(playlist);
            },
            child: Text(l10n.playlistsDeleteConfirmTitle),
          ),
        ],
      ),
    );
  }

  void _deletePlaylist(PlaylistsTableData playlist) {
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    unawaited(
      api
          .deletePlaylist(playlist.id)
          .then((_) {
            if (!mounted) return;
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {}),
    );
  }
}
