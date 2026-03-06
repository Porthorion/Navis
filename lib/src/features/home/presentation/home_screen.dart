import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/presentation/home_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:url_launcher/url_launcher.dart';

/// Section IDs for dynamic home ordering. The default order is the order below.
class HomeSectionIds {
  HomeSectionIds._();
  static const String likedTracks = 'liked_tracks';
  static const String recentlyAdded = 'recently_added';
  static const String recentlyPlayed = 'recently_played';
  static const String randomAlbums = 'random_albums';
  static const String mostPlayed = 'most_played';

  static const List<String> defaultOrder = <String>[
    likedTracks,
    recentlyAdded,
    recentlyPlayed,
    randomAlbums,
    mostPlayed,
  ];
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(homeScrollToTopRequestProvider, (previous, next) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final order =
        ref.watch(homeSectionOrderProvider) ?? HomeSectionIds.defaultOrder;
    final hidden = ref.watch(homeSectionsHiddenProvider) ?? <String>[];

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await ref
                .read(librarySyncControllerProvider.notifier)
                .syncNow(preferIncremental: true);
            ref.invalidate(homeRecentlyAddedProvider);
            ref.invalidate(homeRandomAlbumsProvider);
            ref.invalidate(homeDownloadedRandomAlbumsProvider);
            ref.invalidate(updateProvider);
          },
          child: ListView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: <Widget>[
              // App icon header — always first
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 48, 0, 20),
                child: Center(
                  child: NavisIcon(size: 96, tintWithAccent: true),
                ),
              ),
              const _UpdateBanner(),
              // Dynamic sections
              for (final sectionId in order)
                if (!hidden.contains(sectionId))
                  ..._buildSection(context, ref, sectionId, downloadedOnly),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildSection(
    BuildContext context,
    WidgetRef ref,
    String sectionId,
    bool downloadedOnly,
  ) {
    final l10n = AppLocalizations.of(context)!;
    switch (sectionId) {
      case HomeSectionIds.likedTracks:
        return <Widget>[
          _HomeSection<List<SongsTableData>>(
            title: l10n.homeStarredTitle,
            data: ref.watch(
              downloadedOnly
                  ? homeDownloadedLikedSongsProvider
                  : homeLikedSongsProvider,
            ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, songs) => _SongListSection(
              songs: songs,
              onTap: (song) {
                ref.read(queueProvider.notifier).replace(<String>[
                  song.id,
                ], autoPlay: true).ignore();
              },
            ),
            emptyTitle: l10n.homeStarredEmptyTitle,
            emptySubtitle: l10n.homeStarredEmptySubtitle,
            onRetry: () => ref.invalidate(homeLikedSongsProvider),
          ),
        ];

      case HomeSectionIds.recentlyAdded:
        if (downloadedOnly) {
          return <Widget>[
            _HomeSection<List<AlbumsTableData>>(
              title: l10n.homeRecentlyAddedTitle,
              data: ref.watch(homeDownloadedRecentlyAddedAlbumsProvider),
              isEmpty: (items) => items.isEmpty,
              builder: (context, albums) => _LocalAlbumCarousel(
                albums: albums,
                onTap: (album) => context.push('/library/albums/${album.id}'),
              ),
              emptyTitle: l10n.libraryDownloadedOnlyEmpty,
              emptySubtitle: l10n.libraryDownloadedOnlyEmptySubtitle,
            ),
          ];
        }
        return <Widget>[
          _HomeSection<List<Album>>(
            title: l10n.homeRecentlyAddedTitle,
            data: ref.watch(homeRecentlyAddedProvider),
            isEmpty: (items) => items.isEmpty,
            builder: (context, albums) => _ServerAlbumCarousel(
              albums: albums,
              onTap: (album) => context.push('/library/albums/${album.id}'),
            ),
            emptyTitle: l10n.homeRecentlyAddedEmptyTitle,
            emptySubtitle: l10n.homeRecentlyAddedEmptySubtitle,
            onRetry: () => ref.invalidate(homeRecentlyAddedProvider),
          ),
        ];

      case HomeSectionIds.recentlyPlayed:
        return <Widget>[
          _HomeSection<List<AlbumsTableData>>(
            title: l10n.homeRecentlyPlayedAlbumsTitle,
            data: ref.watch(
              downloadedOnly
                  ? homeDownloadedRecentlyPlayedAlbumsProvider
                  : homeRecentlyPlayedAlbumsProvider,
            ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, albums) => _LocalAlbumCarousel(
              albums: albums,
              onTap: (album) => context.push('/library/albums/${album.id}'),
            ),
            emptyTitle: l10n.homeRecentlyPlayedAlbumsEmptyTitle,
            emptySubtitle: l10n.homeRecentlyPlayedAlbumsEmptySubtitle,
            onRetry: () => ref.invalidate(homeRecentlyPlayedAlbumsProvider),
          ),
        ];

      case HomeSectionIds.randomAlbums:
        if (downloadedOnly) {
          return <Widget>[
            _HomeSection<List<AlbumsTableData>>(
              title: l10n.homeRandomTitle,
              data: ref.watch(homeDownloadedRandomAlbumsProvider),
              isEmpty: (items) => items.isEmpty,
              builder: (context, albums) => _LocalAlbumCarousel(
                albums: albums,
                onTap: (album) => context.push('/library/albums/${album.id}'),
              ),
              emptyTitle: l10n.libraryDownloadedOnlyEmpty,
              emptySubtitle: l10n.libraryDownloadedOnlyEmptySubtitle,
              onRetry: () => ref.invalidate(homeDownloadedRandomAlbumsProvider),
            ),
          ];
        }
        return <Widget>[
          _HomeSection<List<Album>>(
            title: l10n.homeRandomTitle,
            data: ref.watch(homeRandomAlbumsProvider),
            isEmpty: (items) => items.isEmpty,
            builder: (context, albums) => _ServerAlbumCarousel(
              albums: albums,
              onTap: (album) => context.push('/library/albums/${album.id}'),
            ),
            emptyTitle: l10n.homeRandomEmptyTitle,
            emptySubtitle: l10n.homeRandomEmptySubtitle,
            onRetry: () => ref.invalidate(homeRandomAlbumsProvider),
          ),
        ];

      case HomeSectionIds.mostPlayed:
        return <Widget>[
          _HomeSection<List<SongsTableData>>(
            title: l10n.homeMostPlayedTracksTitle,
            data: ref.watch(
              downloadedOnly
                  ? homeDownloadedMostPlayedSongsProvider
                  : homeMostPlayedSongsProvider,
            ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, songs) => _SongListSection(
              songs: songs,
              onTap: (song) {
                ref.read(queueProvider.notifier).replace(<String>[
                  song.id,
                ], autoPlay: true).ignore();
              },
            ),
            emptyTitle: l10n.homeMostPlayedTracksEmptyTitle,
            emptySubtitle: l10n.homeMostPlayedTracksEmptySubtitle,
            onRetry: () => ref.invalidate(homeMostPlayedSongsProvider),
          ),
        ];

      default:
        return const <Widget>[];
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared section wrapper
// ─────────────────────────────────────────────────────────────────────────────

class _HomeSection<T> extends StatelessWidget {
  const _HomeSection({
    required this.title,
    required this.data,
    required this.builder,
    required this.isEmpty,
    required this.emptyTitle,
    required this.emptySubtitle,
    this.onRetry,
  });

  final String title;
  final AsyncValue<T> data;
  final Widget Function(BuildContext context, T value) builder;
  final bool Function(T value) isEmpty;
  final String emptyTitle;
  final String emptySubtitle;
  final VoidCallback? onRetry;

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
                onRetry: onRetry,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Album carousels (horizontal scroll of square AlbumCards)
// ─────────────────────────────────────────────────────────────────────────────

/// Carousel for [Album] objects coming from the server API.
class _ServerAlbumCarousel extends ConsumerWidget {
  const _ServerAlbumCarousel({required this.albums, required this.onTap});

  final List<Album> albums;
  final void Function(Album album) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = coverArtShapeToRadius(coverShape);
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final album = albums[index];
          return _ServerAlbumCard(
            name: album.name,
            artist: album.artist,
            coverArtId: album.coverArt,
            borderRadius: coverRadius,
            heroTag: buildCoverArtHeroTag(
              coverArtId: album.coverArt,
              context: 'album',
            ),
            onTap: () => onTap(album),
            onLongPress: () => showAlbumContextMenu(context, ref, album.id),
          );
        },
      ),
    );
  }
}

