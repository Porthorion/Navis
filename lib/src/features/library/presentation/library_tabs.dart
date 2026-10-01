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
    final borderRadius = coverArtShapeToRadius(shape);
    final textStyle = Theme.of(context).textTheme.bodySmall;

    return InkWell(
      borderRadius: NavisRadius.mdAll,
      onTap: onTap,
      onLongPress: onLongPress,
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
  const new({this.scrollController});

  /// Optional external [ScrollController] for scroll-to-top support.
  final ScrollController? scrollController;

  @override
  ConsumerState<_LibraryPlaylistsTab> createState() =>
      _LibraryPlaylistsTabState();
}

class _LibraryPlaylistsTabState extends ConsumerState<_LibraryPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  late final ProviderSubscription<AsyncValue<void>> _playlistSyncSubscription;
  List<PlaylistLibraryItem> _cachedPlaylistItems =
      const <PlaylistLibraryItem>[];

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final l10n = AppLocalizations.of(context)!;
    final playlistsAsync = ref.watch(playlistLibraryItemsProvider);
    final playlistSyncAsync = ref.watch(playlistSyncProvider);

    playlistsAsync.whenData((items) {
      _cachedPlaylistItems = items;
    });

    final effectiveItems = playlistsAsync.asData?.value ?? _cachedPlaylistItems;

    return Stack(
      children: [
        RefreshIndicator(
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

              return _buildPlaylistList(effectiveItems);
            },
            loading: () {
              if (effectiveItems.isNotEmpty) {
                return _buildPlaylistList(effectiveItems);
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
        if (playlistSyncAsync.isLoading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
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

  Widget _buildPlaylistList(List<PlaylistLibraryItem> items) {
    final firstNormalIndex = items.indexWhere((item) => !item.isVirtual);
    final hasVirtualPlaylists = items.any((item) => item.isVirtual);
    final showGroupDivider = hasVirtualPlaylists && firstNormalIndex > 0;

    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: items.length + (showGroupDivider ? 1 : 0),
      itemBuilder: (context, index) {
        if (showGroupDivider && index == firstNormalIndex) {
          return const Divider(
            key: ValueKey<String>('listenBrainzPlaylistDivider'),
            height: 16,
            indent: 16,
            endIndent: 16,
          );
        }
        final itemIndex = showGroupDivider && index > firstNormalIndex
            ? index - 1
            : index;
        final item = items[itemIndex];
        final virtual = item.virtualPlaylist;
        if (virtual != null) {
          return _buildVirtualPlaylistTile(item, virtual);
        }
        return _buildPlaylistTile(item.playlist!);
      },
    );
  }

  Widget _buildVirtualPlaylistTile(
    PlaylistLibraryItem item,
    ListenBrainzDiscoverPlaylist virtual,
  ) {
    return ListTile(
      minLeadingWidth: 48,
      horizontalTitleGap: 12,
      leading: ListenBrainzPlaylistArtwork(
        playlist: virtual,
        size: 48,
        borderRadius: 6,
      ),
      title: Text(item.name),
      subtitle: Text(
        '${listenBrainzPlaylistAvailabilityLabel(virtual)} · ListenBrainz',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => NavService.openListenBrainzWeeklyDetail(
        context,
        ref,
        virtual.playlist.sourcePatch ?? '',
      ),
    );
  }

  Widget _buildPlaylistTile(PlaylistsTableData playlist) {
    final l10n = AppLocalizations.of(context)!;
    final tile = ListTile(
      minLeadingWidth: 48,
      horizontalTitleGap: 12,
      leading: SizedBox(
        width: 48,
        height: 48,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CoverArtImage(
            coverArtId: playlist.coverArt,
            size: 48,
            semanticLabel: playlist.name,
          ),
        ),
      ),
      title: Text(playlist.name),
      subtitle: playlist.songCount != null
          ? Text(l10n.playlistsSongCount(playlist.songCount!))
          : null,
      trailing: isDesktopRuntime
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
      onLongPress: isDesktopRuntime
          ? null
          : () => _showPlaylistActions(context, playlist),
    );
    if (!isDesktopRuntime) return tile;
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
          decoration: InputDecoration(labelText: l10n.playlistsCreateNameLabel),
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
            showAppNotice(
              context,
              message: l10n.playlistsCreateSuccess,
              level: AppNoticeLevel.success,
            );
            ref.invalidate(playlistSyncProvider);
          })
          .catchError((_) {
            if (!mounted) return;
            showAppNotice(
              context,
              message: l10n.playlistsCreateFailed,
              level: AppNoticeLevel.error,
            );
          }),
    );
  }

  void _showPlaylistActions(
    BuildContext context,
    PlaylistsTableData playlist, {
    Offset? anchor,
  }) {
    if (anchor != null && isDesktopRuntime) {
      unawaited(_showDesktopPlaylistActions(context, playlist, anchor: anchor));
      return;
    }
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
          value: _PlaylistContextAction.rename,
          child: Text(l10n.playlistsRenameTitle),
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
      case _PlaylistContextAction.rename:
        _showRenameDialog(context, playlist);
        return;
      case _PlaylistContextAction.delete:
        _confirmDelete(context, playlist);
        return;
    }
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
          decoration: InputDecoration(labelText: l10n.playlistsCreateNameLabel),
          onSubmitted: (_) =>
              _renamePlaylist(dialogContext, playlist, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () => _renamePlaylist(
              dialogContext,
              playlist,
              controller.text.trim(),
            ),
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

  void _confirmDelete(BuildContext context, PlaylistsTableData playlist) {
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

enum _PlaylistContextAction { rename, delete }

// ─────────────────────────────────────────────────────────────────────────────
// Liked Albums — full-screen list (navigated to from the "See all" button)
// ─────────────────────────────────────────────────────────────────────────────

class LikedAlbumsAllScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final likedAlbumsAsync = ref.watch(likedAlbumsProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final downloadedContentIds = downloadedOnly
        ? ref.watch(downloadedContentIdsProvider).asData?.value
        : null;

    Future<void> refresh() {
      return ref.read(librarySyncControllerProvider.notifier).syncNow();
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.libraryLikedAlbumsAllTitle)),
      body: RefreshIndicator(
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
            final filteredAlbums = downloadedOnly
                ? albums
                      .where(
                        (album) =>
                            downloadedContentIds?.albumIds.contains(album.id) ??
                            false,
                      )
                      .toList(growable: false)
                : albums;
            if (filteredAlbums.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: EmptyState(
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
                  ),
                ],
              );
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
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
            );
          },
        ),
      ),
    );
  }
}

/// A liked-artist destination when the general Artists page is hidden.
class LikedArtistsAllScreen extends ConsumerWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final artists = ref.watch(likedArtistsProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final downloaded = downloadedOnly
        ? ref.watch(downloadedContentIdsProvider).asData?.value
        : null;
    Future<void> refresh() =>
        ref.read(librarySyncControllerProvider.notifier).syncNow();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.libraryLikedArtistsSectionTitle)),
      body: RefreshIndicator(
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
            final visible = downloadedOnly
                ? items
                      .where(
                        (artist) =>
                            downloaded?.artistIds.contains(artist.id) ?? false,
                      )
                      .toList(growable: false)
                : items;
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                if (visible.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
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
                      return ArtistGridCard(
                        key: ValueKey('liked-all-artist-${artist.id}'),
                        artist: artist,
                        onTap: () => NavService.openArtistDetail(
                          context,
                          ref,
                          artist.id,
                        ),
                        onLongPress: () =>
                            showArtistContextMenu(context, ref, artist.id),
                        onSecondaryTapDown: (details) => showArtistContextMenu(
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
    );
  }
}
