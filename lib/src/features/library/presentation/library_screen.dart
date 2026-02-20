import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/artist_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

enum _AlbumSort { newest, name, artist }

enum _SongSort { artistAlbum, title, duration }

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String? _selectedArtistLetter;
  _AlbumSort _albumSort = _AlbumSort.newest;
  _SongSort _songSort = _SongSort.artistAlbum;
  final ScrollController _albumsScrollController = ScrollController();
  int _loadedAlbumPages = 1;
  String _lastVisibleAlbumSignature = '';

  @override
  void initState() {
    super.initState();
    _albumsScrollController.addListener(_onAlbumsScroll);
  }

  @override
  void dispose() {
    _albumsScrollController
      ..removeListener(_onAlbumsScroll)
      ..dispose();
    super.dispose();
  }

  Future<void> _refreshLibrary() {
    return ref.read(librarySyncControllerProvider.notifier).syncNow();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final syncState = ref.watch(librarySyncControllerProvider);

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.libraryTitle),
          bottom: TabBar(
            tabs: <Widget>[
              Tab(text: l10n.libraryTabArtists),
              Tab(text: l10n.libraryTabAlbums),
              Tab(text: l10n.libraryTabSongs),
              Tab(text: l10n.libraryTabGenres),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            _SyncStatusBanner(syncState: syncState, onRetry: _refreshLibrary),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  _buildArtistsTab(context),
                  _buildAlbumsTab(context),
                  _buildSongsTab(context),
                  _buildGenresTab(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtistsTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artists = ref.watch(artistsProvider);

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: artists.when(
        data: (items) {
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                EmptyState(
                  title: l10n.libraryArtistsEmptyTitle,
                  subtitle: l10n.libraryArtistsEmptySubtitle,
                  icon: Icons.person_outline,
                ),
              ],
            );
          }

          final grouped = _groupArtistsByInitial(items);
          final letters = grouped.keys.toList()..sort();
          final selectedLetter = _selectedArtistLetter;
          final visibleLetters = selectedLetter == null
              ? letters
              : letters.where((letter) => letter == selectedLetter).toList();

          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: <Widget>[
                    ChoiceChip(
                      label: Text(l10n.libraryArtistsIndexAll),
                      selected: _selectedArtistLetter == null,
                      onSelected: (_) =>
                          setState(() => _selectedArtistLetter = null),
                    ),
                    for (final letter in letters) ...<Widget>[
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(letter),
                        selected: _selectedArtistLetter == letter,
                        onSelected: (_) =>
                            setState(() => _selectedArtistLetter = letter),
                      ),
                    ],
                  ],
                ),
              ),
              for (final letter in visibleLetters) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    letter,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final artist in grouped[letter]!)
                  ArtistCard(
                    artist: artist,
                    onTap: () => context.go('/library/artists/${artist.id}'),
                    onLongPress: () => _showArtistMenu(context, artist),
                  ),
              ],
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
    final albumsAsync = ref.watch(
      pagedAlbumsProvider(
        (
          sort: _toAlbumSortOrder(_albumSort),
          limit: limit,
        ),
      ),
    );

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: albumsAsync.when(
        data: (items) {
          _reportVisibleAlbumPriority(items);
          final totalAlbums = totalAlbumsAsync.asData?.value ?? items.length;
          final hasMore = items.length < totalAlbums;
          return CustomScrollView(
            controller: _albumsScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: _SortRow<_AlbumSort>(
                  label: l10n.libraryAlbumsSortLabel,
                  value: _albumSort,
                  items: <DropdownMenuItem<_AlbumSort>>[
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
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _albumSort = value;
                        _loadedAlbumPages = 1;
                      });
                      if (_albumsScrollController.hasClients) {
                        _albumsScrollController.jumpTo(0);
                      }
                    }
                  },
                ),
              ),
              if (items.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    title: l10n.libraryAlbumsEmptyTitle,
                    subtitle: l10n.libraryAlbumsEmptySubtitle,
                    icon: Icons.album_outlined,
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 1.25,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final album = items[index];
                      return Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            ref
                                .read(librarySyncControllerProvider.notifier)
                                .registerAlbumInteraction(album.id);
                            context.go('/library/albums/${album.id}');
                          },
                          onLongPress: () => _showAlbumMenu(context, album),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                CoverArtImage(
                                  coverArtId: album.coverArt,
                                  size: 320,
                                  height: 62,
                                  width: double.infinity,
                                  borderRadius: BorderRadius.circular(8),
                                  placeholderIcon: Icons.album_outlined,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  album.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  album.artistName ??
                                      l10n.albumDetailUnknownArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }, childCount: items.length),
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
      _AlbumSort.newest => AlbumSortOrder.newest,
      _AlbumSort.name => AlbumSortOrder.name,
      _AlbumSort.artist => AlbumSortOrder.artist,
    };
  }

  Widget _buildSongsTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final songsAsync = ref.watch(songsProvider);

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: songsAsync.when(
        data: (items) {
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                EmptyState(
                  title: l10n.librarySongsEmptyTitle,
                  subtitle: l10n.librarySongsEmptySubtitle,
                  icon: Icons.music_note_outlined,
                ),
              ],
            );
          }

          final songs = [...items];
          switch (_songSort) {
            case _SongSort.artistAlbum:
              songs.sort((a, b) {
                final byArtist = (a.artistName ?? '').compareTo(
                  b.artistName ?? '',
                );
                if (byArtist != 0) {
                  return byArtist;
                }
                final byAlbum = (a.albumName ?? '').compareTo(
                  b.albumName ?? '',
                );
                if (byAlbum != 0) {
                  return byAlbum;
                }
                return (a.track ?? 0).compareTo(b.track ?? 0);
              });
            case _SongSort.title:
              songs.sort((a, b) => a.title.compareTo(b.title));
            case _SongSort.duration:
              songs.sort(
                (a, b) => (b.duration ?? 0).compareTo(a.duration ?? 0),
              );
          }

          return ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: songs.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return _SortRow<_SongSort>(
                  label: l10n.librarySongsSortLabel,
                  value: _songSort,
                  items: <DropdownMenuItem<_SongSort>>[
                    DropdownMenuItem(
                      value: _SongSort.artistAlbum,
                      child: Text(l10n.librarySortArtistAlbum),
                    ),
                    DropdownMenuItem(
                      value: _SongSort.title,
                      child: Text(l10n.librarySortTitle),
                    ),
                    DropdownMenuItem(
                      value: _SongSort.duration,
                      child: Text(l10n.librarySortDuration),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _songSort = value);
                    }
                  },
                );
              }

              final song = songs[index - 1];
              return TrackListTile(
                song: song,
                onTap: () => _playSongNow(context, song),
                onLongPress: () => _showSongMenu(context, song),
                trailing: IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => _showSongMenu(context, song),
                ),
              );
            },
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
              title: l10n.librarySongsErrorTitle,
              message: error.toString(),
              onRetry: _refreshLibrary,
              retryLabel: l10n.commonRetry,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGenresTab(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final genresAsync = ref.watch(genresProvider);

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: genresAsync.when(
        data: (items) {
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: <Widget>[
                EmptyState(
                  title: l10n.libraryGenresEmptyTitle,
                  subtitle: l10n.libraryGenresEmptySubtitle,
                  icon: Icons.category_outlined,
                ),
              ],
            );
          }

          return ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final genre = items[index];
              final encoded = base64Url.encode(utf8.encode(genre.name));
              return ListTile(
                title: Text(genre.name),
                subtitle: Text(
                  l10n.libraryGenresCount(
                    genre.albumCount ?? 0,
                    genre.songCount ?? 0,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/library/genres/$encoded'),
              );
            },
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
              title: l10n.libraryGenresErrorTitle,
              message: error.toString(),
              onRetry: _refreshLibrary,
              retryLabel: l10n.commonRetry,
            ),
          ],
        ),
      ),
    );
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

  Future<void> _showSongMenu(BuildContext context, SongsTableData song) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.play_arrow_outlined),
                title: Text(l10n.librarySongMenuPlayNow),
                onTap: () {
                  Navigator.of(context).pop();
                  _playSongNow(this.context, song);
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music_outlined),
                title: Text(l10n.librarySongMenuAddToQueue),
                onTap: () {
                  Navigator.of(context).pop();
                  _addSongToQueue(this.context, song);
                },
              ),
              if (song.albumId != null && song.albumId!.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.album_outlined),
                  title: Text(l10n.librarySongMenuOpenAlbum),
                  onTap: () {
                    Navigator.of(context).pop();
                    this.context.go('/library/albums/${song.albumId}');
                  },
                ),
            ],
          ),
        );
      },
    );
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

  void _playSongNow(BuildContext context, SongsTableData song) {
    ref.read(queueProvider.notifier).replace(<String>[song.id]);
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.librarySongPlayNowQueued(song.title))),
    );
  }

  void _addSongToQueue(BuildContext context, SongsTableData song) {
    ref.read(queueProvider.notifier).add(song.id);
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.librarySongAddedToQueue(song.title))),
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

    final timestamp = MaterialLocalizations.of(
      context,
    ).formatFullDate(syncState.lastSyncedAt!);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          l10n.librarySyncLastSynced(timestamp),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
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

class _SortRow<T> extends StatelessWidget {
  const _SortRow({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.titleSmall),
          ),
          DropdownButton<T>(
            value: value,
            items: items,
            onChanged: onChanged,
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