/// Carousel for [AlbumsTableData] objects from the local database.
class _LocalAlbumCarousel extends ConsumerWidget {
  const _LocalAlbumCarousel({required this.albums, required this.onTap});

  final List<AlbumsTableData> albums;
  final void Function(AlbumsTableData album) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final album = albums[index];
          return AlbumCard(
            album: album,
            size: AlbumCardSize.compact,
            heroTag: buildCoverArtHeroTag(
              coverArtId: album.coverArt,
              context: 'album',
            ),
            onTap: () => onTap(album),
            onLongPress: () => showAlbumContextMenu(context, ref, album.id),
          );
        },
      ),
    );
  }
}

/// A small square card for server [Album] objects (same visual as [AlbumCard]
/// but accepts the API model directly).
class _ServerAlbumCard extends StatelessWidget {
  const _ServerAlbumCard({
    required this.name,
    required this.borderRadius,
    this.artist,
    this.coverArtId,
    this.heroTag,
    this.onTap,
    this.onLongPress,
  });

  final String name;
  final BorderRadius borderRadius;
  final String? artist;
  final String? coverArtId;
  final String? heroTag;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: AspectRatio(
        aspectRatio: 1,
        child: Card(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: borderRadius,
          ),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    onLongPress!();
                  },
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (heroTag != null)
                  HeroCoverArt(
                    coverArtId: coverArtId,
                    heroTag: heroTag!,
                    size: 480,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.album_outlined,
                  )
                else
                  CoverArtImage(
                    coverArtId: coverArtId,
                    size: 480,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.album_outlined,
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Colors.black.withValues(alpha: 0),
                          Colors.black.withValues(alpha: 0.75),
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 24, 10, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.95),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (artist != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              artist!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.75),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Song list section (vertical list of song tiles)
// ─────────────────────────────────────────────────────────────────────────────

class _SongListSection extends ConsumerWidget {
  const _SongListSection({
    required this.songs,
    required this.onTap,
  });

