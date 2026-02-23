import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _expandedSections = <SearchResultType, bool>{};

  @override
  void initState() {
    super.initState();
    final initial = ref.read(searchQueryProvider);
    if (initial.isNotEmpty) {
      _controller.text = initial;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    ref.read(searchQueryProvider.notifier).submit(value);
  }

  void _onSearchSubmitted(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final dao = ref.read(navisDatabaseProvider).historyDao;
    unawaited(dao.saveSearchQuery(trimmed));
  }

  void _applyRecentSearch(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: query.length),
    );
    ref.read(searchQueryProvider.notifier).submit(query);
    _focusNode.requestFocus();
  }

  void _clearSearch() {
    _controller.clear();
    ref.read(searchQueryProvider.notifier).clear();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = ref.watch(searchQueryProvider);
    final hasQuery = query.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: _SearchBar(
          controller: _controller,
          focusNode: _focusNode,
          hint: l10n.searchHint,
          onChanged: _onQueryChanged,
          onSubmitted: _onSearchSubmitted,
          onClear: hasQuery ? _clearSearch : null,
        ),
      ),
      body: hasQuery ? _buildResults() : _buildRecentSearches(),
    );
  }

  Widget _buildResults() {
    final results = ref.watch(debouncedSearchProvider);
    final l10n = AppLocalizations.of(context)!;

    return results.when(
      data: (data) {
        if (data == null) {
          return const SizedBox.shrink();
        }
        if (data.artists.isEmpty && data.albums.isEmpty && data.songs.isEmpty) {
          return EmptyState(
            title: l10n.searchNoResults,
            subtitle: l10n.searchNoResultsSubtitle,
            icon: Icons.search_off,
          );
        }
        return ListView(
          children: <Widget>[
            if (data.artists.isNotEmpty)
              _ArtistResultsSection(
                artists: data.artists,
                expanded: _expandedSections[SearchResultType.artists] ?? false,
                onToggleExpanded: () => setState(() {
                  _expandedSections[SearchResultType.artists] =
                      !(_expandedSections[SearchResultType.artists] ?? false);
                }),
              ),
            if (data.albums.isNotEmpty)
              _AlbumResultsSection(
                albums: data.albums,
                expanded: _expandedSections[SearchResultType.albums] ?? false,
                onToggleExpanded: () => setState(() {
                  _expandedSections[SearchResultType.albums] =
                      !(_expandedSections[SearchResultType.albums] ?? false);
                }),
              ),
            if (data.songs.isNotEmpty)
              _SongResultsSection(
                songs: data.songs,
                expanded: _expandedSections[SearchResultType.songs] ?? false,
                onToggleExpanded: () => setState(() {
                  _expandedSections[SearchResultType.songs] =
                      !(_expandedSections[SearchResultType.songs] ?? false);
                }),
              ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        title: l10n.searchNoResults,
        subtitle: error.toString(),
        icon: Icons.error_outline,
      ),
    );
  }

  Widget _buildRecentSearches() {
    final recentAsync = ref.watch(recentSearchesProvider);
    final l10n = AppLocalizations.of(context)!;

    return recentAsync.when(
      data: (searches) {
        if (searches.isEmpty) {
          return EmptyState(
            title: l10n.searchHint,
            icon: Icons.search,
          );
        }
        return ListView(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l10n.searchRecentTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      final dao = ref.read(navisDatabaseProvider).historyDao;
                      unawaited(dao.clearAllHistory());
                    },
                    child: Text(l10n.searchClearRecent),
                  ),
                ],
              ),
            ),
            ...searches.map(
              (s) => ListTile(
                leading: const Icon(Icons.history),
                title: Text(s.query),
                onTap: () => _applyRecentSearch(s.query),
              ),
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    required this.onSubmitted,
    this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: true,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hint,
        border: InputBorder.none,
        suffixIcon: onClear != null
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: onClear,
              )
            : null,
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.itemCount,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          if (itemCount > 5)
            TextButton(
              onPressed: onToggle,
              child: Text(expanded ? l10n.searchShowLess : l10n.searchShowAll),
            ),
        ],
      ),
    );
  }
}

