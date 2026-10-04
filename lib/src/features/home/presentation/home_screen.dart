import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:intl/intl.dart' show DateFormat;
import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/common_widgets/adaptive_track_row.dart';
import 'package:navis/src/common_widgets/content_shelf.dart';
import 'package:navis/src/common_widgets/mouse_drag_scroll.dart';
import 'package:navis/src/routing/content_layout.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport, RenderBox;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop_song_actions.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/entity_action_bar.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/navis_section_header.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/changelog/presentation/changelog_discovery_card.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';
import 'package:navis/src/features/home/presentation/cover_colour_field.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/home/presentation/home_scroll_provider.dart';
import 'package:navis/src/features/home/presentation/recommendation_auto_advance.dart';
import 'package:navis/src/routing/home_activity_scope.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart'
    show quickSearchOverlayVisibleProvider;
import 'package:navis/src/features/home/presentation/listenbrainz_playlist_artwork.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/liked_playback_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:navis/src/theme/artwork_shape.dart';

export 'package:navis/src/features/home/domain/home_section_ids.dart';

part 'home_support_widgets.dart';
part 'you_might_like_widgets.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const new({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class ListenBrainzWeeklyDetailScreen extends ConsumerStatefulWidget {
  const new({required this.sourcePatch, super.key});

  final String sourcePatch;

  @override
  ConsumerState<ListenBrainzWeeklyDetailScreen> createState() =>
      _ListenBrainzWeeklyDetailScreenState();
}

class _ListenBrainzWeeklyDetailScreenState
    extends ConsumerState<ListenBrainzWeeklyDetailScreen> {
  ListenBrainzDiscoverPlaylist? _cachedPlaylist;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playlistsAsync = ref.watch(listenBrainzDiscoverStreamProvider);
    final playlists = playlistsAsync.asData?.value;
    final latest = playlists
        ?.where(
          (playlist) => playlist.playlist.sourcePatch == widget.sourcePatch,
        )
        .firstOrNull;
    if (latest != null) {
      _cachedPlaylist = latest;
    }
    final playlist = latest ?? _cachedPlaylist;
    final title = switch (widget.sourcePatch) {
      'weekly-jams' => l10n.weeklyPlaylistJamsTitle,
      'weekly-exploration' => l10n.weeklyPlaylistExplorationTitle,
      _ => l10n.weeklyPlaylistTitle,
    };
    final adaptiveContext = resolveAdaptiveContextFor(context);

    final Widget body;
    if (playlist != null) {
      body = _ListenBrainzWeeklyDetailContent(
        key: ValueKey<String>('listenbrainz-weekly-${widget.sourcePatch}'),
        playlist: playlist,
      );
    } else if (playlistsAsync.hasError) {
      body = ErrorState(
        title: l10n.weeklyPlaylistLoadError,
        onRetry: () {
          ref
              .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
              .refreshFull();
        },
      );
    } else if (playlistsAsync.hasValue) {
      body = EmptyState(
        icon: Icons.auto_awesome_outlined,
        title: l10n.weeklyPlaylistUnavailableTitle,
        subtitle: l10n.weeklyPlaylistUnavailableSubtitle,
        action: FilledButton.tonal(
          onPressed: () {
            ref
                .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
                .refreshFull();
          },
          child: Text(l10n.commonRetry),
        ),
      );
    } else {
      body = const ShimmerListPage(count: 8, leadingSize: 56);
    }

    return Scaffold(
      appBar: (adaptiveContext.useDesktopShell || playlist == null)
          ? AppBar(
              title: adaptiveContext.useDesktopShell && playlist != null
                  ? null
                  : Text(title),
            )
          : null,
      body: body,
    );
  }
}

class _ListenBrainzWeeklyDetailContent extends ConsumerStatefulWidget {
  const new({required this.playlist, super.key});

  final ListenBrainzDiscoverPlaylist playlist;

  @override
  ConsumerState<_ListenBrainzWeeklyDetailContent> createState() =>
      _ListenBrainzWeeklyDetailContentState();
}