  final List<SongsTableData> songs;
  final void Function(SongsTableData song) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < songs.length; i++)
            ListTile(
              leading: SizedBox(
                width: 48,
                height: 48,
                child: CoverArtImage(
                  coverArtId: songs[i].coverArt,
                  size: 160,
                  borderRadius: BorderRadius.circular(6),
                  placeholderIcon: Icons.music_note_outlined,
                ),
              ),
              title: Text(
                songs[i].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                songs[i].artistName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              dense: true,
              onTap: () => onTap(songs[i]),
              onLongPress: () => showSongContextMenu(context, ref, songs[i]),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shimmer placeholder for loading state
// ─────────────────────────────────────────────────────────────────────────────

class _CarouselShimmer extends StatelessWidget {
  const _CarouselShimmer();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, _) {
          return SizedBox(
            width: 150,
            child: Card(
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: const ShimmerPlaceholder(
                height: 150,
                width: 150,
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Update banner shown at the top of the home screen when a new release is
// available on the Forgejo repository.
// ---------------------------------------------------------------------------
class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updateAsync = ref.watch(updateProvider);
    final settings = ref.watch(appSettingsProvider).asData?.value;

    // If the user has disabled automatic update checks, hide the banner.
    if (settings != null && !settings.updateCheckEnabled) {
      return const SizedBox.shrink();
    }

    return updateAsync.when(
      data: (info) {
        if (info == null) return const SizedBox.shrink();
        return MaterialBanner(
          content: Text(l10n.updateAvailableBody(info.tagName)),
          leading: const Icon(Icons.system_update_outlined),
          actions: [
            TextButton(
              onPressed: () => ref.invalidate(updateProvider),
              child: Text(l10n.updateDismiss),
            ),
            TextButton(
              onPressed: () {
                if (info.apkDownloadUrl != null) {
                  showUpdateDialog(context, info);
                } else {
                  launchUrl(
                    Uri.parse(info.htmlUrl),
                    mode: LaunchMode.externalApplication,
                  );
                }
              },
              child: Text(
                info.apkDownloadUrl != null
                    ? l10n.updateInstall
                    : l10n.updateDownload,
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
