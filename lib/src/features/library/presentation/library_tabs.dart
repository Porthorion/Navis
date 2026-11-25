part of 'library_screen.dart';

class _LikedArtistStripTile extends ConsumerWidget {
  const new({
    required this.artist,
    this.artworkExtent = 64,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
  });

  final ArtistsTableData artist;
  final double artworkExtent;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shape = ref.watch(artistCardShapeProvider);
    final borderRadius = artworkBorderRadius(shape, extent: artworkExtent);
    final textStyle = Theme.of(context).textTheme.bodySmall;

    return InkWell(
      borderRadius: NavisShapeData.of(context).mdAll,
      onTap: onTap,
      enableFeedback: false,
      onLongPress: withLongPressHaptic(onLongPress),
      onSecondaryTapDown: onSecondaryTapDown,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            CoverArtImage(
              coverArtId: artist.coverArt,
              size: kCoverArtStandardSize,
              width: artworkExtent,
              height: artworkExtent,
              borderRadius: borderRadius,
              placeholderIcon: Icons.person_outline,
              isExternalSource: artist.isExternal,
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: Text(
                  artist.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: textStyle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Playlists tab embedded in the Library screen
// ---------------------------------------------------------------------------

class _LibraryPlaylistsTab extends ConsumerStatefulWidget {
  const new({
    this.scrollController,
    this.typeFilterQuery = '',
    this.onClearTypeFilter,
  });

  /// Optional external [ScrollController] for scroll-to-top support.
  final ScrollController? scrollController;

  /// The Library type-to-filter query (desktop). Touch layouts filter with
  /// their own field instead.
  final String typeFilterQuery;

  /// Clears the Library type-to-filter query.
  final VoidCallback? onClearTypeFilter;

  @override
  ConsumerState<_LibraryPlaylistsTab> createState() =>
      _LibraryPlaylistsTabState();
}

class _LibraryPlaylistsTabState extends ConsumerState<_LibraryPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  late final ProviderSubscription<AsyncValue<void>> _playlistSyncSubscription;
  final TextEditingController _filterController = TextEditingController();
  List<PlaylistLibraryItem> _cachedPlaylistItems =
      const <PlaylistLibraryItem>[];

  /// The active filter: the typed Library query on desktop, else the field.
  String get _query =>
      (widget.typeFilterQuery.isNotEmpty
              ? widget.typeFilterQuery
              : _filterController.text)
          .trim();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _playlistSyncSubscription = ref.listenManual<AsyncValue<void>>(
      playlistSyncProvider,
      (prev, next) {
        if (!mounted) {
          return;
        }
        if (next is AsyncError && (prev == null || prev is! AsyncError)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            final l10n = AppLocalizations.of(context)!;
            showAppNotice(
              context,
              message: l10n.playlistsLoadError,
              level: AppNoticeLevel.error,
            );
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _playlistSyncSubscription.close();
    _filterController.dispose();
    super.dispose();
  }

  void _clearFilter() {
    _filterController.clear();
    widget.onClearTypeFilter?.call();
    setState(() {});
  }

  /// The title as shown, so the filter matches what the user reads.
  String _displayTitle(AppLocalizations l10n, PlaylistLibraryItem item) =>
      item.isTrending ? l10n.homeTrendingTitle : item.name;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final l10n = AppLocalizations.of(context)!;
    final playlistsAsync = ref.watch(playlistLibraryItemsProvider);
    final playlistSyncAsync = ref.watch(playlistSyncProvider);
    // The list still shows the weekly playlists and Trending when the server
    // playlists cannot be read; the failure then shows as a row under them.
    final serverPlaylistsFailed = ref.watch(
      playlistListProvider.select((async) => async.hasError),
    );

    playlistsAsync.whenData((items) {
      _cachedPlaylistItems = items;
    });

    final effectiveItems = playlistsAsync.asData?.value ?? _cachedPlaylistItems;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final query = _query;
    final normalizedQuery = normalizeSearchText(query);
    final visibleItems = query.isEmpty
        ? effectiveItems
        : effectiveItems
              .where(
                (item) => searchTextMatches(normalizedQuery, [
                  _displayTitle(l10n, item),
                ]),
              )
              .toList(growable: false);

    final showFilterField = !desktopMode && effectiveItems.isNotEmpty;
    // A hidden field must not keep filtering rows that appear later.
    if (!showFilterField && _filterController.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _filterController.clear();
        setState(() {});
      });
    }

    return Stack(
      children: [
        Column(
          children: <Widget>[
            if (showFilterField)
              LibraryFilterField(
                controller: _filterController,
                hint: l10n.playlistsFilterHint,
                onChanged: (_) => setState(() {}),
                onClear: _clearFilter,
              ),
            Expanded(
              child: NavisRefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(playlistSyncProvider);
                  await ref.read(playlistSyncProvider.future);
                },
                child: playlistsAsync.when(
                  data: (_) {
                    if (effectiveItems.isEmpty) {
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
                    if (visibleItems.isEmpty) {
                      return ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          EmptyState(
                            title: l10n.libraryFilterNoResults(query),
                            subtitle: l10n.libraryFilterNoResultsSubtitle,
                            icon: Icons.search_off,
                            action: FilledButton.tonalIcon(
                              style: NavisColorStyleData.tonalStyleOf(context),
                              key: const ValueKey<String>(
                                'playlistsClearFilterAction',
                              ),
                              onPressed: _clearFilter,
                              icon: const Icon(Icons.filter_alt_off_outlined),
                              label: Text(l10n.libraryClearFiltersAction),
                            ),
                          ),
                        ],
                      );
                    }

                    return _buildPlaylistList(
                      visibleItems,
                      desktopMode: desktopMode,
                      serverPlaylistsFailed: serverPlaylistsFailed,
                    );
                  },
                  loading: () {
                    if (visibleItems.isNotEmpty) {
                      return _buildPlaylistList(
                        visibleItems,
                        desktopMode: desktopMode,
                      );
                    }
                    return const ShimmerListPage(count: 8);
                  },
                  error: (error, _) => ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      ErrorState(
                        title: l10n.playlistsLoadError,
                        onRetry: () => ref.invalidate(playlistSyncProvider),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (playlistSyncAsync.isLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
        Positioned(
          bottom: 16,
          // Clear of a right system strip (iPhone Duo cover screen).
          right: 16 + rightSystemInsetFor(context),
          child: FloatingActionButton(
            heroTag: 'library_playlists_fab',
            onPressed: () => showCreatePlaylistDialog(context, ref),
            tooltip: l10n.playlistsCreateAction,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistList(
    List<PlaylistLibraryItem> items, {
    required bool desktopMode,
    bool serverPlaylistsFailed = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final me = ref.watch(playlistViewerProvider);
    // Headers only tell sections apart, so a single section has none.
    final showHeaders = items.map((item) => item.section).toSet().length > 1;
    final rows = <Object>[];
    PlaylistLibrarySection? previous;
    for (final item in items) {
      if (showHeaders && item.section != previous) rows.add(item.section);
      previous = item.section;
      rows.add(item);
    }

    final loadError = ErrorState(
      key: const ValueKey<String>('library-playlists-load-error'),
      title: l10n.playlistsLoadError,
      onRetry: _retryServerPlaylists,
    );
    String sectionTitle(PlaylistLibrarySection section) => switch (section) {
      PlaylistLibrarySection.yours => l10n.playlistsSectionYours,
      PlaylistLibrarySection.madeForYou => l10n.playlistsSectionMadeForYou,
      PlaylistLibrarySection.other => l10n.playlistsSectionOther,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= kAdaptiveMediumWidth) {
          return _buildPlaylistGrid(
            rows,
            width: constraints.maxWidth,
            canEditFor: (playlist) => canEditPlaylist(playlist, me),
            desktopMode: desktopMode,
            sectionTitle: sectionTitle,
            loadError: serverPlaylistsFailed ? loadError : null,
          );
        }
        return ListView.builder(
          key: const PageStorageKey<String>('library-playlists'),
          controller: widget.scrollController,
          padding: const EdgeInsets.only(bottom: 80),
          itemCount: rows.length + (serverPlaylistsFailed ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == rows.length) return loadError;
            return switch (rows[index]) {
              final PlaylistLibrarySection section => NavisSectionHeader(
                title: sectionTitle(section),
                compact: true,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              ),
              final PlaylistLibraryItem item
                  when item.virtualPlaylist != null =>
                _buildVirtualPlaylistTile(item, item.virtualPlaylist!),
              final PlaylistLibraryItem item when item.isTrending =>
                _buildTrendingTile(item),
              final PlaylistLibraryItem item => _buildPlaylistTile(
                item.playlist!,
                canEdit: canEditPlaylist(item.playlist!, me),
                desktopMode: desktopMode,
              ),
              _ => const SizedBox.shrink(),
            };
          },
        );
      },
    );
  }

  /// The wide-pane Playlists tab: a cover grid per section (like Albums),
  /// with the section headers and the load-error row full width between and
  /// after them.
  Widget _buildPlaylistGrid(
    List<Object> rows, {
    required double width,
    required bool Function(PlaylistsTableData playlist) canEditFor,
    required bool desktopMode,
    required String Function(PlaylistLibrarySection section) sectionTitle,
    required Widget? loadError,
  }) {
    // Headers line up with the first cover column: the grid centres its
    // columns, so add the same remainder it does.
    final padding = ContentLayout.padding(width);
    final gridWidth = math.max(0.0, width - padding * 2);
    final grid = ContentLayout.albums(
      gridWidth,
      ref.watch(gridArtworkSizeProvider),
    );
    final inset = padding + (gridWidth - grid.occupiedWidth) / 2;
    final slivers = <Widget>[];
    var run = <PlaylistLibraryItem>[];
    void flush() {
      if (run.isEmpty) return;
      final group = run;
      run = <PlaylistLibraryItem>[];
      slivers.add(
        ResponsiveContentSliverGrid(
          itemCount: group.length,
          itemBuilder: (context, index) => RepaintBoundary(
            child: _buildPlaylistCard(
              group[index],
              canEditFor: canEditFor,
              desktopMode: desktopMode,
            ),
          ),
        ),
      );
    }

    for (final row in rows) {
      if (row case final PlaylistLibrarySection section) {
        flush();
        slivers.add(
          SliverToBoxAdapter(
            child: NavisSectionHeader(
              title: sectionTitle(section),
              compact: true,
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 8),
            ),
          ),
        );
      } else if (row case final PlaylistLibraryItem item) {
        run.add(item);
      }
    }
    flush();
    if (loadError != null) slivers.add(SliverToBoxAdapter(child: loadError));
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 80)));
    return CustomScrollView(
      key: const PageStorageKey<String>('library-playlists'),
      controller: widget.scrollController,
      slivers: slivers,
    );
  }

  /// One playlist grid cell: [AlbumCardContent] with the row's cover in its
  /// artwork slot and the row's own count or service text as the subtitle.
  /// No `albumId`, so no hover Play button.
  Widget _buildPlaylistCard(
    PlaylistLibraryItem item, {
    required bool Function(PlaylistsTableData playlist) canEditFor,
    required bool desktopMode,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final virtual = item.virtualPlaylist;
    final playlist = item.playlist;
    if (virtual != null) {
      final availability = virtual.matchingComplete
          ? l10n.weeklyPlaylistAvailableCount(
              virtual.matchedCount,
              virtual.totalCount,
            )
          : l10n.weeklyPlaylistAvailableMatching(virtual.matchedCount);
      return AlbumCardContent(
        key: ValueKey<String>('library-playlist-${item.id}'),
        name: item.name,
        artist: <String>[
          availability,
          l10n.weeklyPlaylistServiceName,
        ].join(' • '),
        artwork: LayoutBuilder(
          builder: (context, box) => ListenBrainzPlaylistArtwork(
            playlist: virtual,
            size: box.maxWidth,
          ),
        ),
        onTap: () => NavService.openListenBrainzWeeklyDetail(
          context,
          ref,
          virtual.playlist.sourcePatch ?? '',
        ),
      );
    }
    if (item.isTrending) {
      final tracks = item.trendingTracks;
      return AlbumCardContent(
        key: const ValueKey<String>('library-playlist-trending'),
        name: l10n.homeTrendingTitle,
        artist: <String>[
          if (tracks != null && tracks.isNotEmpty)
            trendingAvailability(l10n, tracks),
          l10n.trendingServiceName,
        ].join(' • '),
        artwork: LayoutBuilder(
          builder: (context, box) => PlaylistCoverMosaic(
            coverArtIds: <String>[
              ...?tracks?.map((track) => track.resolvedSong?.coverArt).nonNulls,
            ],
            size: box.maxWidth,
            fallbackIcon: Icons.trending_up_rounded,
          ),
        ),
        onTap: () => NavService.openPlaylistDetail(context, ref, item.id),
      );
    }
    final canEdit = canEditFor(playlist!);
    // As in the list: a device playlist tiles its songs' covers; a server one
    // keeps the server's own.
    final deviceCovers =
        (playlist.isLocal
            ? ref.watch(devicePlaylistCoverArtIdsProvider).value
            : null)?[playlist.id] ??
        const <String>[];
    return AlbumCardContent(
      key: ValueKey<String>('library-playlist-${playlist.id}'),
      name: playlist.name,
      artist: playlist.isLocal
          ? l10n.playlistDetailMeta(
              l10n.playlistsOnDevice,
              playlist.songCount ?? 0,
            )
          : playlist.songCount != null
          ? l10n.playlistsSongCount(playlist.songCount!)
          : '',
      coverArtId: deviceCovers.isEmpty ? playlist.coverArt : null,
      artwork: deviceCovers.isNotEmpty
          ? LayoutBuilder(
              builder: (context, box) => PlaylistCoverMosaic(
                coverArtIds: deviceCovers,
                size: box.maxWidth,
              ),
            )
          : CoverArtImage(
              coverArtId: playlist.coverArt,
              size: kCoverArtStandardSize,
              fit: BoxFit.cover,
              placeholderIcon: Icons.queue_music_outlined,
            ),
      // The list's More button, so keyboard and screen-reader users still
      // reach rename and delete on desktop.
      badge: desktopMode && canEdit
          ? Builder(
              builder: (buttonContext) => IconButton.filledTonal(
                key: ValueKey<String>('library-playlist-more-${playlist.id}'),
                icon: const Icon(Icons.more_vert),
                tooltip: l10n.nowPlayingMore,
                onPressed: () {
                  final renderObject = buttonContext.findRenderObject();
                  if (renderObject is! RenderBox) return;
                  _showPlaylistActions(
                    context,
                    playlist,
                    anchor: renderObject.localToGlobal(
                      renderObject.size.center(Offset.zero),
                    ),
                  );
                },
              ),
            )
          : null,
      onTap: () => NavService.openPlaylistDetail(context, ref, playlist.id),
      onLongPress: desktopMode || !canEdit
          ? null
          : () => _showPlaylistActions(context, playlist),
      onSecondaryTapDown: secondaryClickMenusEnabled(context) && canEdit
          ? (details) => _showPlaylistActions(
              context,
              playlist,
              anchor: details.globalPosition,
            )
          : null,
    );
  }

  /// Reads the server playlists again and asks the server for them.
  void _retryServerPlaylists() {
    ref
      ..invalidate(playlistListProvider)
      ..invalidate(playlistSyncProvider);
  }

  Widget _buildVirtualPlaylistTile(
    PlaylistLibraryItem item,
    ListenBrainzDiscoverPlaylist virtual,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final availability = virtual.matchingComplete
        ? l10n.weeklyPlaylistAvailableCount(
            virtual.matchedCount,
            virtual.totalCount,
          )
        : l10n.weeklyPlaylistAvailableMatching(virtual.matchedCount);
    final density = NavisDensityScope.of(context);
    final cover = density.listCover;
    return ListTile(
      dense: density.compact,
      visualDensity: density.compact ? VisualDensity.compact : null,
      minLeadingWidth: cover,
      horizontalTitleGap: 12,
      leading: ListenBrainzPlaylistArtwork(playlist: virtual, size: cover),
      title: Text(item.name),
      subtitle: Text(
        <String>[availability, l10n.weeklyPlaylistServiceName].join(' • '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => NavService.openListenBrainzWeeklyDetail(
        context,
        ref,
        virtual.playlist.sourcePatch ?? '',
      ),
    );
  }

  /// Trending Now, right under the weekly playlists: the chart's covers,
  /// its availability while it is known, and Deezer.
  Widget _buildTrendingTile(PlaylistLibraryItem item) {
    final l10n = AppLocalizations.of(context)!;
    final tracks = item.trendingTracks;
    final density = NavisDensityScope.of(context);
    final cover = density.listCover;
    return ListTile(
      key: const ValueKey<String>('library-playlist-trending'),
      dense: density.compact,
      visualDensity: density.compact ? VisualDensity.compact : null,
      minLeadingWidth: cover,
      horizontalTitleGap: 12,
      leading: PlaylistCoverMosaic(
        coverArtIds: <String>[
          ...?tracks?.map((track) => track.resolvedSong?.coverArt).nonNulls,
        ],
        size: cover,
        fallbackIcon: Icons.trending_up_rounded,
      ),
      title: Text(l10n.homeTrendingTitle),
      subtitle: Text(
        <String>[
          if (tracks != null && tracks.isNotEmpty)
            trendingAvailability(l10n, tracks),
          l10n.trendingServiceName,
        ].join(' • '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => NavService.openPlaylistDetail(context, ref, item.id),
    );
  }

  /// A playlist row. Rename and delete are offered only when [canEdit]: the
  /// server refuses other users' and read-only playlists anyway.
  Widget _buildPlaylistTile(
    PlaylistsTableData playlist, {
    required bool canEdit,
    required bool desktopMode,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final density = NavisDensityScope.of(context);
    final cover = density.listCover;
    // A device playlist tiles its songs' covers; a server one keeps the
    // server's own (Navidrome renders its mosaic).
    final deviceCovers =
        (playlist.isLocal
            ? ref.watch(devicePlaylistCoverArtIdsProvider).value
            : null)?[playlist.id] ??
        const <String>[];
    final tile = ListTile(
      dense: density.compact,
      visualDensity: density.compact ? VisualDensity.compact : null,
      minLeadingWidth: cover,
      horizontalTitleGap: 12,
      leading: SizedBox(
        width: cover,
        height: cover,
        child: deviceCovers.isNotEmpty
            ? PlaylistCoverMosaic(coverArtIds: deviceCovers, size: cover)
            : CoverArtImage(
                coverArtId: playlist.coverArt,
                size: 48,
                width: cover,
                height: cover,
                shape: ArtworkShapeRole.cover,
                semanticLabel: playlist.name,
              ),
      ),
      title: Text(playlist.name),
      subtitle: playlist.isLocal
          ? Text(
              l10n.playlistDetailMeta(
                l10n.playlistsOnDevice,
                playlist.songCount ?? 0,
              ),
            )
          : playlist.songCount != null
          ? Text(l10n.playlistsSongCount(playlist.songCount!))
          : null,
      trailing: desktopMode && canEdit
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Builder(
                  builder: (buttonContext) => IconButton(
                    icon: const Icon(Icons.more_vert),
                    tooltip: l10n.nowPlayingMore,
                    onPressed: () {
                      final renderObject = buttonContext.findRenderObject();
                      if (renderObject is! RenderBox) return;
                      _showPlaylistActions(
                        context,
                        playlist,
                        anchor: renderObject.localToGlobal(
                          renderObject.size.center(Offset.zero),
                        ),
                      );
                    },
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            )
          : const Icon(Icons.chevron_right),
      onTap: () => NavService.openPlaylistDetail(context, ref, playlist.id),
      enableFeedback: false,
      onLongPress: withLongPressHaptic(
        desktopMode || !canEdit
            ? null
            : () => _showPlaylistActions(context, playlist),
      ),
    );
    if (!secondaryClickMenusEnabled(context) || !canEdit) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) => _showPlaylistActions(
        context,
        playlist,
        anchor: details.globalPosition,
      ),
      child: tile,
    );
  }

  void _showPlaylistActions(
    BuildContext context,
    PlaylistsTableData playlist, {
    Offset? anchor,
  }) {
    if (anchor != null) {
      unawaited(_showDesktopPlaylistActions(context, playlist, anchor: anchor));
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    showNavisModalSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.playlistsEditTitle),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showEditDialog(context, playlist);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                l10n.playlistsDeleteConfirmTitle,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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

  Future<void> _showDesktopPlaylistActions(
    BuildContext context,
    PlaylistsTableData playlist, {
    required Offset anchor,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final action = await showDesktopContextMenu<_PlaylistContextAction>(
      context: context,
      anchor: anchor,
      items: <PopupMenuEntry<_PlaylistContextAction>>[
        PopupMenuItem<_PlaylistContextAction>(
          value: _PlaylistContextAction.edit,
          child: Text(l10n.playlistsEditTitle),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<_PlaylistContextAction>(
          value: _PlaylistContextAction.delete,
          textStyle: TextStyle(color: colors.error),
          child: Text(l10n.playlistsDeleteConfirmTitle),
        ),
      ],
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case _PlaylistContextAction.edit:
        _showEditDialog(context, playlist);
        return;
      case _PlaylistContextAction.delete:
        _confirmDelete(context, playlist);
        return;
    }
  }

  void _showEditDialog(BuildContext context, PlaylistsTableData playlist) {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: playlist.name);
    final canUpload =
        playlist.isLocal && ref.read(playlistServerCreationAvailableProvider);
    var toServer = false;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) => AlertDialog(
          title: Text(l10n.playlistsEditTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.playlistsCreateNameLabel,
                ),
                onSubmitted: (_) => unawaited(
                  _editPlaylist(
                    dialogContext,
                    playlist,
                    controller.text.trim(),
                    toServer: toServer,
                  ),
                ),
              ),
              if (playlist.isLocal)
                NavisSwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.playlistsSaveOnServerTitle),
                  subtitle: Text(
                    canUpload
                        ? l10n.playlistsSaveOnServerHint
                        : l10n.playlistsSaveOnServerOffline,
                  ),
                  value: toServer,
                  onChanged: canUpload
                      ? (value) => setDialogState(() => toServer = value)
                      : null,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              onPressed: () => unawaited(
                _editPlaylist(
                  dialogContext,
                  playlist,
                  controller.text.trim(),
                  toServer: toServer,
                ),
              ),
              child: Text(l10n.commonSave),
            ),
          ],
        ),
      ),
    );
  }

  /// Renames when the name changed, then (device playlists) moves it to the
  /// server. The rename lands first, so an upload failure keeps the new name.
  Future<void> _editPlaylist(
    BuildContext dialogContext,
    PlaylistsTableData playlist,
    String newName, {
    required bool toServer,
  }) async {
    if (newName.isEmpty) return;
    Navigator.of(dialogContext).pop();
    final l10n = AppLocalizations.of(context)!;
    final actions = ref.read(playlistActionsProvider);
    if (newName != playlist.name &&
        !await _runPlaylistAction(
          () => actions.rename(playlist, newName),
          l10n.playlistsRenameFailed,
        )) {
      return;
    }
    if (toServer) {
      await _runPlaylistAction(() async {
        final result = await actions.uploadToServer(playlist.id);
        if (!mounted) return;
        final messages = [
          if (result.deviceCopyKept) l10n.playlistsChangedWhileSaving,
          if (result.kept < result.total)
            l10n.playlistsSavedSongCount(result.kept, result.total),
        ];
        if (messages.isNotEmpty) {
          showAppNotice(context, message: messages.join('\n'));
        }
      }, l10n.playlistsSaveOnServerFailed);
    }
  }

  /// Runs a playlist change and returns whether it succeeded; a failure is
  /// shown, never swallowed.
  Future<bool> _runPlaylistAction(
    Future<void> Function() action,
    String failureMessage,
  ) async {
    try {
      await action();
      return true;
    } on Object catch (error) {
      AppLogger.warning('Playlist action failed: $error');
      if (mounted) {
        showAppNotice(
          context,
          message: failureMessage,
          level: AppNoticeLevel.error,
        );
      }
      return false;
    }
  }

  void _confirmDelete(BuildContext context, PlaylistsTableData playlist) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.playlistsDeleteConfirmTitle),
        content: Text(
          playlist.isLocal
              ? l10n.playlistsDeleteLocalConfirmMessage(playlist.name)
              : l10n.playlistsDeleteConfirmMessage(playlist.name),
        ),
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
    unawaited(
      _runPlaylistAction(
        () => ref.read(playlistActionsProvider).delete(playlist),
        AppLocalizations.of(context)!.playlistsDeleteFailed,
      ),
    );
  }
}

enum _PlaylistContextAction { edit, delete }

// ─────────────────────────────────────────────────────────────────────────────
// Liked Albums — full-screen list (navigated to from the "See all" button)
// ─────────────────────────────────────────────────────────────────────────────

class LikedAlbumsAllScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<LikedAlbumsAllScreen> createState() =>
      _LikedAlbumsAllScreenState();
}

class _LikedAlbumsAllScreenState extends ConsumerState<LikedAlbumsAllScreen>
    with
        TypeToFilter<LikedAlbumsAllScreen>,
        DebouncedSearch<LikedAlbumsAllScreen> {
  /// The active filter: the typed query on desktop, else the touch field.
  String get _filterQuery => activeFilterQuery(query);

  void _clearFilter() {
    clearSearch();
    clearTypeFilter();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final likedAlbumsAsync = ref.watch(likedAlbumsProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final downloadedContentIds = downloadedOnly
        ? ref.watch(downloadedContentIdsProvider).asData?.value
        : null;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    Future<void> refresh() => triggerLibrarySyncFromPull(ref);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.libraryLikedAlbumsAllTitle)),
      body: typeFilterFrame(
        Column(
          children: <Widget>[
            _likedSyncBanner(refresh),
            Expanded(
              child: NavisRefreshIndicator(
                onRefresh: refresh,
                child: likedAlbumsAsync.when(
                  loading: () => const _LoadingListPlaceholder(),
                  error: (error, _) => ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      ErrorState(
                        title: l10n.libraryAlbumsErrorTitle,
                        onRetry: refresh,
                        retryLabel: l10n.commonRetry,
                      ),
                    ],
                  ),
                  data: (albums) {
                    final base = downloadedOnly
                        ? albums
                              .where(
                                (album) =>
                                    downloadedContentIds?.albumIds.contains(
                                      album.id,
                                    ) ??
                                    false,
                              )
                              .toList(growable: false)
                        : albums;
                    final filtering = _filterQuery.isNotEmpty;
                    final normalized = normalizeSearchText(_filterQuery);
                    final filteredAlbums = filtering
                        ? base
                              .where(
                                (album) => searchTextMatches(normalized, [
                                  album.name,
                                  album.artistName,
                                ]),
                              )
                              .toList(growable: false)
                        : base;
                    return CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        // Desktop filters by typing; touch gets the field
                        // (kept while a query is set so it can be cleared).
                        if (!desktopMode &&
                            (base.isNotEmpty || search.text.isNotEmpty))
                          SliverToBoxAdapter(
                            child: ListFilterField(
                              controller: search,
                              hint: l10n.libraryLikedAlbumsFilterHint,
                              onChanged: onSearchChanged,
                              onClear: _clearFilter,
                            ),
                          ),
                        if (filteredAlbums.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: filtering && base.isNotEmpty
                                ? FilterNoResults(
                                    query: _filterQuery,
                                    onClear: _clearFilter,
                                  )
                                : EmptyState(
                                    title: downloadedOnly
                                        ? l10n.libraryDownloadedOnlyEmpty
                                        : l10n.libraryLikedEmptyTitle,
                                    subtitle: downloadedOnly
                                        ? l10n.libraryDownloadedOnlyEmptySubtitle
                                        : l10n.libraryLikedEmptySubtitle,
                                    icon: downloadedOnly
                                        ? Icons.download_done_outlined
                                        : Icons.favorite_border_outlined,
                                  ),
                          )
                        else
                          ResponsiveContentSliverGrid(
                            itemCount: filteredAlbums.length,
                            itemBuilder: (context, index) {
                              final album = filteredAlbums[index];
                              final heroTag = buildCoverArtHeroTag(
                                coverArtId: album.coverArt,
                                context: 'liked_all_album',
                                entityId: album.id,
                              );
                              return RepaintBoundary(
                                child: AlbumCard(
                                  key: ValueKey('liked-all-album-${album.id}'),
                                  album: album,
                                  size: AlbumCardSize.library,
                                  heroTag: heroTag,
                                  badge: AlbumDownloadBadge(albumId: album.id),
                                  onTap: () {
                                    ref
                                        .read(
                                          librarySyncControllerProvider
                                              .notifier,
                                        )
                                        .registerAlbumInteraction(album.id);
                                    NavService.openAlbumDetail(
                                      context,
                                      ref,
                                      album.id,
                                      heroTag: heroTag,
                                    );
                                  },
                                  onLongPress: () => showAlbumContextMenu(
                                    context,
                                    ref,
                                    album.id,
                                  ),
                                  onSecondaryTapDown: (details) =>
                                      showAlbumContextMenu(
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
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sync banner under a Liked "see all" app bar; only the banner follows
/// sync progress, so the list below does not rebuild with it.
Widget _likedSyncBanner(Future<void> Function() onRetry) => Consumer(
  builder: (context, ref, _) => LibrarySyncStatusBanner(
    syncState: ref.watch(librarySyncControllerProvider),
    onRetry: onRetry,
    onCancel: () =>
        ref.read(librarySyncControllerProvider.notifier).cancelSync(),
  ),
);

/// A liked-artist destination when the general Artists page is hidden.
class LikedArtistsAllScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<LikedArtistsAllScreen> createState() =>
      _LikedArtistsAllScreenState();
}

class _LikedArtistsAllScreenState extends ConsumerState<LikedArtistsAllScreen>
    with
        TypeToFilter<LikedArtistsAllScreen>,
        DebouncedSearch<LikedArtistsAllScreen> {
  /// The active filter: the typed query on desktop, else the touch field.
  String get _filterQuery => activeFilterQuery(query);

  void _clearFilter() {
    clearSearch();
    clearTypeFilter();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artists = ref.watch(likedArtistsProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final downloaded = downloadedOnly
        ? ref.watch(downloadedContentIdsProvider).asData?.value
        : null;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    Future<void> refresh() => triggerLibrarySyncFromPull(ref);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.libraryLikedArtistsSectionTitle)),
      body: typeFilterFrame(
        Column(
          children: <Widget>[
            _likedSyncBanner(refresh),
            Expanded(
              child: NavisRefreshIndicator(
                onRefresh: refresh,
                child: artists.when(
                  loading: () => const _LoadingListPlaceholder(),
                  error: (error, stack) => ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      ErrorState(
                        title: l10n.libraryArtistsErrorTitle,
                        onRetry: refresh,
                      ),
                    ],
                  ),
                  data: (items) {
                    final base = downloadedOnly
                        ? items
                              .where(
                                (artist) =>
                                    downloaded?.artistIds.contains(artist.id) ??
                                    false,
                              )
                              .toList(growable: false)
                        : items;
                    final filtering = _filterQuery.isNotEmpty;
                    final normalized = normalizeSearchText(_filterQuery);
                    final visible = filtering
                        ? base
                              .where(
                                (artist) => searchTextMatches(normalized, [
                                  artist.name,
                                ]),
                              )
                              .toList(growable: false)
                        : base;
                    return CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        // Desktop filters by typing; touch gets the field
                        // (kept while a query is set so it can be cleared).
                        if (!desktopMode &&
                            (base.isNotEmpty || search.text.isNotEmpty))
                          SliverToBoxAdapter(
                            child: ListFilterField(
                              controller: search,
                              hint: l10n.libraryLikedArtistsFilterHint,
                              onChanged: onSearchChanged,
                              onClear: _clearFilter,
                            ),
                          ),
                        if (visible.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: filtering && base.isNotEmpty
                                ? FilterNoResults(
                                    query: _filterQuery,
                                    onClear: _clearFilter,
                                  )
                                : EmptyState(
                                    title: downloadedOnly
                                        ? l10n.libraryDownloadedOnlyEmpty
                                        : l10n.libraryLikedEmptyTitle,
                                    subtitle: downloadedOnly
                                        ? l10n.libraryDownloadedOnlyEmptySubtitle
                                        : l10n.libraryLikedEmptySubtitle,
                                    icon: Icons.person_outline,
                                  ),
                          )
                        else
                          ResponsiveContentSliverGrid(
                            artists: true,
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final artist = visible[index];
                              return ArtistCard.grid(
                                key: ValueKey('liked-all-artist-${artist.id}'),
                                artist: artist,
                                onTap: () => NavService.openArtistDetail(
                                  context,
                                  ref,
                                  artist.id,
                                ),
                                onLongPress: () => showArtistContextMenu(
                                  context,
                                  ref,
                                  artist.id,
                                ),
                                onSecondaryTapDown: (details) =>
                                    showArtistContextMenu(
                                      context,
                                      ref,
                                      artist.id,
                                      anchor: details.globalPosition,
                                    ),
                              );
                            },
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