class _ArtistResultsSection extends StatelessWidget {
  const _ArtistResultsSection({
    required this.artists,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final List<Artist> artists;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final visible = expanded ? artists : artists.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          title: l10n.searchArtistsSection,
          expanded: expanded,
          onToggle: onToggleExpanded,
          itemCount: artists.length,
        ),
        ...visible.map(
          (artist) => ListTile(
            leading: CircleAvatar(
              child: artist.coverArt != null
                  ? CoverArtImage(
                      coverArtId: artist.coverArt,
                      size: 80,
                      width: 40,
                      height: 40,
                      borderRadius: BorderRadius.circular(20),
                    )
                  : const Icon(Icons.person),
            ),
            title: Text(artist.name),
            subtitle: artist.albumCount != null
                ? Text(l10n.searchAlbumCount(artist.albumCount!))
                : null,
            onTap: () => context.push('/library/artists/${artist.id}'),
          ),
        ),
      ],
    );
  }
}

class _AlbumResultsSection extends StatelessWidget {
  const _AlbumResultsSection({
    required this.albums,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final List<Album> albums;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final visible = expanded ? albums : albums.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          title: l10n.searchAlbumsSection,
          expanded: expanded,
          onToggle: onToggleExpanded,
          itemCount: albums.length,
        ),
        ...visible.map(
          (album) => ListTile(
            leading: CoverArtImage(
              coverArtId: album.coverArt,
              size: 80,
              width: 48,
              height: 48,
              borderRadius: BorderRadius.circular(4),
            ),
            title: Text(album.name),
            subtitle: Text(album.artist ?? ''),
            onTap: () => context.push('/library/albums/${album.id}'),
          ),
        ),
      ],
    );
  }
}

class _SongResultsSection extends ConsumerWidget {
  const _SongResultsSection({
    required this.songs,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final List<Song> songs;
  final bool expanded;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final visible = expanded ? songs : songs.take(5).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          title: l10n.searchSongsSection,
          expanded: expanded,
          onToggle: onToggleExpanded,
          itemCount: songs.length,
        ),
        ...visible.asMap().entries.map(
          (entry) {
            final index = entry.key;
            final song = entry.value;

            return ListTile(
              leading: CoverArtImage(
                coverArtId: song.coverArt,
                size: 80,
                width: 48,
                height: 48,
                borderRadius: BorderRadius.circular(4),
              ),
              title: Text(song.title),
              subtitle: Text(
                <String>[
                  if (song.artist != null) song.artist!,
                  if (song.album != null) song.album!,
                ].join(' • '),
              ),
              trailing: Text(_formatDuration(song.duration)),
              onTap: () {
                final songIds = songs.map((s) => s.id).toList();
                unawaited(
                  ref
                      .read(queueProvider.notifier)
                      .replace(
                        songIds,
                        startIndex: index,
                      ),
                );
              },
              onLongPress: () => _showSongContextMenu(context, ref, song),
            );
          },
        ),
      ],
    );
  }

  void _showSongContextMenu(
    BuildContext context,
    WidgetRef ref,
    Song song,
  ) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: Text(l10n.searchPlayNext),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  ref.read(queueProvider.notifier).playNext(song.id),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(l10n.searchAddToQueue),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  ref.read(queueProvider.notifier).add(song.id),
                );
              },
            ),
            if (song.albumId != null)
              ListTile(
                leading: const Icon(Icons.album),
                title: Text(l10n.nowPlayingGoToAlbum),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push('/library/albums/${song.albumId}');
                },
              ),
            if (song.artistId != null)
              ListTile(
                leading: const Icon(Icons.person),
                title: Text(l10n.nowPlayingGoToArtist),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.push('/library/artists/${song.artistId}');
                },
              ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(int? seconds) {
  if (seconds == null || seconds <= 0) {
    return '';
  }
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}
