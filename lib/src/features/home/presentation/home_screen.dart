import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.homeTitle)),
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(librarySyncControllerProvider.notifier).syncNow();
          ref.invalidate(homeRecentlyAddedProvider);
          ref.invalidate(homeFrequentAlbumsProvider);
          ref.invalidate(homeRandomAlbumsProvider);
          ref.invalidate(homeStarredSongsProvider);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: <Widget>[
            _HomeSection<List<SongsTableData>>(
              title: l10n.homeRecentlyPlayedTitle,
              data: ref.watch(homeRecentlyPlayedProvider),
              isEmpty: (items) => items.isEmpty,
              builder: (context, songs) => _SongCarousel(
                songs: songs,
                onTap: (song) {
                  final albumId = song.albumId;
                  if (albumId != null && albumId.isNotEmpty) {
                    context.go('/library/albums/$albumId');
                  }
                },
              ),
              emptyTitle: l10n.homeRecentlyPlayedEmptyTitle,
              emptySubtitle: l10n.homeRecentlyPlayedEmptySubtitle,
            ),
            _HomeSection<List<Album>>(
              title: l10n.homeRecentlyAddedTitle,
              data: ref.watch(homeRecentlyAddedProvider),
              isEmpty: (items) => items.isEmpty,
              builder: (context, albums) => _AlbumCarousel(
                albums: albums,
                onTap: (album) => context.go('/library/albums/${album.id}'),
              ),
              emptyTitle: l10n.homeRecentlyAddedEmptyTitle,
              emptySubtitle: l10n.homeRecentlyAddedEmptySubtitle,
            ),
            _HomeSection<List<Album>>(
              title: l10n.homeFrequentTitle,
              data: ref.watch(homeFrequentAlbumsProvider),
              isEmpty: (items) => items.isEmpty,
              builder: (context, albums) => _AlbumCarousel(
                albums: albums,
                onTap: (album) => context.go('/library/albums/${album.id}'),
              ),
              emptyTitle: l10n.homeFrequentEmptyTitle,
              emptySubtitle: l10n.homeFrequentEmptySubtitle,
            ),
            _HomeSection<List<Album>>(
              title: l10n.homeRandomTitle,
              data: ref.watch(homeRandomAlbumsProvider),
              isEmpty: (items) => items.isEmpty,
              builder: (context, albums) => _AlbumCarousel(
                albums: albums,
                onTap: (album) => context.go('/library/albums/${album.id}'),
              ),
              emptyTitle: l10n.homeRandomEmptyTitle,
              emptySubtitle: l10n.homeRandomEmptySubtitle,
            ),
            _HomeSection<List<Song>>(
              title: l10n.homeStarredTitle,
              data: ref.watch(homeStarredSongsProvider),
              isEmpty: (items) => items.isEmpty,
              builder: (context, songs) => _ServerSongCarousel(
                songs: songs,
                onTap: (song) {
                  final albumId = song.albumId;
                  if (albumId != null && albumId.isNotEmpty) {
                    context.go('/library/albums/$albumId');
                  }
                },
              ),
              emptyTitle: l10n.homeStarredEmptyTitle,
              emptySubtitle: l10n.homeStarredEmptySubtitle,
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeSection<T> extends StatelessWidget {
  const _HomeSection({
    required this.title,
    required this.data,
    required this.builder,
    required this.isEmpty,
    required this.emptyTitle,
    required this.emptySubtitle,
  });

  final String title;
  final AsyncValue<T> data;
  final Widget Function(BuildContext context, T value) builder;
  final bool Function(T value) isEmpty;
  final String emptyTitle;
  final String emptySubtitle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          const SizedBox(height: 10),
          data.when(
            data: (value) {
              if (isEmpty(value)) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: EmptyState(
                    title: emptyTitle,
                    subtitle: emptySubtitle,
                    icon: Icons.library_music_outlined,
                  ),
                );
              }
              return builder(context, value);
            },
            loading: () => const _CarouselShimmer(),
            error: (error, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ErrorState(
                title: l10n.homeLoadErrorTitle,
                message: error.toString(),
                retryLabel: l10n.commonRetry,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumCarousel extends StatelessWidget {
  const _AlbumCarousel({required this.albums, required this.onTap});

  final List<Album> albums;
  final void Function(Album album) onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final album = albums[index];
          return _HomeCard(
            title: album.name,
            subtitle: album.artist ?? l10n.albumDetailUnknownArtist,
            coverArtId: album.coverArt,
            icon: Icons.album_outlined,
            onTap: () => onTap(album),
          );
        },
      ),
    );
  }
}

class _SongCarousel extends StatelessWidget {
  const _SongCarousel({required this.songs, required this.onTap});

  final List<SongsTableData> songs;
  final void Function(SongsTableData song) onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: songs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final song = songs[index];
          return _HomeCard(
            title: song.title,
            subtitle: song.artistName ?? l10n.albumDetailUnknownArtist,
            coverArtId: song.coverArt,
            icon: Icons.music_note_outlined,
            onTap: () => onTap(song),
          );
        },
      ),
    );
  }
}

class _ServerSongCarousel extends StatelessWidget {
  const _ServerSongCarousel({required this.songs, required this.onTap});

  final List<Song> songs;
  final void Function(Song song) onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: songs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final song = songs[index];
          return _HomeCard(
            title: song.title,
            subtitle: song.artist ?? l10n.albumDetailUnknownArtist,
            coverArtId: song.coverArt,
            icon: Icons.star_outline,
            onTap: () => onTap(song),
          );
        },
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.coverArtId,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final String? coverArtId;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 136;
                final imageHeight = compact ? 62.0 : 68.0;
                final subtitleLines = compact ? 1 : 2;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    CoverArtImage(
                      coverArtId: coverArtId,
                      size: 320,
                      height: imageHeight,
                      width: double.infinity,
                      borderRadius: BorderRadius.circular(8),
                      placeholderIcon: icon,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.max,
                        children: <Widget>[
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Flexible(
                            child: Text(
                              subtitle,
                              maxLines: subtitleLines,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _CarouselShimmer extends StatelessWidget {
  const _CarouselShimmer();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 172,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, _) {
          return SizedBox(
            width: 170,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const <Widget>[
                    ShimmerPlaceholder(height: 68),
                    SizedBox(height: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          ShimmerPlaceholder(height: 16, width: 120),
                          SizedBox(height: 8),
                          ShimmerPlaceholder(height: 14, width: 90),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
