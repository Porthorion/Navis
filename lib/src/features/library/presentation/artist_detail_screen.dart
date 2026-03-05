import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:navis/src/common_widgets/album_download_badge.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class ArtistDetailScreen extends ConsumerStatefulWidget {
  const ArtistDetailScreen({required this.artistId, super.key});

  final String artistId;

  @override
  ConsumerState<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends ConsumerState<ArtistDetailScreen> {
  bool _isStarred = false;
  bool _isStarring = false;

  Future<void> _toggleStar({required bool isStarred}) async {
    final api = ref.read(subsonicApiProvider);
    if (api == null) return;
    // Optimistic update — flip the icon immediately, block re-taps in flight.
    setState(() {
      _isStarred = !isStarred;
      _isStarring = true;
    });
    // DB update first so all watching streams update immediately (before API ~300ms).
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    await dao.updateArtistStarred(
      widget.artistId,
      isStarred ? null : DateTime.now(),
    );
    try {
      if (isStarred) {
        await api.unstar(widget.artistId);
      } else {
        await api.star(widget.artistId);
      }
    } on SubsonicConnectionException {
      // Offline — queue for retry and keep the optimistic UI (DB already updated).
      if (!mounted) return;
      final db = ref.read(navisDatabaseProvider);
      await db.starSyncDao.queueStarAction(
        itemId: widget.artistId,
        itemType: 'artist',
        action: isStarred ? 'unstar' : 'star',
      );
    } on Object catch (error, stackTrace) {
      debugPrint('Star toggle failed: $error\n$stackTrace');
      // Rollback the optimistic update on failure.
      if (!mounted) return;
      await dao.updateArtistStarred(
        widget.artistId,
        isStarred ? DateTime.now() : null,
      );
      setState(() => _isStarred = isStarred);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.albumDetailStarFailure,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isStarring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artist = ref.watch(artistByIdProvider(widget.artistId));
    final albums = ref.watch(albumsByArtistProvider(widget.artistId));
    final artistInfo = ref.watch(artistInfoProvider(widget.artistId));

    return Scaffold(
      appBar: AppBar(title: Text(l10n.artistDetailTitle)),
      body: artist.when(
        data: (artistData) {
          if (artistData == null) {
            return EmptyState(
              title: l10n.artistDetailNotFoundTitle,
              subtitle: l10n.artistDetailNotFoundSubtitle,
              icon: Icons.person_off_outlined,
            );
          }

          final isStarred = _isStarred || artistData.starred != null;

          return RefreshIndicator(
            onRefresh: () => ref
                .read(librarySyncControllerProvider.notifier)
                .syncNow(preferIncremental: true),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: <Widget>[
                // ── Artist image header ─────────────────────────────────────
                artistInfo.when(
                  data: (info) {
                    final url =
                        info?.largeImageUrl ?? info?.mediumImageUrl ?? '';
                    if (url.isEmpty) return const SizedBox.shrink();
                    return _ArtistImageHeader(imageUrl: url);
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),
                // ── Name + star ─────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          artistData.name,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      StarButton(
                        isStarred: isStarred,
                        onPressed: _isStarring
                            ? null
                            : () => _toggleStar(isStarred: isStarred),
                        compact: true,
                        tooltip: l10n.albumDetailStarAction,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    l10n.artistDetailAlbumCount(artistData.albumCount ?? 0),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                // ── Bio ─────────────────────────────────────────────────────
                artistInfo.when(
                  data: (info) {
                    if (info == null) {
                      return const SizedBox.shrink();
                    }
                    return _ArtistInfoSection(info: info);
                  },
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                  error: (_, _) => const SizedBox.shrink(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    l10n.artistDetailAlbumsSection,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                albums.when(
                  data: (items) {
                    if (items.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: EmptyState(
                          title: l10n.artistDetailAlbumsEmptyTitle,
                          subtitle: l10n.artistDetailAlbumsEmptySubtitle,
                          icon: Icons.album_outlined,
                        ),
                      );
                    }
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                      child: GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: items.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              childAspectRatio: 1,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemBuilder: (context, index) {
                          final album = items[index];
                          return RepaintBoundary(
                            child: AlbumCard(
                              album: album,
                              size: AlbumCardSize.library,
                              badge: AlbumDownloadBadge(albumId: album.id),
                              onTap: () =>
                                  context.push('/library/albums/${album.id}'),
                            ),
                          );
                        },
                      ),
                    );
                  },
                  loading: () =>
                      const ShimmerListPage(count: 4, leadingSize: 56),
                  error: (error, _) => ErrorState(
                    title: l10n.artistDetailAlbumsErrorTitle,
                    message: error.toString(),
                    onRetry: () =>
                        ref.invalidate(albumsByArtistProvider(widget.artistId)),
                  ),
                ),
                // ── Similar Artists (below albums for navigation continuity) ─
                artistInfo.when(
                  data: (info) {
                    final similar = info?.similarArtists ?? const <Artist>[];
                    if (similar.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return _SimilarArtistsSection(
                      title: l10n.artistDetailSimilarSection,
                      artists: similar
                          .map(
                            (artist) => _SimilarArtistEntry(
                              id: artist.id,
                              name: artist.name,
                              coverArt: artist.coverArt,
                            ),
                          )
                          .toList(growable: false),
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),
                if (ref.watch(audioMuseAvailableProvider))
                  _AudioMuseSimilarArtists(artistId: widget.artistId),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
        loading: () => const ShimmerListPage(count: 8, leadingSize: 56),
        error: (error, _) => ErrorState(
          title: l10n.artistDetailLoadErrorTitle,
          message: error.toString(),
          onRetry: () => ref.invalidate(artistByIdProvider(widget.artistId)),
        ),
      ),
    );
  }
}

/// Full-width header image shown at the top of the artist detail page when
/// the artist has a photo from the Last.fm / MusicBrainz metadata.
class _ArtistImageHeader extends StatelessWidget {
  const _ArtistImageHeader({required this.imageUrl});

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 240,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
          // Gradient overlay — fades to scaffold background at the bottom
          // so the artist name blends in naturally.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0x00000000),
                  Color(0xCC000000),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistInfoSection extends StatelessWidget {
  const _ArtistInfoSection({required this.info});

  final ArtistInfo info;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (info.biography == null || info.biography!.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (info.biography != null &&
              info.biography!.trim().isNotEmpty) ...<Widget>[
            Text(
              l10n.artistDetailBioSection,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(info.biography!),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _SimilarArtistEntry {
  const _SimilarArtistEntry({
    required this.id,
    required this.name,
    this.coverArt,
  });

  final String id;
  final String name;
  final String? coverArt;
}

class _SimilarArtistsSection extends StatelessWidget {
  const _SimilarArtistsSection({
    required this.title,
    required this.artists,
  });

  final String title;
  final List<_SimilarArtistEntry> artists;

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final crossAxisCount = (constraints.maxWidth / 120).floor().clamp(
                2,
                3,
              );
              final maxVisible = crossAxisCount * 2;
              final visibleArtists = artists.take(maxVisible).toList(
                growable: false,
              );

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: visibleArtists.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  childAspectRatio: 0.78,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                ),
                itemBuilder: (context, index) {
                  final artist = visibleArtists[index];
                  return _SimilarArtistCard(artist: artist);
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SimilarArtistCard extends StatelessWidget {
  const _SimilarArtistCard({required this.artist});

  final _SimilarArtistEntry artist;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/library/artists/${artist.id}'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: <Widget>[
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final side = constraints.maxWidth < constraints.maxHeight
                      ? constraints.maxWidth
                      : constraints.maxHeight;
                  return SizedBox(
                    width: side,
                    height: side,
                    child: CoverArtImage(
                      coverArtId: artist.coverArt,
                      size: 200,
                      width: side,
                      height: side,
                      borderRadius: BorderRadius.circular(999),
                      placeholderIcon: Icons.person_outline,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Text(
              artist.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// AI-powered similar artists section, gated behind
/// [audioMuseAvailableProvider]. Hidden when no recommendations are returned.
class _AudioMuseSimilarArtists extends ConsumerWidget {
  const _AudioMuseSimilarArtists({required this.artistId});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final asyncRecs = ref.watch(audioMuseSimilarArtistsProvider(artistId));

    return asyncRecs.when(
      data: (recs) {
        if (recs.isEmpty) return const SizedBox.shrink();
        return _SimilarArtistsSection(
          title: l10n.audioMuseSimilarArtists,
          artists: recs
              .map(
                (rec) => _SimilarArtistEntry(
                  id: rec.id,
                  name: rec.title,
                ),
              )
              .toList(growable: false),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}
