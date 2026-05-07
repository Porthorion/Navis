part of 'library_screen.dart';

class _LikedArtistStripTile extends ConsumerWidget {
  const _LikedArtistStripTile({
    required this.artist,
    this.onTap,
    this.onLongPress,
  });

  final ArtistsTableData artist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shape = ref.watch(artistCardShapeProvider);
    final borderRadius = coverArtShapeToRadius(shape);
    final textStyle = Theme.of(context).textTheme.bodySmall;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            CoverArtImage(
              coverArtId: artist.coverArt,
              size: kCoverArtStandardSize,
              width: 64,
              height: 64,
              borderRadius: borderRadius,
              placeholderIcon: Icons.person_outline,
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
  const _LibraryPlaylistsTab({this.scrollController});

  /// Optional external [ScrollController] for scroll-to-top support.
  final ScrollController? scrollController;

  @override
  ConsumerState<_LibraryPlaylistsTab> createState() =>
      _LibraryPlaylistsTabState();
}

class _LibraryPlaylistsTabState extends ConsumerState<_LibraryPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  late final ProviderSubscription<AsyncValue<void>> _playlistSyncSubscription;
  List<PlaylistsTableData> _cachedPlaylists = const <PlaylistsTableData>[];

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
    final playlistsAsync = ref.watch(playlistListProvider);
    final playlistSyncAsync = ref.watch(playlistSyncProvider);

    playlistsAsync.whenData((playlists) {
      _cachedPlaylists = playlists;
    });

    final effectivePlaylists = playlistsAsync.asData?.value ?? _cachedPlaylists;

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(playlistSyncProvider);
            await ref.read(playlistSyncProvider.future);
          },
          child: playlistsAsync.when(
            data: (_) {
              if (effectivePlaylists.isEmpty) {
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
                itemCount: effectivePlaylists.length,
                itemBuilder: (context, index) {
                  final playlist = effectivePlaylists[index];
                  return ListTile(
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
                    onTap: () => context.push(
                      '/library/playlists/${playlist.id}',
                    ),
                    onLongPress: () => _showPlaylistActions(context, playlist),
                  );
                },
              );
            },
            loading: () {
              if (effectivePlaylists.isNotEmpty) {
                return ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.only(bottom: 80),
                  itemCount: effectivePlaylists.length,
                  itemBuilder: (context, index) {
                    final playlist = effectivePlaylists[index];
                    return ListTile(
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
                      onTap: () => context.push(
                        '/library/playlists/${playlist.id}',
                      ),
                      onLongPress: () =>
                          _showPlaylistActions(context, playlist),
                    );
                  },
                );
              }
              return const ShimmerListPage(count: 8);
            },
            error: (error, _) => ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                ErrorState(
                  title: l10n.playlistsLoadError,
                  message: error.toString(),
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

// ─────────────────────────────────────────────────────────────────────────────
// Liked Albums — full-screen list (navigated to from the "See all" button)
// ─────────────────────────────────────────────────────────────────────────────

class LikedAlbumsAllScreen extends ConsumerWidget {
  const LikedAlbumsAllScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final likedAlbumsAsync = ref.watch(likedAlbumsProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final downloadedContentIds = downloadedOnly
        ? ref.watch(downloadedContentIdsProvider).asData?.value
        : null;

    Future<void> refresh() {
      return ref
          .read(librarySyncControllerProvider.notifier)
          .syncNow(preferIncremental: true);
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
                message: error.toString(),
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
                final gridWidth = (constraints.maxWidth - 24).clamp(
                  240.0,
                  2400.0,
                );
                return CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: computeGridCrossAxisCount(
                            ref.watch(albumGridDensityProvider),
                            gridWidth,
                          ),
                          childAspectRatio: 1,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final album = filteredAlbums[index];
                          return RepaintBoundary(
                            child: AlbumCard(
                              key: ValueKey('liked-all-album-${album.id}'),
                              album: album,
                              size: AlbumCardSize.library,
                              heroTag: buildCoverArtHeroTag(
                                coverArtId: album.coverArt,
                                context: 'liked_all_album',
                              ),
                              badge: AlbumDownloadBadge(albumId: album.id),
                              onTap: () {
                                ref
                                    .read(
                                      librarySyncControllerProvider.notifier,
                                    )
                                    .registerAlbumInteraction(album.id);
                                context.push('/library/albums/${album.id}');
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
                        }, childCount: filteredAlbums.length),
                      ),
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