class _ListenBrainzWeeklyDetailContentState
    extends ConsumerState<_ListenBrainzWeeklyDetailContent> {
  DownloadQualityChoice? _pendingDownloadChoice;
  final Set<String> _downloadIntentQueuedSongIds = <String>{};
  final ScrollController _scrollController = ScrollController();
  double _headerProgress = 0;
  double _screenWidth = 0;

  ListenBrainzDiscoverPlaylist get playlist => widget.playlist;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ListenBrainzWeeklyDetailContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.playlist.identifier !=
        widget.playlist.playlist.identifier) {
      _pendingDownloadChoice = null;
      _downloadIntentQueuedSongIds.clear();
    }
  }

  void _onScroll() {
    final maxScroll = math.max(1, _screenWidth - kToolbarHeight).toDouble();
    final newProgress = (_scrollController.offset / maxScroll)
        .clamp(0, 1)
        .toDouble();
    if ((newProgress - _headerProgress).abs() > 0.001) {
      setState(() => _headerProgress = newProgress);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textTheme = theme.textTheme;
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final serverSongs = _serverSongs;
    _enqueuePendingDownloads(serverSongs);

    if (adaptiveContext.useDesktopShell) {
      const artSize = 260.0;
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
              ColoredBox(
                key: const ValueKey<String>('albumDetailDesktopHeader'),
                color: colors.surfaceContainerHigh,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      SizedBox.square(
                        dimension: artSize,
                        child: _ListenBrainzArtwork(
                          playlist: playlist,
                          size: artSize,
                        ),
                      ),
                      const SizedBox(width: 28),
                      Expanded(
                        child: _VirtualAlbumHeaderText(
                          playlist: playlist,
                          textAlign: TextAlign.start,
                          titleStyle: textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            height: 1.1,
                          ),
                          metadataStyle: textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                          actions: _buildActions(serverSongs),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
              Expanded(
                child: CustomScrollView(
                  slivers: <Widget>[
                    _buildTrackSliver(compact: false),
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (adaptiveContext.useCompactWideLandscape) {
      return SafeArea(
        left: false,
        right: false,
        child: Row(
          key: const ValueKey<String>('albumDetailCompactWideSplitPane'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: 236,
              child: Material(
                color: colors.surfaceContainerHigh,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      IconButton(
                        tooltip: MaterialLocalizations.of(context)
                            .backButtonTooltip,
                        onPressed: () => NavService.back(context),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const SizedBox(height: 4),
                      Center(
                        child: SizedBox.square(
                          dimension: 168,
                          child: _ListenBrainzArtwork(
                            playlist: playlist,
                            size: 168,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _VirtualAlbumHeaderText(
                        playlist: playlist,
                        textAlign: TextAlign.start,
                        titleStyle: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                        ),
                        metadataStyle: textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                        compact: true,
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
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 8, 2),
                      child: _buildActions(serverSongs, iconOnly: true),
                    ),
                  ),
                  _buildTrackSliver(compact: true),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final screenWidth = MediaQuery.sizeOf(context).width;
    _screenWidth = screenWidth;
    final gradientScrollFade = ((0.9 - _headerProgress) / 0.3).clamp(0.0, 1.0);
    final toolbarTitleOpacity = ((_headerProgress - 0.8) / 0.2).clamp(0.0, 1.0);

    return CustomScrollView(
      controller: _scrollController,
      slivers: <Widget>[
        SliverAppBar(
          key: const ValueKey<String>('albumDetailMobileExpandedArtAppBar'),
          automaticallyImplyLeading: false,
          pinned: true,
          toolbarHeight: kToolbarHeight,
          expandedHeight: screenWidth,
          backgroundColor: Color.lerp(
            Colors.transparent,
            colors.surfaceContainerHighest,
            _headerProgress,
          ),
          systemOverlayStyle: SystemUiOverlayStyle.light,
          leading: _buildAnimatedNavButton(
            icon: Icons.arrow_back,
            onPressed: () => NavService.back(context),
          ),
          title: Opacity(
            opacity: toolbarTitleOpacity,
            child: Text(
              playlist.localizedTitle(AppLocalizations.of(context)!),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          flexibleSpace: FlexibleSpaceBar(
            collapseMode: CollapseMode.pin,
            background: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _ListenBrainzArtwork(playlist: playlist, size: screenWidth),
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
                        stops: const <double>[0, 0.60, 0.85],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Opacity(
                    opacity: gradientScrollFade,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        playlist.localizedTitle(AppLocalizations.of(context)!),
                        style: textTheme.displayMedium?.copyWith(
                          color: Colors.white,
                          shadows: <Shadow>[
                            Shadow(
                              color: Colors.black.withValues(alpha: 0.55),
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: _VirtualAlbumHeaderText(
              playlist: playlist,
              showTitle: false,
              titleStyle: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
              metadataStyle: textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              actions: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: _buildActions(serverSongs),
              ),
            ),
          ),
        ),
        _buildTrackSliver(compact: false),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _buildAnimatedNavButton({
    required IconData icon,
    required VoidCallback? onPressed,
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
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: Icon(icon, color: iconColor),
          onPressed: onPressed,
        ),
      ),
    );
  }

  List<SongsTableData> get _serverSongs => playlist.recommendations
      .where((recommendation) => recommendation.hasServerSong)
      .map((recommendation) => recommendation.tableSong!)
      .toList(growable: false);

  String get _playlistSourcePatch =>
      playlist.playlist.sourcePatch?.trim() ?? '';

  bool get _playlistIsMatching {
    final sourcePatch = _playlistSourcePatch;
    return sourcePatch.isNotEmpty &&
        ref
            .watch(listenBrainzPlaylistRematchControllerProvider)
            .contains(sourcePatch);
  }

  Widget _buildActions(
    List<SongsTableData> serverSongs, {
    bool iconOnly = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // Play and Shuffle include remote matches; only songs on the server can
    // be downloaded.
    final playableSongs = playlist.playableSongs;
    final sourcePatch = _playlistSourcePatch;
    final canMatch = sourcePatch.isNotEmpty && !_playlistIsMatching;
    if (iconOnly) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('weeklyPlayButton'),
            tooltip: l10n.albumDetailPlayAction,
            icon: const Icon(Icons.play_arrow),
            onPressed: playableSongs.isEmpty
                ? null
                : () => _queueSongs(playableSongs, shuffle: false),
          ),
          IconButton(
            tooltip: l10n.albumDetailShuffleAction,
            icon: const Icon(Icons.shuffle),
            onPressed: playableSongs.isEmpty
                ? null
                : () => _queueSongs(playableSongs, shuffle: true),
          ),
          IconButton(
            tooltip: l10n.albumDetailDownloadAction,
            icon: const Icon(Icons.download_outlined),
            onPressed: serverSongs.isEmpty ? null : _downloadVirtualAlbum,
          ),
          IconButton(
            tooltip: l10n.weeklyPlaylistMatchAction,
            icon: _playlistIsMatching
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
            onPressed: canMatch ? _rematchPlaylist : null,
          ),
        ],
      );
    }

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        FilledButton.icon(
          key: const ValueKey<String>('weeklyPlayButton'),
          onPressed: playableSongs.isEmpty
              ? null
              : () => _queueSongs(playableSongs, shuffle: false),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(l10n.albumDetailPlayAction),
        ),
        FilledButton.tonalIcon(
          onPressed: playableSongs.isEmpty
              ? null
              : () => _queueSongs(playableSongs, shuffle: true),
          icon: const Icon(Icons.shuffle_rounded),
          label: Text(l10n.albumDetailShuffleAction),
        ),
        OutlinedButton.icon(
          onPressed: serverSongs.isEmpty ? null : _downloadVirtualAlbum,
          icon: const Icon(Icons.download_outlined),
          label: Text(l10n.albumDetailDownloadAction),
        ),
        OutlinedButton.icon(
          onPressed: canMatch ? _rematchPlaylist : null,
          icon: _playlistIsMatching
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync_rounded),
          label: Text(l10n.weeklyPlaylistMatchAction),
        ),
      ],
    );
  }

  SliverList _buildTrackSliver({required bool compact}) {
    return SliverList.builder(
      itemCount: playlist.recommendations.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return AdaptiveTrackHeader(
            numberColumnExtent: 32,
            leadingExtent: 32,
            leadingGap: 6,
            actionExtent: 96,
            padding: compact
                ? const EdgeInsetsDirectional.only(start: 8, end: 4)
                : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          );
        }
        final recommendation = playlist.recommendations[index - 1];
        final tableSong = recommendation.tableSong;
        // Keyed by recommendation for the clone-only weeklyLastRow action.
        final rowKey = ValueKey<String>('weekly-row-${index - 1}');
        if (recommendation.hasServerSong && tableSong != null) {
          return TrackListTile(
            key: rowKey,
            song: tableSong.copyWith(track: Value(index)),
            contentPadding: compact
                ? const EdgeInsetsDirectional.only(start: 8, end: 4)
                : null,
            horizontalTitleGap: 6,
            actionExtent: 96,
            onTap: () => _playRecommendation(index - 1),
            onLongPress: () => showSongContextMenu(context, ref, tableSong),
            onSecondaryTapDown: (details) => showSongContextMenu(
              context,
              ref,
              tableSong,
              anchor: details.globalPosition,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 48,
                  height: 48,
                  child: SongDownloadStatusIcon(
                    songId: tableSong.id,
                    onDownload: () => _downloadSong(tableSong),
                  ),
                ),
                Builder(
                  builder: (buttonContext) => IconButton(
                    tooltip: MaterialLocalizations.of(buttonContext)
                        .showMenuTooltip,
                    icon: const Icon(Icons.more_vert),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () => showSongContextMenu(
                      context,
                      ref,
                      tableSong,
                      anchor: _menuAnchorFor(buttonContext),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return _ListenBrainzRecommendationTile(
          key: rowKey,
          recommendation: recommendation,
          index: index,
          contentPadding: compact
              ? const EdgeInsetsDirectional.only(start: 8, end: 4)
              : null,
          horizontalTitleGap: 6,
          onPlay: (_) => _playRecommendation(index - 1),
          onSearch: (track) {
            NavService.openSearch(
              context,
              ref,
              '${track.title} ${track.creator ?? ''}'.trim(),
            );
          },
        );
      },
    );
  }

  Offset? _menuAnchorFor(BuildContext anchorContext) {
    if (!isDesktopRuntime) return null;
    final renderObject = anchorContext.findRenderObject();
    if (renderObject is! RenderBox) return null;
    return renderObject.localToGlobal(renderObject.size.center(Offset.zero));
  }

  void _queueSongs(List<Song> songs, {required bool shuffle}) {
    final queueSongs = List<Song>.of(songs);
    if (shuffle) {
      queueSongs.shuffle(math.Random());
    }
    // Saves remote matches as provisional rows before queueing them.
    ref
        .read(queueProvider.notifier)
        .replaceWithSongs(queueSongs, expandMatchFlows: false)
        .ignore();
  }

  void _playRecommendation(int index) {
    _playWeeklyRecommendation(ref, playlist.recommendations, index);
  }

  Future<void> _rematchPlaylist() async {
    try {
      final matched = await ref
          .read(listenBrainzPlaylistRematchControllerProvider.notifier)
          .rematch(playlist);
      if (!mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(
          context,
        )!.weeklyPlaylistMatchSuccess(matched.matchedCount, matched.totalCount),
        level: AppNoticeLevel.success,
      );
    } on Object {
      if (!mounted) return;
      showAppNotice(
        context,
        message: AppLocalizations.of(context)!.weeklyPlaylistMatchError,
        level: AppNoticeLevel.error,
      );
    }
  }

  Future<void> _downloadVirtualAlbum() async {
    final choice = await requestDownloadQuality(context, ref);
    if (choice == null || !mounted) return;
    setState(() {
      _pendingDownloadChoice = choice;
      _downloadIntentQueuedSongIds.clear();
    });
    final count = await _enqueueDownloads(_serverSongs, choice);
    if (!mounted) return;
    showAppNotice(
      context,
      message: downloadQueuedNotice(
        AppLocalizations.of(context)!,
        AppLocalizations.of(context)!.downloadAlbumQueued(count),
        choice,
      ),
      level: AppNoticeLevel.success,
    );
  }

  Future<void> _downloadSong(SongsTableData song) async {
    final choice = await requestDownloadQuality(context, ref);
    if (choice == null || !mounted) return;
    await ref
        .read(downloadServiceProvider)
        .enqueueSong(
          song.id,
          albumId: song.albumId,
          quality: choice.quality,
          format: choice.format,
        );
    if (!mounted) return;
    showAppNotice(
      context,
      message: downloadQueuedNotice(
        AppLocalizations.of(context)!,
        AppLocalizations.of(context)!.downloadSongQueued,
        choice,
      ),
      level: AppNoticeLevel.success,
    );
  }

  void _enqueuePendingDownloads(List<SongsTableData> serverSongs) {
    final choice = _pendingDownloadChoice;
    if (choice == null) return;
    final newSongs = serverSongs
        .where((song) => !_downloadIntentQueuedSongIds.contains(song.id))
        .toList(growable: false);
    if (newSongs.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingDownloadChoice != choice) return;
      _enqueueDownloads(newSongs, choice).ignore();
    });
  }

  Future<int> _enqueueDownloads(
    List<SongsTableData> songs,
    DownloadQualityChoice choice,
  ) async {
    var count = 0;
    final service = ref.read(downloadServiceProvider);
    for (final song in songs) {
      if (!_downloadIntentQueuedSongIds.add(song.id)) {
        continue;
      }
      await service.enqueueSong(
        song.id,
        albumId: song.albumId,
        quality: choice.quality,
        format: choice.format,
      );
      count++;
    }
    return count;
  }
}

class _VirtualAlbumHeaderText extends StatelessWidget {
  const new({
    required this.playlist,
    required this.titleStyle,
    required this.metadataStyle,
    this.actions,
    this.textAlign = TextAlign.center,
    this.compact = false,
    this.showTitle = true,
  });

  final ListenBrainzDiscoverPlaylist playlist;
  final TextStyle? titleStyle;
  final TextStyle? metadataStyle;
  final Widget? actions;
  final TextAlign textAlign;
  final bool compact;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final date = _listenBrainzGenerationDate(playlist);
    final metadata = <String>[
      l10n.weeklyPlaylistServiceName,
      DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
          .format(date),
      l10n.weeklyPlaylistTrackCount(playlist.totalCount),
      _listenBrainzAvailabilityText(playlist, l10n),
    ].join(' • ');
    return Column(
      crossAxisAlignment: textAlign == TextAlign.center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showTitle) ...<Widget>[
          Text(
            playlist.localizedTitle(l10n),
            textAlign: textAlign,
            maxLines: compact ? 3 : 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
          const SizedBox(height: 8),
        ],
        Text(
          metadata,
          textAlign: textAlign,
          maxLines: compact ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: metadataStyle,
        ),
        if (actions != null) ...<Widget>[const SizedBox(height: 20), actions!],
      ],
    );
  }
}

DateTime _listenBrainzGenerationDate(ListenBrainzDiscoverPlaylist playlist) {
  final direct = playlist.playlist.date;
  if (direct != null) {
    return direct;
  }
  final match = RegExp(
    r'week of (\d{4}-\d{2}-\d{2})',
    caseSensitive: false,
  ).firstMatch(playlist.playlist.title);
  if (match != null) {
    final parsed = DateTime.tryParse(match.group(1)!);
    if (parsed != null) {
      return parsed;
    }
  }
  return DateTime.now();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with SingleTickerProviderStateMixin {
  static const double _homePullDistanceForFullProgress = 120;

  late final ScrollController _scrollController;
  late final AnimationController _homePullSpringController;
  Animation<double>? _homePullSpringAnimation;
  double _homePullDragOffset = 0;
  double _homePullProgress = 0;
  bool _homeImmediateTriggerRingVisible = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _homePullSpringController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 190),
        )..addListener(() {
          final animation = _homePullSpringAnimation;
          if (animation == null || !mounted) {
            return;
          }
          setState(() {
            _homePullProgress = animation.value;
          });
        });
  }

  @override
  void dispose() {
    _homePullSpringController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _runHomeRefresh() async {
    ref.read(homeRandomShowcaseShuffleSeedProvider.notifier).reshuffle();
    await ref.read(librarySyncControllerProvider.notifier).syncNow();
    ref.invalidate(homeRecentlyAddedProvider);
    ref.invalidate(homeRandomAlbumsProvider);
    ref.invalidate(homeDownloadedRandomAlbumsProvider);
    ref.invalidate(homeRandomAlbumShowcaseProvider);
    ref.invalidate(homeRandomShowcaseProvider);
    ref.read(listenBrainzDiscoverRefreshEpochProvider.notifier).refreshFull();
    ref.invalidate(updateProvider);
  }

  void _setHomePullProgress(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if ((_homePullProgress - clamped).abs() < 0.001) {
      return;
    }
    setState(() {
      _homePullProgress = clamped;
    });
  }

  void _animateHomePullProgressToZero() {
    if (_homePullProgress <= 0.001) {
      if (_homePullProgress != 0) {
        setState(() {
          _homePullProgress = 0;
        });
      }
      return;
    }
    _homePullSpringController.stop();
    _homePullSpringAnimation = Tween<double>(begin: _homePullProgress, end: 0)
        .animate(
          CurvedAnimation(
            parent: _homePullSpringController,
            curve: Curves.easeOutCubic,
          ),
        );
    _homePullSpringController.forward(from: 0);
  }

  bool _handleHomeRefreshScrollNotification(
    ScrollNotification notification,
    bool enabled,
  ) {
    if (!enabled || notification.depth != 0) {
      return false;
    }
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }

    final atTop = notification.metrics.extentBefore <= 0;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _homePullSpringController.stop();
      _homePullDragOffset = 0;
      return false;
    }

    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      if (!atTop) {
        _homePullDragOffset = 0;
        _setHomePullProgress(0);
        return false;
      }
      final delta = notification.scrollDelta ?? 0;
      switch (notification.metrics.axisDirection) {
        case AxisDirection.down:
          _homePullDragOffset -= delta;
        case AxisDirection.up:
          _homePullDragOffset += delta;
        case AxisDirection.left:
        case AxisDirection.right:
          return false;
      }
      _setHomePullProgress(
        _homePullDragOffset / _homePullDistanceForFullProgress,
      );
      return false;
    }

    if (notification is OverscrollNotification && atTop) {
      switch (notification.metrics.axisDirection) {
        case AxisDirection.down:
          _homePullDragOffset -= notification.overscroll;
        case AxisDirection.up:
          _homePullDragOffset += notification.overscroll;
        case AxisDirection.left:
        case AxisDirection.right:
          return false;
      }
      _setHomePullProgress(
        _homePullDragOffset / _homePullDistanceForFullProgress,
      );
      return false;
    }

    if (notification is ScrollEndNotification) {
      _homePullDragOffset = 0;
      _animateHomePullProgressToZero();
    }
    return false;
  }

  void _handleHomeRefreshStatusChanged(RefreshIndicatorStatus? status) {
    if (!mounted) {
      return;
    }
    setState(() {
      switch (status) {
        case RefreshIndicatorStatus.drag:
        case RefreshIndicatorStatus.armed:
          _homeImmediateTriggerRingVisible = false;
        case RefreshIndicatorStatus.snap:
        case RefreshIndicatorStatus.refresh:
          _homeImmediateTriggerRingVisible = true;
        case RefreshIndicatorStatus.done:
        case RefreshIndicatorStatus.canceled:
        case null:
          _homeImmediateTriggerRingVisible = false;
      }
    });
    if (status == RefreshIndicatorStatus.snap ||
        status == RefreshIndicatorStatus.refresh ||
        status == RefreshIndicatorStatus.done ||
        status == RefreshIndicatorStatus.canceled ||
        status == null) {
      _homePullDragOffset = 0;
      _animateHomePullProgressToZero();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Home sections only need to know whether sync is running; the logo
    // watches detailed progress itself.
    final syncRunning = ref.watch(
      librarySyncControllerProvider.select((state) => state.isRunning),
    );
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
    final likedOnly = ref.watch(homeLikedOnlyFilterProvider);
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final adaptiveLayoutClass = adaptiveContext.adaptiveLayoutClass;
    final compactWideLandscapeMode = adaptiveContext.useCompactWideLandscape;
    final compactHorizontalInset = compactWideLandscapeMode ? 10.0 : 0.0;
    final desktopRuntime = adaptiveContext.desktopRuntime;
    final desktopMode = adaptiveContext.useDesktopShell;
    final useCustomHomePullRefresh = !desktopMode;
    final homeDensity = ref.watch(homeDensityProvider);
    final order =
        ref.watch(homeSectionOrderProvider) ?? HomeSectionIds.defaultOrder;
    final hidden =
        ref.watch(homeSectionsHiddenProvider) ?? HomeSectionIds.defaultHidden;

    final content = ListView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        compactHorizontalInset,
        0,
        compactHorizontalInset,
        24,
      ),
      children: <Widget>[
        if (desktopMode)
          Padding(
            key: const ValueKey<String>('homeDesktopBrandRow'),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: <Widget>[
                _HomeSyncLogo(
                  size: 48,
                  pullProgress: 0,
                  showImmediateRefreshRing: false,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.appName,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const _HomeActionRow(variant: _HomeActionRowVariant.desktop),
              ],
            ),
          )
        else if (compactWideLandscapeMode)
          Padding(
            key: const ValueKey<String>('homeCompactWideHeaderRow'),
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
            child: Row(
              children: <Widget>[
                _HomeSyncLogo(
                  size: 60,
                  pullProgress: useCustomHomePullRefresh
                      ? _homePullProgress
                      : 0,
                  showImmediateRefreshRing:
                      useCustomHomePullRefresh &&
                      _homeImmediateTriggerRingVisible &&
                      !syncRunning,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const _HomeActionRow(
                  variant: _HomeActionRowVariant.compactWide,
                ),
              ],
            ),
          )
        else ...<Widget>[
          Padding(
            key: const ValueKey<String>('homeCenteredLogoHeader'),
            padding: const EdgeInsets.fromLTRB(0, 48, 0, 14),
            child: Center(
              child: _HomeSyncLogo(
                size: 96,
                pullProgress: useCustomHomePullRefresh ? _homePullProgress : 0,
                showImmediateRefreshRing:
                    useCustomHomePullRefresh &&
                    _homeImmediateTriggerRingVisible &&
                    !syncRunning,
              ),
            ),
          ),
          const _HomeActionRow(variant: _HomeActionRowVariant.mobile),
          const SizedBox(height: 10),
        ],
        const ChangelogDiscoveryCard(),
        const _UpdateBanner(),
        for (final sectionId in order)
          if (!hidden.contains(sectionId))
            ..._buildSection(
              context,
              ref,
              sectionId,
              downloadedOnly,
              likedOnly,
              syncRunning,
              homeDensity,
              desktopRuntime,
              desktopMode,
              adaptiveLayoutClass,
              compactWideLandscapeMode,
            ),
      ],
    );

    final resolvedContent = content;

    final scrollObservedContent = useCustomHomePullRefresh
        ? NotificationListener<ScrollNotification>(
            onNotification: (notification) =>
                _handleHomeRefreshScrollNotification(
                  notification,
                  useCustomHomePullRefresh,
                ),
            child: resolvedContent,
          )
        : resolvedContent;

    final refreshContainer = useCustomHomePullRefresh
        ? RefreshIndicator.noSpinner(
            onRefresh: _runHomeRefresh,
            onStatusChange: _handleHomeRefreshStatusChanged,
            child: scrollObservedContent,
          )
        : RefreshIndicator(
            onRefresh: _runHomeRefresh,
            child: scrollObservedContent,
          );

    return Scaffold(
      body: SafeArea(
        left: !compactWideLandscapeMode,
        right: !compactWideLandscapeMode,
        child: refreshContainer,
      ),
    );
  }

  List<Widget> _buildSection(
    BuildContext context,
    WidgetRef ref,
    String sectionId,
    bool downloadedOnly,
    bool likedOnly,
    bool syncRunning,
    String homeDensity,
    bool desktopRuntime,
    bool desktopMode,
    AdaptiveLayoutClass adaptiveLayoutClass,
    bool compactWideLandscapeMode,
  ) {
    // Quick actions are shown inline in the desktop brand row instead.
    if (desktopMode && sectionId == HomeSectionIds.quickActions) {
      return const <Widget>[];
    }
    final l10n = AppLocalizations.of(context)!;
    final sectionDensity = homeDensity == 'compact'
        ? _HomeSectionDensity.compact
        : _HomeSectionDensity.comfortable;
    switch (sectionId) {
      case HomeSectionIds.recentlyLikedAlbums:
        final downloadedAlbumIds = downloadedOnly
            ? (ref.watch(downloadedContentIdsProvider).asData?.value.albumIds ??
                  const <String>{})
            : const <String>{};
        return <Widget>[
          _HomeSection<List<AlbumsTableData>>(
            title: l10n.homeRecentlyLikedAlbumsTitle,
            onSeeAll: () => NavService.openLikedAlbums(context, ref),
            desktopMode: desktopMode,
            adaptiveLayoutClass: adaptiveLayoutClass,
            compactWideLandscapeMode: compactWideLandscapeMode,
            template: _HomeSectionTemplate.carousel,
            density: sectionDensity,
            data: ref
                .watch(likedAlbumsRecentProvider)
                .whenData(
                  (albums) => downloadedOnly
                      ? albums
                            .where(
                              (album) => downloadedAlbumIds.contains(album.id),
                            )
                            .toList(growable: false)
                      : albums,
                ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, albums) => _LocalAlbumCarousel(
              albums: albums,
              heroContext: 'home_recently_liked',
              density: sectionDensity,
              desktopMode: desktopMode,
              tabletMode:
                  !desktopMode &&
                  adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact,
              adaptiveLayoutClass: adaptiveLayoutClass,
              compactWideLandscapeMode: compactWideLandscapeMode,
              onTap: (album, heroTag) => NavService.openAlbumDetail(
                context,
                ref,
                album.id,
                heroTag: heroTag,
              ),
            ),
            emptyTitle: l10n.homeRecentlyLikedAlbumsEmptyTitle,
            emptySubtitle: l10n.homeRecentlyLikedAlbumsEmptySubtitle,
          ),
        ];

      case HomeSectionIds.likedTracks:
        return <Widget>[
          _HomeSection<List<SongsTableData>>(
            title: l10n.homeStarredTitle,
            desktopMode: desktopRuntime && !compactWideLandscapeMode,
            adaptiveLayoutClass: adaptiveLayoutClass,
            compactWideLandscapeMode: compactWideLandscapeMode,
            template: _HomeSectionTemplate.compactList,
            density: sectionDensity,
            data: ref.watch(
              downloadedOnly
                  ? homeDownloadedLikedSongsProvider
                  : homeLikedSongsProvider,
            ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, songs) => _SongListSection(
              songs: songs,
              density: sectionDensity,
              desktopMode: desktopRuntime && !compactWideLandscapeMode,
              adaptiveLayoutClass: adaptiveLayoutClass,
              compactWideLandscapeMode: compactWideLandscapeMode,
              onTap: (song) {
                final allLikedSongs = ref.read(likedPlaybackSongsProvider);
                final eligibleSongs = downloadedOnly
                    ? filterLikedPlaybackToDownloads(
                        allLikedSongs,
                        ref.read(downloadedSongIdsProvider).asData?.value ??
                            const <String>{},
                      )
                    : allLikedSongs;
                if (shouldQueueLikedPlayback(
                  albumQueueEnabled: ref.read(albumQueueEnabledProvider),
                  likedQueueEnabled: ref.read(likedQueueEnabledProvider),
                  eligibleSongCount: eligibleSongs.length,
                )) {
                  final startIndex = eligibleSongs.indexWhere(
                    (candidate) => candidate.id == song.id,
                  );
                  ref
                      .read(queueProvider.notifier)
                      .replaceWithTableData(
                        eligibleSongs,
                        startIndex: startIndex < 0 ? 0 : startIndex,
                        autoPlay: true,
                      )
                      .ignore();
                  return;
                }
                ref.read(queueProvider.notifier).replaceWithTableData(
                  <SongsTableData>[song],
                  autoPlay: true,
                ).ignore();
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
              desktopMode: desktopMode,
              adaptiveLayoutClass: adaptiveLayoutClass,
              compactWideLandscapeMode: compactWideLandscapeMode,
              template: _HomeSectionTemplate.carousel,
              density: sectionDensity,
              data: ref
                  .watch(homeDownloadedRecentlyAddedAlbumsProvider)
                  .whenData(
                    (albums) => likedOnly
                        ? albums
                              .where((album) => album.starred != null)
                              .toList(growable: false)
                        : albums,
                  ),
              isEmpty: (items) => items.isEmpty,
              builder: (context, albums) => _LocalAlbumCarousel(
                albums: albums,
                heroContext: 'home_recently_added',
                density: sectionDensity,
                desktopMode: desktopMode,
                tabletMode:
                    !desktopMode &&
                    adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact,
                adaptiveLayoutClass: adaptiveLayoutClass,
                compactWideLandscapeMode: compactWideLandscapeMode,
                onTap: (album, heroTag) => NavService.openAlbumDetail(
                  context,
                  ref,
                  album.id,
                  heroTag: heroTag,
                ),
              ),
              emptyTitle: l10n.libraryDownloadedOnlyEmpty,
              emptySubtitle: l10n.libraryDownloadedOnlyEmptySubtitle,
            ),
          ];
        }
        return <Widget>[
          _HomeSection<List<Album>>(
            title: l10n.homeRecentlyAddedTitle,
            desktopMode: desktopMode,
            adaptiveLayoutClass: adaptiveLayoutClass,
            compactWideLandscapeMode: compactWideLandscapeMode,
            template: _HomeSectionTemplate.carousel,
            density: sectionDensity,
            data: ref
                .watch(homeRecentlyAddedProvider)
                .whenData(
                  (albums) => likedOnly
                      ? albums
                            .where((album) => album.starred != null)
                            .toList(growable: false)
                      : albums,
                ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, albums) => _ServerAlbumCarousel(
              albums: albums,
              heroContext: 'home_recently_added',
              density: sectionDensity,
              desktopMode: desktopMode,
              tabletMode:
                  !desktopMode &&
                  adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact,
              adaptiveLayoutClass: adaptiveLayoutClass,
              compactWideLandscapeMode: compactWideLandscapeMode,
              onTap: (album, heroTag) => NavService.openAlbumDetail(
                context,
                ref,
                album.id,
                heroTag: heroTag,
              ),
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
            desktopMode: desktopMode,
            adaptiveLayoutClass: adaptiveLayoutClass,
            compactWideLandscapeMode: compactWideLandscapeMode,
            template: _HomeSectionTemplate.carousel,
            density: sectionDensity,
            data: ref
                .watch(
                  downloadedOnly
                      ? homeDownloadedRecentlyPlayedAlbumsProvider
                      : homeRecentlyPlayedAlbumsProvider,
                )
                .whenData(
                  (albums) => likedOnly
                      ? albums
                            .where((album) => album.starred != null)
                            .toList(growable: false)
                      : albums,
                ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, albums) => _LocalAlbumCarousel(
              albums: albums,
              heroContext: 'home_recently_played',
              density: sectionDensity,
              desktopMode: desktopMode,
              tabletMode:
                  !desktopMode &&
                  adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact,
              adaptiveLayoutClass: adaptiveLayoutClass,
              compactWideLandscapeMode: compactWideLandscapeMode,
              onTap: (album, heroTag) => NavService.openAlbumDetail(
                context,
                ref,
                album.id,
                heroTag: heroTag,
              ),
            ),
            emptyTitle: l10n.homeRecentlyPlayedAlbumsEmptyTitle,
            emptySubtitle: l10n.homeRecentlyPlayedAlbumsEmptySubtitle,
            onRetry: () => ref.invalidate(homeRecentlyPlayedAlbumsProvider),
          ),
        ];

      case HomeSectionIds.randomAlbums:
        return <Widget>[
          _HomeSection<List<HomeRandomShowcaseItem>>(
            title: l10n.homeRandomTitle,
            desktopMode: desktopMode,
            adaptiveLayoutClass: adaptiveLayoutClass,
            compactWideLandscapeMode: compactWideLandscapeMode,
            template: _HomeSectionTemplate.carousel,
            density: sectionDensity,
            loadingBuilder: () => _RandomHeroShimmer(
              density: sectionDensity,
              desktopMode: desktopMode,
              adaptiveLayoutClass: adaptiveLayoutClass,
            ),
            keepPreviousDataWhileLoading: true,
            data: ref.watch(
              homeRandomShowcaseProvider((
                downloadedOnly: downloadedOnly,
                likedOnly: likedOnly,
              )),
            ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, albums) {
              final hasListenBrainzItems = albums.any(
                (item) => item is HomeRandomShowcaseListenBrainz,
              );
              final freezeListUpdates = syncRunning && !hasListenBrainzItems;
              return desktopMode
                  ? _DesktopRandomAlbumsPager(
                      albums: albums,
                      heroContext: 'home_random',
                      density: sectionDensity,
                      freezeListUpdates: freezeListUpdates,
                    )
                  : _RandomAlbumsHeroCarousel(
                      albums: albums,
                      heroContext: 'home_random',
                      density: sectionDensity,
                      freezeListUpdates: freezeListUpdates,
                      desktopMode: desktopMode,
                      adaptiveLayoutClass: adaptiveLayoutClass,
                    );
            },
            emptyTitle: l10n.homeRandomEmptyTitle,
            emptySubtitle: l10n.homeRandomEmptySubtitle,
            onRetry: () {
              ref.invalidate(homeRandomAlbumsProvider);
              ref.invalidate(homeRandomAlbumShowcaseProvider);
              ref
                  .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
                  .refreshFull();
              ref.invalidate(homeRandomShowcaseProvider);
            },
          ),
        ];

      case HomeSectionIds.mostPlayed:
        return <Widget>[
          _HomeSection<List<SongsTableData>>(
            title: l10n.homeMostPlayedTracksTitle,
            desktopMode: desktopRuntime && !compactWideLandscapeMode,
            adaptiveLayoutClass: adaptiveLayoutClass,
            compactWideLandscapeMode: compactWideLandscapeMode,
            template: _HomeSectionTemplate.compactList,
            density: sectionDensity,
            data: ref
                .watch(
                  downloadedOnly
                      ? homeDownloadedMostPlayedSongsProvider
                      : homeMostPlayedSongsProvider,
                )
                .whenData(
                  (songs) => likedOnly
                      ? songs
                            .where((song) => song.starred != null)
                            .toList(growable: false)
                      : songs,
                ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, songs) => _SongListSection(
              songs: songs,
              density: sectionDensity,
              desktopMode: desktopRuntime && !compactWideLandscapeMode,
              adaptiveLayoutClass: adaptiveLayoutClass,
              compactWideLandscapeMode: compactWideLandscapeMode,
              onTap: (song) {
                ref.read(queueProvider.notifier).replaceWithTableData(
                  <SongsTableData>[song],
                  autoPlay: true,
                ).ignore();
              },
            ),
            emptyTitle: l10n.homeMostPlayedTracksEmptyTitle,
            emptySubtitle: l10n.homeMostPlayedTracksEmptySubtitle,
            onRetry: () => ref.invalidate(homeMostPlayedSongsProvider),
          ),
        ];

      case HomeSectionIds.recentlyPlayedTracks:
        final downloadedSongIds = downloadedOnly
            ? (ref.watch(downloadedSongIdsProvider).asData?.value ??
                  const <String>{})
            : const <String>{};
        return <Widget>[
          _HomeSection<List<SongsTableData>>(
            title: l10n.homeRecentlyPlayedTracksTitle,
            desktopMode: desktopRuntime && !compactWideLandscapeMode,
            adaptiveLayoutClass: adaptiveLayoutClass,
            compactWideLandscapeMode: compactWideLandscapeMode,
            template: _HomeSectionTemplate.compactList,
            density: sectionDensity,
            data: ref
                .watch(homeRecentlyPlayedProvider)
                .whenData(
                  (songs) =>
                      (downloadedOnly
                              ? songs.where(
                                  (song) => downloadedSongIds.contains(song.id),
                                )
                              : songs)
                          .where((song) => !likedOnly || song.starred != null)
                          .take(5)
                          .toList(growable: false),
                ),
            isEmpty: (items) => items.isEmpty,
            builder: (context, songs) => _SongListSection(
              songs: songs,
              density: sectionDensity,
              desktopMode: desktopRuntime && !compactWideLandscapeMode,
              adaptiveLayoutClass: adaptiveLayoutClass,
              compactWideLandscapeMode: compactWideLandscapeMode,
              onTap: (song) {
                ref.read(queueProvider.notifier).replaceWithTableData(
                  <SongsTableData>[song],
                  autoPlay: true,
                ).ignore();
              },
            ),
            emptyTitle: l10n.homeRecentlyPlayedTracksEmptyTitle,
            emptySubtitle: l10n.homeRecentlyPlayedTracksEmptySubtitle,
            onRetry: () => ref.invalidate(homeRecentlyPlayedProvider),
          ),
        ];

      case HomeSectionIds.frequentAlbums:
        if (downloadedOnly) {
          return const <Widget>[];
        }
        final frequentAsync = ref
            .watch(homeFrequentAlbumsProvider)
            .whenData(
              (albums) => likedOnly
                  ? albums
                        .where((album) => album.starred != null)
                        .toList(growable: false)
                  : albums,
            );
        if (frequentAsync.hasError) {
          return const <Widget>[];
        }
        final frequentData = frequentAsync.asData?.value;
        if (frequentData != null && frequentData.isEmpty) {
          return const <Widget>[];
        }
        return <Widget>[
          _HomeSection<List<Album>>(
            title: l10n.homeFrequentTitle,
            desktopMode: desktopMode,
            adaptiveLayoutClass: adaptiveLayoutClass,
            compactWideLandscapeMode: compactWideLandscapeMode,
            template: _HomeSectionTemplate.carousel,
            density: sectionDensity,
            data: frequentAsync,
            isEmpty: (items) => items.isEmpty,
            builder: (context, albums) => _ServerAlbumCarousel(
              albums: albums,
              heroContext: 'home_frequent',
              density: sectionDensity,
              desktopMode: desktopMode,
              tabletMode:
                  !desktopMode &&
                  adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact,
              adaptiveLayoutClass: adaptiveLayoutClass,
              compactWideLandscapeMode: compactWideLandscapeMode,
              onTap: (album, heroTag) => NavService.openAlbumDetail(
                context,
                ref,
                album.id,
                heroTag: heroTag,
              ),
            ),
            emptyTitle: l10n.homeFrequentEmptyTitle,
            emptySubtitle: l10n.homeFrequentEmptySubtitle,
            onRetry: () => ref.invalidate(homeFrequentAlbumsProvider),
          ),
        ];

      default:
        return const <Widget>[];
    }
  }
}

class _HomeSyncLogo extends ConsumerWidget {
  const new({
    required this.size,
    this.pullProgress = 0,
    this.showImmediateRefreshRing = false,
  });

  static const Key ringKey = ValueKey<String>('home-sync-ring');

  final double size;
  final double pullProgress;
  final bool showImmediateRefreshRing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(librarySyncControllerProvider);
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final accentColors = NavisAccentColors.of(context);
    final clampedPullProgress = pullProgress.clamp(0.0, 1.0);
    final isRunning = syncState.isRunning;
    final hasDeterminate =
        isRunning && !syncState.fastPathActive && (syncState.total ?? 0) > 0;
    final showFailure =
        !isRunning && syncState.status == LibrarySyncStatus.failed;
    final showBridgeRing =
        showImmediateRefreshRing && !isRunning && !showFailure;
    final showRing = isRunning || showFailure || showBridgeRing;
    final total = syncState.total ?? 0;
    final processed = syncState.processed ?? 0;
    final progressValue = hasDeterminate
        ? (processed / total).clamp(0.0, 1.0)
        : null;
    final determinateProgress = progressValue ?? 0.0;
    final semanticsLabel = switch ((isRunning, hasDeterminate, showFailure)) {
      (true, true, _) => l10n.librarySyncRunningWithProgress(processed, total),
      (true, false, _) => l10n.librarySyncRunning,
      (false, _, true) => l10n.syncSettingsStatusFailed,
      _ => showBridgeRing ? l10n.librarySyncRunning : null,
    };
    final strokeWidth = (size * 0.055).clamp(2.2, 5.2);
    final ringColor = showFailure
        ? colorScheme.error.withValues(alpha: 0.65)
        : accentColors.brand;
    final ringTrackColor = showFailure
        ? colorScheme.error.withValues(alpha: 0.18)
        : accentColors.brandTrack;
    final logo = Transform.translate(
      offset: Offset(0, size * 0.10 * clampedPullProgress),
      child: Transform.rotate(
        angle: (math.pi * 7 / 180) * clampedPullProgress,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            SizedBox.square(
              dimension: size,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 190),
                curve: Curves.easeOutCubic,
                opacity: showRing ? 1 : 0,
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 190),
                  curve: Curves.easeOutCubic,
                  scale: showRing ? 1 : 0.94,
                  child: Padding(
                    padding: EdgeInsets.all(strokeWidth / 2),
                    child: hasDeterminate
                        ? TweenAnimationBuilder<double>(
                            tween: Tween<double>(
                              begin: 0,
                              end: determinateProgress,
                            ),
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOutCubic,
                            builder: (context, animatedValue, _) {
                              return CircularProgressIndicator(
                                key: ringKey,
                                value: animatedValue,
                                strokeWidth: strokeWidth,
                                color: ringColor,
                                backgroundColor: ringTrackColor,
                              );
                            },
                          )
                        : CircularProgressIndicator(
                            key: ringKey,
                            value: isRunning || showBridgeRing ? null : 1,
                            strokeWidth: strokeWidth,
                            color: ringColor,
                            backgroundColor: ringTrackColor,
                          ),
                  ),
                ),
              ),
            ),
            NavisIcon(
              key: const ValueKey<String>('home-sync-logo'),
              size: size,
              tintWithAccent: true,
            ),
          ],
        ),
      ),
    );

    if (semanticsLabel == null) {
      return logo;
    }
    return Semantics(
      container: true,
      label: semanticsLabel,
      liveRegion: isRunning,
      child: logo,
    );
  }
}

enum _HomeSectionDensity { comfortable, compact }

enum _HomeSectionTemplate { carousel, compactList }

bool _homeRandomShowcaseItemsVisuallyChanged(
  List<HomeRandomShowcaseItem> previous,
  List<HomeRandomShowcaseItem> next,
) {
  if (identical(previous, next)) {
    return false;
  }
  if (previous.length != next.length) {
    return true;
  }
  for (var index = 0; index < previous.length; index++) {
    final prior = previous[index];
    final incoming = next[index];
    if (prior.stableId != incoming.stableId) {
      return true;
    }
    if (prior is HomeRandomShowcaseListenBrainz &&
        incoming is HomeRandomShowcaseListenBrainz) {
      if (prior.isLoading != incoming.isLoading) {
        return true;
      }
      final priorCount = prior.playlist?.recommendations.length ?? 0;
      final incomingCount = incoming.playlist?.recommendations.length ?? 0;
      if (priorCount != incomingCount) {
        return true;
      }
    }
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared section wrapper
// ─────────────────────────────────────────────────────────────────────────────

class _HomeSection<T> extends StatelessWidget {
  const new({
    required this.title,
    required this.data,
    required this.builder,
    required this.isEmpty,
    required this.emptyTitle,
    required this.emptySubtitle,
    this.desktopMode = false,
    this.adaptiveLayoutClass = AdaptiveLayoutClass.phoneCompact,
    this.compactWideLandscapeMode = false,
    this.template = _HomeSectionTemplate.carousel,
    this.density = _HomeSectionDensity.comfortable,
    this.loadingBuilder,
    this.keepPreviousDataWhileLoading = false,
    this.onRetry,
    this.onSeeAll,
  });

  final String title;
  final AsyncValue<T> data;
  final Widget Function(BuildContext context, T value) builder;
  final bool Function(T value) isEmpty;
  final String emptyTitle;
  final String emptySubtitle;
  final bool desktopMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final bool compactWideLandscapeMode;
  final _HomeSectionTemplate template;
  final _HomeSectionDensity density;
  final Widget Function()? loadingBuilder;
  final bool keepPreviousDataWhileLoading;
  final VoidCallback? onRetry;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final compactDensity = density == _HomeSectionDensity.compact;
    final showSeeAll =
        onSeeAll != null && data.asData != null && !isEmpty(data.asData!.value);
    final titleWidget = NavisSectionHeader(
      title: title,
      compact: template == _HomeSectionTemplate.compactList,
      onSeeAll: showSeeAll ? onSeeAll : null,
    );
    final sectionBody = data.when(
      skipLoadingOnRefresh: keepPreviousDataWhileLoading,
      skipLoadingOnReload: keepPreviousDataWhileLoading,
      data: (value) {
        if (isEmpty(value)) {
          return Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compactWideLandscapeMode ? 0 : 16,
            ),
            child: EmptyState(
              title: emptyTitle,
              subtitle: emptySubtitle,
              icon: Icons.library_music_outlined,
            ),
          );
        }
        return builder(context, value);
      },
      loading: () =>
          loadingBuilder?.call() ??
          (template == _HomeSectionTemplate.carousel
              ? _CarouselShimmer(
                  density: density,
                  compactWideLandscapeMode: compactWideLandscapeMode,
                )
              : _ListShimmer(density: density)),
      error: (error, _) => Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compactWideLandscapeMode ? 0 : 16,
        ),
        child: ErrorState(title: l10n.homeLoadErrorTitle, onRetry: onRetry),
      ),
    );

    final tabletMode =
        !desktopMode && adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
    final topPadding = compactDensity
        ? (tabletMode ? 14.0 : 12.0)
        : (tabletMode ? 18.0 : 16.0);

    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      child: desktopMode
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  titleWidget,
                  SizedBox(height: compactDensity ? 8 : 10),
                  sectionBody,
                ],
              ),
            )
          : tabletMode
          ? compactWideLandscapeMode
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: titleWidget,
                        ),
                        SizedBox(height: compactDensity ? 8 : 10),
                        sectionBody,
                      ],
                    ),
                  )
                : Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          titleWidget,
                          SizedBox(height: compactDensity ? 8 : 10),
                          sectionBody,
                        ],
                      ),
                    ),
                  )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: titleWidget,
                ),
                SizedBox(height: compactDensity ? 8 : 10),
                sectionBody,
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
  const new({
    required this.albums,
    required this.onTap,
    required this.heroContext,
    required this.desktopMode,
    required this.tabletMode,
    required this.adaptiveLayoutClass,
    required this.compactWideLandscapeMode,
    this.density = _HomeSectionDensity.comfortable,
  });

  final List<Album> albums;
  final void Function(Album album, String heroTag) onTap;
  final String heroContext;
  final bool desktopMode;
  final bool tabletMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final bool compactWideLandscapeMode;
  final _HomeSectionDensity density;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = artworkBorderRadius(
      coverShape,
      extent: double.infinity,
    );
    final compactDensity = density == _HomeSectionDensity.compact;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cardSize = width < 600
            ? (compactDensity ? 138.0 : 150.0)
            : (compactDensity ? 152.0 : 164.0);
        final horizontalPadding = desktopMode || tabletMode ? 0.0 : 16.0;
        final usableWidth = (width - horizontalPadding * 2).clamp(
          0.0,
          double.infinity,
        );
        final visibleAlbums = albums;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: ContentShelf(
            height: cardSize,
            extent: cardSize,
            gap: ContentLayout.gap(usableWidth),
            itemCount: visibleAlbums.length,
            itemBuilder: (context, index) {
              final album = visibleAlbums[index];
              final heroTag = buildCoverArtHeroTag(
                coverArtId: album.coverArt,
                context: '${heroContext}_${album.id}',
              );
              return _ServerAlbumCard(
                name: album.name,
                artist: album.artist,
                coverArtId: album.coverArt,
                width: cardSize,
                borderRadius: coverRadius,
                isExternalSource: isExternalCatalogSource(
                  id: album.id,
                  apiIsExternal: album.isExternal,
                ),
                heroTag: heroTag,
                onTap: () => onTap(album, heroTag),
                onLongPress: () => showAlbumContextMenu(context, ref, album.id),
                onSecondaryTapDown: (details) => showAlbumContextMenu(
                  context,
                  ref,
                  album.id,
                  anchor: details.globalPosition,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _LocalAlbumCarousel extends ConsumerWidget {
  const new({
    required this.albums,
    required this.onTap,
    required this.heroContext,
    required this.desktopMode,
    required this.tabletMode,
    required this.adaptiveLayoutClass,
    required this.compactWideLandscapeMode,
    this.density = _HomeSectionDensity.comfortable,
  });

  final List<AlbumsTableData> albums;
  final void Function(AlbumsTableData album, String heroTag) onTap;
  final String heroContext;
  final bool desktopMode;
  final bool tabletMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final bool compactWideLandscapeMode;
  final _HomeSectionDensity density;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compactDensity = density == _HomeSectionDensity.compact;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cardSize = width < 600
            ? (compactDensity ? 138.0 : 150.0)
            : (compactDensity ? 152.0 : 164.0);
        final horizontalPadding = desktopMode || tabletMode ? 0.0 : 16.0;
        final usableWidth = (width - horizontalPadding * 2).clamp(
          0.0,
          double.infinity,
        );
        final visibleAlbums = heroContext == 'home_recently_liked'
            ? albums
                  .take(ContentLayout.shelfLimit(usableWidth, cardSize))
                  .toList(growable: false)
            : albums;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: ContentShelf(
            height: cardSize,
            extent: cardSize,
            gap: ContentLayout.gap(usableWidth),
            itemCount: visibleAlbums.length,
            itemBuilder: (context, index) {
              final album = visibleAlbums[index];
              final heroTag = buildCoverArtHeroTag(
                coverArtId: album.coverArt,
                context: '${heroContext}_${album.id}',
              );
              return AlbumCard(
                album: album,
                size: AlbumCardSize.compact,
                extent: cardSize,
                heroTag: heroTag,
                onTap: () => onTap(album, heroTag),
                onLongPress: () => showAlbumContextMenu(context, ref, album.id),
                onSecondaryTapDown: (details) => showAlbumContextMenu(
                  context,
                  ref,
                  album.id,
                  anchor: details.globalPosition,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _CarouselEdgeArrow extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.onPressed,
    this.extent = 48,
    this.elevation = 3,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final double extent;
  final double elevation;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final arrow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: colors.surfaceContainerHigh.withValues(alpha: 0.92),
        elevation: elevation,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: extent,
            height: extent,
            child: Icon(icon, size: extent < 48 ? 20 : null),
          ),
        ),
      ),
    );
    final label = tooltip;
    return label == null ? arrow : Tooltip(message: label, child: arrow);
  }
}

class _DesktopRandomAlbumsPager extends ConsumerStatefulWidget {
  const new({
    required this.albums,
    required this.heroContext,
    this.density = _HomeSectionDensity.comfortable,
    this.freezeListUpdates = false,
  });

  final List<HomeRandomShowcaseItem> albums;
  final String heroContext;
  final _HomeSectionDensity density;
  final bool freezeListUpdates;

  @override
  ConsumerState<_DesktopRandomAlbumsPager> createState() =>
      _DesktopRandomAlbumsPagerState();
}

class _DesktopRandomAlbumsPagerState
    extends ConsumerState<_DesktopRandomAlbumsPager> {
  late final PageController _pageController;
  late List<HomeRandomShowcaseItem> _displayedAlbums;
  int _currentPage = 0;
  String? _currentStableId;

  @override
  void initState() {
    super.initState();
    _displayedAlbums = List<HomeRandomShowcaseItem>.unmodifiable(widget.albums);
    if (_displayedAlbums.isNotEmpty) {
      _currentStableId = _displayedAlbums.first.stableId;
    }
    _pageController = PageController();
  }

  @override
  void didUpdateWidget(covariant _DesktopRandomAlbumsPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.freezeListUpdates && _displayedAlbums.isNotEmpty) return;
    final incoming = List<HomeRandomShowcaseItem>.unmodifiable(widget.albums);
    final oldIds = _displayedAlbums.map((item) => item.stableId).toList();
    final newIds = incoming.map((item) => item.stableId).toList();
    if (listEquals(oldIds, newIds)) {
      if (_homeRandomShowcaseItemsVisuallyChanged(_displayedAlbums, incoming)) {
        _displayedAlbums = incoming;
      }
      return;
    }
    final retained = incoming.indexWhere(
      (item) => item.stableId == _currentStableId,
    );
    _displayedAlbums = incoming;
    _currentPage = incoming.isEmpty
        ? 0
        : retained >= 0
        ? retained
        : _currentPage.clamp(0, incoming.length - 1);
    _currentStableId = incoming.isEmpty
        ? null
        : incoming[_currentPage].stableId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _pageController.hasClients &&
          _displayedAlbums.isNotEmpty) {
        _pageController.jumpToPage(_currentPage);
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _animateToPage(int target) {
    if (!_pageController.hasClients || _displayedAlbums.isEmpty) {
      return;
    }
    final clampedTarget = target.clamp(0, _displayedAlbums.length - 1);
    if (clampedTarget == _currentPage) {
      return;
    }
    if (MotionPolicy.of(context).reduceMotion) {
      _pageController.jumpToPage(clampedTarget);
    } else {
      _pageController.animateToPage(
        clampedTarget,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }
  }

  double _heroHeightFor(double availableWidth) {
    final compact = widget.density == _HomeSectionDensity.compact;
    return (availableWidth * (compact ? 0.26 : 0.29)).clamp(
      compact ? 300.0 : 330.0,
      compact ? 330.0 : 360.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_displayedAlbums.isEmpty) {
      return const SizedBox.shrink();
    }

    final currentItem =
        _displayedAlbums[_currentPage.clamp(0, _displayedAlbums.length - 1)];
    final pager = Column(
      key: const ValueKey<String>('home-random-desktop-pager'),
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            final cardMode = availableWidth < 640;
            final height = cardMode
                ? (widget.density == _HomeSectionDensity.compact
                      ? 240.0
                      : 260.0)
                : _heroHeightFor(availableWidth);
            return SizedBox(
              height: height,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: PageView.builder(
                      key: const ValueKey<String>(
                        'home-random-desktop-pageview',
                      ),
                      controller: _pageController,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _displayedAlbums.length,
                      onPageChanged: (page) {
                        if (!mounted) {
                          return;
                        }
                        setState(() {
                          _currentPage = page;
                          _currentStableId = _displayedAlbums[page].stableId;
                        });
                      },
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: KeyedSubtree(
                            key: ValueKey<String>(
                              _displayedAlbums[index].stableId,
                            ),
                            child: cardMode
                                ? _RandomAlbumsHeroCard(
                                    album: _displayedAlbums[index],
                                    heroContext: widget.heroContext,
                                  )
                                : _DesktopRandomAlbumPage(
                                    album: _displayedAlbums[index],
                                    heroContext: widget.heroContext,
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                  // The wide hero keeps its arrows beside the cover strip so
                  // they never cover the track list's row actions.
                  if (cardMode &&
                      _displayedAlbums.length > 1 &&
                      _currentPage > 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _CarouselEdgeArrow(
                        icon: Icons.chevron_left_rounded,
                        onPressed: () => _animateToPage(_currentPage - 1),
                      ),
                    ),
                  if (cardMode &&
                      _displayedAlbums.length > 1 &&
                      _currentPage < _displayedAlbums.length - 1)
                    Align(
                      alignment: Alignment.centerRight,
                      child: _CarouselEdgeArrow(
                        icon: Icons.chevron_right_rounded,
                        onPressed: () => _animateToPage(_currentPage + 1),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        if (_displayedAlbums.length > 1) ...<Widget>[
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final cardMode = constraints.maxWidth < 640;
              final l10n = AppLocalizations.of(context)!;
              return _DesktopRandomMiniCoverStrip(
                albums: _displayedAlbums,
                currentPage: _currentPage,
                onPageSelected: _animateToPage,
                previousTooltip: l10n.nowPlayingPrevious,
                nextTooltip: l10n.nowPlayingNext,
                showArrows: !cardMode,
              );
            },
          ),
        ],
      ],
    );
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _ShowcaseColourWash(
            coverArtId: _showcaseWashCoverId(currentItem),
            subtle: true,
          ),
        ),
        pager,
      ],
    );
  }
}

class _DesktopRandomAlbumPage extends ConsumerWidget {
  const new({required this.album, required this.heroContext});

  final HomeRandomShowcaseItem album;
  final String heroContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = this.album;
    if (item is HomeRandomShowcaseListenBrainz) {
      return _DesktopListenBrainzPage(item: item);
    }
    final album = item as HomeRandomShowcaseAlbum;
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 330.0;
        final coverWidth = math.min(pageHeight, constraints.maxWidth * 0.4);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: coverWidth,
              height: pageHeight,
              child: _DesktopRandomAlbumVisual(
                album: album,
                heroContext: heroContext,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: pageHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLowest.withValues(
                      alpha: 0.28,
                    ),
                    borderRadius: NavisRadius.xlAll,
                    border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: 0.34),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: _DesktopRandomAlbumSongList(album: album),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DesktopRandomAlbumVisual extends ConsumerWidget {
  const new({required this.album, required this.heroContext});

  final HomeRandomShowcaseAlbum album;
  final String heroContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = artworkBorderRadius(
      coverShape,
      extent: double.infinity,
    );
    final heroTag = buildCoverArtHeroTag(
      coverArtId: album.coverArtId,
      context: '${heroContext}_${album.id}_desktop_page',
      entityId: album.id,
    );

    return Material(
      color: Colors.transparent,
      borderRadius: NavisRadius.lgAll,
      child: InkWell(
        borderRadius: NavisRadius.lgAll,
        onTap: () => NavService.openAlbumDetail(
          context,
          ref,
          album.id,
          heroTag: heroTag,
        ),
        onLongPress: () => showAlbumContextMenu(context, ref, album.id),
        onSecondaryTapDown: (details) => showAlbumContextMenu(
          context,
          ref,
          album.id,
          anchor: details.globalPosition,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 4, 2, 4),
          child: SizedBox.expand(
            child: Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(borderRadius: coverRadius),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  HeroCoverArt(
                    coverArtId: album.coverArtId,
                    heroTag: heroTag,
                    size: kCoverArtStandardSize,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.album_outlined,
                    borderRadius: coverRadius,
                    isExternalSource: album.isExternal,
                  ),
                  HeroRouteChrome(
                    heroTag: heroTag,
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        const Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Colors.transparent,
                                  Colors.transparent,
                                  Color(0x66000000),
                                  Color(0xD0000000),
                                ],
                                stops: <double>[0, 0.52, 0.74, 1],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 10,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                album.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      shadows: const <Shadow>[
                                        Shadow(
                                          offset: Offset(0, 1),
                                          blurRadius: 2,
                                          color: Color(0x99000000),
                                        ),
                                      ],
                                    ),
                              ),
                              if (album.artist != null &&
                                  album.artist!.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    album.artist!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: const Color(0xE6FFFFFF),
                                          shadows: const <Shadow>[
                                            Shadow(
                                              offset: Offset(0, 1),
                                              blurRadius: 2,
                                              color: Color(0x99000000),
                                            ),
                                          ],
                                        ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopListenBrainzPage extends ConsumerWidget {
  const new({required this.item});

  final HomeRandomShowcaseListenBrainz item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 330.0;
        final coverWidth = math.min(pageHeight, constraints.maxWidth * 0.4);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              width: coverWidth,
              height: pageHeight,
              child: _ListenBrainzShowcaseVisual(item: item),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: pageHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLowest
                        .withValues(alpha: 0.28),
                    borderRadius: NavisRadius.xlAll,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant
                          .withValues(alpha: 0.34),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: _DesktopListenBrainzSongList(
                      key: ValueKey<String>(item.stableId),
                      item: item,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ListenBrainzShowcaseVisual extends ConsumerWidget {
  const new({required this.item});

  final HomeRandomShowcaseListenBrainz item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: artworkBorderRadius(
          ref.watch(coverArtShapeProvider),
          extent: double.infinity,
        ),
      ),
      child: InkWell(
        onTap: item.isLoading
            ? null
            : () =>
                  _showListenBrainzDiscoverDetail(context, ref, item.playlist!),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (item.isLoading)
              const _ListenBrainzLoadingArtwork()
            else
              _ListenBrainzArtwork(playlist: item.playlist!, size: 480),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(alpha: 0.78),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    item.localizedTitle(AppLocalizations.of(context)!),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.isLoading
                        ? l10n.weeklyPlaylistFetching
                        : _listenBrainzAvailabilityText(item.playlist!, l10n),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Colors.white.withValues(alpha: 0.78)),
                  ),
                ],
              ),
            ),
            if (item.isLoading)
              const Positioned(
                top: 14,
                right: 14,
                child: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DesktopListenBrainzSongList extends ConsumerStatefulWidget {
  const new({required this.item, super.key});

  final HomeRandomShowcaseListenBrainz item;

  @override
  ConsumerState<_DesktopListenBrainzSongList> createState() =>
      _DesktopListenBrainzSongListState();
}

class _DesktopListenBrainzSongListState
    extends ConsumerState<_DesktopListenBrainzSongList> {
  final ScrollController _scrollController = ScrollController();
  var _hadRecommendations = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final item = widget.item;
    final recommendations = item.playlist?.recommendations ?? const [];
    if (recommendations.isNotEmpty) {
      _hadRecommendations = true;
    }
    if ((item.isLoading || item.playlist == null) && !_hadRecommendations) {
      return Center(
        child: Text(
          l10n.weeklyPlaylistLoading,
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    if (recommendations.isEmpty) {
      return Center(
        child: Text(
          l10n.weeklyPlaylistNoTracksYet,
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      key: PageStorageKey<String>('lb-desktop-songs-${item.stableId}'),
      controller: _scrollController,
      padding: EdgeInsets.zero,
      itemCount: recommendations.length,
      itemBuilder: (context, index) {
        final recommendation = recommendations[index];
        return _ListenBrainzRecommendationTile(
          recommendation: recommendation,
          index: index + 1,
          // Numbered hero list without artwork: denser rows.
          minHeight: 48,
          onPlay: (_) => _playWeeklyRecommendation(ref, recommendations, index),
          onSearch: (track) {
            NavService.openSearch(
              context,
              ref,
              '${track.title} ${track.creator ?? ''}'.trim(),
            );
          },
        );
      },
    );
  }
}

/// Plays the weekly-playlist recommendation at [index]. With Album Queue on
/// the whole playlist's matched songs (on the server or remote) are queued
/// from that song, like an album; otherwise only that song plays. Match
/// flows stay collapsed: the playlist already chose these songs.
void _playWeeklyRecommendation(
  WidgetRef ref,
  List<ListenBrainzResolvedRecommendation> recommendations,
  int index,
) {
  final playback = listenBrainzPlaybackFrom(recommendations, index);
  if (playback == null) return;
  final queueAll =
      ref.read(albumQueueEnabledProvider) && playback.songs.length > 1;
  ref
      .read(queueProvider.notifier)
      .replaceWithSongs(
        queueAll ? playback.songs : <Song>[playback.songs[playback.startIndex]],
        startIndex: queueAll ? playback.startIndex : 0,
        expandMatchFlows: false,
      )
      .ignore();
}

class _ListenBrainzLoadingArtwork extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.surfaceContainerHighest),
      child: Center(
        child: Icon(
          Icons.graphic_eq_rounded,
          size: 72,
          color: colors.onSurfaceVariant.withValues(alpha: 0.72),
        ),
      ),
    );
  }
}

class _DesktopRandomAlbumSongList extends ConsumerWidget {
  const new({required this.album});

  final HomeRandomShowcaseAlbum album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final albumAsync = ref.watch(albumProvider(album.id));
    final fallbackAsync = ref.watch(songByIdProvider(album.id));
    final albumData = albumAsync.asData?.value;
    final fallbackSong = fallbackAsync.asData?.value;
    final allSongs = _resolveDesktopRandomSongs(
      albumSongs: albumData?.songs,
      fallbackSong: fallbackSong,
    );
    final waitingForData =
        (albumAsync.isLoading || fallbackAsync.isLoading) &&
        albumData == null &&
        fallbackSong == null;

    if (waitingForData) {
      return Center(
        child: Text(
          l10n.commonLoading,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }

    if (allSongs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              l10n.homeRandomEmptySubtitle,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () =>
                  NavService.openAlbumDetail(context, ref, album.id),
              icon: const Icon(Icons.album_outlined),
              label: Text(l10n.librarySongMenuOpenAlbum),
            ),
          ],
        ),
      );
    }

    final colors = Theme.of(context).colorScheme;
    Future<void> queueAll({required bool shuffle}) {
      final songs = <SongsTableData>[...allSongs];
      if (shuffle) songs.shuffle();
      ref
          .read(librarySyncControllerProvider.notifier)
          .registerAlbumInteraction(album.id);
      return ref.read(queueProvider.notifier).replaceWithTableData(songs);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 0, 6),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _showcaseMetaLine(l10n, album),
                  key: const ValueKey<String>('home-random-desktop-reason'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
              ),
              EntityActionBar(
                compact: true,
                playKey: const ValueKey<String>('home-random-desktop-play'),
                shuffleKey: const ValueKey<String>(
                  'home-random-desktop-shuffle',
                ),
                onPlay: () => unawaited(queueAll(shuffle: false)),
                onShuffle: () => unawaited(queueAll(shuffle: true)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            key: ValueKey<String>('home-random-desktop-song-list-${album.id}'),
            padding: EdgeInsets.zero,
            itemCount: allSongs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (context, index) {
              final song = allSongs[index];
              return _DesktopRandomAlbumSongRow(
                song: song,
                albumTracks: allSongs,
                queueStartIndex: index,
                displayIndex: index + 1,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DesktopRandomAlbumSongRow extends ConsumerWidget {
  const new({
    required this.song,
    required this.albumTracks,
    required this.queueStartIndex,
    required this.displayIndex,
  });

  final SongsTableData song;
  final List<SongsTableData> albumTracks;
  final int queueStartIndex;
  final int displayIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playbackState = ref.watch(
      songPlaybackIndicatorStateProvider(song.id),
    );
    final row = AdaptiveTrackRow(
      key: ValueKey<String>('home-random-desktop-song-row-${song.id}'),
      title: song.title,
      artist: song.artistName,
      album: song.albumName,
      duration: song.duration,
      selected: playbackState.isSelected,
      isRemote: song.isExternal,
      leadingExtent: 24,
      leadingGap: 6,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      // Numbered hero list without artwork: denser rows.
      minHeight: 48,
      leading: Center(
        child: playbackState.isSelected
            ? SongPlaybackMarker(state: playbackState, size: 17)
            : Text('$displayIndex', textAlign: TextAlign.center),
      ),
      actions: DesktopSongActions(song: song, keyPrefix: 'home-random-desktop'),
      onTap: () => unawaited(
        ref
            .read(queueProvider.notifier)
            .replaceWithTableData(
              albumTracks,
              startIndex: queueStartIndex,
              autoPlay: true,
            ),
      ),
      onSecondaryTapDown: (details) => unawaited(
        showSongContextMenu(context, ref, song, anchor: details.globalPosition),
      ),
    );
    return SongPlaybackSemantics(state: playbackState, child: row);
  }
}

class _DesktopRandomMiniCoverStrip extends ConsumerWidget {
  const new({
    required this.albums,
    required this.currentPage,
    required this.onPageSelected,
    required this.previousTooltip,
    required this.nextTooltip,
    this.showArrows = false,
  });

  final List<HomeRandomShowcaseItem> albums;
  final int currentPage;
  final ValueChanged<int> onPageSelected;
  final String previousTooltip;
  final String nextTooltip;
  final bool showArrows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = artworkBorderRadius(
      coverShape,
      extent: double.infinity,
    );
    final colors = Theme.of(context).colorScheme;

    final scroller = MouseDragScroll(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(albums.length, (index) {
            final item = albums[index];
            final active = currentPage == index;
            return Padding(
              padding: EdgeInsets.only(
                right: index == albums.length - 1 ? 0 : 6,
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: coverRadius,
                child: InkWell(
                  key: ValueKey<String>(
                    'home-random-desktop-mini-cover-$index',
                  ),
                  borderRadius: coverRadius,
                  onTap: () => onPageSelected(index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    width: active ? 34 : 32,
                    height: active ? 34 : 32,
                    padding: const EdgeInsets.all(1.2),
                    decoration: BoxDecoration(
                      borderRadius: coverRadius,
                      border: Border.all(
                        color: active
                            ? colors.primary
                            : colors.outlineVariant.withValues(alpha: 0.42),
                        width: active ? 1.6 : 1.0,
                      ),
                    ),
                    child: _RandomMiniCover(
                      item: item,
                      borderRadius: coverRadius,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
    if (!showArrows) {
      return SizedBox(
        height: 42,
        child: Align(alignment: Alignment.center, child: scroller),
      );
    }
    const arrowExtent = 36.0;
    const arrowSlot = SizedBox.square(dimension: arrowExtent + 4);
    return SizedBox(
      height: 42,
      child: Center(
        child: Row(
          key: const ValueKey<String>('home-random-desktop-strip-controls'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (currentPage > 0)
              _CarouselEdgeArrow(
                key: const ValueKey<String>('home-random-desktop-previous'),
                icon: Icons.chevron_left_rounded,
                extent: arrowExtent,
                elevation: 0,
                tooltip: previousTooltip,
                onPressed: () => onPageSelected(currentPage - 1),
              )
            else
              arrowSlot,
            const SizedBox(width: 8),
            Flexible(child: scroller),
            const SizedBox(width: 8),
            if (currentPage < albums.length - 1)
              _CarouselEdgeArrow(
                key: const ValueKey<String>('home-random-desktop-next'),
                icon: Icons.chevron_right_rounded,
                extent: arrowExtent,
                elevation: 0,
                tooltip: nextTooltip,
                onPressed: () => onPageSelected(currentPage + 1),
              )
            else
              arrowSlot,
          ],
        ),
      ),
    );
  }
}

class _RandomMiniCover extends StatelessWidget {
  const new({required this.item, required this.borderRadius});

  final HomeRandomShowcaseItem item;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    if (item is HomeRandomShowcaseListenBrainz) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: item.isLoading
            ? const _ListenBrainzLoadingArtwork()
            : _ListenBrainzArtwork(playlist: item.playlist!, size: 96),
      );
    }
    final album = item as HomeRandomShowcaseAlbum;
    return ClipRRect(
      borderRadius: borderRadius,
      child: CoverArtImage(
        coverArtId: album.coverArtId,
        size: 96,
        fit: BoxFit.cover,
        placeholderIcon: Icons.album_outlined,
        isExternalSource: album.isExternal,
      ),
    );
  }
}

List<SongsTableData> _resolveDesktopRandomSongs({
  required List<SongsTableData>? albumSongs,
  required SongsTableData? fallbackSong,
}) {
  final candidates = <SongsTableData>[
    ...(albumSongs ?? const <SongsTableData>[]),
    if ((albumSongs == null || albumSongs.isEmpty) && fallbackSong != null)
      fallbackSong,
  ];
  candidates.sort(_compareDesktopRandomSongs);
  return List<SongsTableData>.unmodifiable(candidates);
}

int _compareDesktopRandomSongs(SongsTableData a, SongsTableData b) {
  final discComparison = (a.discNumber ?? 1 << 20).compareTo(
    b.discNumber ?? 1 << 20,
  );
  if (discComparison != 0) {
    return discComparison;
  }

  final trackComparison = (a.track ?? 1 << 20).compareTo(b.track ?? 1 << 20);
  if (trackComparison != 0) {
    return trackComparison;
  }

  final titleComparison = a.title.toLowerCase().compareTo(
    b.title.toLowerCase(),
  );
  if (titleComparison != 0) {
    return titleComparison;
  }

  return a.id.compareTo(b.id);
}

class _RandomAlbumsHeroCarousel extends ConsumerStatefulWidget {
  const new({
    required this.albums,
    required this.heroContext,
    required this.desktopMode,
    required this.adaptiveLayoutClass,
    this.density = _HomeSectionDensity.comfortable,
    this.freezeListUpdates = false,
  });

  final List<HomeRandomShowcaseItem> albums;
  final String heroContext;
  final bool desktopMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final _HomeSectionDensity density;
  final bool freezeListUpdates;

  @override
  ConsumerState<_RandomAlbumsHeroCarousel> createState() =>
      _RandomAlbumsHeroCarouselState();
}

class _RandomAlbumsHeroCarouselState
    extends ConsumerState<_RandomAlbumsHeroCarousel>
    with WidgetsBindingObserver {
  static const int _kVirtualLoopCycles = 10000;
  late PageController _pageController;
  double _viewportFraction = 0.66;
  double? _pendingViewportFraction;
  Timer? _viewportFractionTimer;
  late List<HomeRandomShowcaseItem> _displayedAlbums;
  late final RecommendationAutoAdvance _autoAdvance;
  final GlobalKey _viewportKey = GlobalKey();
  ScrollPosition? _homeScrollPosition;
  bool _visibilityCheckPending = false;
  bool _heroVisible = false;
  bool _gestureActive = false;
  bool _pageScrolling = false;
  bool _manualPageScroll = false;
  bool _enabled = false;
  bool _homeActive = false;
  bool _desktopRuntime = true;
  bool _routeCurrent = false;
  bool _resumed = true;
  bool _overlayFree = true;
  bool _reduceMotion = false;
  int _currentVirtualPage = 0;
  int _currentLogicalPage = 0;

  @override
  void initState() {
    super.initState();
    _displayedAlbums = List<HomeRandomShowcaseItem>.unmodifiable(widget.albums);
    final initialPage = _initialVirtualPage(_displayedAlbums.length);
    _currentVirtualPage = initialPage;
    _currentLogicalPage = _logicalIndexForPage(
      initialPage,
      _displayedAlbums.length,
    );
    _pageController = PageController(
      viewportFraction: _viewportFraction,
      initialPage: initialPage,
    );
    _autoAdvance = RecommendationAutoAdvance(
      onAdvance: () {
        if (mounted &&
            _pageController.hasClients &&
            _displayedAlbums.length > 1) {
          _pageController.animateToPage(
            _currentVirtualPage + 1,
            duration: const Duration(milliseconds: 460),
            curve: Curves.easeOutCubic,
          );
        }
      },
    );
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    ref.listenManual(homeRecommendationsAutoAdvanceProvider, (_, enabled) {
      _enabled = enabled;
      _updateAutoAdvance();
    }, fireImmediately: true);
    void checkOverlays() {
      _overlayFree =
          ref.read(playerOverlayStackProvider).isEmpty &&
          !ref.read(quickSearchOverlayVisibleProvider);
      _updateAutoAdvance();
    }

    ref.listenManual(
      playerOverlayStackProvider,
      (_, next) => checkOverlays(),
      fireImmediately: true,
    );
    ref.listenManual(
      quickSearchOverlayVisibleProvider,
      (_, next) => checkOverlays(),
      fireImmediately: true,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MotionPolicy.of(context).reduceMotion;
    _desktopRuntime = resolveAdaptiveContextFor(context).desktopRuntime;
    _homeActive = HomeActivityScope.of(context) && TickerMode.of(context);
    _routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final position = Scrollable.maybeOf(context)?.position;
    if (_homeScrollPosition != position) {
      _homeScrollPosition?.removeListener(_onHomeScroll);
      _homeScrollPosition = position;
      position?.addListener(_onHomeScroll);
    }
    _updateAutoAdvance();
    _scheduleVisibilityCheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _updateAutoAdvance();
  }

  void _onHomeScroll() {
    _heroVisible = false;
    _updateAutoAdvance();
    _autoAdvance.recordInteraction();
    _scheduleVisibilityCheck();
  }

  void _scheduleVisibilityCheck() {
    if (_visibilityCheckPending) return;
    _visibilityCheckPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckPending = false;
      if (!mounted) return;
      final box = _viewportKey.currentContext?.findRenderObject();
      var visible = false;
      if (box is RenderBox && box.hasSize && box.size.height > 0) {
        final bounds = box.localToGlobal(Offset.zero) & box.size;
        final Object? viewport = RenderAbstractViewport.maybeOf(box);
        final clip = viewport is RenderBox && viewport.hasSize
            ? viewport.localToGlobal(Offset.zero) & viewport.size
            : Offset.zero & MediaQuery.sizeOf(context);
        final intersection = bounds.intersect(clip);
        visible =
            !intersection.isEmpty &&
            intersection.height >= bounds.height * .5 &&
            intersection.width > 0;
      }
      _heroVisible = visible;
      _updateAutoAdvance();
    });
  }

  void _updateAutoAdvance() {
    _autoAdvance.setEligible(
      eligible:
          _enabled &&
          !widget.desktopMode &&
          !_desktopRuntime &&
          _displayedAlbums.length > 1 &&
          _resumed &&
          _homeActive &&
          _routeCurrent &&
          _heroVisible &&
          _overlayFree &&
          !_gestureActive &&
          !_pageScrolling &&
          !_reduceMotion,
    );
  }

  @override
  void didUpdateWidget(covariant _RandomAlbumsHeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incomingAlbums = List<HomeRandomShowcaseItem>.unmodifiable(
      widget.albums,
    );

    if (oldWidget.desktopMode != widget.desktopMode) {
      _replacePageController(_viewportFraction);
    }

    if (widget.freezeListUpdates && _displayedAlbums.isNotEmpty) {
      return;
    }

    final oldIds = _displayedAlbums.map((album) => album.stableId).toList();
    final newIds = incomingAlbums.map((album) => album.stableId).toList();
    final contentChanged = !listEquals(oldIds, newIds);
    if (!contentChanged) {
      if (_homeRandomShowcaseItemsVisuallyChanged(
        _displayedAlbums,
        incomingAlbums,
      )) {
        setState(() {
          _displayedAlbums = incomingAlbums;
        });
      }
      return;
    }

    final previousDisplayedAlbums = _displayedAlbums;
    _displayedAlbums = incomingAlbums;

    if (_displayedAlbums.isEmpty) {
      _currentVirtualPage = 0;
      _currentLogicalPage = 0;
      _updateAutoAdvance();
      return;
    }

    String? currentAlbumId;
    if (previousDisplayedAlbums.isNotEmpty) {
      currentAlbumId =
          previousDisplayedAlbums[_currentLogicalPage.clamp(
                0,
                previousDisplayedAlbums.length - 1,
              )]
              .stableId;
    }
    var nextLogicalPage = _currentLogicalPage.clamp(
      0,
      _displayedAlbums.length - 1,
    );
    if (currentAlbumId != null) {
      final matchedIndex = newIds.indexOf(currentAlbumId);
      if (matchedIndex != -1) {
        nextLogicalPage = matchedIndex;
      }
    }
    nextLogicalPage = nextLogicalPage.clamp(0, _displayedAlbums.length - 1);
    _currentLogicalPage = nextLogicalPage;
    _currentVirtualPage = _rebaseVirtualPage(nextLogicalPage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(_currentVirtualPage);
      }
      if (mounted) _scheduleVisibilityCheck();
    });
    _updateAutoAdvance();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _homeScrollPosition?.removeListener(_onHomeScroll);
    _autoAdvance.dispose();
    _viewportFractionTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _pauseAutoAdvanceTemporarily() => _autoAdvance.recordInteraction();

  int _initialVirtualPage(int albumCount) {
    if (albumCount <= 1) {
      return 0;
    }
    return albumCount * _kVirtualLoopCycles;
  }

  int _logicalIndexForPage(int page, int albumCount) {
    if (albumCount <= 0) {
      return 0;
    }
    final modulo = page % albumCount;
    return modulo < 0 ? modulo + albumCount : modulo;
  }

  int _rebaseVirtualPage(int logicalPage) {
    final albumCount = _displayedAlbums.length;
    if (albumCount <= 1) {
      return 0;
    }
    final cycle = _currentVirtualPage ~/ albumCount;
    return cycle * albumCount + logicalPage;
  }

  /// Side of the focused square cover: a generous share of the width, but
  /// capped so tablets and landscape phones keep the whole section in view.
  double _coverSideFor(double availableWidth, Size screen) {
    final compact = widget.density == _HomeSectionDensity.compact;
    final cap = switch (widget.adaptiveLayoutClass) {
      AdaptiveLayoutClass.phoneCompact => compact ? 236.0 : 260.0,
      AdaptiveLayoutClass.tabletMedium => compact ? 280.0 : 300.0,
      AdaptiveLayoutClass.tabletExpanded => compact ? 300.0 : 320.0,
    };
    return math.min(
      math.min(availableWidth * 0.62, cap),
      math.max(140.0, screen.height * 0.42),
    );
  }

  /// Page controllers fix their viewport fraction, so a new width that needs
  /// a different peek swaps in a controller at the same page. The swap waits
  /// until the width has settled and no drag or page animation is running,
  /// so resizing a window or rotating a phone replaces it once, not per frame.
  void _syncViewportFraction(double fraction) {
    if ((fraction - _viewportFraction).abs() < 0.005) {
      _pendingViewportFraction = null;
      _viewportFractionTimer?.cancel();
      return;
    }
    if (_pendingViewportFraction == fraction) return;
    _pendingViewportFraction = fraction;
    _viewportFractionTimer?.cancel();
    _viewportFractionTimer = Timer(
      const Duration(milliseconds: 200),
      _applyPendingViewportFraction,
    );
  }

  void _applyPendingViewportFraction() {
    final fraction = _pendingViewportFraction;
    if (!mounted || fraction == null) return;
    if (_gestureActive || _pageScrolling) {
      _viewportFractionTimer = Timer(
        const Duration(milliseconds: 200),
        _applyPendingViewportFraction,
      );
      return;
    }
    _pendingViewportFraction = null;
    setState(() => _replacePageController(fraction));
  }

  void _replacePageController(double fraction) {
    final previous = _pageController;
    _viewportFraction = fraction;
    _pageController = PageController(
      viewportFraction: fraction,
      initialPage: _currentVirtualPage,
    );
    // The old controller is still attached until the next frame rebuilds the
    // PageView with the new one.
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  @override
  Widget build(BuildContext context) {
    if (_displayedAlbums.isEmpty) {
      return const SizedBox.shrink();
    }

    _scheduleVisibilityCheck();
    final motion = MotionPolicy.of(context);
    final currentIndex = _currentLogicalPage.clamp(
      0,
      _displayedAlbums.length - 1,
    );
    final currentItem = _displayedAlbums[currentIndex];
    final currentPageLabel = 'home-random-hero-carousel-page-$currentIndex';
    const shadowTop = 8.0;
    const shadowBottom = 24.0;
    const peekGap = 16.0;

    final section = Column(
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            final side = _coverSideFor(
              availableWidth,
              MediaQuery.sizeOf(context),
            );
            _syncViewportFraction(
              ((side + peekGap) / availableWidth).clamp(0.2, 1.0),
            );

            final carouselViewport = PageView.builder(
              key: const ValueKey<String>('home-random-hero-carousel'),
              controller: _pageController,
              // Full-width carousel: let cover shadows fall off softly
              // instead of being cut at the viewport edges.
              clipBehavior: Clip.none,
              itemCount: _displayedAlbums.length <= 1 ? 1 : null,
              onPageChanged: (index) {
                if (!mounted) {
                  return;
                }
                setState(() {
                  _currentVirtualPage = index;
                  _currentLogicalPage = _logicalIndexForPage(
                    index,
                    _displayedAlbums.length,
                  );
                });
              },
              itemBuilder: (context, index) {
                final logicalIndex = _logicalIndexForPage(
                  index,
                  _displayedAlbums.length,
                );
                final card = SizedBox.square(
                  dimension: side,
                  child: _ShowcaseCoverCard(
                    item: _displayedAlbums[logicalIndex],
                    heroContext: widget.heroContext,
                    focused: _currentVirtualPage == index,
                  ),
                );
                // Neighbours shrink and dim with the swipe itself rather
                // than snapping once the page settles.
                return Center(
                  child: AnimatedBuilder(
                    animation: _pageController,
                    child: card,
                    builder: (context, child) {
                      final position =
                          _pageController.hasClients &&
                              _pageController.position.hasContentDimensions
                          ? _pageController.page ??
                                _currentVirtualPage.toDouble()
                          : _currentVirtualPage.toDouble();
                      final distance = (position - index).abs().clamp(0.0, 1.0);
                      return Opacity(
                        opacity: 1 - 0.45 * distance,
                        child: Transform.scale(
                          scale: 1 - 0.14 * distance,
                          child: child,
                        ),
                      );
                    },
                  ),
                );
              },
            );

            final viewportChild = Listener(
              onPointerDown: (_) {
                _gestureActive = true;
                _pauseAutoAdvanceTemporarily();
                _updateAutoAdvance();
              },
              onPointerUp: (_) {
                _gestureActive = false;
                _pauseAutoAdvanceTemporarily();
                _updateAutoAdvance();
              },
              onPointerCancel: (_) {
                _gestureActive = false;
                _pauseAutoAdvanceTemporarily();
                _updateAutoAdvance();
              },
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollStartNotification) {
                    _pageScrolling = true;
                    _manualPageScroll = notification.dragDetails != null;
                    _updateAutoAdvance();
                  } else if (notification is ScrollEndNotification) {
                    _pageScrolling = false;
                    if (_manualPageScroll) _pauseAutoAdvanceTemporarily();
                    _manualPageScroll = false;
                    _updateAutoAdvance();
                  }
                  return false;
                },
                child: carouselViewport,
              ),
            );

            return SizedBox(
              key: _viewportKey,
              height: side + shadowTop + shadowBottom,
              child: Padding(
                padding: const EdgeInsets.only(
                  top: shadowTop,
                  bottom: shadowBottom,
                ),
                child: viewportChild,
              ),
            );
          },
        ),
        _ShowcaseInfoPanel(item: currentItem, heroContext: widget.heroContext),
        if (_displayedAlbums.length > 1) ...[
          const SizedBox(height: NavisSpace.sm),
          Wrap(
            key: ValueKey<String>(currentPageLabel),
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: List<Widget>.generate(
              _displayedAlbums.length,
              (index) => AnimatedContainer(
                duration: motion.feedback,
                curve: Curves.easeOutCubic,
                width: currentIndex == index ? 16 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: currentIndex == index
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.35),
                  borderRadius: NavisRadius.pillAll,
                ),
              ),
            ),
          ),
        ],
      ],
    );

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _ShowcaseColourWash(
            coverArtId: _showcaseWashCoverId(currentItem),
          ),
        ),
        section,
      ],
    );
  }
}

class _RandomAlbumsHeroCard extends ConsumerWidget {
  const new({required this.album, required this.heroContext});

  final HomeRandomShowcaseItem album;
  final String heroContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = this.album;
    if (item is HomeRandomShowcaseListenBrainz) {
      return _RandomListenBrainzHeroCard(item: item);
    }
    final album = item as HomeRandomShowcaseAlbum;
    final heroTag = buildCoverArtHeroTag(
      coverArtId: album.coverArtId,
      context: '${heroContext}_hero',
      entityId: album.id,
    );
    final metadataParts = <String>[
      if (album.year != null && album.year! > 0) album.year.toString(),
      if (album.songCount != null && album.songCount! > 0)
        AppLocalizations.of(context)!.playlistsSongCount(album.songCount!),
    ];
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: artworkBorderRadius(
          ref.watch(coverArtShapeProvider),
          extent: double.infinity,
        ),
      ),
      child: InkWell(
        onTap: () => NavService.openAlbumDetail(
          context,
          ref,
          album.id,
          heroTag: heroTag,
        ),
        onLongPress: () => showAlbumContextMenu(context, ref, album.id),
        onSecondaryTapDown: (details) => showAlbumContextMenu(
          context,
          ref,
          album.id,
          anchor: details.globalPosition,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            HeroCoverArt(
              coverArtId: album.coverArtId,
              heroTag: heroTag,
              size: kCoverArtStandardSize,
              fit: BoxFit.cover,
              placeholderIcon: Icons.album_outlined,
              borderRadius: artworkBorderRadius(
                ref.watch(coverArtShapeProvider),
                extent: double.infinity,
              ),
              isExternalSource: album.isExternal,
            ),
            HeroRouteChrome(
              heroTag: heroTag,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Colors.black.withValues(alpha: 0),
                          Colors.black.withValues(alpha: 0.76),
                        ],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 44, 14, 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            album.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          if (album.artist != null &&
                              album.artist!.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                album.artist!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.86,
                                      ),
                                    ),
                              ),
                            ),
                          if (metadataParts.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                metadataParts.join(' • '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.72,
                                      ),
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RandomListenBrainzHeroCard extends ConsumerWidget {
  const new({required this.item});

  final HomeRandomShowcaseListenBrainz item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: artworkBorderRadius(
          ref.watch(coverArtShapeProvider),
          extent: double.infinity,
        ),
      ),
      child: InkWell(
        onTap: item.isLoading
            ? null
            : () =>
                  _showListenBrainzDiscoverDetail(context, ref, item.playlist!),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (item.isLoading)
              const _ListenBrainzLoadingArtwork()
            else
              _ListenBrainzArtwork(playlist: item.playlist!, size: 420),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(alpha: 0.78),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 44, 14, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.localizedTitle(AppLocalizations.of(context)!),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.isLoading
                          ? l10n.weeklyPlaylistFetching
                          : _listenBrainzAvailabilityText(item.playlist!, l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.86),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.isLoading
                          ? l10n.weeklyPlaylistLoading
                          : item.playlist!.matchingComplete
                          ? l10n.weeklyPlaylistReady
                          : l10n.weeklyPlaylistMatching,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (item.isLoading)
              const Positioned(
                top: 14,
                right: 14,
                child: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _listenBrainzAvailabilityText(
  ListenBrainzDiscoverPlaylist playlist,
  AppLocalizations l10n,
) {
  if (!playlist.matchingComplete) {
    return l10n.weeklyPlaylistAvailableMatching(playlist.matchedCount);
  }
  return l10n.weeklyPlaylistAvailableCount(
    playlist.matchedCount,
    playlist.totalCount,
  );
}

/// A small square card for server [Album] objects (same visual as [AlbumCard]
/// but accepts the API model directly).
class _ServerAlbumCard extends StatelessWidget {
  const new({
    required this.name,
    required this.borderRadius,
    this.width = 150,
    this.artist,
    this.coverArtId,
    this.heroTag,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.isExternalSource = false,
  });

  final String name;
  final double width;
  final BorderRadius borderRadius;
  final String? artist;
  final String? coverArtId;
  final String? heroTag;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;
  final bool isExternalSource;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 1,
        child: Card(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: borderRadius),
          child: InkWell(
            onTap: onTap,
            onSecondaryTapDown: onSecondaryTapDown,
            onLongPress: onLongPress == null
                ? null
                : () {
                    unawaited(HapticFeedback.mediumImpact());
                    onLongPress!();
                  },
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (heroTag != null)
                  HeroCoverArt(
                    coverArtId: coverArtId,
                    heroTag: heroTag!,
                    size: kCoverArtStandardSize,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.album_outlined,
                    borderRadius: borderRadius,
                    isExternalSource: isExternalSource,
                  )
                else
                  CoverArtImage(
                    coverArtId: coverArtId,
                    size: kCoverArtStandardSize,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.album_outlined,
                    isExternalSource: isExternalSource,
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: HeroRouteChrome(
                    heroTag: heroTag,
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
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.75,
                                      ),
                                      fontWeight: FontWeight.w400,
                                    ),
                              ),
                            ],
                          ],
                        ),
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
  const new({
    required this.songs,
    required this.onTap,
    this.density = _HomeSectionDensity.comfortable,
    this.desktopMode = false,
    this.adaptiveLayoutClass = AdaptiveLayoutClass.phoneCompact,
    this.compactWideLandscapeMode = false,
  });

  static const double _compactWideTwoColumnMinWidth = 900;
  static const double _compactWideColumnGap = 8;

  final List<SongsTableData> songs;
  final void Function(SongsTableData song) onTap;
  final _HomeSectionDensity density;
  final bool desktopMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final bool compactWideLandscapeMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compactDensity = density == _HomeSectionDensity.compact;
    final tabletMode = adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;

    Widget songTile(SongsTableData song) => TrackListTile(
      key: ValueKey(song.id),
      song: song,
      showAlbumArt: true,
      actionExtent: desktopMode ? null : 0,
      contentPadding: EdgeInsets.symmetric(
        horizontal: tabletMode ? 12 : 8,
        vertical: compactDensity ? 4 : 8,
      ),
      trailing: desktopMode
          ? DesktopSongActions(song: song, keyPrefix: 'home-song')
          : null,
      onTap: () => onTap(song),
      onLongPress: () => showSongContextMenu(context, ref, song),
      onSecondaryTapDown: (details) => showSongContextMenu(
        context,
        ref,
        song,
        anchor: details.globalPosition,
      ),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tabletMode ? 4 : 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useTwoColumns =
              compactWideLandscapeMode &&
              constraints.maxWidth >= _compactWideTwoColumnMinWidth;
          if (useTwoColumns) {
            return Column(
              key: const ValueKey<String>('homeSongListTwoColumnGrid'),
              children: [
                for (var index = 0; index < songs.length; index += 2)
                  Padding(
                    padding: EdgeInsets.only(bottom: compactDensity ? 2 : 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: songTile(songs[index])),
                        const SizedBox(width: _compactWideColumnGap),
                        Expanded(
                          child: index + 1 < songs.length
                              ? songTile(songs[index + 1])
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          }
          return Column(
            key: const ValueKey<String>('homeSongListSingleColumn'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[for (final song in songs) songTile(song)],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home action row
// ─────────────────────────────────────────────────────────────────────────────

enum _HomeActionRowVariant { mobile, desktop, compactWide }

/// Whether Instant Radio has anything to play under the Home filters. One
/// `EXISTS` query instead of loading the whole catalog on every song write.
final _homeRadioAvailableProvider = StreamProvider.autoDispose
    .family<bool, ({bool likedOnly, bool downloadedOnly})>((ref, filters) {
      return ref
          .watch(navisDatabaseProvider)
          .libraryDao
          .watchHasRadioCandidate(
            likedOnly: filters.likedOnly,
            downloadedOnly: filters.downloadedOnly,
          );
    });

class _HomeActionRow extends ConsumerWidget {
  const new({required this.variant});

  final _HomeActionRowVariant variant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final likedOnly = ref.watch(homeLikedOnlyFilterProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final radioState = ref.watch(personalRadioProvider);
    final radioAvailable =
        ref
            .watch(
              _homeRadioAvailableProvider((
                likedOnly: likedOnly,
                downloadedOnly: downloadedOnly,
              )),
            )
            .asData
            ?.value ??
        false;

    void toggleLikedOnly() {
      ref.read(homeLikedOnlyFilterProvider.notifier).enabled = !likedOnly;
    }

    void toggleDownloadedOnly() {
      ref.read(downloadedOnlyFilterProvider.notifier).enabled = !downloadedOnly;
    }

    // Desktop View has no expanded player; its Now Playing surface is the
    // lyrics overlay, which radio does not open.
    void expandPlayer() {
      if (resolveAdaptiveContextFor(context).desktopRuntime) {
        return;
      }
      ref.read(playerOverlayStackProvider.notifier).expand();
    }

    Future<void> startInstantRadio() async {
      if (radioState.busy) return;
      if (radioState.retryCount >= 5) {
        final result = await ref.read(personalRadioProvider.notifier).retry();
        if (context.mounted && result.succeeded) {
          expandPlayer();
        }
        return;
      }
      if (radioState.active) {
        ref.read(personalRadioProvider.notifier).stop();
        return;
      }
      final result = await ref
          .read(personalRadioProvider.notifier)
          .start(
            filters: RadioFilters(
              likedOnly: likedOnly,
              downloadedOnly: downloadedOnly,
            ),
          );
      if (!context.mounted) return;
      if (result.succeeded) {
        expandPlayer();
      } else {
        showAppNotice(
          context,
          message: result.issue == RecommendationIssue.empty
              ? l10n.instantRadioEmpty
              : l10n.instantRadioError,
          level: AppNoticeLevel.error,
        );
      }
    }

    // Icon button constraints: pin to 40×40 so the extra 48×48 tap-target
    // padding doesn't consume layout space inside the Row.
    const iconConstraints = BoxConstraints.tightFor(width: 40, height: 40);

    if (variant == _HomeActionRowVariant.desktop ||
        variant == _HomeActionRowVariant.compactWide) {
      return Row(
        key: variant == _HomeActionRowVariant.compactWide
            ? const ValueKey<String>('homeCompactWideActionRow')
            : null,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: l10n.libraryLikedOnlyFilter,
            constraints: variant == _HomeActionRowVariant.compactWide
                ? iconConstraints
                : null,
            icon: Icon(
              likedOnly
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
            ),
            color: likedOnly ? colorScheme.primary : null,
            onPressed: toggleLikedOnly,
          ),
          IconButton(
            tooltip: l10n.libraryDownloadedOnlyFilter,
            constraints: variant == _HomeActionRowVariant.compactWide
                ? iconConstraints
                : null,
            icon: Icon(
              downloadedOnly
                  ? Icons.download_done_rounded
                  : Icons.download_rounded,
            ),
            color: downloadedOnly ? colorScheme.primary : null,
            onPressed: toggleDownloadedOnly,
          ),
          IconButton(
            tooltip: radioState.retryCount >= 5
                ? l10n.instantRadioRetry
                : radioState.active
                ? l10n.instantRadioStop
                : l10n.instantRadioAction,
            constraints: variant == _HomeActionRowVariant.compactWide
                ? iconConstraints
                : null,
            icon: radioState.busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    radioState.retryCount >= 5
                        ? Icons.refresh_rounded
                        : radioState.active
                        ? Icons.stop_rounded
                        : Icons.radio_rounded,
                  ),
            onPressed: (radioAvailable || radioState.active) && !radioState.busy
                ? startInstantRadio
                : null,
          ),
        ],
      );
    }

    return Padding(
      key: const ValueKey<String>('homeMobileActionRow'),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: <Widget>[
          IconButton.filledTonal(
            isSelected: likedOnly,
            constraints: iconConstraints,
            icon: const Icon(Icons.favorite_border_rounded),
            selectedIcon: const Icon(Icons.favorite_rounded),
            tooltip: l10n.libraryLikedOnlyFilter,
            onPressed: toggleLikedOnly,
          ),
          const SizedBox(width: 4),
          IconButton.filledTonal(
            isSelected: downloadedOnly,
            constraints: iconConstraints,
            icon: const Icon(Icons.download_rounded),
            selectedIcon: const Icon(Icons.download_done_rounded),
            tooltip: l10n.libraryDownloadedOnlyFilter,
            onPressed: toggleDownloadedOnly,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                Flexible(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.secondaryContainer,
                      foregroundColor: colorScheme.onSecondaryContainer,
                      iconColor: colorScheme.onSecondaryContainer,
                      disabledBackgroundColor: colorScheme.onSurface.withValues(
                        alpha: 0.12,
                      ),
                      disabledForegroundColor: colorScheme.onSurface.withValues(
                        alpha: 0.38,
                      ),
                      iconSize: 18,
                    ),
                    onPressed:
                        (radioAvailable || radioState.active) &&
                            !radioState.busy
                        ? startInstantRadio
                        : null,
                    icon: radioState.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            radioState.retryCount >= 5
                                ? Icons.refresh_rounded
                                : radioState.active
                                ? Icons.stop_rounded
                                : Icons.radio_rounded,
                          ),
                    label: Text(
                      radioState.busy
                          ? l10n.instantRadioLoading
                          : radioState.retryCount >= 5
                          ? l10n.instantRadioRetry
                          : radioState.active
                          ? l10n.instantRadioStop
                          : l10n.instantRadioAction,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
