import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
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
import 'package:navis/src/features/library/presentation/artist_top_tracks_section.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';

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
      AppNoticeMessenger.of(context).showSnackBar(
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

    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final artistBody = artist.when(
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
              // ── Artist image header with name + heart overlaid ──────────
              artistInfo.when(
                data: (info) {
                  final url = info?.largeImageUrl ?? info?.mediumImageUrl ?? '';
                  if (url.isNotEmpty) {
                    return _ArtistImageHeader(
                      imageUrl: url,
                      artistName: artistData.name,
                      isStarred: isStarred,
                      isStarring: _isStarring,
                      onStarToggle: _isStarring
                          ? null
                          : () => _toggleStar(isStarred: isStarred),
                      starTooltip: l10n.albumDetailStarAction,
                    );
                  }
                  // No photo — plain name row
                  return _ArtistNameHeader(
                    name: artistData.name,
                    isStarred: isStarred,
                    isStarring: _isStarring,
                    onStarToggle: _isStarring
                        ? null
                        : () => _toggleStar(isStarred: isStarred),
                    starTooltip: l10n.albumDetailStarAction,
                  );
                },
                loading: () => _ArtistNameHeader(
                  name: artistData.name,
                  isStarred: isStarred,
                  isStarring: _isStarring,
                  onStarToggle: null,
                  starTooltip: l10n.albumDetailStarAction,
                ),
                error: (_, _) => _ArtistNameHeader(
                  name: artistData.name,
                  isStarred: isStarred,
                  isStarring: _isStarring,
                  onStarToggle: _isStarring
                      ? null
                      : () => _toggleStar(isStarred: isStarred),
                  starTooltip: l10n.albumDetailStarAction,
                ),
              ),
              // ── Bio ─────────────────────────────────────────────────────
              artistInfo.when(
                data: (info) {
                  if (info == null) {
                    return const SizedBox.shrink();
                  }
                  return _ArtistInfoSection(
                    info: info,
                    albumCount: artistData.albumCount,
                  );
                },
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
                error: (_, _) => const SizedBox.shrink(),
              ),
              // ── Top Tracks (Last.fm, gated by build-time API key) ────────
              if (ref.watch(hasLastFmApiKeyProvider))
                ArtistTopTracksSection(artistName: artistData.name),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Text(
                  l10n.artistDetailAlbumsSection,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
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
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final availableWidth = constraints.maxWidth;
                        final spacing = availableWidth >= 900 ? 12.0 : 8.0;
                        final minTileWidth = switch (availableWidth) {
                          >= 1400 => 220.0,
                          >= 1100 => 200.0,
                          >= 840 => 180.0,
                          _ => 160.0,
                        };
                        final crossAxisCount =
                            ((availableWidth + spacing) /
                                    (minTileWidth + spacing))
                                .floor()
                                .clamp(2, 7);
                        return GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: items.length,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                childAspectRatio: 1,
                                crossAxisSpacing: spacing,
                                mainAxisSpacing: spacing,
                              ),
                          itemBuilder: (context, index) {
                            final album = items[index];
                            return RepaintBoundary(
                              child: AlbumCard(
                                album: album,
                                size: AlbumCardSize.library,
                                badge: AlbumDownloadBadge(albumId: album.id),
                                onTap: () => context.push(
                                  '/library/albums/${album.id}',
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  );
                },
                loading: () => const ShimmerListPage(count: 4, leadingSize: 56),
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
                  final currentArtistId = widget.artistId.trim();
                  final similar = (info?.similarArtists ?? const <Artist>[])
                      .where((artist) {
                        final candidateId = artist.id.trim();
                        return candidateId.isNotEmpty &&
                            candidateId != currentArtistId;
                      })
                      .toList(growable: false);
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
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.artistDetailTitle)),
      body: desktopMode
          ? DesktopFrame(
              layoutClass: resolveDesktopLayoutClass(
                MediaQuery.sizeOf(context).width,
              ),
              child: artistBody,
            )
          : artistBody,
    );
  }
}

/// Full-width header image shown at the top of the artist detail page when
/// the artist has a photo from the Last.fm / MusicBrainz metadata.
/// Overlays the artist name and heart/star icon at the bottom of the image.
class _ArtistImageHeader extends StatelessWidget {
  const _ArtistImageHeader({
    required this.imageUrl,
    required this.artistName,
    required this.isStarred,
    required this.isStarring,
    required this.onStarToggle,
    required this.starTooltip,
  });

  final String imageUrl;
  final String artistName;
  final bool isStarred;
  final bool isStarring;
  final VoidCallback? onStarToggle;
  final String starTooltip;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final headerHeight = (availableWidth * 0.43).clamp(260.0, 560.0);

