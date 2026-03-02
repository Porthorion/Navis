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
import 'package:navis/src/features/audiomuse/domain/audiomuse_models.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:url_launcher/url_launcher.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await ref
                .read(librarySyncControllerProvider.notifier)
                .syncNow(preferIncremental: true);
            ref.invalidate(homeRecentlyAddedProvider);
            ref.invalidate(homeRandomAlbumsProvider);
            // Re-check for app updates (and APK availability) on refresh.
            ref.invalidate(updateProvider);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: <Widget>[
              // App icon header — accent-tinted, modernized feel
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 48, 0, 20),
                child: Center(
                  child: NavisIcon(size: 96, tintWithAccent: true),
                ),
              ),
              const _UpdateBanner(),
              // ── 1. Liked Tracks (vertical list, 5 items + See all) ──
              _HomeSection<List<SongsTableData>>(
                title: l10n.homeStarredTitle,
                data: ref.watch(homeLikedSongsProvider),
                isEmpty: (items) => items.isEmpty,
                builder: (context, songs) => _SongListSection(
                  songs: songs,
                  onTap: (song) {
                    ref.read(queueProvider.notifier).replace([
                      song.id,
                    ]).ignore();
                  },
                ),
                emptyTitle: l10n.homeStarredEmptyTitle,
                emptySubtitle: l10n.homeStarredEmptySubtitle,
                onRetry: () => ref.invalidate(homeLikedSongsProvider),
              ),

              // ── 2. Recently Added Albums (horizontal card carousel) ──
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

              // ── 3. Recently Played Albums (horizontal card carousel) ──
              _HomeSection<List<AlbumsTableData>>(
                title: l10n.homeRecentlyPlayedAlbumsTitle,
                data: ref.watch(homeRecentlyPlayedAlbumsProvider),
                isEmpty: (items) => items.isEmpty,
                builder: (context, albums) => _LocalAlbumCarousel(
                  albums: albums,
                  onTap: (album) => context.push('/library/albums/${album.id}'),
                ),
                emptyTitle: l10n.homeRecentlyPlayedAlbumsEmptyTitle,
                emptySubtitle: l10n.homeRecentlyPlayedAlbumsEmptySubtitle,
                onRetry: () => ref.invalidate(homeRecentlyPlayedAlbumsProvider),
              ),

              // ── 4. Random Albums (horizontal card carousel) ──
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

              // ── 5. Most Played Tracks (vertical list) ──
              _HomeSection<List<SongsTableData>>(
                title: l10n.homeMostPlayedTracksTitle,
                data: ref.watch(homeMostPlayedSongsProvider),
                isEmpty: (items) => items.isEmpty,
                builder: (context, songs) => _SongListSection(
                  songs: songs,
                  onTap: (song) {
                    ref.read(queueProvider.notifier).replace([
                      song.id,
                    ]).ignore();
                  },
                ),
                emptyTitle: l10n.homeMostPlayedTracksEmptyTitle,
                emptySubtitle: l10n.homeMostPlayedTracksEmptySubtitle,
                onRetry: () => ref.invalidate(homeMostPlayedSongsProvider),
              ),

              // ── 6. AudioMuse AI Recommendations ──
              if (ref.watch(audioMuseAvailableProvider))
                _HomeSection<List<AudioMuseRecommendation>>(
                  title: l10n.audioMuseHomeRecommendations,
                  data: ref.watch(audioMuseHomeRecommendationsProvider),
                  isEmpty: (items) => items.isEmpty,
                  builder: (context, recs) => _AudioMuseRecsSection(recs: recs),
                  emptyTitle: l10n.audioMuseHomeRecommendations,
                  emptySubtitle: l10n.audioMuseNotConfigured,
                  onRetry: () =>
                      ref.invalidate(audioMuseHomeRecommendationsProvider),
                ),
            ],
          ),
        ),
      ),
    );
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
    this.artist,
    this.coverArtId,
    this.heroTag,
    this.onTap,
    this.onLongPress,
  });

  final String name;
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
            borderRadius: BorderRadius.circular(12),
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
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Color(0x00000000),
                          Color(0xCC000000),
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
                            style: const TextStyle(
                              color: Colors.white,
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
                              style: const TextStyle(
                                color: Color(0xCCFFFFFF),
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
          for (final song in songs)
            ListTile(
              leading: SizedBox(
                width: 48,
                height: 48,
                child: CoverArtImage(
                  coverArtId: song.coverArt,
                  size: 160,
                  borderRadius: BorderRadius.circular(6),
                  placeholderIcon: Icons.music_note_outlined,
                ),
              ),
              title: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                song.artistName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              dense: true,
              onTap: () => onTap(song),
              onLongPress: () => showSongContextMenu(context, ref, song),
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
      data: (UpdateInfo? info) {
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

// ─────────────────────────────────────────────────────────────────────────────
// AudioMuse AI Recommendations section
// ─────────────────────────────────────────────────────────────────────────────

class _AudioMuseRecsSection extends StatelessWidget {
  const _AudioMuseRecsSection({required this.recs});

  final List<AudioMuseRecommendation> recs;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: recs.map((rec) {
        return ActionChip(
          avatar: const Icon(Icons.auto_awesome, size: 16),
          label: Text(
            rec.artist != null ? '${rec.title} — ${rec.artist}' : rec.title,
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => context.go('/library/albums/${rec.id}'),
        );
      }).toList(),
    );
  }
}
