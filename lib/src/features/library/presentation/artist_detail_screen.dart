import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:navis/src/common_widgets/album_download_badge.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/artist_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_section.dart';
import 'package:navis/src/features/library/presentation/artist_virtual_playlist_artwork.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';

class ArtistDetailScreen extends ConsumerStatefulWidget {
  const ArtistDetailScreen({required this.artistId, super.key});

  final String artistId;

  @override
  ConsumerState<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends ConsumerState<ArtistDetailScreen> {
  bool _isStarred = false;
  bool _isStarring = false;

  @override
  void initState() {
    super.initState();
    ref
        .read(librarySyncControllerProvider.notifier)
        .registerArtistInteraction(widget.artistId);
  }

  void _queueArtist(
    List<SongsTableData> songs, {
    required bool shuffle,
  }) {
    if (songs.isEmpty) return;
    final songsToQueue = List<SongsTableData>.of(songs);
    if (shuffle) songsToQueue.shuffle(Random());
    ref
        .read(queueProvider.notifier)
        .fireAndForget(
          () => ref
              .read(queueProvider.notifier)
              .replaceWithTableData(songsToQueue, autoPlay: true),
          label: 'replace',
        );
  }

  Future<void> _toggleStar({required bool isStarred}) async {
    setState(() {
      _isStarred = !isStarred;
      _isStarring = true;
    });
    try {
      await ref
          .read(navisDatabaseProvider)
          .starSyncDao
          .setStarred(
            itemId: widget.artistId,
            itemType: 'artist',
            liked: !isStarred,
          );
    } on Object {
      // A local persistence failure means the intent was not saved.
      if (!mounted) return;
      setState(() => _isStarred = isStarred);
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.albumDetailStarFailure,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) setState(() => _isStarring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final artist = ref.watch(artistByIdProvider(widget.artistId));
    final albumSections = ref.watch(
      artistAlbumSectionsProvider(widget.artistId),
    );
    final songs = ref.watch(songsByArtistProvider(widget.artistId));
    final artistInfo = ref.watch(artistInfoProvider(widget.artistId));
    final currentArtist = artist.value;
    final availableSongs = songs.value ?? const <SongsTableData>[];

    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
    final artistBody = artist.when(
      data: (artistData) {
        if (artistData == null) {
          return EmptyState(
            title: l10n.artistDetailNotFoundTitle,
            subtitle: l10n.artistDetailNotFoundSubtitle,
            icon: Icons.person_off_outlined,
            action: OutlinedButton.icon(
              key: const ValueKey<String>('artist-detail-back-to-library'),
              onPressed: () => NavService.returnToLibrary(context, ref),
              icon: const Icon(Icons.library_music_outlined),
              label: Text(l10n.detailUnavailableBackToLibrary),
            ),
          );
        }

        final isStarred = _isStarred || artistData.starred != null;

        return RefreshIndicator(
          onRefresh: () => ref
              .read(librarySyncControllerProvider.notifier)
              .refreshArtist(widget.artistId),
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
                      albumCount: artistData.albumCount,
                      isStarred: isStarred,
                      isStarring: _isStarring,
                      onStarToggle: _isStarring
                          ? null
                          : () => _toggleStar(isStarred: isStarred),
                      starTooltip: l10n.albumDetailStarAction,
                      isExternalSource: artistData.isExternal,
                    );
                  }
                  // No photo — plain name row
                  return _ArtistNameHeader(
                    name: artistData.name,
                    albumCount: artistData.albumCount,
                    isExternalSource: artistData.isExternal,
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
                  albumCount: artistData.albumCount,
                  isExternalSource: artistData.isExternal,
                  isStarred: isStarred,
                  isStarring: _isStarring,
                  onStarToggle: null,
                  starTooltip: l10n.albumDetailStarAction,
                ),
                error: (_, _) => _ArtistNameHeader(
                  name: artistData.name,
                  albumCount: artistData.albumCount,
                  isExternalSource: artistData.isExternal,
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
              // ── Play / Shuffle buttons ────────────────────────────────
              if (availableSongs.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: () => _queueArtist(
                          availableSongs,
                          shuffle: false,
                        ),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(l10n.albumDetailPlayAction),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _queueArtist(
                          availableSongs,
                          shuffle: true,
                        ),
                        icon: const Icon(Icons.shuffle, size: 18),
                        label: Text(l10n.albumDetailShuffleAction),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => unawaited(
                          showArtistContextMenu(
                            context,
                            ref,
                            artistData.id,
                          ),
                        ),
                        icon: const Icon(Icons.more_horiz, size: 18),
                        label: Text(l10n.actionMore),
                      ),
                    ],
                  ),
                ),
              // ── Top Tracks (Last.fm, gated by build-time API key) ────────
              if (ref.watch(hasLastFmApiKeyProvider))
                ArtistTopTracksSection(artistName: artistData.name),
              if (ref.watch(hasLastFmApiKeyProvider))
                _ArtistTopTracksPlaylistCard(
                  artistId: artistData.id,
                  artistName: artistData.name,
                  imageUrl:
                      artistInfo.asData?.value?.largeImageUrl ??
                      artistInfo.asData?.value?.mediumImageUrl,
                ),
              albumSections.when(
                data: (sections) {
                  if (sections.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: EmptyState(
                        title: l10n.artistDetailAlbumsEmptyTitle,
                        subtitle: l10n.artistDetailAlbumsEmptySubtitle,
                        icon: Icons.album_outlined,
                      ),
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (sections.albums.isNotEmpty)
                        _ArtistAlbumSection(
                          title: l10n.artistDetailAlbumsSection,
                          albums: sections.albums,
                        ),
                      if (sections.featuredIn.isNotEmpty)
                        _ArtistAlbumSection(
                          title: l10n.artistDetailFeaturedSection,
                          albums: sections.featuredIn,
                        ),
                    ],
                  );
                },
                loading: () => const ShimmerListPage(count: 4, leadingSize: 56),
                error: (error, _) => ErrorState(
                  title: l10n.artistDetailAlbumsErrorTitle,
                  onRetry: () => ref.invalidate(
                    artistAlbumSectionsProvider(widget.artistId),
                  ),
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
      loading: () => const _ArtistDetailLoadingState(),
      error: (error, _) => ErrorState(
        title: l10n.artistDetailLoadErrorTitle,
        onRetry: () => ref.invalidate(artistByIdProvider(widget.artistId)),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(currentArtist?.name ?? l10n.artistDetailTitle),
        actions: currentArtist == null
            ? const <Widget>[]
            : <Widget>[
                Builder(
                  builder: (buttonContext) => IconButton(
                    icon: const Icon(Icons.more_horiz),
                    tooltip: MaterialLocalizations.of(
                      buttonContext,
                    ).showMenuTooltip,
                    onPressed: () {
                      final renderObject = buttonContext.findRenderObject();
                      if (renderObject is! RenderBox) return;
                      unawaited(
                        showArtistContextMenu(
                          context,
                          ref,
                          currentArtist.id,
                          anchor: renderObject.localToGlobal(
                            renderObject.size.center(Offset.zero),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
      ),
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

/// The initial detail query has no artist identity to preserve yet. Keep the
/// page's eventual silhouette visible so a cold deep link never reads as an
/// empty page while the local library stream is connecting.
class _ArtistDetailLoadingState extends StatelessWidget {
  const _ArtistDetailLoadingState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final headerHeight = (availableWidth * (desktopMode ? 0.32 : 0.43))
            .clamp(260.0, desktopMode ? 420.0 : 560.0);

        return Semantics(
          label: l10n.artistDetailLoadingLabel,
          child: ExcludeSemantics(
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: <Widget>[
                SizedBox(
                  height: headerHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          colorScheme.surfaceContainerHighest,
                          colorScheme.surfaceContainerHigh,
                          colorScheme.surface,
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const <Widget>[
                            _ArtistDetailLoadingPlaceholder(
                              height: 44,
                              width: 240,
                            ),
                            SizedBox(height: 10),
                            _ArtistDetailLoadingPlaceholder(
                              height: 16,
                              width: 96,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: <Widget>[
                      _ArtistDetailLoadingPlaceholder(height: 40, width: 88),
                      SizedBox(width: 10),
                      _ArtistDetailLoadingPlaceholder(height: 40, width: 104),
                      SizedBox(width: 10),
                      _ArtistDetailLoadingPlaceholder(height: 40, width: 88),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 28, 16, 12),
                  child: _ArtistDetailLoadingPlaceholder(
                    height: 24,
                    width: 92,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: <Widget>[
                      _ArtistDetailLoadingAlbumRow(),
                      SizedBox(height: 12),
                      _ArtistDetailLoadingAlbumRow(),
                      SizedBox(height: 12),
                      _ArtistDetailLoadingAlbumRow(),
                      SizedBox(height: 12),
                      _ArtistDetailLoadingAlbumRow(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ArtistDetailLoadingAlbumRow extends StatelessWidget {
  const _ArtistDetailLoadingAlbumRow();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        _ArtistDetailLoadingPlaceholder(height: 88, width: 88),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _ArtistDetailLoadingPlaceholder(height: 16),
              SizedBox(height: 8),
              _ArtistDetailLoadingPlaceholder(height: 12, width: 128),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArtistDetailLoadingPlaceholder extends StatelessWidget {
  const _ArtistDetailLoadingPlaceholder({
    required this.height,
    this.width = double.infinity,
  });

  final double height;
  final double width;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SizedBox(height: height, width: width),
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
    required this.albumCount,
    required this.isStarred,
    required this.isStarring,
    required this.onStarToggle,
    required this.starTooltip,
    required this.isExternalSource,
  });

  final String imageUrl;
  final String artistName;
  final int? albumCount;
  final bool isStarred;
  final bool isStarring;
  final VoidCallback? onStarToggle;
  final String starTooltip;
  final bool isExternalSource;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final desktopMode = resolveAdaptiveContextFor(context).useDesktopShell;
        final headerHeight = (availableWidth * (desktopMode ? 0.32 : 0.43))
            .clamp(260.0, desktopMode ? 420.0 : 560.0);

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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          FittedBox(
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
                          if (albumCount != null) ...<Widget>[
                            const SizedBox(height: 6),
                            Text(
                              AppLocalizations.of(
                                context,
                              )!.artistCardAlbumCount(
                                albumCount!,
                              ),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.82),
                                    shadows: const <Shadow>[
                                      Shadow(
                                        blurRadius: 8,
                                        color: Color(0xCC000000),
                                      ),
                                    ],
                                  ),
                            ),
                          ],
                          if (isExternalSource) ...<Widget>[
                            const SizedBox(height: 8),
                            const RemoteSourceIndicator(
                              variant: RemoteSourceIndicatorVariant.chip,
                            ),
                          ],
                        ],
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
    required this.albumCount,
    required this.isStarred,
    required this.isStarring,
    required this.onStarToggle,
    required this.starTooltip,
    required this.isExternalSource,
  });

  final String name;
  final int? albumCount;
  final bool isStarred;
  final bool isStarring;
  final VoidCallback? onStarToggle;
  final String starTooltip;
  final bool isExternalSource;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FittedBox(
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
                if (albumCount != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(l10n.artistCardAlbumCount(albumCount!)),
                ],
                if (isExternalSource) ...<Widget>[
                  const SizedBox(height: 8),
                  const RemoteSourceIndicator(
                    variant: RemoteSourceIndicatorVariant.chip,
                  ),
                ],
              ],
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

class _ArtistTopTracksPlaylistCard extends ConsumerWidget {
  const _ArtistTopTracksPlaylistCard({
    required this.artistId,
    required this.artistName,
    required this.imageUrl,
  });

  final String artistId;
  final String artistName;
  final String? imageUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(artistTopTracksPlaylistProvider(artistName));
    return tracks.when(
      skipLoadingOnReload: true,
      data: (playlistTracks) {
        if (playlistTracks.isEmpty) return const SizedBox.shrink();
        final coverArtIds = playlistTracks
            .map((track) => track.resolvedSong?.coverArt)
            .nonNulls
            .toList(growable: false);
        final l10n = AppLocalizations.of(context)!;
        final colorScheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
          child: Material(
            color: colorScheme.secondaryContainer.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => NavService.openArtistTopTracksPlaylist(
                context,
                ref,
                artistId,
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: <Widget>[
                    ArtistVirtualPlaylistArtwork(
                      coverArtIds: coverArtIds,
                      imageUrl: imageUrl,
                      size: 64,
                      borderRadius: 6,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        l10n.artistTopTracksPlaylistTitle(artistName),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: colorScheme.onSecondaryContainer,
                            ),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _ArtistAlbumSection extends ConsumerWidget {
  const _ArtistAlbumSection({required this.title, required this.albums});

  final String title;
  final List<AlbumsTableData> albums;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Padding(
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
                  ((availableWidth + spacing) / (minTileWidth + spacing))
                      .floor()
                      .clamp(2, 7);
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: albums.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  childAspectRatio: 1,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                ),
                itemBuilder: (context, index) {
                  final album = albums[index];
                  final heroTag = buildCoverArtHeroTag(
                    coverArtId: album.coverArt,
                    context: 'artist_album',
                    entityId: album.id,
                  );
                  return RepaintBoundary(
                    child: AlbumCard(
                      album: album,
                      size: AlbumCardSize.library,
                      heroTag: heroTag,
                      badge: AlbumDownloadBadge(albumId: album.id),
                      onTap: () => NavService.openAlbumDetail(
                        context,
                        ref,
                        album.id,
                        heroTag: heroTag,
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
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

class _SimilarArtistCard extends ConsumerWidget {
  const _SimilarArtistCard({required this.artist});

  final _SimilarArtistEntry artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => NavService.openArtistDetail(context, ref, artist.id),
      onLongPress: () => unawaited(
        showArtistContextMenu(context, ref, artist.id),
      ),
      onSecondaryTapDown: (details) => unawaited(
        showArtistContextMenu(
          context,
          ref,
          artist.id,
          anchor: details.globalPosition,
        ),
      ),
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
                size: kCoverArtStandardSize,
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