        // Gradually shift the vertical anchor from top (portrait/narrow screens
        // where topCenter works well for portrait artist shots) toward center
        // (wide/cinematic displays where topCenter cuts off the face).
        // The transition spans aspect‑ratios 1.5 → 2.5:
        //   ≤ 1.5  → Alignment(0, −1)  = topCenter
        //   ≥ 2.5  → Alignment(0,  0)  = center
        final displayRatio = availableWidth / headerHeight;
        final alignY = ((displayRatio - 1.5) / 1.0).clamp(0.0, 1.0) - 1.0;
        final imageAlignment = Alignment(0.0, alignY);

        return SizedBox(
          height: headerHeight,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                alignment: imageAlignment,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
              // Dual gradient: slight top vignette + heavy bottom scrim
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x55000000),
                      Color(0x00000000),
                      Color(0xF2000000),
                    ],
                    stops: <double>[0.0, 0.35, 1.0],
                  ),
                ),
              ),
              // Artist name (bottom-left) + heart (bottom-right) overlaid
              Positioned(
                left: 20,
                right: 8,
                bottom: 20,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.bottomLeft,
                        child: Text(
                          artistName,
                          style: Theme.of(context).textTheme.displayLarge
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1.0,
                                height: 1.05,
                                fontSize: 64,
                                shadows: const <Shadow>[
                                  Shadow(
                                    blurRadius: 4,
                                    color: Color(0xCC000000),
                                  ),
                                  Shadow(
                                    blurRadius: 24,
                                    color: Color(0xAA000000),
                                  ),
                                ],
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        isStarred ? Icons.favorite : Icons.favorite_border,
                        color: isStarred
                            ? Colors.red[300]
                            : Colors.white.withValues(alpha: 0.8),
                        size: 26,
                      ),
                      tooltip: isDesktopRuntime ? starTooltip : null,
                      onPressed: onStarToggle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Fallback header shown when there is no artist photo.
class _ArtistNameHeader extends StatelessWidget {
  const _ArtistNameHeader({
    required this.name,
    required this.isStarred,
    required this.isStarring,
    required this.onStarToggle,
    required this.starTooltip,
  });

  final String name;
  final bool isStarred;
  final bool isStarring;
  final VoidCallback? onStarToggle;
  final String starTooltip;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 32, 12, 24),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          CircleAvatar(
            radius: 36,
            backgroundColor: colorScheme.primaryContainer,
            child: Text(
              initial,
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                name,
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.0,
                  fontSize: 56,
                ),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              isStarred ? Icons.favorite : Icons.favorite_border,
              color: isStarred
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
              size: 26,
            ),
            tooltip: isDesktopRuntime ? starTooltip : null,
            onPressed: onStarToggle,
          ),
        ],
      ),
    );
  }
}

class _ArtistInfoSection extends StatelessWidget {
  const _ArtistInfoSection({required this.info, this.albumCount});

  final ArtistInfo info;
  final int? albumCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (info.biography == null || info.biography!.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final bioTitle = albumCount != null && albumCount! > 0
        ? '${l10n.artistDetailBioSection} · ${l10n.artistDetailAlbumCount(albumCount!)}'
        : l10n.artistDetailBioSection;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (info.biography != null &&
              info.biography!.trim().isNotEmpty) ...<Widget>[
            Text(
              bioTitle,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              info.biography!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.65,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 16),
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
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final availableWidth = constraints.maxWidth;
              final spacing = availableWidth >= 900 ? 10.0 : 8.0;
              final minTileWidth = switch (availableWidth) {
                >= 1400 => 190.0,
                >= 1100 => 170.0,
                >= 840 => 150.0,
                _ => 128.0,
              };
              final crossAxisCount =
                  ((availableWidth + spacing) / (minTileWidth + spacing))
                      .floor()
                      .clamp(2, 6);
              final maxVisible = crossAxisCount * 2;
              final visibleArtists = artists
                  .take(maxVisible)
                  .toList(
                    growable: false,
                  );

              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: visibleArtists.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisExtent: 184,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
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
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 110,
              height: 110,
              child: CoverArtImage(
                coverArtId: artist.coverArt,
                size: 220,
                width: 110,
                height: 110,
                circular: true,
                placeholderIcon: Icons.person_outline,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              artist.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
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
        final currentArtistId = artistId.trim();
        final filteredRecs = recs
            .where((rec) {
              final candidateId = rec.id.trim();
              return candidateId.isNotEmpty && candidateId != currentArtistId;
            })
            .toList(growable: false);
        if (filteredRecs.isEmpty) return const SizedBox.shrink();
        return _SimilarArtistsSection(
          title: l10n.audioMuseSimilarArtists,
          artists: filteredRecs
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
