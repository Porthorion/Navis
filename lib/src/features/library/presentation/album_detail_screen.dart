import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/cover_art_viewer.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/star_button.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/library/domain/set_rating.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/add_to_playlist_sheet.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:url_launcher/url_launcher.dart';

class AlbumDetailScreen extends ConsumerStatefulWidget {
  const AlbumDetailScreen({
    required this.albumId,
    this.likedOnly = false,
    super.key,
  });

  final String albumId;
  final bool likedOnly;

  @override
  ConsumerState<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends ConsumerState<AlbumDetailScreen> {
  bool _isStarred = false;
  bool _isStarring = false;
  bool _isUpdatingRating = false;
  bool _isRefreshingAlbum = false;
  late bool _showLikedOnly = widget.likedOnly;
  bool _showDownloadedOnly = false;

  // Tracks the current visible (filtered) song list so _playNow can queue
  // the full album when the "queue full album on track tap" setting is on.
  List<SongsTableData> _currentFilteredSongs = const [];

  // Scroll-driven animation for the mobile header.
  final ScrollController _scrollController = ScrollController();
  double _headerProgress = 0.0; // 0 = art fully visible, 1 = fully collapsed
  double _screenWidth = 0.0;

  // One-shot enter animation removed — gradient and album name show immediately.

  @override
  void initState() {
    super.initState();
    ref
        .read(librarySyncControllerProvider.notifier)
        .registerAlbumInteraction(widget.albumId);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final maxScroll = max(1.0, _screenWidth - kToolbarHeight);
    final newProgress = (_scrollController.offset / maxScroll).clamp(0.0, 1.0);
    if ((newProgress - _headerProgress).abs() > 0.001) {
      setState(() => _headerProgress = newProgress);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final album = ref.watch(albumProvider(widget.albumId));
    final downloadedSongIds = _showDownloadedOnly
        ? ref.watch(downloadedSongIdsProvider).asData?.value ?? const <String>{}
        : const <String>{};
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = coverArtShapeToRadius(coverShape);
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final desktopMode = adaptiveContext.useDesktopShell;
    final compactWideMode = adaptiveContext.useCompactWideLandscape;

    return Scaffold(
      // AppBar is only shown on desktop or when album data is still loading/errored.
      // The mobile data state uses a custom SliverAppBar with overlay nav buttons.
      appBar: (desktopMode || album.asData?.value == null)
          ? AppBar(
              title: Text(l10n.albumDetailTitle),
              backgroundColor: desktopMode
                  ? Theme.of(context).colorScheme.surfaceContainerHigh
                  : null,
              actions: <Widget>[
                IconButton(
                  tooltip: l10n.commonRetry,
                  onPressed: _isRefreshingAlbum ? null : _refreshAlbum,
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _isRefreshingAlbum
                        ? const SizedBox(
                            key: ValueKey<String>('album-refresh-loading'),
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : const Icon(
                            Icons.refresh,
                            key: ValueKey<String>('album-refresh-idle'),
                          ),
                  ),
                ),
              ],
            )
          : null,
      body: Stack(
        children: <Widget>[
          album.when(
            data: (data) {
              if (data == null) {
                return EmptyState(
                  title: l10n.albumDetailNotFoundTitle,
                  subtitle: l10n.albumDetailNotFoundSubtitle,
                  icon: Icons.album_outlined,
                );
              }
              final details = data.album;
              final songs = data.songs;
              final filteredSongs = songs
                  .where((song) {
                    if (_showLikedOnly && song.starred == null) {
                      return false;
                    }
                    if (_showDownloadedOnly &&
                        !downloadedSongIds.contains(song.id)) {
                      return false;
                    }
                    return true;
                  })
                  .toList(growable: false);
              _currentFilteredSongs = filteredSongs;
              final isStarred = _isStarred || details.starred != null;
              final albumInfoAsync = ref.watch(
                albumInfoProvider(widget.albumId),
              );
              final albumRating =
                  ref
                      .watch(albumRatingProvider(widget.albumId))
                      .asData
                      ?.value ??
                  details.userRating;
              final coverArtHeroTag = buildCoverArtHeroTag(
                coverArtId: details.coverArt,
                context: 'album',
                entityId: widget.albumId,
              );
              // ── Build render items with disc headers for multi-disc ──
              final renderItems = _buildRenderItems(filteredSongs);
              final tracksSliver = renderItems.isEmpty
                  ? SliverFillRemaining(
                      hasScrollBody: false,
                      child: _showDownloadedOnly
                          ? EmptyState(
                              title: l10n.libraryDownloadedOnlyEmpty,
                              subtitle: l10n.libraryDownloadedOnlyEmptySubtitle,
                              icon: Icons.download_done_outlined,
                            )
                          : _showLikedOnly
                          ? Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                EmptyState(
                                  title: l10n.albumDetailLikedTracksEmptyTitle,
                                  subtitle:
                                      l10n.albumDetailLikedTracksEmptySubtitle,
                                  icon: Icons.favorite_border_outlined,
                                ),
                                const SizedBox(height: 12),
                                FilledButton.tonal(
                                  onPressed: () =>
                                      setState(() => _showLikedOnly = false),
                                  child: Text(
                                    l10n.albumDetailShowAllTracksAction,
                                  ),
                                ),
                              ],
                            )
                          : EmptyState(
                              title: l10n.albumDetailTracksEmptyTitle,
                              subtitle: l10n.albumDetailTracksEmptySubtitle,
                              icon: Icons.music_note_outlined,
                            ),
                    )
                  : SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final item = renderItems[index];
                        return switch (item) {
                          _DiscHeader(:final discNumber, :final isFirst) =>
                            _buildDiscHeader(
                              context,
                              l10n,
                              discNumber,
                              isFirst,
                            ),
                          _SongItem(:final song) => TrackListTile(
                            song: song,
                            contentPadding: compactWideMode
                                ? const EdgeInsetsDirectional.only(
                                    start: 8,
                                    end: 4,
                                  )
                                : null,
                            horizontalTitleGap: 6,
                            onTap: () => _playNow(song),
                            onLongPress: () =>
                                unawaited(_showSongActions(song)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                SongDownloadStatusIcon(
                                  songId: song.id,
                                  onDownload: () =>
                                      unawaited(_downloadSong(song)),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.more_vert),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                  onPressed: () =>
                                      unawaited(_showSongActions(song)),
                                ),
                              ],
                            ),
                          ),
                        };
                      }, childCount: renderItems.length),
                    );

              // ── Desktop layout: horizontal header + scrollable track panel ──
              if (desktopMode) {
                const artSize = 260.0;
                final colors = Theme.of(context).colorScheme;
                final textTheme = Theme.of(context).textTheme;
                final albumInfoWidget = albumInfoAsync.when(
                  data: (info) {
                    if (info == null) return const SizedBox.shrink();
                    final notes = _stripHtml(info.notes ?? '');
                    final hasNotes = notes.trim().isNotEmpty;
                    final hasLinks =
                        (info.lastFmUrl ?? '').trim().isNotEmpty ||
                        (info.musicBrainzId ?? '').trim().isNotEmpty;
                    if (!hasNotes && !hasLinks) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Divider(height: 1),
                          const SizedBox(height: 14),
                          Text(
                            l10n.albumDetailAboutSection,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (hasNotes) ...<Widget>[
                            const SizedBox(height: 8),
                            Text(
                              notes,
                              style: textTheme.bodyMedium?.copyWith(
                                height: 1.6,
                                color: colors.onSurface.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                          if (hasLinks) ...<Widget>[
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: <Widget>[
                                if ((info.lastFmUrl ?? '').trim().isNotEmpty)
                                  ActionChip(
                                    avatar: const Icon(
                                      Icons.open_in_new,
                                      size: 16,
                                    ),
                                    label: Text(l10n.albumDetailLastFm),
                                    onPressed: () => unawaited(
                                      _openExternalLink(info.lastFmUrl!),
                                    ),
                                  ),
                                if ((info.musicBrainzId ?? '')
                                    .trim()
                                    .isNotEmpty)
                                  ActionChip(
                                    avatar: const Icon(
                                      Icons.album_outlined,
                                      size: 16,
                                    ),
                                    label: Text(
                                      l10n.albumDetailMusicBrainz,
                                    ),
                                    onPressed: () => unawaited(
                                      _openExternalLink(
                                        'https://musicbrainz.org/release-group/${info.musicBrainzId}',
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 12),
                        ],
                      ),
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                );
                return SafeArea(
                  bottom: false,
                  child: DesktopFrame(
                    layoutClass: resolveDesktopLayoutClass(
                      MediaQuery.sizeOf(context).width,
                    ),
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // ── Spotify-style header: tinted background ──
                        ColoredBox(
                          key: const ValueKey<String>(
                            'albumDetailDesktopHeader',
                          ),
                          color: colors.surfaceContainerHigh,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: <Widget>[
                                InkWell(
                                  borderRadius: coverRadius,
                                  onTap: () => unawaited(
                                    showCoverArtViewer(
                                      context,
                                      coverArtId: details.coverArt,
                                      heroTag: coverArtHeroTag,
                                      previewSize: 300,
                                      isExternalSource: details.isExternal,
                                    ),
                                  ),
                                  child: HeroCoverArt(
                                    coverArtId: details.coverArt,
                                    heroTag: coverArtHeroTag,
                                    size: 300,
                                    width: artSize,
                                    height: artSize,
                                    isExternalSource: details.isExternal,
                                    borderRadius: coverRadius,
                                    placeholderIcon: Icons.album_outlined,
                                    loadPriority: CoverArtLoadPriority.critical,
                                  ),
                                ),
                                const SizedBox(width: 28),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      // Album title — large
                                      Text(
                                        details.name,
                                        style: textTheme.displaySmall?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.5,
                                          height: 1.1,
                                        ),
                                        maxLines: 3,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 10),
                                      // Artist · Year · Count
                                      Wrap(
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        runSpacing: 4,
                                        children: <Widget>[
                                          ..._buildArtistChips(
                                            context: context,
                                            artists: _resolveArtists(details),
                                            textStyle: textTheme.titleMedium
                                                ?.copyWith(
                                                  color: colors.primary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                            dimStyle: textTheme.titleMedium
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                          Text(
                                            ' • ${details.year?.toString() ?? '-'} • ${filteredSongs.length}',
                                            style: textTheme.bodyMedium
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 20),
                                      // Primary action buttons
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: <Widget>[
                                          FilledButton.icon(
                                            onPressed: filteredSongs.isEmpty
                                                ? null
                                                : () => _queueAlbum(
                                                    filteredSongs,
                                                    shuffle: false,
                                                  ),
                                            icon: const Icon(
                                              Icons.play_arrow,
                                              size: 20,
                                            ),
                                            label: Text(
                                              l10n.albumDetailPlayAction,
                                            ),
                                          ),
                                          FilledButton.tonalIcon(
                                            onPressed: filteredSongs.isEmpty
                                                ? null
                                                : () => _queueAlbum(
                                                    filteredSongs,
                                                    shuffle: true,
                                                  ),
                                            icon: const Icon(
                                              Icons.shuffle,
                                              size: 18,
                                            ),
                                            label: Text(
                                              l10n.albumDetailShuffleAction,
                                            ),
                                          ),
                                          StarButton(
                                            isStarred: isStarred,
                                            onPressed: _isStarring
                                                ? null
                                                : () => _toggleStar(
                                                    isStarred: isStarred,
                                                  ),
                                            label: l10n.actionLike,
                                            starredLabel: l10n.actionLiked,
                                          ),
                                          OutlinedButton.icon(
                                            onPressed: () async {
                                              final choice =
                                                  await showDownloadQualitySheet(
                                                    context,
                                                  );
                                              if (choice == null ||
                                                  !context.mounted) {
                                                return;
                                              }
                                              final service = ref.read(
                                                downloadServiceProvider,
                                              );
                                              final count = await service
                                                  .enqueueAlbum(
                                                    widget.albumId,
                                                    quality: choice.quality,
                                                    format: choice.format,
                                                  );
                                              if (context.mounted) {
                                                showAppNotice(
                                                  context,
                                                  message: l10n
                                                      .downloadAlbumQueued(
                                                        count,
                                                      ),
                                                  level: AppNoticeLevel.success,
                                                );
                                              }
                                            },
                                            icon: const Icon(
                                              Icons.download_outlined,
                                              size: 18,
                                            ),
                                            label: Text(
                                              l10n.albumDetailDownloadAction,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      // Rating button
                                      _RatingButton(
                                        rating: albumRating,
                                        loading: _isUpdatingRating,
                                        onChanged: (next) => unawaited(
                                          _updateAlbumRating(next),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      // Filter chips with header
                                      Row(
                                        children: <Widget>[
                                          Icon(
                                            Icons.filter_list,
                                            size: 14,
                                            color: colors.onSurfaceVariant,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            l10n.albumDetailFilterLabel,
                                            style: textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: <Widget>[
                                          FilterChip(
                                            label: Text(
                                              l10n.libraryLikedOnlyFilter,
                                            ),
                                            avatar: Icon(
                                              _showLikedOnly
                                                  ? Icons.favorite
                                                  : Icons.favorite_border,
                                              size: 18,
                                            ),
                                            selected: _showLikedOnly,
                                            onSelected: (value) => setState(
                                              () => _showLikedOnly = value,
                                            ),
                                          ),
                                          FilterChip(
                                            label: Text(
                                              l10n.libraryDownloadedOnlyFilter,
                                            ),
                                            avatar: Icon(
                                              _showDownloadedOnly
                                                  ? Icons.download_done
                                                  : Icons.download_outlined,
                                              size: 18,
                                            ),
                                            selected: _showDownloadedOnly,
                                            onSelected: (value) => setState(
                                              () => _showDownloadedOnly = value,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // ── Gradient fade from header into track list ──
                        Container(
                          height: 28,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: <Color>[
                                colors.surfaceContainerHigh,
                                colors.surface,
                              ],
                            ),
                          ),
                        ),
                        // ── Track list — flat, no card ──
                        Expanded(
                          child: CustomScrollView(
                            slivers: <Widget>[
                              SliverToBoxAdapter(child: albumInfoWidget),
                              tracksSliver,
                              if (ref.watch(audioMuseAvailableProvider))
                                SliverToBoxAdapter(
                                  child: _AudioMuseSimilarAlbums(
                                    albumId: widget.albumId,
                                  ),
                                ),
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 16),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              if (compactWideMode) {
                final colors = Theme.of(context).colorScheme;
                final textTheme = Theme.of(context).textTheme;
                final albumInfoSliver = albumInfoAsync.when<Widget>(
                  data: (info) {
                    if (info == null) return const SliverToBoxAdapter();
                    final notes = _stripHtml(info.notes ?? '');
                    final hasNotes = notes.trim().isNotEmpty;
                    final hasLinks =
                        (info.lastFmUrl ?? '').trim().isNotEmpty ||
                        (info.musicBrainzId ?? '').trim().isNotEmpty;
                    if (!hasNotes && !hasLinks) {
                      return const SliverToBoxAdapter();
                    }

                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Divider(height: 1),
                            const SizedBox(height: 12),
                            Text(
                              l10n.albumDetailAboutSection,
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (hasNotes) ...<Widget>[
                              const SizedBox(height: 8),
                              Text(
                                notes,
                                style: textTheme.bodyMedium?.copyWith(
                                  height: 1.5,
                                  color: colors.onSurface.withValues(
                                    alpha: 0.82,
                                  ),
                                ),
                              ),
                            ],
                            if (hasLinks) ...<Widget>[
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: <Widget>[
                                  if ((info.lastFmUrl ?? '').trim().isNotEmpty)
                                    ActionChip(
                                      avatar: const Icon(
                                        Icons.open_in_new,
                                        size: 16,
                                      ),
                                      label: Text(l10n.albumDetailLastFm),
                                      onPressed: () => unawaited(
                                        _openExternalLink(info.lastFmUrl!),
                                      ),
                                    ),
                                  if ((info.musicBrainzId ?? '')
                                      .trim()
                                      .isNotEmpty)
                                    ActionChip(
                                      avatar: const Icon(
                                        Icons.album_outlined,
                                        size: 16,
                                      ),
                                      label: Text(l10n.albumDetailMusicBrainz),
                                      onPressed: () => unawaited(
                                        _openExternalLink(
                                          'https://musicbrainz.org/release-group/${info.musicBrainzId}',
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                  loading: () => const SliverToBoxAdapter(),
                  error: (_, _) => const SliverToBoxAdapter(),
                );
                final toolbarSliver = SliverToBoxAdapter(
                  child: Material(
                    key: const ValueKey<String>(
                      'albumDetailCompactWideToolbar',
                    ),
                    color: colors.surface,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 8, 2),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          IconButton(
                            tooltip: l10n.albumDetailPlayAction,
                            icon: const Icon(Icons.play_arrow),
                            onPressed: filteredSongs.isEmpty
                                ? null
                                : () => _queueAlbum(
                                    filteredSongs,
                                    shuffle: false,
                                  ),
                          ),
                          IconButton(
                            tooltip: l10n.albumDetailShuffleAction,
                            icon: const Icon(Icons.shuffle),
                            onPressed: filteredSongs.isEmpty
                                ? null
                                : () => _queueAlbum(
                                    filteredSongs,
                                    shuffle: true,
                                  ),
                          ),
                          _RatingButton(
                            rating: albumRating,
                            loading: _isUpdatingRating,
                            onChanged: (next) =>
                                unawaited(_updateAlbumRating(next)),
                          ),
                          IconButton(
                            tooltip: isStarred
                                ? l10n.actionLiked
                                : l10n.actionLike,
                            icon: Icon(
                              isStarred
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                            ),
                            color: isStarred ? colors.error : null,
                            onPressed: _isStarring
                                ? null
                                : () => _toggleStar(isStarred: isStarred),
                          ),
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).showMenuTooltip,
                            icon: const Icon(Icons.more_vert),
                            onPressed: () => unawaited(
                              _showMobileAlbumContextMenu(
                                details,
                                filteredSongs,
                                albumRating,
                                coverArtHeroTag,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                final filterSliver = SliverToBoxAdapter(
                  child: Material(
                    key: const ValueKey<String>(
                      'albumDetailCompactWideFilterRow',
                    ),
                    color: colors.surface,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.filter_list,
                                size: 16,
                                color: colors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                l10n.albumDetailFilterLabel,
                                style: textTheme.labelSmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(l10n.libraryLikedOnlyFilter),
                            avatar: Icon(
                              _showLikedOnly
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 16,
                            ),
                            selected: _showLikedOnly,
                            onSelected: (value) =>
                                setState(() => _showLikedOnly = value),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(l10n.libraryDownloadedOnlyFilter),
                            avatar: Icon(
                              _showDownloadedOnly
                                  ? Icons.download_done
                                  : Icons.download_outlined,
                              size: 16,
                            ),
                            selected: _showDownloadedOnly,
                            onSelected: (value) =>
                                setState(() => _showDownloadedOnly = value),
                          ),
                        ],
                      ),
                    ),
                  ),
                );

                return SafeArea(
                  left: false,
                  right: false,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final panelWidthValue = (constraints.maxWidth * 0.28)
                          .clamp(208, 256);
                      final panelWidth = panelWidthValue.toDouble();
                      final artSize = min<double>(
                        168,
                        max<double>(148, panelWidth - 56),
                      );

                      return Row(
                        key: const ValueKey<String>(
                          'albumDetailCompactWideSplitPane',
                        ),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          SizedBox(
                            width: panelWidth,
                            child: Material(
                              color: colors.surfaceContainerHigh,
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  8,
                                  10,
                                  12,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Row(
                                      children: <Widget>[
                                        IconButton(
                                          tooltip: MaterialLocalizations.of(
                                            context,
                                          ).backButtonTooltip,
                                          onPressed: () => context.pop(),
                                          icon: const Icon(Icons.arrow_back),
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          tooltip: l10n.commonRetry,
                                          onPressed: _isRefreshingAlbum
                                              ? null
                                              : _refreshAlbum,
                                          icon: AnimatedSwitcher(
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            child: _isRefreshingAlbum
                                                ? const SizedBox(
                                                    key: ValueKey<String>(
                                                      'album-refresh-loading',
                                                    ),
                                                    width: 20,
                                                    height: 20,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2.2,
                                                        ),
                                                  )
                                                : const Icon(
                                                    Icons.refresh,
                                                    key: ValueKey<String>(
                                                      'album-refresh-idle',
                                                    ),
                                                  ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Center(
                                      child: InkWell(
                                        borderRadius: coverRadius,
                                        onTap: () => unawaited(
                                          showCoverArtViewer(
                                            context,
                                            coverArtId: details.coverArt,
                                            heroTag: coverArtHeroTag,
                                            previewSize: 160,
                                            isExternalSource:
                                                details.isExternal,
                                          ),
                                        ),
                                        child: HeroCoverArt(
                                          coverArtId: details.coverArt,
                                          heroTag: coverArtHeroTag,
                                          size: 168,
                                          width: artSize,
                                          height: artSize,
                                          isExternalSource: details.isExternal,
                                          borderRadius: coverRadius,
                                          placeholderIcon: Icons.album_outlined,
                                          loadPriority:
                                              CoverArtLoadPriority.critical,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      details.name,
                                      style: textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        height: 1.15,
                                      ),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      runSpacing: 2,
                                      children: <Widget>[
                                        ..._buildArtistChips(
                                          context: context,
                                          artists: _resolveArtists(details),
                                          textStyle: textTheme.bodyMedium
                                              ?.copyWith(
                                                color: colors.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                          dimStyle: textTheme.bodyMedium
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                              ),
                                        ),
                                        if (details.year != null)
                                          Text(
                                            ' • ${details.year}',
                                            style: textTheme.bodySmall
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      l10n.playlistsSongCount(songs.length),
                                      style: textTheme.labelSmall?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: colors.outlineVariant,
                          ),
                          Expanded(
                            child: CustomScrollView(
                              slivers: <Widget>[
                                toolbarSliver,
                                filterSliver,
                                tracksSliver,
                                albumInfoSliver,
                                if (ref.watch(audioMuseAvailableProvider))
                                  SliverToBoxAdapter(
                                    child: _AudioMuseSimilarAlbums(
                                      albumId: widget.albumId,
                                    ),
                                  ),
                                const SliverToBoxAdapter(
                                  child: SizedBox(height: 16),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              }

              final screenWidth = MediaQuery.of(context).size.width;
              final mobileColors = Theme.of(context).colorScheme;
              final mobileTextTheme = Theme.of(context).textTheme;
              // Keep _screenWidth in sync so the scroll listener can compute progress.
              _screenWidth = screenWidth;

              // Album name opacity fades out as the header collapses (gone by 90% scroll).
              final gradientScrollFade = ((0.9 - _headerProgress) / 0.3).clamp(
                0.0,
                1.0,
              );
              // Toolbar title fades in during the last 20% of the collapse.
              final toolbarTitleOpacity = ((_headerProgress - 0.8) / 0.2).clamp(
                0.0,
                1.0,
              );

              return CustomScrollView(
                controller: _scrollController,
                slivers: <Widget>[
                  // Full-bleed album art with scroll-driven collapsed toolbar.
                  SliverAppBar(
                    key: const ValueKey<String>(
                      'albumDetailMobileExpandedArtAppBar',
                    ),
                    automaticallyImplyLeading: false,
                    pinned: true,
                    toolbarHeight: kToolbarHeight,
                    expandedHeight: screenWidth,
                    backgroundColor: Color.lerp(
                      Colors.transparent,
                      mobileColors.surfaceContainerHighest,
                      _headerProgress,
                    ),
                    systemOverlayStyle: SystemUiOverlayStyle.light,
                    leading: _buildAnimatedNavButton(
                      icon: Icons.arrow_back,
                      onPressed: () => context.pop(),
                    ),
                    actions: <Widget>[
                      _buildAnimatedNavButton(
                        icon: Icons.refresh,
                        isLoading: _isRefreshingAlbum,
                        onPressed: _isRefreshingAlbum ? null : _refreshAlbum,
                      ),
                    ],
                    title: Opacity(
                      opacity: toolbarTitleOpacity,
                      child: Text(
                        details.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    flexibleSpace: FlexibleSpaceBar(
                      collapseMode: CollapseMode.pin,
                      background: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          // Hero with a custom shuttle that includes the
                          // gradient + album name so they're visible inside
                          // the Navigator overlay during the hero flight.
                          // The child (CoverArtImage) is what renders when
                          // the page is at rest (no animation in progress).
                          Hero(
                            tag: coverArtHeroTag,
                            transitionOnUserGestures: true,
                            flightShuttleBuilder:
                                (
                                  flightContext,
                                  animation,
                                  flightDirection,
                                  fromHeroContext,
                                  toHeroContext,
                                ) {
                                  final bgColor = Theme.of(
                                    context,
                                  ).scaffoldBackgroundColor;
                                  // Push: gradient+name fade IN  (0→1)
                                  // Pop:  gradient+name fade OUT (1→0)
                                  final overlayOpacity =
                                      flightDirection ==
                                          HeroFlightDirection.push
                                      ? animation
                                      : Tween<double>(
                                          begin: 1.0,
                                          end: 0.0,
                                        ).animate(animation);
                                  return AnimatedBuilder(
                                    animation: overlayOpacity,
                                    builder: (ctx, _) => Stack(
                                      fit: StackFit.expand,
                                      children: <Widget>[
                                        CoverArtImage(
                                          coverArtId: details.coverArt,
                                          size: kCoverArtStandardSize,
                                          lockedSize: kCoverArtStandardSize,
                                          width: double.infinity,
                                          isExternalSource: details.isExternal,
                                          height: double.infinity,
                                          fit: BoxFit.cover,
                                          fadeInDuration: Duration.zero,
                                          showLoadingPlaceholder: false,
                                        ),
                                        Positioned.fill(
                                          child: Opacity(
                                            opacity: overlayOpacity.value,
                                            child: DecoratedBox(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.topCenter,
                                                  end: Alignment.bottomCenter,
                                                  colors: <Color>[
                                                    Colors.transparent,
                                                    Colors.transparent,
                                                    bgColor,
                                                  ],
                                                  stops: const <double>[
                                                    0.0,
                                                    0.60,
                                                    0.85,
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          bottom: 16,
                                          left: 16,
                                          right: 16,
                                          child: Opacity(
                                            opacity: overlayOpacity.value,
                                            child: Text(
                                              details.name,
                                              style: mobileTextTheme
                                                  .displayMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                    shadows: <Shadow>[
                                                      Shadow(
                                                        color: Colors.black
                                                            .withValues(
                                                              alpha: 0.55,
                                                            ),
                                                        blurRadius: 12,
                                                        offset: const Offset(
                                                          0,
                                                          2,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                              textAlign: TextAlign.center,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                            child: CoverArtImage(
                              coverArtId: details.coverArt,
                              size: kCoverArtStandardSize,
                              width: double.infinity,
                              height: double.infinity,
                              isExternalSource: details.isExternal,
                              fit: BoxFit.cover,
                              fadeInDuration: Duration.zero,
                              showLoadingPlaceholder: false,
                            ),
                          ),
                          // Gradient and name below are for when the hero is
                          // at rest (no flight active). They seamlessly match
                          // the shuttle so there is no visible transition.
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: <Color>[
                                    Colors.transparent,
                                    Colors.transparent,
                                    Theme.of(context).scaffoldBackgroundColor,
                                  ],
                                  stops: const <double>[0.0, 0.60, 0.85],
                                ),
                              ),
                            ),
                          ),
                          // Album name — fades out as header collapses.
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: Opacity(
                              opacity: gradientScrollFade,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  16,
                                ),
                                child: Text(
                                  details.name,
                                  style: mobileTextTheme.displayMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        shadows: <Shadow>[
                                          Shadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.55,
                                            ),
                                            blurRadius: 12,
                                            offset: const Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // Artist names (each individually clickable) + year inline
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            runSpacing: 2,
                            children: <Widget>[
                              ..._buildArtistChips(
                                context: context,
                                artists: _resolveArtists(details),
                                textStyle: mobileTextTheme.bodyLarge?.copyWith(
                                  color: mobileColors.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                                dimStyle: mobileTextTheme.bodyLarge?.copyWith(
                                  color: mobileColors.onSurfaceVariant,
                                ),
                              ),
                              if (details.year != null)
                                Text(
                                  ' • ${details.year}',
                                  style: mobileTextTheme.bodyMedium?.copyWith(
                                    color: mobileColors.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // Action buttons:
                        //   Left  — play (icon), shuffle (icon), Rate (text)
                        //   Right — like (icon), 3-dot context menu
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              IconButton(
                                icon: const Icon(Icons.play_arrow),
                                onPressed: filteredSongs.isEmpty
                                    ? null
                                    : () => _queueAlbum(
                                        filteredSongs,
                                        shuffle: false,
                                      ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.shuffle),
                                onPressed: filteredSongs.isEmpty
                                    ? null
                                    : () => _queueAlbum(
                                        filteredSongs,
                                        shuffle: true,
                                      ),
                              ),
                              _RatingButton(
                                rating: albumRating,
                                loading: _isUpdatingRating,
                                onChanged: (next) =>
                                    unawaited(_updateAlbumRating(next)),
                              ),
                              const Spacer(),
                              IconButton(
                                icon: Icon(
                                  isStarred
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                ),
                                color: isStarred ? mobileColors.error : null,
                                onPressed: _isStarring
                                    ? null
                                    : () => _toggleStar(isStarred: isStarred),
                              ),
                              IconButton(
                                icon: const Icon(Icons.more_vert),
                                onPressed: () => unawaited(
                                  _showMobileAlbumContextMenu(
                                    details,
                                    filteredSongs,
                                    albumRating,
                                    coverArtHeroTag,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Filter label
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                          child: Row(
                            children: <Widget>[
                              Icon(
                                Icons.filter_list,
                                size: 16,
                                color: mobileColors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                l10n.albumDetailFilterLabel,
                                style: mobileTextTheme.labelSmall?.copyWith(
                                  color: mobileColors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Filter chips (compact)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: Wrap(
                            spacing: 6,
                            children: <Widget>[
                              FilterChip(
                                visualDensity: VisualDensity.compact,
                                label: Text(l10n.libraryLikedOnlyFilter),
                                avatar: Icon(
                                  _showLikedOnly
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 16,
                                ),
                                selected: _showLikedOnly,
                                onSelected: (value) =>
                                    setState(() => _showLikedOnly = value),
                              ),
                              FilterChip(
                                visualDensity: VisualDensity.compact,
                                label: Text(
                                  l10n.libraryDownloadedOnlyFilter,
                                ),
                                avatar: Icon(
                                  _showDownloadedOnly
                                      ? Icons.download_done
                                      : Icons.download_outlined,
                                  size: 16,
                                ),
                                selected: _showDownloadedOnly,
                                onSelected: (value) => setState(
                                  () => _showDownloadedOnly = value,
                                ),
                              ),
                            ],
                          ),
                        ),
                        albumInfoAsync.when(
                          data: (info) {
                            if (info == null) {
                              return const SizedBox.shrink();
                            }
                            final notes = _stripHtml(info.notes ?? '');
                            final hasNotes = notes.trim().isNotEmpty;
                            final hasLinks =
                                (info.lastFmUrl ?? '').trim().isNotEmpty ||
                                (info.musicBrainzId ?? '').trim().isNotEmpty;
                            if (!hasNotes && !hasLinks) {
                              return const SizedBox.shrink();
                            }

                            return Padding(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                0,
                                12,
                                12,
                              ),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        l10n.albumDetailAboutSection,
                                        style: mobileTextTheme.titleSmall,
                                      ),
                                      if (hasNotes) ...<Widget>[
                                        const SizedBox(height: 8),
                                        Text(
                                          notes,
                                          style: mobileTextTheme.bodyMedium,
                                        ),
                                      ],
                                      if (hasLinks) ...<Widget>[
                                        const SizedBox(height: 10),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: <Widget>[
                                            if ((info.lastFmUrl ?? '')
                                                .trim()
                                                .isNotEmpty)
                                              ActionChip(
                                                avatar: const Icon(
                                                  Icons.open_in_new,
                                                  size: 16,
                                                ),
                                                label: Text(
                                                  l10n.albumDetailLastFm,
                                                ),
                                                onPressed: () => unawaited(
                                                  _openExternalLink(
                                                    info.lastFmUrl!,
                                                  ),
                                                ),
                                              ),
                                            if ((info.musicBrainzId ?? '')
                                                .trim()
                                                .isNotEmpty)
                                              ActionChip(
                                                avatar: const Icon(
                                                  Icons.album_outlined,
                                                  size: 16,
                                                ),
                                                label: Text(
                                                  l10n.albumDetailMusicBrainz,
                                                ),
                                                onPressed: () => unawaited(
                                                  _openExternalLink(
                                                    'https://musicbrainz.org/release-group/${info.musicBrainzId}',
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                          loading: () => const SizedBox.shrink(),
                          error: (_, _) => const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                  tracksSliver,
                  if (ref.watch(audioMuseAvailableProvider))
                    SliverToBoxAdapter(
                      child: _AudioMuseSimilarAlbums(
                        albumId: widget.albumId,
                      ),
                    ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 16),
                  ),
                ],
              );
            },
            loading: () => const ShimmerListPage(count: 8, leadingSize: 56),
            error: (error, _) => ErrorState(
              title: l10n.albumDetailLoadErrorTitle,
              message: error.toString(),
              onRetry: () => ref.invalidate(albumProvider(widget.albumId)),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: _isRefreshingAlbum ? 1 : 0,
              child: const LinearProgressIndicator(minHeight: 2),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshAlbum() async {
    if (_isRefreshingAlbum) {
      return;
    }
    await HapticFeedback.lightImpact();
    setState(() => _isRefreshingAlbum = true);
    try {
      final result = await ref
          .read(librarySyncControllerProvider.notifier)
          .requestTarget(LibrarySyncTarget.album(widget.albumId));
      if (result.status == LibrarySyncStatus.failed) {
        throw StateError(result.errorMessage ?? 'Album refresh failed.');
      }
      ref.invalidate(albumInfoProvider(widget.albumId));
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showAppNotice(
        context,
        message: error.toString(),
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isRefreshingAlbum = false);
      }
    }
  }

  void _queueAlbum(
    List<SongsTableData> songs, {
    required bool shuffle,
  }) {
    if (songs.isEmpty) {
      return;
    }

    final songsToQueue = List<SongsTableData>.of(songs);
    if (shuffle) {
      songsToQueue.shuffle(Random());
    }
    ref
        .read(queueProvider.notifier)
        .fireAndForget(
          () => ref
              .read(queueProvider.notifier)
              .replaceWithTableData(songsToQueue),
          label: 'replace',
        );
  }

  void _playNow(SongsTableData song) {
    final queueFullAlbum = ref.read(albumQueueEnabledProvider);
    if (queueFullAlbum && _currentFilteredSongs.length > 1) {
      final startIndex = _currentFilteredSongs.indexWhere(
        (s) => s.id == song.id,
      );
      final effectiveIndex = startIndex < 0 ? 0 : startIndex;
      ref
          .read(queueProvider.notifier)
          .fireAndForget(
            () => ref
                .read(queueProvider.notifier)
                .replaceWithTableData(
                  _currentFilteredSongs,
                  startIndex: effectiveIndex,
                  autoPlay: true,
                ),
            label: 'playNow',
          );
    } else {
      ref
          .read(queueProvider.notifier)
          .fireAndForget(
            () => ref.read(queueProvider.notifier).replaceWithTableData(
              <SongsTableData>[song],
              autoPlay: true,
            ),
            label: 'playNow',
          );
    }
  }

  void _playNext(SongsTableData song) {
    final l10n = AppLocalizations.of(context)!;
    ref
        .read(queueProvider.notifier)
        .fireAndForget(
          () => ref.read(queueProvider.notifier).playNext(song.id),
          label: 'playNext',
        );
    // Optimistic success feedback — the action is non-blocking now.
    showAppNotice(
      context,
      message: l10n.librarySongPlayNextQueued(song.title),
      level: AppNoticeLevel.success,
    );
  }

  Future<void> _showSongActions(SongsTableData song) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final l10n = AppLocalizations.of(this.context)!;
        final maxHeight = MediaQuery.of(context).size.height * 0.85;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.play_arrow_outlined),
                    title: Text(l10n.librarySongMenuPlayNow),
                    onTap: () {
                      Navigator.of(context).pop();
                      _playNow(song);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.queue_music_outlined),
                    title: Text(l10n.librarySongMenuAddToQueue),
                    onTap: () {
                      Navigator.of(context).pop();
                      ref
                          .read(queueProvider.notifier)
                          .fireAndForget(
                            () => ref.read(queueProvider.notifier).add(song.id),
                            label: 'addToQueue',
                          );
                      // Optimistic success feedback.
                      showAppNotice(
                        this.context,
                        message: l10n.librarySongAddedToQueue(song.title),
                        level: AppNoticeLevel.success,
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.playlist_add_outlined),
                    title: Text(l10n.librarySongMenuPlayNext),
                    onTap: () {
                      Navigator.of(context).pop();
                      _playNext(song);
                    },
                  ),
                  Consumer(
                    builder: (_, likeRef, _) {
                      final isLiked =
                          likeRef
                              .watch(songStarredProvider(song.id))
                              .asData
                              ?.value ??
                          song.starred != null;
                      return ListTile(
                        leading: Icon(
                          isLiked ? Icons.favorite : Icons.favorite_border,
                        ),
                        title: Text(
                          isLiked ? l10n.actionLiked : l10n.actionLike,
                        ),
                        onTap: () {
                          unawaited(
                            toggleSongStar(song.id, ref).catchError((_) {
                              if (this.context.mounted) {
                                showAppNotice(
                                  this.context,
                                  message: l10n.albumDetailStarFailure,
                                  level: AppNoticeLevel.error,
                                );
                              }
                            }),
                          );
                        },
                      );
                    },
                  ),
                  Consumer(
                    builder: (_, ratingRef, _) {
                      final rating = ratingRef
                          .watch(songRatingProvider(song.id))
                          .asData
                          ?.value;
                      return ListTile(
                        leading: const Icon(Icons.star_outline),
                        title: Text(l10n.ratingTitle),
                        subtitle: Text(l10n.ratingHint),
                        trailing: RatingWidget(
                          rating: rating,
                          compact: true,
                          onChanged: (int next) {
                            unawaited(
                              setSongRating(song.id, next, ref).catchError((_) {
                                if (this.context.mounted) {
                                  showAppNotice(
                                    this.context,
                                    message: l10n.ratingUpdateFailed,
                                    level: AppNoticeLevel.error,
                                  );
                                }
                              }),
                            );
                          },
                        ),
                      );
                    },
                  ),
                  if (song.artistId != null && song.artistId!.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(l10n.librarySongMenuOpenArtist),
                      onTap: () {
                        Navigator.of(context).pop();
                        NavService.openArtistDetail(
                          this.context,
                          ref,
                          song.artistId!,
                        );
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: Text(l10n.librarySongMenuAddToPlaylist),
                    onTap: () {
                      Navigator.of(context).pop();
                      showAddToPlaylistSheet(
                        this.context,
                        ref,
                        [song.id],
                      );
                    },
                  ),
                  Consumer(
                    builder: (_, menuRef, _) {
                      final downloadState = menuRef.watch(
                        songDownloadStateProvider(song.id),
                      );
                      final isDownloaded =
                          downloadState.status == SongDownloadStatus.downloaded;
                      if (isDownloaded) {
                        return ListTile(
                          leading: Icon(
                            Icons.delete_outline,
                            color: Theme.of(this.context).colorScheme.error,
                          ),
                          title: Text(
                            l10n.deleteDownloadAction,
                            style: TextStyle(
                              color: Theme.of(this.context).colorScheme.error,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            unawaited(_deleteDownload(song));
                          },
                        );
                      }
                      return ListTile(
                        leading: const Icon(Icons.download_outlined),
                        title: Text(l10n.downloadAction),
                        onTap: () {
                          Navigator.of(context).pop();
                          unawaited(_downloadSong(song));
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _deleteDownload(SongsTableData song) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.downloadsRemoveConfirmTitle),
        content: Text(l10n.downloadsRemoveConfirmContent),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.downloadsRemoveAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(downloadServiceProvider).removeDownloadedTrack(song.id);
  }

  Future<void> _downloadSong(SongsTableData song) async {
    final choice = await showDownloadQualitySheet(context);
    if (choice == null || !mounted) return;

    final service = ref.read(downloadServiceProvider);
    // Fire-and-forget — the service handles errors internally.
    unawaited(
      service.enqueueSong(
        song.id,
        albumId: widget.albumId,
        quality: choice.quality,
        format: choice.format,
      ),
    );
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showAppNotice(
      context,
      message: l10n.downloadSongQueued,
      level: AppNoticeLevel.success,
    );
  }

  Future<void> _toggleStar({required bool isStarred}) async {
    final l10n = AppLocalizations.of(context)!;
    final api = ref.read(subsonicApiProvider);
    if (api == null) {
      return;
    }

    // Optimistic local update — flip the icon immediately, block re-taps.
    setState(() {
      _isStarred = !isStarred;
      _isStarring = true;
    });

    // Optimistic DB update BEFORE the API call — fires Drift stream
    // immediately so library/home screens watching liked albums/songs update
    // without waiting ~300 ms for the server round-trip.
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    await dao.updateAlbumStarred(
      widget.albumId,
      isStarred ? null : DateTime.now(),
    );

    try {
      if (isStarred) {
        await api.unstar(widget.albumId);
      } else {
        await api.star(widget.albumId);
      }
      if (!mounted) {
        return;
      }
      // DB already updated above — nothing more to do on success.
    } on SubsonicConnectionException {
      // Offline — the optimistic DB state is kept; just queue for server sync.
      if (!mounted) return;
      await ref
          .read(navisDatabaseProvider)
          .starSyncDao
          .queueStarAction(
            itemId: widget.albumId,
            itemType: 'album',
            action: isStarred ? 'unstar' : 'star',
          );
    } on Object {
      // API error — rollback both the optimistic local and DB state.
      if (!mounted) {
        return;
      }
      await dao.updateAlbumStarred(
        widget.albumId,
        isStarred ? DateTime.now() : null,
      );
      setState(() => _isStarred = isStarred);
      showAppNotice(
        context,
        message: l10n.albumDetailStarFailure,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isStarring = false);
      }
    }
  }

  Future<void> _updateAlbumRating(int rating) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isUpdatingRating = true);
    try {
      await setAlbumRating(widget.albumId, rating, ref);
    } on Object {
      if (!mounted) {
        return;
      }
      showAppNotice(
        context,
        message: l10n.ratingUpdateFailed,
        level: AppNoticeLevel.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isUpdatingRating = false);
      }
    }
  }

  Future<void> _openExternalLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _stripHtml(String input) {
    return input
        .replaceAll(RegExp('<[^>]+>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Returns the authoritative artist list for [details].
  ///
  /// Prefers the OpenSubsonic `artists` list (populated after a full sync on
  /// servers that support the extension). Falls back to splitting the legacy
  /// `artistName` string (e.g. "Artist A & Artist B, Artist C") into individual
  /// entries, all linked to `artistId`. As a last resort returns a single entry.
  List<ArtistRef> _resolveArtists(AlbumsTableData details) {
    if (details.artists.isNotEmpty) return details.artists;
    final id = details.artistId;
    final name = details.artistName;
    if (id == null || id.isEmpty || name == null || name.isEmpty) {
      return const [];
    }
    // Try to split compound names ("Artist A & Artist B", "Artist A feat. B").
    final segments = _parseArtistSegments(name);
    final nameSegments = segments
        .where((s) => !s.$2)
        .map((s) => ArtistRef(id: id, name: s.$1))
        .toList(growable: false);
    return nameSegments.isNotEmpty
        ? nameSegments
        : [ArtistRef(id: id, name: name)];
  }

  /// Splits [name] into alternating (text, isDelimiter) pairs so each artist
  /// name segment can be rendered as its own tappable widget.
  ///
  /// Recognised separators: `,`, ` & `, ` feat.`, ` ft.`, ` with `.
  static List<(String text, bool isDelimiter)> _parseArtistSegments(
    String name,
  ) {
    final result = <(String, bool)>[];
    final sep = RegExp(
      r'\s*(?:,\s*|&|feat\.?|ft\.?|with)\s*',
      caseSensitive: false,
    );
    var last = 0;
    for (final match in sep.allMatches(name)) {
      if (match.start > last) {
        final seg = name.substring(last, match.start).trim();
        if (seg.isNotEmpty) result.add((seg, false));
      }
      result.add((match.group(0)!, true));
      last = match.end;
    }
    if (last < name.length) {
      final seg = name.substring(last).trim();
      if (seg.isNotEmpty) result.add((seg, false));
    }
    return result;
  }

  /// Builds [Widget]s for a [Wrap] where each artist is individually tappable.
  ///
  /// Separators (`' & '`) are rendered in [dimStyle] between artists.
  /// When [artists] is empty a plain "Unknown artist" label is returned.
  List<Widget> _buildArtistChips({
    required BuildContext context,
    required List<ArtistRef> artists,
    required TextStyle? textStyle,
    required TextStyle? dimStyle,
  }) {
    if (artists.isEmpty) {
      final fallbackLabel = AppLocalizations.of(
        context,
      )!.albumDetailUnknownArtist;
      return [Text(fallbackLabel, style: dimStyle)];
    }
    final widgets = <Widget>[];
    for (var i = 0; i < artists.length; i++) {
      if (i > 0) {
        widgets.add(Text(' & ', style: dimStyle));
      }
      final artist = artists[i];
      widgets.add(
        InkWell(
          onTap: () => NavService.openArtistDetail(context, ref, artist.id),
          child: Text(artist.name, style: textStyle),
        ),
      );
    }
    return widgets;
  }

  /// Pre-processes [songs] into a flat list of render items.
  /// Inserts [_DiscHeader]s when there are multiple distinct disc numbers.
  List<_AlbumRenderItem> _buildRenderItems(List<SongsTableData> songs) {
    if (songs.isEmpty) return const <_AlbumRenderItem>[];

    final discNumbers = <int>{};
    for (final song in songs) {
      discNumbers.add(song.discNumber ?? 1);
    }
    final isMultiDisc = discNumbers.length > 1;

    if (!isMultiDisc) {
      return songs.map((s) => _SongItem(song: s)).toList(growable: false);
    }

    final items = <_AlbumRenderItem>[];
    int? currentDisc;
    var isFirst = true;
    for (final song in songs) {
      final disc = song.discNumber ?? 1;
      if (disc != currentDisc) {
        items.add(_DiscHeader(discNumber: disc, isFirst: isFirst));
        currentDisc = disc;
        isFirst = false;
      }
      items.add(_SongItem(song: song));
    }
    return items;
  }

  /// A circular nav button used in the mobile SliverAppBar leading/actions slots.
  /// Colors animate with scroll: white over art (expanded) → onSurface over
  /// surface (collapsed), controlled by [_headerProgress].
  Widget _buildAnimatedNavButton({
    required IconData icon,
    required VoidCallback? onPressed,
    bool isLoading = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final iconColor = Color.lerp(
      Colors.white,
      colorScheme.onSurface,
      _headerProgress,
    );
    final circleAlpha = 0.35 * (1.0 - _headerProgress);
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: circleAlpha),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          icon: isLoading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: iconColor,
                  ),
                )
              : Icon(icon, color: iconColor),
          onPressed: onPressed,
        ),
      ),
    );
  }

  /// Bottom-sheet context menu for the mobile album detail screen (3-dot button).
  Future<void> _showMobileAlbumContextMenu(
    AlbumsTableData details,
    List<SongsTableData> songs,
    int? albumRating,
    String coverArtHeroTag,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final l10n = AppLocalizations.of(context)!;
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.85;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // Show album art
                  ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: Text(l10n.albumDetailMenuShowAlbumArt),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(
                        showCoverArtViewer(
                          context,
                          coverArtId: details.coverArt,
                          heroTag: coverArtHeroTag,
                          previewSize: 200,
                          isExternalSource: details.isExternal,
                        ),
                      );
                    },
                  ),
                  // Go to artist (only when artist is known)
                  if (details.artistId != null && details.artistId!.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(l10n.librarySongMenuOpenArtist),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        NavService.openArtistDetail(
                          context,
                          ref,
                          details.artistId!,
                        );
                      },
                    ),
                  // Add to favorites (toggle star)
                  Consumer(
                    builder: (_, favRef, _) {
                      final currentlyStarred =
                          favRef
                              .watch(albumProvider(widget.albumId))
                              .asData
                              ?.value
                              ?.album
                              .starred !=
                          null;
                      return ListTile(
                        leading: Icon(
                          currentlyStarred
                              ? Icons.favorite
                              : Icons.favorite_border,
                        ),
                        title: Text(
                          currentlyStarred ? l10n.actionLiked : l10n.actionLike,
                        ),
                        onTap: () {
                          unawaited(
                            _toggleStar(isStarred: currentlyStarred),
                          );
                        },
                      );
                    },
                  ),
                  // Rating
                  Consumer(
                    builder: (_, ratingRef, _) {
                      final currentRating =
                          ratingRef
                              .watch(albumRatingProvider(widget.albumId))
                              .asData
                              ?.value ??
                          albumRating;
                      return ListTile(
                        leading: const Icon(Icons.star_outline),
                        title: Text(l10n.ratingTitle),
                        subtitle: Text(l10n.ratingHint),
                        trailing: RatingWidget(
                          rating: currentRating,
                          compact: true,
                          onChanged: (next) {
                            unawaited(_updateAlbumRating(next));
                          },
                        ),
                      );
                    },
                  ),
                  // Add to playlist
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: Text(l10n.librarySongMenuAddToPlaylist),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(
                        showAddToPlaylistSheet(
                          context,
                          ref,
                          songs.map((s) => s.id).toList(growable: false),
                        ),
                      );
                    },
                  ),
                  // Download album
                  Consumer(
                    builder: (_, dlRef, _) {
                      final isFullyDownloaded =
                          songs.isNotEmpty &&
                          songs.every(
                            (s) =>
                                dlRef
                                    .watch(songDownloadStateProvider(s.id))
                                    .status ==
                                SongDownloadStatus.downloaded,
                          );
                      if (isFullyDownloaded) {
                        return ListTile(
                          leading: Icon(
                            Icons.delete_outlined,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          title: Text(
                            l10n.deleteDownloadAction,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(
                              _deleteAllAlbumDownloads(context, songs),
                            );
                          },
                        );
                      }
                      return ListTile(
                        leading: const Icon(Icons.download_outlined),
                        title: Text(l10n.albumDetailDownloadAction),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(
                            _downloadAlbumSongs(context),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Downloads all tracks in the current album (same logic as the old inline
  /// download button).
  Future<void> _downloadAlbumSongs(BuildContext ctx) async {
    final choice = await showDownloadQualitySheet(ctx);
    if (choice == null || !ctx.mounted) return;
    final service = ref.read(downloadServiceProvider);
    final count = await service.enqueueAlbum(
      widget.albumId,
      quality: choice.quality,
      format: choice.format,
    );
    if (!ctx.mounted) return;
    final l10n = AppLocalizations.of(ctx)!;
    showAppNotice(
      ctx,
      message: l10n.downloadAlbumQueued(count),
      level: AppNoticeLevel.success,
    );
  }

  /// Shows a confirmation dialog and removes all downloaded tracks in [songs].
  Future<void> _deleteAllAlbumDownloads(
    BuildContext ctx,
    List<SongsTableData> songs,
  ) async {
    if (!ctx.mounted) return;
    final l10n = AppLocalizations.of(ctx)!;
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l10n.downloadsRemoveConfirmTitle),
        content: Text(l10n.downloadsRemoveConfirmContent),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogCtx).colorScheme.error,
              foregroundColor: Theme.of(dialogCtx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(l10n.downloadsRemoveAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(downloadServiceProvider)
        .removeDownloadedTracks(songs.map((song) => song.id));
  }

  Widget _buildDiscHeader(
    BuildContext context,
    AppLocalizations l10n,
    int discNumber,
    bool isFirst,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (!isFirst) const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.album_outlined,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                l10n.albumDetailDiscHeader(discNumber),
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}

class _AudioMuseSimilarAlbums extends ConsumerWidget {
  const _AudioMuseSimilarAlbums({required this.albumId});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncAlbums = ref.watch(audioMuseSimilarAlbumsProvider(albumId));
    return asyncAlbums.when(
      data: (albums) {
        if (albums.isEmpty) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context)!;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    l10n.audioMuseSimilarAlbums,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: albums.map((rec) {
                  return ActionChip(
                    avatar: const Icon(Icons.album, size: 18),
                    label: Text(
                      rec.artist != null
                          ? '${rec.title} — ${rec.artist}'
                          : rec.title,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () =>
                        NavService.openAlbumDetail(context, ref, rec.id),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

// ── Rating button ───────────────────────────────────────────────────────────

/// Collapsed: an outlined button showing "[star] Rate" or "[star] n/5".
/// Expanded: an inline row of 5 tappable stars with hover-fill on desktop.
class _RatingButton extends StatefulWidget {
  const _RatingButton({
    required this.rating,
    required this.onChanged,
    this.loading = false,
  });

  final int? rating;
  final ValueChanged<int> onChanged;
  final bool loading;

  @override
  State<_RatingButton> createState() => _RatingButtonState();
}

class _RatingButtonState extends State<_RatingButton>
    with SingleTickerProviderStateMixin {
  int _hovered = 0;
  late AnimationController _ctrl;
  late Animation<double> _anim;

  // Approximate pill widths (px). Collapsed fits star icon + "Rate"/"3/5".
  static const double _kCollapsedWidth = 92.0;
  // 5 stars × 30px + close (28px) + horizontal padding (2×12) = 202px.
  static const double _kExpandedWidth = 202.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _expand() {
    _ctrl.forward();
  }

  void _collapse() {
    _ctrl.reverse().then((_) {
      if (mounted)
        setState(() {
          _hovered = 0;
        });
    });
  }

  void _confirm(int value) {
    // Tapping the current rating deselects it (sets to 0).
    final next = value == (widget.rating ?? 0) ? 0 : value;
    widget.onChanged(next);
    _collapse();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasRating = (widget.rating ?? 0) > 0;
    final effective = widget.rating ?? 0;

    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final t = _anim.value;
        final w = _kCollapsedWidth + (_kExpandedWidth - _kCollapsedWidth) * t;

        // Collapsed label fades out in the first 40% of the expansion.
        final labelOpacity = (1.0 - t / 0.4).clamp(0.0, 1.0);
        // Stars fade in starting at 30% of the expansion.
        final starsOpacity = ((t - 0.3) / 0.7).clamp(0.0, 1.0);

        final borderColor = hasRating
            ? cs.secondary.withValues(alpha: 0.45)
            : cs.outline.withValues(alpha: 0.5);

        return SizedBox(
          width: w,
          height: 36,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(17),
              child: Material(
                color: Colors.transparent,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // ── Expanded: stars + close ───────────────────────────
                    if (t > 0)
                      Opacity(
                        opacity: starsOpacity,
                        child: OverflowBox(
                          maxWidth: _kExpandedWidth,
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 1; i <= 5; i++)
                                MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  onEnter: (_) => setState(() => _hovered = i),
                                  onExit: (_) => setState(() => _hovered = 0),
                                  child: GestureDetector(
                                    onTap: widget.loading
                                        ? null
                                        : () => _confirm(i),
                                    child: SizedBox(
                                      width: 30,
                                      height: 36,
                                      child: Center(
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 120,
                                          ),
                                          transitionBuilder: (child, anim) =>
                                              ScaleTransition(
                                                scale: anim,
                                                child: child,
                                              ),
                                          child: Icon(
                                            (_hovered > 0
                                                    ? i <= _hovered
                                                    : i <= effective)
                                                ? Icons.star_rounded
                                                : Icons.star_border_rounded,
                                            key: ValueKey(
                                              _hovered > 0
                                                  ? i <= _hovered
                                                  : i <= effective,
                                            ),
                                            size: 20,
                                            color:
                                                (_hovered > 0
                                                    ? i <= _hovered
                                                    : i <= effective)
                                                ? cs.secondary
                                                : cs.onSurfaceVariant
                                                      .withValues(alpha: 0.4),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 2),
                              if (widget.loading)
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: cs.secondary,
                                  ),
                                )
                              else
                                InkResponse(
                                  onTap: _collapse,
                                  radius: 14,
                                  child: Icon(
                                    Icons.close,
                                    size: 14,
                                    color: cs.onSurfaceVariant.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ), // OverflowBox
                      ),
                    // ── Collapsed: label ─────────────────────────────────
                    if (t < 1.0)
                      Opacity(
                        opacity: labelOpacity,
                        child: InkWell(
                          onTap: widget.loading ? null : _expand,
                          borderRadius: BorderRadius.circular(17),
                          child: SizedBox(
                            width: _kCollapsedWidth,
                            height: 36,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  hasRating
                                      ? Icons.star_rounded
                                      : Icons.star_border_rounded,
                                  size: 16,
                                  color: hasRating
                                      ? cs.secondary
                                      : cs.onSurfaceVariant,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  hasRating ? '${widget.rating}/5' : 'Rate',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: hasRating
                                        ? cs.secondary
                                        : cs.onSurfaceVariant,
                                  ),
                                ),
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
      },
    );
  }
}

// ── Render-item types for disc-grouped track lists ─────────────────────────

sealed class _AlbumRenderItem {
  const _AlbumRenderItem();
}

final class _DiscHeader extends _AlbumRenderItem {
  const _DiscHeader({required this.discNumber, required this.isFirst});
  final int discNumber;
  final bool isFirst;
}

final class _SongItem extends _AlbumRenderItem {
  const _SongItem({required this.song});
  final SongsTableData song;
}
